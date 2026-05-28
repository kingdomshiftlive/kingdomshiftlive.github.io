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

-- RLS Policies
CREATE POLICY "Profiles are public" ON profiles FOR SELECT USING (true);
CREATE POLICY "Users can update own profile" ON profiles FOR UPDATE USING (auth.uid()::text = id);
CREATE POLICY "Users can insert own profile" ON profiles FOR INSERT WITH CHECK (auth.uid()::text = id);

CREATE POLICY "Public videos" ON videos FOR SELECT USING (status = 'published');
CREATE POLICY "Creators manage videos" ON videos FOR ALL USING (auth.uid()::text = creator_id);

CREATE POLICY "Public shop items" ON shop_items FOR SELECT USING (active = true);
CREATE POLICY "Creators manage shop" ON shop_items FOR ALL USING (auth.uid()::text = creator_id);

CREATE POLICY "Users see own wallet" ON creator_wallets FOR SELECT USING (auth.uid()::text = creator_id);
CREATE POLICY "System updates wallet" ON creator_wallets FOR UPDATE USING (auth.uid()::text = creator_id);

CREATE POLICY "Users see own scores" ON battle_scores FOR SELECT USING (auth.uid()::text = user_id);
CREATE POLICY "Users insert scores" ON battle_scores FOR INSERT WITH CHECK (auth.uid()::text = user_id);

CREATE POLICY "Reports are private" ON reports FOR INSERT WITH CHECK (auth.uid()::text = reporter_id);

CREATE POLICY "Public follows" ON follows FOR SELECT USING (true);
CREATE POLICY "Users manage follows" ON follows FOR ALL USING (auth.uid()::text = follower_id);

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
