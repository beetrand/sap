// 外部決済Providerの代わりに、DBへ冪等な決済・返金結果を記録するMock Lambda。
import {
  execute,
  rows,
  stringParameter,
  uuidParameter,
} from "./data-api.mjs";
import { getSimulationMode } from "./simulation.mjs";
import { decidePaymentOutcome } from "./workflow-domain.mjs";

export async function handler(input) {
  const reservationId = input?.reservationId;
  const operationType = input?.action === "refund" ? "refund" : "charge";
  if (!reservationId) throw new Error("reservationId is required");

  const operationKey = `${operationType === "charge" ? "payment" : "refund"}:${reservationId}`;
  const existing = await findOperation(operationKey);
  if (existing?.status === "succeeded") {
    return {
      ...input,
      reservationId,
      paymentOperation: existing,
      replayed: true,
    };
  }

  const reservation = await loadReservation(reservationId);
  if (!reservation) throw new Error("ReservationNotFound");

  const operation = await beginAttempt({
    reservationId,
    operationType,
    operationKey,
    amountYen: reservation.price_yen,
  });
  const mode = await getSimulationMode();
  const outcome = decidePaymentOutcome(
    mode,
    operationType,
    operation.attempt_count,
  );

  if (outcome === "declined") {
    await updateOperation(operationKey, "declined");
    throw namedError("PaymentDeclinedError", "Mock payment was declined.");
  }

  if (outcome === "transient-error") {
    await updateOperation(operationKey, "retrying");
    throw namedError(
      "TransientPaymentError",
      `Mock ${operationType} transient failure.`,
    );
  }

  const succeeded = await updateOperation(
    operationKey,
    "succeeded",
    `mock-${operationType}-${reservationId}`,
  );
  return {
    ...input,
    reservationId,
    paymentOperation: succeeded,
    replayed: false,
  };
}

async function findOperation(operationKey) {
  const result = await execute(
    `SELECT operation_key, operation_type, status, amount_yen,
            attempt_count, provider_reference
       FROM payments
      WHERE operation_key = :operation_key`,
    [stringParameter("operation_key", operationKey)],
  );
  return rows(result)[0] ?? null;
}

async function loadReservation(reservationId) {
  const result = await execute(
    `SELECT r.id, r.status, s.price_yen
       FROM reservations r
       JOIN seats s ON s.id = r.seat_id
      WHERE r.id = :reservation_id`,
    [uuidParameter("reservation_id", reservationId)],
  );
  return rows(result)[0] ?? null;
}

async function beginAttempt({
  reservationId,
  operationType,
  operationKey,
  amountYen,
}) {
  const result = await execute(
    `INSERT INTO payments
       (reservation_id, operation_type, operation_key, status, amount_yen, attempt_count)
     VALUES
       (:reservation_id, :operation_type, :operation_key, 'processing', :amount_yen, 1)
     ON CONFLICT (operation_key) DO UPDATE
       SET status = 'processing',
           attempt_count = payments.attempt_count + 1,
           updated_at = CURRENT_TIMESTAMP
     RETURNING operation_key, operation_type, status, amount_yen,
               attempt_count, provider_reference`,
    [
      uuidParameter("reservation_id", reservationId),
      stringParameter("operation_type", operationType),
      stringParameter("operation_key", operationKey),
      { name: "amount_yen", value: { longValue: amountYen } },
    ],
  );
  return rows(result)[0];
}

async function updateOperation(operationKey, status, providerReference = null) {
  const result = await execute(
    `UPDATE payments
        SET status = :status,
            provider_reference = COALESCE(:provider_reference, provider_reference),
            updated_at = CURRENT_TIMESTAMP
      WHERE operation_key = :operation_key
      RETURNING operation_key, operation_type, status, amount_yen,
                attempt_count, provider_reference`,
    [
      stringParameter("operation_key", operationKey),
      stringParameter("status", status),
      providerReference === null
        ? { name: "provider_reference", value: { isNull: true } }
        : stringParameter("provider_reference", providerReference),
    ],
  );
  return rows(result)[0];
}

function namedError(name, message) {
  const error = new Error(message);
  error.name = name;
  return error;
}

