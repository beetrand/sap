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

