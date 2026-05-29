-- RUN THIS IN SUPABASE SQL EDITOR
-- Adds live streaming tables

CREATE TABLE IF NOT EXISTS live_streams (
  id           TEXT PRIMARY KEY,
  creator_id   TEXT REFERENCES profiles(id),
  title        TEXT NOT NULL,
  status       TEXT DEFAULT 'live',
  viewer_count INTEGER DEFAULT 0,
  peak_viewers INTEGER DEFAULT 0,
  started_at   TIMESTAMPTZ DEFAULT NOW(),
  ended_at     TIMESTAMPTZ
);

ALTER TABLE live_streams ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Public live streams" ON live_streams FOR SELECT USING (true);
CREATE POLICY "Creators manage streams" ON live_streams FOR ALL USING (auth.uid()::text = creator_id);

-- Allow viewer count updates
CREATE POLICY "Anyone can update viewer count" ON live_streams 
  FOR UPDATE USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_live_status ON live_streams(status);
CREATE INDEX IF NOT EXISTS idx_live_creator ON live_streams(creator_id);
