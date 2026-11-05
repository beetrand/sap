CREATE EXTENSION IF NOT EXISTS pgcrypto;
-- statement-break
CREATE TABLE IF NOT EXISTS events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  venue text NOT NULL,
  starts_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- statement-break
CREATE TABLE IF NOT EXISTS seats (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  seat_label text NOT NULL,
  price_yen integer NOT NULL CHECK (price_yen >= 0),
  status text NOT NULL DEFAULT 'available'
    CHECK (status IN ('available', 'held', 'sold')),
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (event_id, seat_label)
);
-- statement-break
CREATE TABLE IF NOT EXISTS reservations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES events(id),
  seat_id uuid NOT NULL REFERENCES seats(id),
  customer_name text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  status text NOT NULL
    CHECK (status IN ('pending', 'confirmed', 'failed', 'refunding', 'refunded')),
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- statement-break
CREATE TABLE IF NOT EXISTS outbox_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  aggregate_type text NOT NULL,
  aggregate_id uuid NOT NULL,
  event_type text NOT NULL,
  payload jsonb NOT NULL,
  published_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- statement-break
CREATE INDEX IF NOT EXISTS idx_outbox_unpublished
  ON outbox_events (created_at)
  WHERE published_at IS NULL;
-- statement-break
WITH new_event AS (
  INSERT INTO events (name, venue, starts_at)
  SELECT 'SAP Learning Live', 'Tokyo Lab Arena', CURRENT_TIMESTAMP + INTERVAL '30 days'
  WHERE NOT EXISTS (SELECT 1 FROM events)
  RETURNING id
)
INSERT INTO seats (event_id, seat_label, price_yen)
SELECT new_event.id, 'A-' || LPAD(n::text, 2, '0'), 8000
FROM new_event
CROSS JOIN generate_series(1, 20) AS n;
