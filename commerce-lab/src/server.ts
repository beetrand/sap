import { createApp } from "./app.js";
import { MemoryStore } from "./memory-store.js";
import { PostgresStore } from "./postgres-store.js";

const port = Number(process.env.PORT ?? "3000");
const store = process.env.DATABASE_HOST ? new PostgresStore() : new MemoryStore();

await initializeWithRetry();
const server = createApp(store).listen(port, "0.0.0.0", () => {
  console.log(JSON.stringify({ level: "info", event: "server_started", port }));
});

async function initializeWithRetry(): Promise<void> {
  const maxAttempts = 10;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      await store.initialize();
      return;
    } catch (error) {
      console.error(
        JSON.stringify({
          level: "error",
          event: "database_initialization_failed",
          attempt,
          maxAttempts,
          message: error instanceof Error ? error.message : "unknown error",
        }),
      );
      if (attempt === maxAttempts) throw error;
      await new Promise((resolve) => setTimeout(resolve, Math.min(attempt * 2_000, 10_000)));
    }
  }
}

async function shutdown(signal: string) {
  console.log(JSON.stringify({ level: "info", event: "shutdown_started", signal }));
  server.close(async () => {
    await store.close();
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 10_000).unref();
}

process.on("SIGTERM", () => void shutdown("SIGTERM"));
process.on("SIGINT", () => void shutdown("SIGINT"));
