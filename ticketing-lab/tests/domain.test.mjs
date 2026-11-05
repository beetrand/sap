// Node.js標準Test Runnerで、AWSへ接続せず入力Validationだけを高速確認する。
import test from "node:test";
import assert from "node:assert/strict";
import { parseReservation, ValidationError } from "../src/domain.mjs";

// 正常入力では空白を除去し、期待する4項目だけが返ることを確認する。
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

// 冪等KeyがないRequestは二重予約防止ができないため、必ず拒否する。
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
