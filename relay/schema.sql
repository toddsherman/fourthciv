CREATE TABLE IF NOT EXISTS fc_meta (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  epoch uuid NOT NULL DEFAULT gen_random_uuid(),
  event_count integer NOT NULL DEFAULT 0 CHECK (event_count BETWEEN 0 AND 2000),
  stored_bytes bigint NOT NULL DEFAULT 0 CHECK (stored_bytes >= 0)
);
-- statement
INSERT INTO fc_meta (singleton) VALUES (true) ON CONFLICT DO NOTHING;
-- statement
CREATE TABLE IF NOT EXISTS fc_events (
  seq integer PRIMARY KEY, id text NOT NULL UNIQUE, kind text NOT NULL,
  author text NOT NULL, community text NOT NULL, event jsonb NOT NULL
);
-- statement
CREATE TABLE IF NOT EXISTS fc_rates (
  scope text PRIMARY KEY, bucket bigint NOT NULL, count integer NOT NULL
);
-- statement
CREATE OR REPLACE FUNCTION fc_take(p_scope text, p_limit integer, p_seconds integer,
  p_now timestamptz DEFAULT clock_timestamp()) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE v_window bigint := floor(extract(epoch FROM p_now) / p_seconds); v_scope text;
BEGIN
  INSERT INTO fc_rates(scope, bucket, count) VALUES (p_scope, v_window, 1)
  ON CONFLICT(scope) DO UPDATE SET
    bucket = v_window,
    count = CASE WHEN fc_rates.bucket <> v_window THEN 1 ELSE fc_rates.count + 1 END
  WHERE fc_rates.bucket <> v_window OR fc_rates.count < p_limit
  RETURNING scope INTO v_scope;
  RETURN v_scope IS NOT NULL;
END $$;
-- statement
-- Request admission is separate from event publication limits. The single budget
-- row serializes admission so concurrent server instances cannot overspend.
CREATE TABLE IF NOT EXISTS fc_request_budget (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  minute bigint NOT NULL DEFAULT -1, minute_count integer NOT NULL DEFAULT 0,
  day bigint NOT NULL DEFAULT -1, day_count integer NOT NULL DEFAULT 0,
  cleanup_day bigint NOT NULL DEFAULT -1
);
-- statement
INSERT INTO fc_request_budget(singleton) VALUES (true) ON CONFLICT DO NOTHING;
-- statement
CREATE TABLE IF NOT EXISTS fc_request_clients (
  client text PRIMARY KEY CHECK (client ~ '^[a-f0-9]{64}$'),
  minute bigint NOT NULL, minute_count integer NOT NULL,
  day bigint NOT NULL, day_count integer NOT NULL
);
-- statement
CREATE INDEX IF NOT EXISTS fc_request_clients_day ON fc_request_clients(day);
-- statement
CREATE OR REPLACE FUNCTION fc_permit_request(p_client text, p_now timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE b fc_request_budget%ROWTYPE; c fc_request_clients%ROWTYPE;
  v_seconds bigint; v_minute bigint; v_day bigint;
BEGIN
  IF p_client IS NULL OR p_client !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'invalid-client-key'; END IF;
  SELECT * INTO b FROM fc_request_budget WHERE singleton FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'missing-request-budget'; END IF;
  -- Sample production time after admission lock acquisition. A queued request
  -- must not restore an earlier window when requests straddle a minute/day.
  p_now := coalesce(p_now, clock_timestamp());
  v_seconds := floor(extract(epoch FROM p_now));
  v_minute := floor(extract(epoch FROM p_now) / 60);
  v_day := floor(extract(epoch FROM p_now) / 86400);
  IF b.minute <> v_minute THEN b.minute := v_minute; b.minute_count := 0; END IF;
  IF b.day <> v_day THEN b.day := v_day; b.day_count := 0; END IF;
  IF b.cleanup_day <> v_day THEN
    -- Keep at most the current and preceding UTC day's pseudonymous keys.
    DELETE FROM fc_request_clients WHERE day < v_day - 1;
    b.cleanup_day := v_day;
  END IF;
  UPDATE fc_request_budget SET minute=b.minute, minute_count=b.minute_count,
    day=b.day, day_count=b.day_count, cleanup_day=b.cleanup_day WHERE singleton;
  -- Refuse new rows once globally full, bounding admitted-client storage growth.
  IF b.day_count >= 120000 THEN
    RETURN jsonb_build_object('allowed',false,'scope','relay','retryAfter',(v_day+1)*86400-v_seconds);
  END IF;
  IF b.minute_count >= 1200 THEN
    RETURN jsonb_build_object('allowed',false,'scope','relay','retryAfter',(v_minute+1)*60-v_seconds);
  END IF;
  SELECT * INTO c FROM fc_request_clients WHERE client=p_client;
  IF NOT FOUND THEN
    c.minute := v_minute; c.minute_count := 0; c.day := v_day; c.day_count := 0;
  END IF;
  IF c.minute <> v_minute THEN c.minute := v_minute; c.minute_count := 0; END IF;
  IF c.day <> v_day THEN c.day := v_day; c.day_count := 0; END IF;
  IF c.day_count >= 60000 THEN
    RETURN jsonb_build_object('allowed',false,'scope','client','retryAfter',(v_day+1)*86400-v_seconds);
  END IF;
  IF c.minute_count >= 120 THEN
    RETURN jsonb_build_object('allowed',false,'scope','client','retryAfter',(v_minute+1)*60-v_seconds);
  END IF;
  INSERT INTO fc_request_clients(client,minute,minute_count,day,day_count)
    VALUES(p_client,v_minute,c.minute_count+1,v_day,c.day_count+1)
  ON CONFLICT(client) DO UPDATE SET minute=EXCLUDED.minute, minute_count=EXCLUDED.minute_count,
    day=EXCLUDED.day, day_count=EXCLUDED.day_count;
  UPDATE fc_request_budget SET minute_count=b.minute_count+1, day_count=b.day_count+1 WHERE singleton;
  RETURN jsonb_build_object('allowed',true);
END $$;
-- statement
CREATE OR REPLACE FUNCTION fc_accept(p_event jsonb, p_bytes integer) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE m fc_meta%ROWTYPE; parent_event fc_events%ROWTYPE;
BEGIN
  -- Serializes dependency checks, deduplication, capacity, and sequence allocation.
  SELECT * INTO m FROM fc_meta WHERE singleton FOR UPDATE;
  IF EXISTS (SELECT 1 FROM fc_events WHERE id = p_event->>'id') THEN
    RETURN jsonb_build_object('id', p_event->>'id', 'result', 'already-present');
  END IF;
  IF m.event_count >= 2000 OR m.stored_bytes + p_bytes > 33554432 THEN RAISE EXCEPTION 'relay-capacity'; END IF;
  IF p_event->>'kind' = 'message' THEN
    IF NOT EXISTS (SELECT 1 FROM fc_events WHERE id = p_event->>'community' AND kind = 'community') THEN RAISE EXCEPTION 'unknown-community'; END IF;
    IF p_event->>'parent' <> '' THEN
      SELECT * INTO parent_event FROM fc_events WHERE id = p_event->>'parent';
      IF NOT FOUND OR parent_event.kind <> 'message' OR parent_event.community <> p_event->>'community' THEN RAISE EXCEPTION 'invalid-parent'; END IF;
    END IF;
  END IF;
  IF NOT fc_take('publish-all', 120, 60) OR NOT fc_take('author:' || (p_event->>'author'), 30, 3600) THEN RAISE EXCEPTION 'publish-rate'; END IF;
  INSERT INTO fc_events(seq,id,kind,author,community,event)
    VALUES(m.event_count,p_event->>'id',p_event->>'kind',p_event->>'author',p_event->>'community',p_event);
  UPDATE fc_meta SET event_count = event_count + 1, stored_bytes = stored_bytes + p_bytes WHERE singleton;
  RETURN jsonb_build_object('id', p_event->>'id', 'result', 'accepted');
END $$;
