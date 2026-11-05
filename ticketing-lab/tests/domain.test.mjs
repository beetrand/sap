import test from "node:test";
import assert from "node:assert/strict";
import { parseReservation, ValidationError } from "../src/domain.mjs";

test("reservation input is trimmed and accepted", () => {
  assert.deepEqual(
    parseReservation({
      eventId: " event-1 ",
      seatId: " seat-1 ",
      customerName: " Alice ",
      idempotencyKey: " request-1 ",
    }),
    {
      eventId: "event-1",
      seatId: "seat-1",
      customerName: "Alice",
      idempotencyKey: "request-1",
    },
  );
});

test("missing idempotency key is rejected", () => {
  assert.throws(
    () =>
      parseReservation({
        eventId: "event-1",
        seatId: "seat-1",
        customerName: "Alice",
      }),
    ValidationError,
  );
});
