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
BEGIN;
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
COMMIT;
