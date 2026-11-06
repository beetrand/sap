// AWSへ接続せず、Step Functions Retryを発生させるSimulation判断を確認する。
import test from "node:test";
import assert from "node:assert/strict";
import {
  decidePaymentOutcome,
  isSimulationMode,
  parsePublisherRequest,
} from "../src/workflow-domain.mjs";

test("payment transient mode fails twice and then succeeds", () => {
  assert.equal(
    decidePaymentOutcome("payment-transient", "charge", 1),
    "transient-error",
  );
  assert.equal(
    decidePaymentOutcome("payment-transient", "charge", 2),
    "transient-error",
  );
  assert.equal(
    decidePaymentOutcome("payment-transient", "charge", 3),
    "succeeded",
  );
});

test("decline applies to charge but not refund", () => {
  assert.equal(
    decidePaymentOutcome("payment-declined", "charge", 1),
    "declined",
  );
  assert.equal(
    decidePaymentOutcome("payment-declined", "refund", 1),
    "succeeded",
  );
});

test("refund failure keeps failing until the mode changes", () => {
  assert.equal(
    decidePaymentOutcome("refund-failure", "refund", 1),
    "transient-error",
  );
  assert.equal(
    decidePaymentOutcome("refund-failure", "refund", 10),
    "transient-error",
  );
});

test("only documented simulation modes are accepted", () => {
  assert.equal(isSimulationMode("success"), true);
  assert.equal(isSimulationMode("unknown"), false);
});

test("publisher handles a specified outbox as the immediate single path", () => {
  assert.deepEqual(
    parsePublisherRequest({
      outboxId: "123e4567-e89b-42d3-a456-426614174000",
    }),
    {
      mode: "single",
      outboxId: "123e4567-e89b-42d3-a456-426614174000",
    },
  );
});

test("publisher uses recovery mode when scheduler supplies no outbox id", () => {
  assert.deepEqual(parsePublisherRequest({ source: "scheduler" }), {
    mode: "recovery",
  });
  assert.throws(
    () => parsePublisherRequest({ outboxId: "not-a-uuid" }),
    /outboxId must be a UUID/,
  );
});
