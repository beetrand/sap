// Step Functionsから呼ばれ、ReservationとSeatの状態をTransactionで変更するLambda。
import {
  execute,
  rows,
  stringParameter,
  uuidParameter,
  withTransaction,
} from "./data-api.mjs";
import { getSimulationMode } from "./simulation.mjs";

export async function handler(input) {
  const action = input?.action;
  const reservationId = input?.reservationId;
  if (!action || !reservationId) {
    throw new Error("action and reservationId are required");
  }

  if (action === "confirm") return confirmReservation(input);
  if (action === "payment-failed") return failReservation(input);
  if (action === "mark-refunding") return markRefunding(input);
  if (action === "mark-refunded") return markRefunded(input);
  if (action === "email-queue-failed") return recordEmailQueueFailure(input);
  throw new Error(`Unsupported reservation action: ${action}`);
}

async function confirmReservation(input) {
  const mode = await getSimulationMode();
  if (mode === "confirmation-failure") {
    throw namedError(
      "ConfirmationFailedError",
      "Mock seat confirmation failure.",
    );
  }

  return withTransaction(async (transactionId) => {
    const current = await getReservation(input.reservationId, transactionId);
    if (current?.status === "confirmed") return { ...input, ...current };

    const seat = await execute(
      `UPDATE seats
          SET status = 'sold', updated_at = CURRENT_TIMESTAMP
        WHERE id = :seat_id AND status = 'held'
      RETURNING id`,
      [uuidParameter("seat_id", current.seat_id)],
      transactionId,
    );
    if (rows(seat).length !== 1) {
      throw namedError(
        "ConfirmationFailedError",
        "Seat is no longer held.",
      );
    }

    const updated = await execute(
      `UPDATE reservations
          SET status = 'confirmed', updated_at = CURRENT_TIMESTAMP
        WHERE id = :reservation_id AND status = 'pending'
      RETURNING id, seat_id, customer_name, status`,
      [uuidParameter("reservation_id", input.reservationId)],
      transactionId,
    );
    if (rows(updated).length !== 1) {
      throw namedError(
        "ConfirmationFailedError",
        "Reservation is not pending.",
      );
    }
    return { ...input, ...rows(updated)[0] };
  });
}

async function failReservation(input) {
  return withTransaction(async (transactionId) => {
    const current = await getReservation(input.reservationId, transactionId);
    if (current.status === "failed") return { ...input, ...current };

    await execute(
      `UPDATE seats
          SET status = 'available', updated_at = CURRENT_TIMESTAMP
        WHERE id = :seat_id AND status = 'held'`,
      [uuidParameter("seat_id", current.seat_id)],
      transactionId,
    );
    const updated = await updateReservationStatus(
      input.reservationId,
      "failed",
      "pending",
      transactionId,
    );
    return { ...input, ...updated };
  });
}

async function markRefunding(input) {
  const current = await getReservation(input.reservationId);
  if (current.status === "refunding") return { ...input, ...current };

  const updated = await updateReservationStatus(
    input.reservationId,
    "refunding",
    "pending",
  );
  return { ...input, ...updated };
}

async function markRefunded(input) {
  return withTransaction(async (transactionId) => {
    const current = await getReservation(input.reservationId, transactionId);
    if (current.status === "refunded") return { ...input, ...current };

    await execute(
      `UPDATE seats
          SET status = 'available', updated_at = CURRENT_TIMESTAMP
        WHERE id = :seat_id AND status = 'held'`,
      [uuidParameter("seat_id", current.seat_id)],
      transactionId,
    );
    const updated = await updateReservationStatus(
      input.reservationId,
      "refunded",
      "refunding",
      transactionId,
    );
    return { ...input, ...updated };
  });
}

async function recordEmailQueueFailure(input) {
  await execute(
    `INSERT INTO email_deliveries
       (reservation_id, status, attempt_count, last_error)
     VALUES
       (:reservation_id, 'queue_failed', 1, :last_error)
     ON CONFLICT (reservation_id) DO UPDATE
       SET status = 'queue_failed',
           attempt_count = email_deliveries.attempt_count + 1,
           last_error = EXCLUDED.last_error,
           updated_at = CURRENT_TIMESTAMP`,
    [
      uuidParameter("reservation_id", input.reservationId),
      stringParameter("last_error", "Step Functions could not enqueue mail."),
    ],
  );
  return { ...input, emailStatus: "queue_failed" };
}

async function getReservation(reservationId, transactionId) {
  const result = await execute(
    `SELECT id, seat_id, customer_name, status
       FROM reservations
      WHERE id = :reservation_id`,
    [uuidParameter("reservation_id", reservationId)],
    transactionId,
  );
  const reservation = rows(result)[0];
  if (!reservation) throw new Error("ReservationNotFound");
  return reservation;
}

// 想定した遷移元だけを更新し、誤ったRetryで状態を巻き戻さない。
async function updateReservationStatus(
  reservationId,
  status,
  expectedStatus,
  transactionId,
) {
  const result = await execute(
    `UPDATE reservations
        SET status = :status, updated_at = CURRENT_TIMESTAMP
      WHERE id = :reservation_id AND status = :expected_status
      RETURNING id, seat_id, customer_name, status`,
    [
      uuidParameter("reservation_id", reservationId),
      stringParameter("status", status),
      stringParameter("expected_status", expectedStatus),
    ],
    transactionId,
  );
  const reservation = rows(result)[0];
  if (!reservation) {
    throw namedError(
      "InvalidReservationTransition",
      `Reservation must be ${expectedStatus} before changing to ${status}.`,
    );
  }
  return reservation;
}

function namedError(name, message) {
  const error = new Error(message);
  error.name = name;
  return error;
}

