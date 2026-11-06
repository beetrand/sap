// AWSへ接続せずTestできる、決済Simulationの判断だけを置くModule。
export const simulationModes = Object.freeze([
  "success",
  "payment-transient",
  "payment-declined",
  "confirmation-failure",
  "refund-transient",
  "refund-failure",
  "mail-failure",
]);

// ScriptとLambdaの両方で同じ許容値を使うためのValidation。
export function isSimulationMode(value) {
  return simulationModes.includes(value);
}

// 同じoperation_keyのattemptCountを使い、一時障害を最初の2回だけ発生させる。
export function decidePaymentOutcome(mode, operationType, attemptCount) {
  if (operationType === "charge" && mode === "payment-declined") {
    return "declined";
  }

  if (
    operationType === "charge" &&
    mode === "payment-transient" &&
    attemptCount <= 2
  ) {
    return "transient-error";
  }

  if (
    operationType === "refund" &&
    mode === "refund-transient" &&
    attemptCount <= 2
  ) {
    return "transient-error";
  }

  if (operationType === "refund" && mode === "refund-failure") {
    return "transient-error";
  }

  return "succeeded";
}

// APIからOutbox IDが渡された時は1行、Scheduler起動時は回復Batchとして扱う。
export function parsePublisherRequest(event) {
  const outboxId = event?.outboxId;
  if (outboxId === undefined || outboxId === null || outboxId === "") {
    return { mode: "recovery" };
  }

  // 内部Invocationでも誤ったIDをSQLへ渡す前に止め、原因をLogで明確にする。
  if (
    typeof outboxId !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(outboxId)
  ) {
    throw new Error("outboxId must be a UUID");
  }

  return { mode: "single", outboxId };
}

