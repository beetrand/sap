-- UUIDをDB内で生成するgen_random_uuid()を使うためのPostgreSQL Extension。
CREATE EXTENSION IF NOT EXISTS pgcrypto;
-- statement-breakはinitialize-database.ps1がSQLを1文ずつData APIへ送る区切り。
-- statement-break

-- 販売対象のEvent。1 Eventに複数のSeatが紐付く親Table。
CREATE TABLE IF NOT EXISTS events (
  -- Application側で連番を予測されにくいUUIDをPrimary Keyにする。
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  venue text NOT NULL,
  starts_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- statement-break

-- Eventごとの座席と現在状態を管理するTable。
CREATE TABLE IF NOT EXISTS seats (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- 親Event削除時、存在できなくなったSeatも同時に削除する。
  event_id uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  seat_label text NOT NULL,
  price_yen integer NOT NULL CHECK (price_yen >= 0),
  -- CHECK制約により、ApplicationのBugでも未知の状態を保存させない。
  status text NOT NULL DEFAULT 'available'
    CHECK (status IN ('available', 'held', 'sold')),
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  -- 同じEvent内でA-01等のLabelが重複しないようにする。
  UNIQUE (event_id, seat_label)
);
-- statement-break

-- 利用者が作成した予約。決済・返金を追加した後もStatusでLifecycleを追う。
CREATE TABLE IF NOT EXISTS reservations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES events(id),
  seat_id uuid NOT NULL REFERENCES seats(id),
  customer_name text NOT NULL,
  -- Client再送時に同じKeyで2件作れないようDBのUNIQUE制約を最後の砦にする。
  idempotency_key text NOT NULL UNIQUE,
  status text NOT NULL
    CHECK (status IN ('pending', 'confirmed', 'failed', 'refunding', 'refunded')),
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- statement-break

-- DB更新後に非同期処理へ渡すEventを一時保存するOutbox Table。
-- 予約と同じTransactionでINSERTし、「予約はあるがEventがない」状態を防ぐ。
CREATE TABLE IF NOT EXISTS outbox_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  aggregate_type text NOT NULL,
  aggregate_id uuid NOT NULL,
  event_type text NOT NULL,
  payload jsonb NOT NULL,
  -- published_atがNULLなら、まだStep Functions等へ渡していないEvent。
  published_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- statement-break

-- 未配信Eventだけを小さなIndexにし、Publisherの検索を速くするPartial Index。
CREATE INDEX IF NOT EXISTS idx_outbox_unpublished
  ON outbox_events (created_at)
  WHERE published_at IS NULL;
-- statement-break

-- Publisherが同じOutboxを安全にRetryするための管理Column。
-- ADD COLUMN IF NOT EXISTSなので、既に作成済みDBへ再実行しても安全にMigrationできる。
ALTER TABLE outbox_events
  ADD COLUMN IF NOT EXISTS attempt_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS claimed_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_error text;
-- statement-break

-- 模擬決済と返金を、Retryされても一度だけ成功させるOperation Table。
CREATE TABLE IF NOT EXISTS payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id uuid NOT NULL REFERENCES reservations(id),
  operation_type text NOT NULL CHECK (operation_type IN ('charge', 'refund')),
  -- payment:{reservationId} / refund:{reservationId}を一意にする。
  operation_key text NOT NULL UNIQUE,
  status text NOT NULL
    CHECK (status IN ('processing', 'retrying', 'succeeded', 'declined', 'failed')),
  amount_yen integer NOT NULL CHECK (amount_yen >= 0),
  attempt_count integer NOT NULL DEFAULT 0,
  provider_reference text,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- statement-break

-- Mailは注文Workflowから分離するが、成功・失敗・試行回数をSQLで観察できるよう記録する。
CREATE TABLE IF NOT EXISTS email_deliveries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id uuid NOT NULL UNIQUE REFERENCES reservations(id),
  status text NOT NULL CHECK (status IN ('sent', 'failed', 'queue_failed')),
  attempt_count integer NOT NULL DEFAULT 0,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- statement-break

-- 初回学習用Data。eventsが空の時だけ1 Eventと20 Seatを作るため再実行しても増殖しない。
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
