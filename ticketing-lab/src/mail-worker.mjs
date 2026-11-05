// SQSからMail Messageを受けるMock Worker。実際の外部Mail送信は行わない。
import {
  execute,
  stringParameter,
  uuidParameter,
} from "./data-api.mjs";
import { getSimulationMode } from "./simulation.mjs";

export async function handler(event) {
  const mode = await getSimulationMode();

  for (const record of event.Records ?? []) {
    const message = JSON.parse(record.body);
    const reservationId = message.reservationId;
    if (!reservationId) throw new Error("reservationId is required");

    if (mode === "mail-failure") {
      await recordDelivery(
        reservationId,
        "failed",
        "Mock mail delivery failure.",
      );
      throw new Error("MockMailFailure");
    }

    await recordDelivery(reservationId, "sent", null);
    console.log(
      JSON.stringify({ event: "mock_mail_sent", reservationId }),
    );
  }

  return { processed: event.Records?.length ?? 0 };
}

async function recordDelivery(reservationId, status, errorMessage) {
  await execute(
    `INSERT INTO email_deliveries
       (reservation_id, status, attempt_count, last_error)
     VALUES
       (:reservation_id, :status, 1, :last_error)
     ON CONFLICT (reservation_id) DO UPDATE
       SET status = EXCLUDED.status,
           attempt_count = email_deliveries.attempt_count + 1,
           last_error = EXCLUDED.last_error,
           updated_at = CURRENT_TIMESTAMP`,
    [
      uuidParameter("reservation_id", reservationId),
      stringParameter("status", status),
      errorMessage === null
        ? { name: "last_error", value: { isNull: true } }
        : stringParameter("last_error", errorMessage),
    ],
  );
}
