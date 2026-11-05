// 利用者の入力MistakeとServer内部Errorを区別するための専用Error。
// HandlerはこのErrorだけをHTTP 400として返す。
export class ValidationError extends Error {}

// POST /reservationsのJSONを、DB処理へ渡して安全な形に整える。
// 外部入力は信用せず、型・必須項目・長さを最初に確認する。
export function parseReservation(body) {
  if (!body || typeof body !== "object") {
    throw new ValidationError("JSON body is required.");
  }

  // 前後の空白を除去し、String以外は空文字として扱う。
  const eventId = normalizedString(body.eventId);
  const seatId = normalizedString(body.seatId);
  const customerName = normalizedString(body.customerName);
  const idempotencyKey = normalizedString(body.idempotencyKey);

  // 4項目のどれか1つでも空なら、DBへAccessする前に拒否する。
  if (!eventId || !seatId || !customerName || !idempotencyKey) {
    throw new ValidationError(
      "eventId, seatId, customerName and idempotencyKey are required.",
    );
  }

  // DBやLogへ極端に長い値を入れられないよう上限を設ける。
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
