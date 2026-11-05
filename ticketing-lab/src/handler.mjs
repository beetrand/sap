// RDS Data API用Command。通常のTCP ConnectionやConnection Poolは使わず、
// HTTPS APIとしてSQLとTransaction命令をAuroraへ送る。
import {
  BeginTransactionCommand,
  CommitTransactionCommand,
  ExecuteStatementCommand,
  RDSDataClient,
  RollbackTransactionCommand,
} from "@aws-sdk/client-rds-data";
import { parseReservation, ValidationError } from "./domain.mjs";

// ClientはLambda Container再利用時にも使い回し、Requestごとの再生成を避ける。
const client = new RDSDataClient({});
// TerraformがLambda環境変数へ設定した接続先情報。
const resourceArn = process.env.DB_CLUSTER_ARN;
const secretArn = process.env.DB_SECRET_ARN;
const database = process.env.DB_NAME;

// すべてのData API Commandに共通する3項目。
const baseRequest = { resourceArn, secretArn, database };

// API GatewayからLambdaを呼ぶと最初に実行されるEntry Point。
export async function handler(event) {
  const method = event.requestContext?.http?.method;
  const path = event.rawPath ?? "/";

  try {
    // DBを確認しないLiveness。LambdaとAPI Gatewayだけの生存確認に使う。
    if (method === "GET" && path === "/health") {
      return response(200, { status: "ok" });
    }

    // Event一覧をDBから取得する。
    if (method === "GET" && path === "/events") {
      return response(200, { events: await listEvents() });
    }

    // /events/{eventId}/seatsからPath Parameterを取り出す。
    const seatsMatch = path.match(/^\/events\/([^/]+)\/seats$/);
    if (method === "GET" && seatsMatch) {
      return response(200, {
        seats: await listSeats(decodeURIComponent(seatsMatch[1])),
      });
    }

    // 予約作成。parseReservationで外部入力を検証してからDB処理へ進む。
    if (method === "POST" && path === "/reservations") {
      const input = parseReservation(JSON.parse(event.body ?? "null"));
      const result = await createReservation(input);
      return response(result.replayed ? 200 : 201, result);
    }

    return response(404, { message: "Not found." });
  } catch (error) {
    // CloudWatch LogsでRequest失敗を追えるよう、共通地点で記録する。
    console.error(JSON.stringify({ event: "request_failed", path, error }));

    if (error instanceof ValidationError || error instanceof SyntaxError) {
      return response(400, { message: error.message });
    }

    if (error instanceof SeatUnavailableError) {
      return response(409, { message: "The seat is no longer available." });
    }

    return response(500, { message: "Internal server error." });
  }
}

async function listEvents() {
  const result = await execute(
    `SELECT id, name, venue, starts_at
       FROM events
      ORDER BY starts_at`,
  );
  return rows(result);
}

async function listSeats(eventId) {
  const result = await execute(
    `SELECT id, seat_label, price_yen, status
       FROM seats
      WHERE event_id = :event_id
      ORDER BY seat_label`,
    [uuidParameter("event_id", eventId)],
  );
  return rows(result);
}

async function createReservation(input) {
  // 同じKeyの再送なら、新しい予約を作らず以前の結果を返す。
  // ClientがResponseを受け取れず再送した場合の二重登録を防ぐ。
  const existing = await findByIdempotencyKey(input.idempotencyKey);
  if (existing) return { ...existing, replayed: true };

  // 座席確保・予約・Outboxを全部成功または全部失敗にするためTransactionを開始する。
  const begun = await client.send(
    new BeginTransactionCommand(baseRequest),
  );
  const transactionId = begun.transactionId;

  try {
    // statusがavailableの時だけheldへ変更する条件付きUPDATE。
    // 同じ席へ同時Requestが来ても、DBがLockを調整し成功は1件だけになる。
    const held = await execute(
      `UPDATE seats
          SET status = 'held', updated_at = CURRENT_TIMESTAMP
        WHERE id = :seat_id
          AND event_id = :event_id
          AND status = 'available'
      RETURNING id, seat_label, price_yen`,
      [
        uuidParameter("seat_id", input.seatId),
        uuidParameter("event_id", input.eventId),
      ],
      transactionId,
    );

    // RETURNINGで座席が1件も返らなければ、既に他の利用者が確保した席。
    if (rows(held).length !== 1) {
      throw new SeatUnavailableError();
    }

    // 利用者へ見せる予約Record。idempotency_keyにはUNIQUE制約がある。
    const reservation = await execute(
      `INSERT INTO reservations
         (event_id, seat_id, customer_name, idempotency_key, status)
       VALUES
         (:event_id, :seat_id, :customer_name, :idempotency_key, 'pending')
       RETURNING id, event_id, seat_id, customer_name, status, created_at`,
      [
        uuidParameter("event_id", input.eventId),
        uuidParameter("seat_id", input.seatId),
        stringParameter("customer_name", input.customerName),
        stringParameter("idempotency_key", input.idempotencyKey),
      ],
      transactionId,
    );

    // 後でStep Functions等を開始するEventを、予約と同じTransaction内に保存する。
    // DB Commit後にEventだけ失う問題を避けるOutbox Patternである。
    const created = rows(reservation)[0];
    await execute(
      `INSERT INTO outbox_events
         (aggregate_type, aggregate_id, event_type, payload)
       VALUES
         ('reservation', :reservation_id, 'ReservationCreated',
          CAST(:payload AS jsonb))`,
      [
        uuidParameter("reservation_id", created.id),
        stringParameter("payload", JSON.stringify(created)),
      ],
      transactionId,
    );

    // 3つのDB変更がすべて成功したので確定する。
    await client.send(
      new CommitTransactionCommand({ ...baseRequest, transactionId }),
    );
    return { ...created, replayed: false };
  } catch (error) {
    // 途中で失敗した場合、座席だけheldになる等の半端な状態を元へ戻す。
    try {
      await client.send(
        new RollbackTransactionCommand({ ...baseRequest, transactionId }),
      );
    } catch (rollbackError) {
      // Rollback失敗は元Errorを上書きせず、別EventとしてLogへ残す。
      console.error(
        JSON.stringify({
          event: "rollback_failed",
          name: rollbackError?.name,
          message: rollbackError?.message,
        }),
      );
    }

    // 事前確認直後に同じKeyが同時登録される競合もあり得る。
    // UNIQUE制約Error後に既存予約を読み直し、再送として同じ結果を返す。
    if (error?.message?.includes("idempotency_key")) {
      const existingAfterRace = await findByIdempotencyKey(input.idempotencyKey);
      if (existingAfterRace) return { ...existingAfterRace, replayed: true };
    }
    throw error;
  }
}

async function findByIdempotencyKey(idempotencyKey) {
  const result = await execute(
    `SELECT id, event_id, seat_id, customer_name, status, created_at
       FROM reservations
      WHERE idempotency_key = :idempotency_key`,
    [stringParameter("idempotency_key", idempotencyKey)],
  );
  return rows(result)[0] ?? null;
}

// RDS Data APIのExecuteStatementを呼ぶ共通関数。
// transactionIdがある時だけ、BeginからCommit/Rollbackまで同じTransactionへ参加する。
async function execute(sql, parameters = [], transactionId) {
  return client.send(
    new ExecuteStatementCommand({
      ...baseRequest,
      sql,
      parameters,
      transactionId,
      includeResultMetadata: true,
      // Column名付きJSONで受け取ると、複雑なField配列をApplication側で変換せずに済む。
      formatRecordsAs: "JSON",
    }),
  );
}

// Data APIのJSON文字列を通常のJavaScript配列へ戻す。
function rows(result) {
  return result.formattedRecords ? JSON.parse(result.formattedRecords) : [];
}

// SQLへ文字列を安全に渡すNamed Parameter。文字列連結によるSQL Injectionを避ける。
function stringParameter(name, value) {
  return { name, value: { stringValue: value } };
}

// UUID列へ文字列を渡す時は、Data APIへ型Hintも明示する。
// HintがないstringValueはPostgreSQLでtext型になり、uuid列との比較が失敗する。
function uuidParameter(name, value) {
  return { name, value: { stringValue: value }, typeHint: "UUID" };
}

// API Gateway Lambda Proxy Integrationが期待するHTTP Response形式。
function response(statusCode, body) {
  return {
    statusCode,
    headers: { "content-type": "application/json; charset=utf-8" },
    body: JSON.stringify(body),
  };
}

// 空席競合をHTTP 409 Conflictへ変換するための内部Error。
class SeatUnavailableError extends Error {}
