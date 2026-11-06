// Aurora OutboxをStep Functions Standardへ橋渡しするPublisher Lambda。
import {
  SFNClient,
  StartExecutionCommand,
} from "@aws-sdk/client-sfn";
import {
  execute,
  rows,
  stringParameter,
  uuidParameter,
  withTransaction,
} from "./data-api.mjs";
import { parsePublisherRequest } from "./workflow-domain.mjs";

const stepFunctions = new SFNClient({});
const stateMachineArn = process.env.STATE_MACHINE_ARN;

export async function handler(input = {}) {
  const request = parsePublisherRequest(input);
  // API起動は指定1行だけ、Scheduler起動は未配信残件を最大10件Claimする。
  const claimed = request.mode === "single"
    ? await claimEvent(request.outboxId)
    : await claimEvents();
  const results = [];

  for (const event of claimed) {
    try {
      await startWorkflow(event);
      await markPublished(event.id);
      results.push({ id: event.id, status: "published" });
    } catch (error) {
      // 同じOutbox IDでExecutionが既に存在するなら、以前の開始は成功している。
      if (error?.name === "ExecutionAlreadyExists") {
        await markPublished(event.id);
        results.push({ id: event.id, status: "already-started" });
        continue;
      }

      await releaseClaim(event.id, error);
      results.push({ id: event.id, status: "failed", error: error?.name });
    }
  }

  console.log(
    JSON.stringify({
      event: "outbox_publish_completed",
      mode: request.mode,
      requestedOutboxId: request.outboxId,
      results,
    }),
  );
  return { mode: request.mode, claimed: claimed.length, results };
}

// 予約APIがCommit直後に渡したOutbox IDだけをLockして取得する通常経路。
async function claimEvent(outboxId) {
  return withTransaction(async (transactionId) => {
    const selected = await execute(
      `SELECT id, aggregate_id, event_type, payload::text AS payload_json
         FROM outbox_events
        WHERE id = :id
          AND published_at IS NULL
          AND (claimed_at IS NULL OR claimed_at < CURRENT_TIMESTAMP - INTERVAL '5 minutes')
        FOR UPDATE SKIP LOCKED`,
      [uuidParameter("id", outboxId)],
      transactionId,
    );
    const events = rows(selected);
    await markClaimed(events, transactionId);
    return events;
  });
}

// SKIP LOCKEDで同時Publisherが同じ行をClaimしないようにする。
async function claimEvents() {
  return withTransaction(async (transactionId) => {
    const selected = await execute(
      `SELECT id, aggregate_id, event_type, payload::text AS payload_json
         FROM outbox_events
        WHERE published_at IS NULL
          AND (claimed_at IS NULL OR claimed_at < CURRENT_TIMESTAMP - INTERVAL '5 minutes')
        ORDER BY created_at
        LIMIT 10
        FOR UPDATE SKIP LOCKED`,
      [],
      transactionId,
    );
    const events = rows(selected);
    await markClaimed(events, transactionId);
    return events;
  });
}

// Claim時刻と試行回数を同じTransaction内で記録する共通処理。
async function markClaimed(events, transactionId) {
  for (const event of events) {
    await execute(
      `UPDATE outbox_events
          SET claimed_at = CURRENT_TIMESTAMP,
              attempt_count = attempt_count + 1,
              last_error = NULL
        WHERE id = :id`,
      [uuidParameter("id", event.id)],
      transactionId,
    );
  }
}

async function startWorkflow(event) {
  const payload = JSON.parse(event.payload_json);
  await stepFunctions.send(
    new StartExecutionCommand({
      stateMachineArn,
      // UUIDとHyphenだけなのでStep FunctionsのExecution Nameに利用できる。
      name: `outbox-${event.id}`,
      input: JSON.stringify({
        outboxId: event.id,
        reservationId: event.aggregate_id,
        eventType: event.event_type,
        payload,
      }),
    }),
  );
}

async function markPublished(id) {
  await execute(
    `UPDATE outbox_events
        SET published_at = CURRENT_TIMESTAMP,
            claimed_at = NULL,
            last_error = NULL
      WHERE id = :id`,
    [uuidParameter("id", id)],
  );
}

async function releaseClaim(id, error) {
  const message = `${error?.name ?? "Error"}: ${error?.message ?? "unknown"}`;
  await execute(
    `UPDATE outbox_events
        SET claimed_at = NULL,
            last_error = :last_error
      WHERE id = :id`,
    [
      uuidParameter("id", id),
      stringParameter("last_error", message.slice(0, 1000)),
    ],
  );
}

