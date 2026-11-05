import {
  BeginTransactionCommand,
  CommitTransactionCommand,
  ExecuteStatementCommand,
  RDSDataClient,
  RollbackTransactionCommand,
} from "@aws-sdk/client-rds-data";
import { parseReservation, ValidationError } from "./domain.mjs";

const client = new RDSDataClient({});
const resourceArn = process.env.DB_CLUSTER_ARN;
const secretArn = process.env.DB_SECRET_ARN;
const database = process.env.DB_NAME;

const baseRequest = { resourceArn, secretArn, database };

export async function handler(event) {
  const method = event.requestContext?.http?.method;
  const path = event.rawPath ?? "/";

  try {
    if (method === "GET" && path === "/health") {
      return response(200, { status: "ok" });
    }

    if (method === "GET" && path === "/events") {
      return response(200, { events: await listEvents() });
    }

    const seatsMatch = path.match(/^\/events\/([^/]+)\/seats$/);
    if (method === "GET" && seatsMatch) {
      return response(200, {
        seats: await listSeats(decodeURIComponent(seatsMatch[1])),
      });
    }

    if (method === "POST" && path === "/reservations") {
      const input = parseReservation(JSON.parse(event.body ?? "null"));
      const result = await createReservation(input);
      return response(result.replayed ? 200 : 201, result);
    }

    return response(404, { message: "Not found." });
  } catch (error) {
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
    [stringParameter("event_id", eventId)],
  );
  return rows(result);
}

async function createReservation(input) {
  const existing = await findByIdempotencyKey(input.idempotencyKey);
  if (existing) return { ...existing, replayed: true };

  const begun = await client.send(
    new BeginTransactionCommand(baseRequest),
  );
  const transactionId = begun.transactionId;

  try {
    const held = await execute(
      `UPDATE seats
          SET status = 'held', updated_at = CURRENT_TIMESTAMP
        WHERE id = :seat_id
          AND event_id = :event_id
          AND status = 'available'
      RETURNING id, seat_label, price_yen`,
      [
        stringParameter("seat_id", input.seatId),
        stringParameter("event_id", input.eventId),
      ],
      transactionId,
    );

    if (rows(held).length !== 1) {
      throw new SeatUnavailableError();
    }

    const reservation = await execute(
      `INSERT INTO reservations
         (event_id, seat_id, customer_name, idempotency_key, status)
       VALUES
         (:event_id, :seat_id, :customer_name, :idempotency_key, 'pending')
       RETURNING id, event_id, seat_id, customer_name, status, created_at`,
      [
        stringParameter("event_id", input.eventId),
        stringParameter("seat_id", input.seatId),
        stringParameter("customer_name", input.customerName),
        stringParameter("idempotency_key", input.idempotencyKey),
      ],
      transactionId,
    );

    const created = rows(reservation)[0];
    await execute(
      `INSERT INTO outbox_events
         (aggregate_type, aggregate_id, event_type, payload)
       VALUES
         ('reservation', :reservation_id, 'ReservationCreated',
          CAST(:payload AS jsonb))`,
      [
        stringParameter("reservation_id", created.id),
        stringParameter("payload", JSON.stringify(created)),
      ],
      transactionId,
    );

    await client.send(
      new CommitTransactionCommand({ ...baseRequest, transactionId }),
    );
    return { ...created, replayed: false };
  } catch (error) {
    try {
      await client.send(
        new RollbackTransactionCommand({ ...baseRequest, transactionId }),
      );
    } catch (rollbackError) {
      console.error(
        JSON.stringify({
          event: "rollback_failed",
          name: rollbackError?.name,
          message: rollbackError?.message,
        }),
      );
    }

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

async function execute(sql, parameters = [], transactionId) {
  return client.send(
    new ExecuteStatementCommand({
      ...baseRequest,
      sql,
      parameters,
      transactionId,
      includeResultMetadata: true,
      formatRecordsAs: "JSON",
    }),
  );
}

function rows(result) {
  return result.formattedRecords ? JSON.parse(result.formattedRecords) : [];
}

function stringParameter(name, value) {
  return { name, value: { stringValue: value } };
}

function response(statusCode, body) {
  return {
    statusCode,
    headers: { "content-type": "application/json; charset=utf-8" },
    body: JSON.stringify(body),
  };
}

class SeatUnavailableError extends Error {}
