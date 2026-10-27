BEGIN;
GRANT SELECT(review_status) ON public.shop_items TO authenticated;
CREATE OR REPLACE FUNCTION public.save_shop_item(item_key uuid,item_name text,item_description text,item_price numeric,item_type text,media_path text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text:=public.require_member(); result uuid;
BEGIN
 PERFORM public.enforce_rate_limit(actor,'catalog',10);
 IF length(btrim(item_name)) NOT BETWEEN 1 AND 160 OR length(item_description)>5000 OR item_price<0.50 OR item_price>10000 OR round(item_price,2)<>item_price OR item_type NOT IN('Digital','eBook') OR media_path IS NULL OR left(media_path,length(actor)+1)<>actor||'/' OR media_path LIKE '%..%' THEN RAISE EXCEPTION 'Invalid product details'; END IF;
 IF item_key IS NULL THEN INSERT INTO public.shop_items(creator_id,name,description,price,type,file_path,active,review_status) VALUES(actor,btrim(item_name),item_description,item_price,item_type,media_path,false,'pending') RETURNING id INTO result;
 ELSE UPDATE public.shop_items SET name=btrim(item_name),description=item_description,price=item_price,type=item_type,file_path=media_path,active=false,review_status='pending' WHERE id=item_key AND creator_id=actor RETURNING id INTO result; END IF;
 IF result IS NULL THEN RAISE EXCEPTION 'Product unavailable'; END IF;RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.archive_shop_item(item_key uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text:=public.require_member();BEGIN UPDATE public.shop_items SET active=false,review_status='removed' WHERE id=item_key AND creator_id=actor;END $$;
CREATE OR REPLACE FUNCTION public.admin_catalog() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN PERFORM public.require_admin();RETURN coalesce((SELECT jsonb_agg(x) FROM(SELECT id,creator_id,name,description,price,type,file_path FROM public.shop_items WHERE review_status='pending' ORDER BY created_at LIMIT 50)x),'[]'::jsonb);END $$;
CREATE OR REPLACE FUNCTION public.moderate_shop_item(item_key uuid,decision text,note text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text:=public.require_admin();BEGIN
 IF decision NOT IN('published','removed') OR length(btrim(note)) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'A decision and review note are required'; END IF;
 UPDATE public.shop_items SET active=decision='published',review_status=decision WHERE id=item_key;
 IF NOT FOUND THEN RAISE EXCEPTION 'Product unavailable'; END IF;
 INSERT INTO public.admin_audit_log(actor_id,action,target_id,note) VALUES(actor,'catalog:'||decision,item_key::text,note);
END $$;
CREATE OR REPLACE FUNCTION public.start_live_stream(creator text,stream_title text) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result text:='ks_'||gen_random_uuid()::text;BEGIN
 IF length(btrim(stream_title)) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'Invalid stream title'; END IF;
 PERFORM id FROM public.profiles WHERE id=creator AND NOT suspended FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Creator unavailable'; END IF;
 UPDATE public.live_streams SET status='ended',ended_at=now() WHERE creator_id=creator AND status IN('live','preparing');
 INSERT INTO public.live_streams(id,creator_id,title,status,lease_expires_at) VALUES(result,creator,btrim(stream_title),'preparing',now()+interval '2 minutes');RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.prepare_account_erasure(target text,request_key uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM id FROM public.account_deletion_requests WHERE id=request_key AND user_id=target AND status IN('pending','processing') FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Deletion request unavailable'; END IF;
 IF EXISTS(SELECT 1 FROM public.creator_wallets WHERE creator_id=target AND balance>0) OR EXISTS(SELECT 1 FROM public.withdrawal_requests WHERE creator_id=target AND status='pending')
 OR EXISTS(SELECT 1 FROM public.billing_subscriptions WHERE user_id=target AND status IN('active','trialing','past_due'))
 OR EXISTS(SELECT 1 FROM public.purchases p JOIN public.shop_items i ON i.id=p.item_id WHERE i.creator_id=target)
 OR EXISTS(SELECT 1 FROM public.checkout_orders WHERE user_id=target AND status='pending') THEN RAISE EXCEPTION 'Settle balances, subscriptions, purchases, and pending orders before erasure'; END IF;
 UPDATE public.profiles SET suspended=true WHERE id=target;
 UPDATE public.account_deletion_requests SET status='processing' WHERE id=request_key;
END $$;
CREATE OR REPLACE FUNCTION public.erase_account_data(target text,request_key uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM public.prepare_account_erasure(target,request_key);
 DELETE FROM public.video_likes WHERE user_id=target OR video_id IN(SELECT id FROM public.videos WHERE creator_id=target);
 DELETE FROM public.video_saves WHERE user_id=target OR video_id IN(SELECT id FROM public.videos WHERE creator_id=target);
 DELETE FROM public.comments WHERE user_id=target OR video_id IN(SELECT id FROM public.videos WHERE creator_id=target);
 DELETE FROM public.videos WHERE creator_id=target;
 DELETE FROM public.direct_messages WHERE sender_id=target OR recipient_id=target;
 DELETE FROM public.notifications WHERE user_id=target;
 DELETE FROM public.user_blocks WHERE user_id=target OR blocked_id=target;
 DELETE FROM public.follows WHERE follower_id=target OR following_id=target;
 UPDATE public.shop_items SET name='Deleted product',description='',cover_url=NULL,file_path=NULL,file_url=NULL,active=false,review_status='removed' WHERE creator_id=target;
 UPDATE public.live_streams SET title='Deleted stream',status='ended',ended_at=now() WHERE creator_id=target;
 UPDATE public.reports SET details='Personal content erased after account deletion',content_url=NULL WHERE reporter_id=target;
 UPDATE public.profiles SET email=NULL,username='deleted_'||replace(target,'-',''),display_name='Deleted account',bio=NULL,avatar='👤',avatar_url=NULL,banner_url=NULL,notif_settings='{}',privacy_settings='{"privateAccount":true}',role='deleted',suspended=true,followers=0,following=0 WHERE id=target;
 UPDATE public.profiles p SET followers=(SELECT count(*) FROM public.follows WHERE following_id=p.id AND status='accepted'),following=(SELECT count(*) FROM public.follows WHERE follower_id=p.id AND status='accepted') WHERE p.id<>target;
END $$;
CREATE OR REPLACE FUNCTION public.platform_health() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$SELECT jsonb_build_object('schema_version',4);$$;
REVOKE ALL ON FUNCTION public.save_shop_item(uuid,text,text,numeric,text,text),public.archive_shop_item(uuid),public.admin_catalog(),public.moderate_shop_item(uuid,text,text),public.start_live_stream(text,text),public.prepare_account_erasure(text,uuid),public.erase_account_data(text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.save_shop_item(uuid,text,text,numeric,text,text),public.archive_shop_item(uuid),public.admin_catalog(),public.moderate_shop_item(uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.start_live_stream(text,text),public.prepare_account_erasure(text,uuid),public.erase_account_data(text,uuid) TO service_role;
GRANT UPDATE ON public.account_deletion_requests TO service_role;
-- Keep balances, entitlements and moderation state out of public profiles.
REVOKE SELECT(coins,role,is_pro,is_church_pro,strikes,suspended) ON public.profiles FROM anon,authenticated;
CREATE OR REPLACE FUNCTION public.get_my_account() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text:=public.require_member();BEGIN
 RETURN (SELECT jsonb_build_object('coins',coins,'role',role,'is_pro',is_pro,'is_church_pro',is_church_pro,'strikes',strikes,'suspended',suspended) FROM public.profiles WHERE id=actor);
END $$;
CREATE OR REPLACE FUNCTION public.is_platform_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$SELECT EXISTS(SELECT 1 FROM public.profiles WHERE id=(SELECT auth.uid())::text AND role='admin' AND NOT suspended);$$;
REVOKE ALL ON FUNCTION public.get_my_account(),public.is_platform_admin() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_account(),public.is_platform_admin() TO authenticated;
CREATE OR REPLACE FUNCTION public.submit_safety_report(content_url text,details text,concern text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text:=public.require_member();result uuid;BEGIN
 PERFORM public.enforce_rate_limit(actor,'report',5);
 IF concern IS NULL OR content_url IS NULL OR details IS NULL OR concern NOT IN('other','child_safety','harassment') OR content_url !~ '^https?://' OR length(content_url)>2048 OR length(btrim(details)) NOT BETWEEN 10 AND 4000 THEN RAISE EXCEPTION 'A valid content URL and report details are required';END IF;
 INSERT INTO public.reports(reporter_id,reported_id,type,status,priority,content_url,details) VALUES(actor,NULL,concern,'pending','normal',content_url,btrim(details)) RETURNING id INTO result;RETURN result;
END $$;
REVOKE INSERT(reporter_id,reported_id,type,status,priority,content_url,details) ON public.reports FROM authenticated;
REVOKE INSERT ON public.reports FROM authenticated;
REVOKE ALL ON FUNCTION public.submit_safety_report(text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.submit_safety_report(text,text,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_operations() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN PERFORM public.require_admin();RETURN jsonb_build_object(
 'incidents',coalesce((SELECT jsonb_agg(x) FROM(SELECT * FROM public.payment_incidents ORDER BY created_at DESC LIMIT 50)x),'[]'::jsonb),
 'withdrawals',coalesce((SELECT jsonb_agg(x) FROM(SELECT * FROM public.withdrawal_requests WHERE status='pending' ORDER BY requested_at LIMIT 50)x),'[]'::jsonb),
 'deletions',coalesce((SELECT jsonb_agg(x) FROM(SELECT * FROM public.account_deletion_requests WHERE status IN('pending','processing') ORDER BY created_at LIMIT 50)x),'[]'::jsonb));END $$;
REVOKE ALL ON FUNCTION public.admin_operations() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_operations() TO authenticated;
CREATE OR REPLACE FUNCTION public.is_active_member() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$SELECT EXISTS(SELECT 1 FROM public.profiles WHERE id=(SELECT auth.uid())::text AND NOT suspended AND role<>'deleted');$$;
REVOKE ALL ON FUNCTION public.is_active_member() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.is_active_member() TO authenticated;
CREATE OR REPLACE FUNCTION public.creator_analytics() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text:=public.require_member();BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=actor AND is_pro) THEN RAISE EXCEPTION 'An active Creator Pro subscription is required';END IF;
 RETURN jsonb_build_object('posts',(SELECT count(*) FROM public.videos WHERE creator_id=actor AND status='published'),
 'likes',coalesce((SELECT sum(likes) FROM public.videos WHERE creator_id=actor AND status='published'),0),
 'comments',(SELECT count(*) FROM public.comments c JOIN public.videos v ON v.id=c.video_id WHERE v.creator_id=actor),
 'followers',(SELECT followers FROM public.profiles WHERE id=actor),
 'sales',(SELECT count(*) FROM public.purchases p JOIN public.shop_items i ON i.id=p.item_id JOIN public.checkout_orders o ON o.id=p.order_id WHERE i.creator_id=actor AND o.status='paid'),
 'total_earned',coalesce((SELECT total_earned FROM public.creator_wallets WHERE creator_id=actor),0));
END $$;
REVOKE ALL ON FUNCTION public.creator_analytics() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.creator_analytics() TO authenticated;
COMMIT;
