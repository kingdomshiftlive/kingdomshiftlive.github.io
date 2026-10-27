-- KINGDOMSHIFT STAGING ONLY: kingdomshiftlive-staging (jsraezhloekelhuzehou).
-- Do not run in Kingdomshiftlive / production (cotcogrkmtgibbpwhxrg).
-- Prepared from Draft PR #1 canonical SQL; no new schema design or pricing changes.
-- Run as the database owner in the staging SQL Editor. This creates staging
-- tables/functions/policies/private buckets, not a website or Edge deployment.
-- All SQL is in one transaction; an error rolls the transaction back.
BEGIN;
SET LOCAL search_path = public, extensions;
DO $guard$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind IN ('r','p')
  ) THEN
    RAISE EXCEPTION 'Stopped: public already contains tables. Use reviewed incremental migrations, not the empty-staging bootstrap.';
  END IF;
END;
$guard$;


-- SOURCE: supabase_schema.sql SHA256 2c70ca43e348bf34376dd2880b29dca42ce677a0e011977764dcfc3cbcdbd53d

-- RUN THIS IN SUPABASE → SQL EDITOR

-- Profiles table
CREATE TABLE IF NOT EXISTS profiles (
  id            TEXT PRIMARY KEY,
  email         TEXT UNIQUE,
  username      TEXT UNIQUE,
  display_name  TEXT,
  bio           TEXT,
  avatar        TEXT DEFAULT '👤',
  avatar_url    TEXT,
  banner_url    TEXT,
  followers     INTEGER DEFAULT 0,
  following     INTEGER DEFAULT 0,
  videos        INTEGER DEFAULT 0,
  coins         INTEGER DEFAULT 0,
  verified      BOOLEAN DEFAULT FALSE,
  is_pro        BOOLEAN DEFAULT FALSE,
  is_church_pro BOOLEAN DEFAULT FALSE,
  tier          TEXT DEFAULT 'Seed',
  role          TEXT DEFAULT 'creator',
  strikes       INTEGER DEFAULT 0,
  suspended     BOOLEAN DEFAULT FALSE,
  battle_score  INTEGER DEFAULT 0,
  notif_settings JSONB DEFAULT '{}',
  privacy_settings JSONB DEFAULT '{}',
  joined_at     TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

-- Creator wallets
CREATE TABLE IF NOT EXISTS creator_wallets (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id      TEXT REFERENCES profiles(id) UNIQUE,
  balance         DECIMAL(10,2) DEFAULT 0.00,
  total_earned    DECIMAL(10,2) DEFAULT 0.00,
  total_withdrawn DECIMAL(10,2) DEFAULT 0.00,
  locked          BOOLEAN DEFAULT TRUE,
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Videos
CREATE TABLE IF NOT EXISTS videos (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id   TEXT REFERENCES profiles(id),
  title        TEXT NOT NULL,
  description  TEXT,
  video_url    TEXT,
  thumbnail    TEXT,
  duration     INTEGER DEFAULT 0,
  views        INTEGER DEFAULT 0,
  likes        INTEGER DEFAULT 0,
  category     TEXT DEFAULT 'Faith',
  status       TEXT DEFAULT 'published',
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

-- Shop items
CREATE TABLE IF NOT EXISTS shop_items (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id  TEXT REFERENCES profiles(id),
  name        TEXT NOT NULL,
  description TEXT,
  price       DECIMAL(10,2) NOT NULL,
  type        TEXT NOT NULL,
  icon        TEXT DEFAULT '📦',
  cover_url   TEXT,
  file_url    TEXT,
  sales       INTEGER DEFAULT 0,
  active      BOOLEAN DEFAULT TRUE,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- Gifts
CREATE TABLE IF NOT EXISTS gifts (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id    TEXT REFERENCES profiles(id),
  receiver_id  TEXT REFERENCES profiles(id),
  gift_name    TEXT,
  gift_icon    TEXT,
  coins_spent  INTEGER NOT NULL,
  creator_cut  INTEGER NOT NULL,
  live_id      TEXT,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

-- Reports
CREATE TABLE IF NOT EXISTS reports (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id TEXT REFERENCES profiles(id),
  reported_id TEXT REFERENCES profiles(id),
  type        TEXT NOT NULL,
  status      TEXT DEFAULT 'pending',
  priority    TEXT DEFAULT 'normal',
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- Battle scores
CREATE TABLE IF NOT EXISTS battle_scores (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    TEXT REFERENCES profiles(id),
  mode       TEXT NOT NULL,
  score      INTEGER NOT NULL,
  questions  INTEGER NOT NULL,
  correct    INTEGER NOT NULL,
  streak     INTEGER DEFAULT 0,
  played_at  TIMESTAMPTZ DEFAULT NOW()
);

-- Withdrawal requests
CREATE TABLE IF NOT EXISTS withdrawal_requests (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id   TEXT REFERENCES profiles(id),
  amount       DECIMAL(10,2) NOT NULL,
  method       TEXT NOT NULL,
  status       TEXT DEFAULT 'pending',
  requested_at TIMESTAMPTZ DEFAULT NOW()
);

-- Follows
CREATE TABLE IF NOT EXISTS follows (
  follower_id  TEXT REFERENCES profiles(id),
  following_id TEXT REFERENCES profiles(id),
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (follower_id, following_id)
);

-- Enable Row Level Security
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE creator_wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE videos ENABLE ROW LEVEL SECURITY;
ALTER TABLE shop_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE gifts ENABLE ROW LEVEL SECURITY;
ALTER TABLE reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE battle_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE withdrawal_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE follows ENABLE ROW LEVEL SECURITY;

-- Auto create wallet when profile created
CREATE OR REPLACE FUNCTION public.create_wallet()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO creator_wallets (creator_id) VALUES (NEW.id) ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE TRIGGER on_profile_created
  AFTER INSERT ON profiles
  FOR EACH ROW EXECUTE FUNCTION create_wallet();

-- Unlock wallet at 5000 followers
CREATE OR REPLACE FUNCTION public.check_withdrawal_gate()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.followers >= 5000 AND (OLD.followers < 5000 OR OLD.followers IS NULL) THEN
    UPDATE creator_wallets SET locked = FALSE WHERE creator_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE TRIGGER follower_gate
  AFTER UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION check_withdrawal_gate();


-- Security policies for fresh installations. Existing installations may run
-- migrations/001_security_hardening.sql directly.
-- Run as the database owner in Supabase SQL Editor after supabase_schema.sql.
-- Also supports existing installations. Transactional and repeatable.

CREATE TABLE IF NOT EXISTS public.live_streams (
  id text PRIMARY KEY,
  creator_id text REFERENCES public.profiles(id),
  title text NOT NULL,
  status text DEFAULT 'live',
  viewer_count integer DEFAULT 0,
  peak_viewers integer DEFAULT 0,
  started_at timestamptz DEFAULT now(),
  ended_at timestamptz
);
ALTER TABLE public.reports ADD COLUMN IF NOT EXISTS content_url text;
ALTER TABLE public.reports ADD COLUMN IF NOT EXISTS details text;
ALTER TABLE public.live_streams ENABLE ROW LEVEL SECURITY;

-- Remove all existing policies on these application tables, including permissive
-- policies with unknown names. Recreate a deliberately limited API surface.
DO $$
DECLARE policy record;
BEGIN
  FOR policy IN SELECT schemaname, tablename, policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = ANY (ARRAY[
      'profiles','creator_wallets','videos','shop_items','gifts','reports',
      'battle_scores','withdrawal_requests','follows','live_streams'])
  LOOP
    EXECUTE format('DROP POLICY %I ON %I.%I',policy.policyname,policy.schemaname,policy.tablename);
  END LOOP;
END $$;

-- Table revokes do not remove pre-existing column grants. Remove those too.
REVOKE ALL ON public.profiles, public.creator_wallets, public.videos,
  public.shop_items, public.gifts, public.reports, public.battle_scores,
  public.withdrawal_requests, public.follows, public.live_streams FROM PUBLIC, anon, authenticated;
DO $$
DECLARE tbl text; cols text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY['profiles','creator_wallets','videos','shop_items',
    'gifts','reports','battle_scores','withdrawal_requests','follows','live_streams']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',tbl);
    SELECT string_agg(quote_ident(column_name), ',') INTO cols
      FROM information_schema.columns WHERE table_schema='public' AND table_name=tbl;
    EXECUTE format('REVOKE SELECT (%s), INSERT (%s), UPDATE (%s), REFERENCES (%s) ON public.%I FROM PUBLIC, anon, authenticated',cols,cols,cols,cols,tbl);
  END LOOP;
END $$;

-- Private content is visible only to its owner until an approval system exists.
CREATE OR REPLACE FUNCTION public.can_view_creator(creator text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id=creator
    AND (p.id=(SELECT auth.uid())::text OR
      coalesce(p.privacy_settings->>'privateAccount','false') <> 'true'));
$$;
REVOKE ALL ON FUNCTION public.can_view_creator(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_view_creator(text) TO anon, authenticated;

CREATE POLICY "Visible profiles" ON public.profiles FOR SELECT
  USING (public.can_view_creator(id));
CREATE POLICY "Own profile insert" ON public.profiles FOR INSERT TO authenticated
  WITH CHECK (id=(SELECT auth.uid())::text);
CREATE POLICY "Own profile update" ON public.profiles FOR UPDATE TO authenticated
  USING (id=(SELECT auth.uid())::text) WITH CHECK (id=(SELECT auth.uid())::text);
-- Email and preference objects are intentionally excluded from public reads.
GRANT SELECT (id,username,display_name,bio,avatar,avatar_url,banner_url,followers,
  following,videos,coins,verified,is_pro,is_church_pro,tier,role,strikes,suspended,
  battle_score,joined_at,updated_at) ON public.profiles TO anon,authenticated;
GRANT INSERT (id,username,display_name) ON public.profiles TO authenticated;
GRANT UPDATE (username,display_name,bio,avatar,avatar_url,banner_url,
  notif_settings,privacy_settings) ON public.profiles TO authenticated;

CREATE OR REPLACE FUNCTION public.get_my_settings()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('notif_settings',p.notif_settings,
    'privacy_settings',p.privacy_settings)
  FROM public.profiles p WHERE p.id=(SELECT auth.uid())::text;
$$;
REVOKE ALL ON FUNCTION public.get_my_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_settings() TO authenticated;

CREATE POLICY "Own wallet read" ON public.creator_wallets FOR SELECT TO authenticated
  USING (creator_id=(SELECT auth.uid())::text);
GRANT SELECT ON public.creator_wallets TO authenticated;
-- No client wallet, gift, withdrawal, or subscription writes. A future trusted
-- service must verify payment, available funds, and entitlement atomically.

CREATE POLICY "Visible videos" ON public.videos FOR SELECT
  USING (creator_id=(SELECT auth.uid())::text OR
    (status='published' AND public.can_view_creator(creator_id)));
CREATE POLICY "Visible shop" ON public.shop_items FOR SELECT
  USING (creator_id=(SELECT auth.uid())::text OR
    (active AND public.can_view_creator(creator_id)));
CREATE POLICY "Visible streams" ON public.live_streams FOR SELECT
  USING (creator_id=(SELECT auth.uid())::text OR
    (status='live' AND public.can_view_creator(creator_id)));
GRANT SELECT ON public.videos TO anon,authenticated;
-- Do not expose paid download URLs in the public shop API.
GRANT SELECT (id,creator_id,name,description,price,type,icon,cover_url,sales,active,created_at)
  ON public.shop_items TO anon,authenticated;
GRANT SELECT ON public.live_streams TO anon,authenticated;

CREATE POLICY "Own reports insert" ON public.reports FOR INSERT TO authenticated
  WITH CHECK (reporter_id=(SELECT auth.uid())::text AND status='pending'
    AND priority='normal' AND reported_id IS NULL
    AND type IN ('other','child_safety','harassment')
    AND content_url ~ '^https?://' AND length(content_url)<=2048
    AND length(btrim(details)) BETWEEN 10 AND 4000);
GRANT INSERT (reporter_id,reported_id,type,status,priority,content_url,details)
  ON public.reports TO authenticated;
CREATE POLICY "Own scores read" ON public.battle_scores FOR SELECT TO authenticated
  USING (user_id=(SELECT auth.uid())::text);
GRANT SELECT ON public.battle_scores TO authenticated;
-- Quiz scoring stays local; it is not an authority for rewards or rankings.

CREATE POLICY "Visible follows" ON public.follows FOR SELECT
  USING (public.can_view_creator(follower_id) AND public.can_view_creator(following_id));
GRANT SELECT ON public.follows TO anon,authenticated;

-- Pin SECURITY DEFINER lookup paths and fully qualify trigger writes.
CREATE OR REPLACE FUNCTION public.create_wallet() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.creator_wallets (creator_id) VALUES (NEW.id) ON CONFLICT DO NOTHING;
  RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION public.check_withdrawal_gate() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.followers >= 5000 AND (OLD.followers < 5000 OR OLD.followers IS NULL) THEN
    UPDATE public.creator_wallets SET locked=false WHERE creator_id=NEW.id;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.create_wallet(), public.check_withdrawal_gate() FROM PUBLIC;


-- SOURCE: migrations/002_customer_platform.sql SHA256 7aaac0d63707f57f839ecc5b3c131305135cb315c3002bf61063b674b755091d

-- Apply after 001_security_hardening.sql. No production execution is automatic.

ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS file_path text;
ALTER TABLE public.videos ALTER COLUMN status SET DEFAULT 'pending';
ALTER TABLE public.shop_items ADD COLUMN IF NOT EXISTS file_path text;
ALTER TABLE public.shop_items ADD COLUMN IF NOT EXISTS review_status text NOT NULL DEFAULT 'pending';
ALTER TABLE public.shop_items ALTER COLUMN active SET DEFAULT false;
ALTER TABLE public.follows ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'accepted';
CREATE TABLE IF NOT EXISTS public.video_likes(user_id text REFERENCES public.profiles(id),video_id uuid REFERENCES public.videos(id),created_at timestamptz DEFAULT now(),PRIMARY KEY(user_id,video_id));
CREATE TABLE IF NOT EXISTS public.video_saves(user_id text REFERENCES public.profiles(id),video_id uuid REFERENCES public.videos(id),created_at timestamptz DEFAULT now(),PRIMARY KEY(user_id,video_id));
CREATE TABLE IF NOT EXISTS public.comments(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),video_id uuid REFERENCES public.videos(id),user_id text REFERENCES public.profiles(id),body text NOT NULL CHECK(length(body) BETWEEN 1 AND 2000),created_at timestamptz DEFAULT now());
CREATE TABLE IF NOT EXISTS public.notifications(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id text REFERENCES public.profiles(id),body text NOT NULL,read_at timestamptz,created_at timestamptz DEFAULT now());
CREATE TABLE IF NOT EXISTS public.direct_messages(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),sender_id text REFERENCES public.profiles(id),recipient_id text REFERENCES public.profiles(id),body text NOT NULL CHECK(length(body) BETWEEN 1 AND 2000),read_at timestamptz,created_at timestamptz DEFAULT now());
CREATE TABLE IF NOT EXISTS public.user_blocks(user_id text REFERENCES public.profiles(id),blocked_id text REFERENCES public.profiles(id),PRIMARY KEY(user_id,blocked_id));
CREATE TABLE IF NOT EXISTS public.account_deletion_requests(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id text UNIQUE REFERENCES public.profiles(id),status text NOT NULL DEFAULT 'pending',created_at timestamptz DEFAULT now(),completed_at timestamptz);
CREATE TABLE IF NOT EXISTS public.admin_audit_log(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),actor_id text REFERENCES public.profiles(id),action text NOT NULL,target_id text NOT NULL,note text NOT NULL,created_at timestamptz DEFAULT now());
CREATE TABLE IF NOT EXISTS public.app_rate_limits(actor text,action text,window_start timestamptz,hits integer NOT NULL,PRIMARY KEY(actor,action));
CREATE INDEX IF NOT EXISTS messages_recipient_time ON public.direct_messages(recipient_id,created_at DESC);
CREATE INDEX IF NOT EXISTS messages_sender_time ON public.direct_messages(sender_id,created_at DESC);
CREATE INDEX IF NOT EXISTS notifications_user_time ON public.notifications(user_id,created_at DESC);
CREATE INDEX IF NOT EXISTS comments_video_time ON public.comments(video_id,created_at);
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['video_likes','video_saves','comments','notifications','direct_messages','user_blocks','account_deletion_requests','admin_audit_log','app_rate_limits'] LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated',t);
 END LOOP;
END $$;
CREATE OR REPLACE FUNCTION public.require_member() RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := (SELECT auth.uid())::text;
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=actor AND NOT suspended AND role<>'deleted') THEN RAISE EXCEPTION 'Sign in with an active account' USING ERRCODE='42501'; END IF;
 RETURN actor;
END $$;
CREATE OR REPLACE FUNCTION public.require_admin() RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member();
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=actor AND role='admin') THEN RAISE EXCEPTION 'Administrator access required' USING ERRCODE='42501'; END IF; RETURN actor;
END $$;
CREATE OR REPLACE FUNCTION public.enforce_rate_limit(actor text,operation text,maximum integer DEFAULT 30) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE used integer;
BEGIN
 INSERT INTO public.app_rate_limits AS r VALUES(actor,operation,date_trunc('minute',now()),1)
 ON CONFLICT ON CONSTRAINT app_rate_limits_pkey DO UPDATE SET window_start=date_trunc('minute',now()),hits=CASE WHEN r.window_start=date_trunc('minute',now()) THEN r.hits+1 ELSE 1 END RETURNING hits INTO used;
 IF used>maximum THEN RAISE EXCEPTION 'Too many requests. Please wait a minute.' USING ERRCODE='P0001'; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.can_view_creator(creator text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=creator AND NOT p.suspended AND
  (p.id=(SELECT auth.uid())::text OR coalesce(p.privacy_settings->>'privateAccount','false')<>'true'
  OR EXISTS(SELECT 1 FROM public.follows f WHERE f.following_id=creator AND f.follower_id=(SELECT auth.uid())::text AND f.status='accepted')));
$$;
CREATE OR REPLACE FUNCTION public.notify_user_event(recipient text,message text,event_type text) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 INSERT INTO public.notifications(user_id,body) SELECT recipient,left(message,300) WHERE EXISTS(SELECT 1 FROM public.profiles WHERE id=recipient AND NOT suspended AND coalesce(notif_settings->>event_type,'true')<>'false');
$$;
CREATE OR REPLACE FUNCTION public.notify_user(recipient text,message text) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$ SELECT public.notify_user_event(recipient,message,'systemAlerts'); $$;
-- Discoverable public identities; private content still requires accepted follow access.
DROP POLICY IF EXISTS "Visible profiles" ON public.profiles;
CREATE POLICY "Visible profiles" ON public.profiles FOR SELECT USING (id=(SELECT auth.uid())::text OR NOT suspended);
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS is_private boolean GENERATED ALWAYS AS (coalesce(privacy_settings->>'privateAccount','false')='true') STORED;
GRANT SELECT(is_private) ON public.profiles TO anon,authenticated;
GRANT SELECT(file_path) ON public.shop_items TO authenticated;

DROP POLICY IF EXISTS "Read own likes" ON public.video_likes;
CREATE POLICY "Read own likes" ON public.video_likes FOR SELECT TO authenticated USING(user_id=(SELECT auth.uid())::text);
DROP POLICY IF EXISTS "Read own saves" ON public.video_saves;
CREATE POLICY "Read own saves" ON public.video_saves FOR SELECT TO authenticated USING(user_id=(SELECT auth.uid())::text);
DROP POLICY IF EXISTS "Read visible comments" ON public.comments;
CREATE POLICY "Read visible comments" ON public.comments FOR SELECT USING(EXISTS(SELECT 1 FROM public.videos v WHERE v.id=video_id AND v.status='published' AND public.can_view_creator(v.creator_id)));
DROP POLICY IF EXISTS "Read own notifications" ON public.notifications;
CREATE POLICY "Read own notifications" ON public.notifications FOR SELECT TO authenticated USING(user_id=(SELECT auth.uid())::text);
DROP POLICY IF EXISTS "Mark own notifications" ON public.notifications;
CREATE POLICY "Mark own notifications" ON public.notifications FOR UPDATE TO authenticated USING(user_id=(SELECT auth.uid())::text) WITH CHECK(user_id=(SELECT auth.uid())::text);
DROP POLICY IF EXISTS "Read own messages" ON public.direct_messages;
CREATE POLICY "Read own messages" ON public.direct_messages FOR SELECT TO authenticated USING(sender_id=(SELECT auth.uid())::text OR recipient_id=(SELECT auth.uid())::text);
DROP POLICY IF EXISTS "Read own blocks" ON public.user_blocks;
CREATE POLICY "Read own blocks" ON public.user_blocks FOR SELECT TO authenticated USING(user_id=(SELECT auth.uid())::text);
DROP POLICY IF EXISTS "Read own deletion request" ON public.account_deletion_requests;
CREATE POLICY "Read own deletion request" ON public.account_deletion_requests FOR SELECT TO authenticated USING(user_id=(SELECT auth.uid())::text);
GRANT SELECT ON public.video_likes,public.video_saves,public.comments,public.notifications,public.direct_messages,public.user_blocks,public.account_deletion_requests TO authenticated;
GRANT UPDATE(read_at) ON public.notifications TO authenticated;

CREATE OR REPLACE FUNCTION public.set_video_like(video uuid,liked boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member(); creator text;
BEGIN
 PERFORM public.enforce_rate_limit(actor,'like',60);
 SELECT creator_id INTO creator FROM public.videos WHERE id=video AND status='published' AND public.can_view_creator(creator_id) FOR UPDATE;
 IF creator IS NULL THEN RAISE EXCEPTION 'Content unavailable'; END IF;
 IF liked THEN INSERT INTO public.video_likes VALUES(actor,video,now()) ON CONFLICT DO NOTHING;
 ELSE DELETE FROM public.video_likes WHERE user_id=actor AND video_id=video; END IF;
 UPDATE public.videos SET likes=(SELECT count(*) FROM public.video_likes WHERE video_id=video) WHERE id=video;
END $$;
CREATE OR REPLACE FUNCTION public.set_video_saved(video uuid,saved boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member();
BEGIN
 PERFORM public.enforce_rate_limit(actor,'save',60);
 IF NOT EXISTS(SELECT 1 FROM public.videos WHERE id=video AND status='published' AND public.can_view_creator(creator_id)) THEN RAISE EXCEPTION 'Content unavailable'; END IF;
 IF saved THEN INSERT INTO public.video_saves VALUES(actor,video,now()) ON CONFLICT DO NOTHING;
 ELSE DELETE FROM public.video_saves WHERE user_id=actor AND video_id=video; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.set_follow(creator text,following boolean) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member(); result text;
BEGIN
 PERFORM public.enforce_rate_limit(actor,'follow',30);
 IF creator=actor OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=creator AND NOT suspended) THEN RAISE EXCEPTION 'Creator unavailable'; END IF;
 PERFORM id FROM public.profiles WHERE id IN(actor,creator) ORDER BY id FOR UPDATE;
 IF following THEN
  SELECT CASE WHEN is_private THEN 'pending' ELSE 'accepted' END INTO result FROM public.profiles WHERE id=creator;
  INSERT INTO public.follows(follower_id,following_id,status) VALUES(actor,creator,result) ON CONFLICT DO NOTHING;
  IF FOUND THEN PERFORM public.notify_user_event(creator,CASE WHEN result='pending' THEN 'New follow request. Review it in Privacy settings.' ELSE 'You have a new follower.' END,'newFollower'); END IF;
  SELECT status INTO result FROM public.follows WHERE follower_id=actor AND following_id=creator;
 ELSE DELETE FROM public.follows WHERE follower_id=actor AND following_id=creator; result := 'none'; END IF;
 UPDATE public.profiles SET followers=(SELECT count(*) FROM public.follows WHERE following_id=creator AND status='accepted') WHERE id=creator;
 UPDATE public.profiles SET following=(SELECT count(*) FROM public.follows WHERE follower_id=actor AND status='accepted') WHERE id=actor;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.review_follow(follower text,accept boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member();
BEGIN
 PERFORM public.enforce_rate_limit(actor,'review_follow',30);
 PERFORM id FROM public.profiles WHERE id IN(actor,follower) ORDER BY id FOR UPDATE;
 IF accept THEN UPDATE public.follows SET status='accepted' WHERE follower_id=follower AND following_id=actor AND status='pending';
 ELSE DELETE FROM public.follows WHERE follower_id=follower AND following_id=actor AND status='pending'; END IF;
 UPDATE public.profiles SET followers=(SELECT count(*) FROM public.follows WHERE following_id=actor AND status='accepted') WHERE id=actor;
 UPDATE public.profiles SET following=(SELECT count(*) FROM public.follows WHERE follower_id=follower AND status='accepted') WHERE id=follower;
END $$;
CREATE OR REPLACE FUNCTION public.get_follow_requests() RETURNS TABLE(follower_id text,username text,display_name text) LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT f.follower_id,p.username,p.display_name FROM public.follows f JOIN public.profiles p ON p.id=f.follower_id WHERE f.following_id=public.require_member() AND f.status='pending';
$$;
CREATE OR REPLACE FUNCTION public.add_comment(video uuid,comment text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member(); result uuid; creator text;
BEGIN
 PERFORM public.enforce_rate_limit(actor,'comment',15);
 IF length(btrim(comment)) NOT BETWEEN 1 AND 2000 THEN RAISE EXCEPTION 'Comment must be 1–2000 characters'; END IF;
 SELECT creator_id INTO creator FROM public.videos WHERE id=video AND status='published' AND public.can_view_creator(creator_id);
 IF creator IS NULL OR EXISTS(SELECT 1 FROM public.user_blocks WHERE (user_id=creator AND blocked_id=actor) OR (user_id=actor AND blocked_id=creator)) THEN RAISE EXCEPTION 'Comments unavailable'; END IF;
 INSERT INTO public.comments(video_id,user_id,body) VALUES(video,actor,btrim(comment)) RETURNING id INTO result;
 IF creator<>actor THEN PERFORM public.notify_user_event(creator,'New comment on your content.','comments'); END IF; RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.send_message(recipient text,message text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member(); result uuid;
BEGIN
 PERFORM public.enforce_rate_limit(actor,'message',15);
 IF recipient=actor OR length(btrim(message)) NOT BETWEEN 1 AND 2000 OR NOT public.can_view_creator(recipient)
 OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=recipient AND NOT suspended AND coalesce(privacy_settings->>'allowMessages','true')<>'false')
 OR EXISTS(SELECT 1 FROM public.user_blocks WHERE (user_id=recipient AND blocked_id=actor) OR (user_id=actor AND blocked_id=recipient)) THEN RAISE EXCEPTION 'Message cannot be sent'; END IF;
 INSERT INTO public.direct_messages(sender_id,recipient_id,body) VALUES(actor,recipient,btrim(message)) RETURNING id INTO result;
 PERFORM public.notify_user_event(recipient,'You have a new message.','messages'); RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.set_user_block(target text,blocked boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member();
BEGIN
 IF actor=target THEN RAISE EXCEPTION 'Cannot block yourself'; END IF;
 IF blocked THEN INSERT INTO public.user_blocks VALUES(actor,target) ON CONFLICT DO NOTHING;
 ELSE DELETE FROM public.user_blocks WHERE user_id=actor AND blocked_id=target; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.save_content(content_id uuid,title text,description text,category text,media_path text DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member(); result uuid;
BEGIN
 PERFORM public.enforce_rate_limit(actor,'publish',10);
 IF length(btrim(title)) NOT BETWEEN 1 AND 160 OR length(description)>5000 OR length(category)>50 OR (media_path IS NOT NULL AND (left(media_path,length(actor)+1)<>actor||'/' OR media_path LIKE '%..%')) THEN RAISE EXCEPTION 'Invalid content'; END IF;
 IF content_id IS NULL THEN
 INSERT INTO public.videos(creator_id,title,description,category,file_path,status) VALUES(actor,btrim(title),description,category,media_path,'pending') RETURNING id INTO result;
 ELSE UPDATE public.videos SET title=btrim(save_content.title),description=save_content.description,category=save_content.category,file_path=media_path,status='pending' WHERE id=content_id AND creator_id=actor RETURNING id INTO result; END IF;
 IF result IS NULL THEN RAISE EXCEPTION 'Content unavailable'; END IF;
 UPDATE public.profiles SET videos=(SELECT count(*) FROM public.videos WHERE creator_id=actor AND status='published') WHERE id=actor;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.remove_content(content_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member(); BEGIN
 UPDATE public.videos SET status='removed' WHERE id=content_id AND creator_id=actor;
 UPDATE public.profiles SET videos=(SELECT count(*) FROM public.videos WHERE creator_id=actor AND status='published') WHERE id=actor;
END $$;
CREATE OR REPLACE FUNCTION public.request_account_deletion() RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member(); result uuid; BEGIN
 INSERT INTO public.account_deletion_requests(user_id) VALUES(actor) ON CONFLICT(user_id) DO UPDATE SET user_id=EXCLUDED.user_id RETURNING id INTO result;
 UPDATE public.profiles SET suspended=true WHERE id=actor;
 UPDATE public.live_streams SET status='ended',ended_at=now() WHERE creator_id=actor;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.admin_overview() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM public.require_admin();
 RETURN jsonb_build_object('profiles',(SELECT count(*) FROM public.profiles),'published',(SELECT count(*) FROM public.videos WHERE status='published'),
 'reports',coalesce((SELECT jsonb_agg(x) FROM (SELECT * FROM public.reports WHERE status='pending' ORDER BY created_at LIMIT 50)x),'[]'::jsonb),
 'content',coalesce((SELECT jsonb_agg(x) FROM (SELECT id,title,creator_id,description,file_path,created_at FROM public.videos WHERE status='pending' ORDER BY created_at LIMIT 50)x),'[]'::jsonb),
 'deletions',coalesce((SELECT jsonb_agg(x) FROM (SELECT * FROM public.account_deletion_requests WHERE status='pending' ORDER BY created_at LIMIT 50)x),'[]'::jsonb));
END $$;
CREATE OR REPLACE FUNCTION public.moderate_content(content_id uuid,decision text,note text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_admin(); creator text;
BEGIN
 IF decision NOT IN('published','removed') OR length(btrim(note)) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'A decision and review note are required'; END IF;
 UPDATE public.videos SET status=decision WHERE id=content_id RETURNING creator_id INTO creator;
 IF creator IS NULL THEN RAISE EXCEPTION 'Content unavailable'; END IF;
 INSERT INTO public.admin_audit_log(actor_id,action,target_id,note) VALUES(actor,'content:'||decision,content_id::text,note);
 UPDATE public.profiles SET videos=(SELECT count(*) FROM public.videos WHERE creator_id=creator AND status='published') WHERE id=creator;
 PERFORM public.notify_user(creator,'Your content review is complete: '||decision);
END $$;
CREATE OR REPLACE FUNCTION public.resolve_report(report_id uuid,decision text,note text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_admin(); BEGIN
 IF decision NOT IN('resolved','dismissed') OR length(btrim(note)) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'A decision and review note are required'; END IF;
 UPDATE public.reports SET status=decision WHERE id=report_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Report unavailable'; END IF;
 INSERT INTO public.admin_audit_log(actor_id,action,target_id,note) VALUES(actor,'report:'||decision,report_id::text,note);
END $$;
CREATE OR REPLACE FUNCTION public.suspend_member(member text,suspended boolean,note text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_admin(); BEGIN
 IF member=actor OR length(btrim(note)) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'Invalid action'; END IF;
 UPDATE public.profiles SET suspended=suspend_member.suspended WHERE id=member AND role<>'admin';
 IF NOT FOUND THEN RAISE EXCEPTION 'Member unavailable'; END IF;
 INSERT INTO public.admin_audit_log(actor_id,action,target_id,note) VALUES(actor,'suspension:'||suspended::text,member,note);
END $$;
CREATE OR REPLACE FUNCTION public.can_view_media(path text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.videos WHERE file_path=path AND ((status='published' AND public.can_view_creator(creator_id)) OR creator_id=(SELECT auth.uid())::text)) OR EXISTS(SELECT 1 FROM public.profiles WHERE id=(SELECT auth.uid())::text AND role='admin' AND NOT suspended);
$$;
-- New functions are deny-by-default; expose only bounded authenticated actions.
REVOKE ALL ON FUNCTION public.require_member(),public.require_admin(),public.enforce_rate_limit(text,text,integer),public.notify_user(text,text),public.notify_user_event(text,text,text) FROM PUBLIC,anon,authenticated;
DO $$ DECLARE signature text; BEGIN
 FOREACH signature IN ARRAY ARRAY['set_video_like(uuid,boolean)','set_video_saved(uuid,boolean)','set_follow(text,boolean)','review_follow(text,boolean)','get_follow_requests()','add_comment(uuid,text)','send_message(text,text)','set_user_block(text,boolean)','save_content(uuid,text,text,text,text)','remove_content(uuid)','request_account_deletion()','admin_overview()','moderate_content(uuid,text,text)','resolve_report(uuid,text,text)','suspend_member(text,boolean,text)','can_view_media(text)'] LOOP
 EXECUTE 'REVOKE ALL ON FUNCTION public.'||signature||' FROM PUBLIC,anon,authenticated';
 EXECUTE 'GRANT EXECUTE ON FUNCTION public.'||signature||' TO authenticated';
 END LOOP;
END $$;


-- SOURCE: migrations/003_billing_streams.sql SHA256 5d8650e44637ad69344c4ecbf63047662863114995db91cb1151118936476df3

-- Payment receipts and streaming operations. Live billing remains disabled by default.

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


-- SOURCE: migrations/004_catalog_and_operations.sql SHA256 84fc9e2fd75dc0337bd009d69cf9bb419ff3104a73e993ba2e7818088dd2a621


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


-- SOURCE: supabase/storage.sql SHA256 5753cf28a6a20de2914feb603f3b66c2532d0beef3853cfdae849661e04ea70b


INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
VALUES('videos','videos',false,104857600,ARRAY['video/mp4','video/webm'])
ON CONFLICT(id) DO UPDATE SET public=false,file_size_limit=EXCLUDED.file_size_limit,allowed_mime_types=EXCLUDED.allowed_mime_types;
DROP POLICY IF EXISTS "KS upload own video" ON storage.objects;
CREATE POLICY "KS upload own video" ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='videos' AND (storage.foldername(name))[1]=(SELECT auth.uid())::text AND public.is_active_member());
DROP POLICY IF EXISTS "KS view authorized video" ON storage.objects;
CREATE POLICY "KS view authorized video" ON storage.objects FOR SELECT TO anon,authenticated USING(bucket_id='videos' AND public.can_view_media(name));
DROP POLICY IF EXISTS "KS remove own video" ON storage.objects;
CREATE POLICY "KS remove own video" ON storage.objects FOR DELETE TO authenticated USING(bucket_id='videos' AND (storage.foldername(name))[1]=(SELECT auth.uid())::text);
GRANT EXECUTE ON FUNCTION public.can_view_media(text) TO anon;


INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types) VALUES('shop-files','shop-files',false,52428800,ARRAY['application/pdf','application/epub+zip','application/zip','application/x-zip-compressed']) ON CONFLICT(id) DO UPDATE SET public=false,file_size_limit=EXCLUDED.file_size_limit,allowed_mime_types=EXCLUDED.allowed_mime_types;
DROP POLICY IF EXISTS "KS upload digital product" ON storage.objects;
CREATE POLICY "KS upload digital product" ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='shop-files' AND (storage.foldername(name))[1]=(SELECT auth.uid())::text AND public.is_active_member());
DROP POLICY IF EXISTS "KS review own product" ON storage.objects;
CREATE POLICY "KS review own product" ON storage.objects FOR SELECT TO authenticated USING(bucket_id='shop-files' AND ((storage.foldername(name))[1]=(SELECT auth.uid())::text OR public.is_platform_admin()));
-- Customers receive short-lived download links from the authenticated Edge API
-- only after a paid receipt. Product files never have public bucket access.


-- Billing remains disabled. No provider credentials are installed.
SELECT public.platform_health() AS staging_schema, public.billing_environment() AS billing_mode;
COMMIT;
