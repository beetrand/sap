export class ValidationError extends Error {}

export function parseReservation(body) {
  if (!body || typeof body !== "object") {
    throw new ValidationError("JSON body is required.");
  }

  const eventId = normalizedString(body.eventId);
  const seatId = normalizedString(body.seatId);
  const customerName = normalizedString(body.customerName);
  const idempotencyKey = normalizedString(body.idempotencyKey);

  if (!eventId || !seatId || !customerName || !idempotencyKey) {
    throw new ValidationError(
      "eventId, seatId, customerName and idempotencyKey are required.",
    );
  }

  if (customerName.length > 100) {
    throw new ValidationError("customerName must be 100 characters or fewer.");
  }

  if (idempotencyKey.length > 100) {
    throw new ValidationError("idempotencyKey must be 100 characters or fewer.");
  }

  return { eventId, seatId, customerName, idempotencyKey };
}

function normalizedString(value) {
  return typeof value === "string" ? value.trim() : "";
}
