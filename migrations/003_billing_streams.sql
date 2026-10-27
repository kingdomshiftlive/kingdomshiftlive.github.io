-- Payment receipts and streaming operations. Live billing remains disabled by default.
BEGIN;
CREATE TABLE IF NOT EXISTS public.platform_settings(key text PRIMARY KEY,value text NOT NULL);
ALTER TABLE public.platform_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.platform_settings FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.platform_settings TO service_role;
INSERT INTO public.platform_settings VALUES('payment_environment','disabled') ON CONFLICT DO NOTHING;
CREATE OR REPLACE FUNCTION public.billing_environment() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$SELECT value FROM public.platform_settings WHERE key='payment_environment';$$;
REVOKE ALL ON FUNCTION public.billing_environment() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.billing_environment() TO service_role;

CREATE TABLE IF NOT EXISTS public.checkout_orders(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id text NOT NULL REFERENCES public.profiles(id),request_key uuid NOT NULL,
 environment text NOT NULL DEFAULT 'test' CHECK(environment IN('test','live')),kind text NOT NULL CHECK(kind IN('coins','pro','shop')),product_id text NOT NULL,amount_cents integer NOT NULL CHECK(amount_cents>0),
 credits integer NOT NULL DEFAULT 0 CHECK(credits>=0),item_id uuid REFERENCES public.shop_items(id),seller_id text REFERENCES public.profiles(id),
 stripe_session text UNIQUE,stripe_subscription text,status text NOT NULL DEFAULT 'pending',created_at timestamptz DEFAULT now(),UNIQUE(user_id,request_key));
CREATE TABLE IF NOT EXISTS public.payment_events(id text PRIMARY KEY,order_id uuid REFERENCES public.checkout_orders(id),created_at timestamptz DEFAULT now());
CREATE TABLE IF NOT EXISTS public.coin_ledger(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id text REFERENCES public.profiles(id),delta integer NOT NULL,source text NOT NULL UNIQUE,created_at timestamptz DEFAULT now());
CREATE TABLE IF NOT EXISTS public.purchases(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),order_id uuid UNIQUE REFERENCES public.checkout_orders(id),user_id text REFERENCES public.profiles(id),item_id uuid REFERENCES public.shop_items(id),created_at timestamptz DEFAULT now());
CREATE TABLE IF NOT EXISTS public.billing_subscriptions(id text PRIMARY KEY,user_id text REFERENCES public.profiles(id),status text NOT NULL,created_at timestamptz DEFAULT now());
ALTER TABLE public.gifts ADD COLUMN IF NOT EXISTS request_id uuid;
CREATE UNIQUE INDEX IF NOT EXISTS gift_request_unique ON public.gifts(sender_id,request_id) WHERE request_id IS NOT NULL;
ALTER TABLE public.live_streams ADD COLUMN IF NOT EXISTS lease_expires_at timestamptz DEFAULT now();
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['checkout_orders','payment_events','coin_ledger','purchases','billing_subscriptions'] LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated',t);
  EXECUTE format('GRANT ALL ON public.%I TO service_role',t);
 END LOOP;
END $$;
DROP POLICY IF EXISTS "Own checkout orders" ON public.checkout_orders;
CREATE POLICY "Own checkout orders" ON public.checkout_orders FOR SELECT TO authenticated USING(user_id=(SELECT auth.uid())::text);
DROP POLICY IF EXISTS "Own ledger" ON public.coin_ledger;
CREATE POLICY "Own ledger" ON public.coin_ledger FOR SELECT TO authenticated USING(user_id=(SELECT auth.uid())::text);
DROP POLICY IF EXISTS "Own purchases" ON public.purchases;
CREATE POLICY "Own purchases" ON public.purchases FOR SELECT TO authenticated USING(user_id=(SELECT auth.uid())::text);
GRANT SELECT ON public.checkout_orders,public.coin_ledger,public.purchases TO authenticated;
GRANT SELECT,INSERT,UPDATE ON public.live_streams TO service_role;
GRANT SELECT ON public.profiles,public.follows,public.shop_items,public.creator_wallets,public.account_deletion_requests TO service_role;
DROP POLICY IF EXISTS "Visible streams" ON public.live_streams;
CREATE POLICY "Visible streams" ON public.live_streams FOR SELECT USING(creator_id=(SELECT auth.uid())::text OR (status='live' AND lease_expires_at>now() AND public.can_view_creator(creator_id)));

CREATE OR REPLACE FUNCTION public.fulfill_checkout(order_key uuid,session_id text,amount integer,currency text,event_id text,subscription_id text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE receipt public.checkout_orders%ROWTYPE;
BEGIN
 SELECT * INTO receipt FROM public.checkout_orders WHERE id=order_key FOR UPDATE;
 IF NOT FOUND OR receipt.environment IS DISTINCT FROM public.billing_environment() OR receipt.stripe_session IS NULL OR receipt.stripe_session IS DISTINCT FROM session_id OR receipt.amount_cents IS DISTINCT FROM amount OR currency IS DISTINCT FROM 'usd' THEN RAISE EXCEPTION 'Payment receipt mismatch'; END IF;
 IF receipt.status='paid' THEN RETURN; END IF;
 IF receipt.status<>'pending' THEN RAISE EXCEPTION 'Payment receipt is not pending'; END IF;
 INSERT INTO public.payment_events(id,order_id) VALUES(event_id,order_key);
 IF receipt.kind='coins' THEN
  UPDATE public.profiles SET coins=coins+receipt.credits WHERE id=receipt.user_id;
  INSERT INTO public.coin_ledger(user_id,delta,source) VALUES(receipt.user_id,receipt.credits,'checkout:'||order_key::text);
 ELSIF receipt.kind='pro' THEN
  IF subscription_id IS NULL THEN RAISE EXCEPTION 'Subscription required'; END IF;
  INSERT INTO public.billing_subscriptions(id,user_id,status) VALUES(subscription_id,receipt.user_id,'active') ON CONFLICT(id) DO NOTHING;
  UPDATE public.profiles SET is_pro=true WHERE id=receipt.user_id;
 ELSE
  IF receipt.item_id IS NULL OR receipt.seller_id IS NULL THEN RAISE EXCEPTION 'Product receipt incomplete'; END IF;
  INSERT INTO public.purchases(order_id,user_id,item_id) VALUES(order_key,receipt.user_id,receipt.item_id);
  UPDATE public.shop_items SET sales=sales+1 WHERE id=receipt.item_id;
  UPDATE public.creator_wallets SET balance=balance+floor(receipt.amount_cents*0.77)/100,total_earned=total_earned+floor(receipt.amount_cents*0.77)/100 WHERE creator_id=receipt.seller_id;
 END IF;
 UPDATE public.checkout_orders SET status='paid',stripe_subscription=subscription_id WHERE id=order_key;
 PERFORM public.notify_user(receipt.user_id,'Payment confirmed. Your purchase is available.');
END $$;
CREATE OR REPLACE FUNCTION public.sync_subscription(subscription_id text,subscription_status text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE owner_id text;
BEGIN
 UPDATE public.billing_subscriptions SET status=subscription_status WHERE id=subscription_id RETURNING user_id INTO owner_id;
 IF owner_id IS NULL THEN RETURN; END IF;
 UPDATE public.profiles SET is_pro=EXISTS(SELECT 1 FROM public.billing_subscriptions WHERE user_id=owner_id AND status IN('active','trialing')) WHERE id=owner_id;
END $$;
CREATE OR REPLACE FUNCTION public.send_live_gift(stream text,gift text,request_key uuid) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text:=public.require_member(); receiver text; cost integer; remaining integer; cut integer;
BEGIN
 IF coalesce(public.billing_environment(),'disabled') NOT IN('test','live') THEN RAISE EXCEPTION 'Gifting awaits billing approval'; END IF;
 PERFORM public.enforce_rate_limit(actor,'gift',30);
 SELECT creator_id INTO receiver FROM public.live_streams WHERE id=stream AND status='live' AND lease_expires_at>now() AND public.can_view_creator(creator_id) FOR SHARE;
 IF receiver IS NULL OR receiver=actor THEN RAISE EXCEPTION 'Stream unavailable for gifting'; END IF;
 IF request_key IS NULL THEN RAISE EXCEPTION 'A request key is required'; END IF;
 cost:=CASE gift WHEN 'Rose' THEN 5 WHEN 'Heart' THEN 10 WHEN 'Fire' THEN 25 WHEN 'Star' THEN 50 WHEN 'Crown' THEN 100 WHEN 'Diamond' THEN 500 WHEN 'Kingdom' THEN 1000 WHEN 'GLORY' THEN 9999 ELSE NULL END;
 IF cost IS NULL THEN RAISE EXCEPTION 'Unknown gift'; END IF;
 PERFORM id FROM public.profiles WHERE id IN(actor,receiver) ORDER BY id FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.gifts WHERE sender_id=actor AND request_id=request_key) THEN
  IF NOT EXISTS(SELECT 1 FROM public.gifts WHERE sender_id=actor AND request_id=request_key AND live_id=stream AND gift_name=gift) THEN RAISE EXCEPTION 'Request key already used'; END IF;
  SELECT coins INTO remaining FROM public.profiles WHERE id=actor;RETURN remaining;
 END IF;
 UPDATE public.profiles SET coins=coins-cost WHERE id=actor AND coins>=cost RETURNING coins INTO remaining;
 IF remaining IS NULL THEN RAISE EXCEPTION 'Insufficient coins'; END IF;
 cut:=floor(cost*0.20);
 INSERT INTO public.gifts(sender_id,receiver_id,gift_name,coins_spent,creator_cut,live_id,request_id) VALUES(actor,receiver,gift,cost,cut,stream,request_key);
 INSERT INTO public.coin_ledger(user_id,delta,source) VALUES(actor,-cost,'gift:'||actor||':'||request_key::text);
 UPDATE public.creator_wallets SET balance=balance+cut::numeric/100,total_earned=total_earned+cut::numeric/100 WHERE creator_id=receiver;
 PERFORM public.notify_user_event(receiver,'You received a '||gift||' gift.','gifts');RETURN remaining;
END $$;
CREATE OR REPLACE FUNCTION public.request_withdrawal() RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text:=public.require_member(); wallet public.creator_wallets%ROWTYPE; result uuid;
BEGIN
 IF coalesce(public.billing_environment(),'disabled') NOT IN('test','live') THEN RAISE EXCEPTION 'Withdrawals await billing approval'; END IF;
 PERFORM public.enforce_rate_limit(actor,'withdrawal',2);
 SELECT * INTO wallet FROM public.creator_wallets WHERE creator_id=actor FOR UPDATE;
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=actor AND followers>=5000) OR wallet.locked OR wallet.balance<50 OR wallet.id IS NULL OR EXISTS(SELECT 1 FROM public.withdrawal_requests WHERE creator_id=actor AND status='pending') THEN RAISE EXCEPTION 'Withdrawal eligibility or available balance not met'; END IF;
 INSERT INTO public.withdrawal_requests(creator_id,amount,method,status) VALUES(actor,wallet.balance,'manual_review','pending') RETURNING id INTO result;
 UPDATE public.creator_wallets SET balance=0 WHERE creator_id=actor;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.platform_health() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT jsonb_build_object('schema_version',3); $$;
REVOKE ALL ON FUNCTION public.fulfill_checkout(uuid,text,integer,text,text,text),public.sync_subscription(text,text),public.platform_health(),public.send_live_gift(text,text,uuid),public.request_withdrawal() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.fulfill_checkout(uuid,text,integer,text,text,text),public.sync_subscription(text,text),public.platform_health(),public.enforce_rate_limit(text,text,integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.send_live_gift(text,text,uuid),public.request_withdrawal() TO authenticated;
-- Refund/dispute incidents enter an explicit operations queue.
ALTER TABLE public.checkout_orders ADD COLUMN IF NOT EXISTS payment_intent text;
ALTER TABLE public.billing_subscriptions ADD COLUMN IF NOT EXISTS customer_id text;
CREATE TABLE IF NOT EXISTS public.payment_incidents(id text PRIMARY KEY,order_id uuid REFERENCES public.checkout_orders(id),kind text NOT NULL,created_at timestamptz DEFAULT now());
ALTER TABLE public.payment_incidents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payment_incidents FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.payment_incidents TO service_role;
CREATE OR REPLACE FUNCTION public.flag_payment_incident(intent text,event_key text,incident_type text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE receipt public.checkout_orders%ROWTYPE;
BEGIN
 SELECT * INTO receipt FROM public.checkout_orders WHERE payment_intent=intent FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Payment receipt unavailable'; END IF;
 INSERT INTO public.payment_incidents(id,order_id,kind) VALUES(event_key,receipt.id,incident_type) ON CONFLICT DO NOTHING;
 UPDATE public.checkout_orders SET status='review' WHERE id=receipt.id;
 UPDATE public.profiles SET suspended=true WHERE id=receipt.user_id;
 PERFORM public.notify_user(receipt.user_id,'A payment requires support review. Contact kingdomshiftmedia@gmail.com.');
END $$;
REVOKE ALL ON FUNCTION public.flag_payment_incident(text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.flag_payment_incident(text,text,text) TO service_role;
CREATE OR REPLACE FUNCTION public.cancel_checkout(order_key uuid,session_id text,event_id text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE receipt public.checkout_orders%ROWTYPE;BEGIN
 SELECT * INTO receipt FROM public.checkout_orders WHERE id=order_key FOR UPDATE;
 IF NOT FOUND OR receipt.stripe_session IS NULL OR receipt.stripe_session IS DISTINCT FROM session_id THEN RAISE EXCEPTION 'Payment receipt mismatch';END IF;
 INSERT INTO public.payment_events(id,order_id) VALUES(event_id,order_key) ON CONFLICT DO NOTHING;
 IF receipt.status='pending' THEN UPDATE public.checkout_orders SET status='canceled' WHERE id=order_key;END IF;
END $$;
REVOKE ALL ON FUNCTION public.cancel_checkout(uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_checkout(uuid,text,text) TO service_role;
COMMIT;
