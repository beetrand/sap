import express from "express";
import helmet from "helmet";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import type { Store } from "./domain.js";
import { DomainError } from "./domain.js";

const customerIdSchema = z.string().trim().min(1).max(100).regex(/^[a-zA-Z0-9_-]+$/);
const orderSchema = z.object({
  customerId: customerIdSchema,
  items: z
    .array(
      z.object({
        productId: z.string().trim().min(1).max(100),
        quantity: z.number().int().min(1).max(20),
      }),
    )
    .min(1)
    .max(20)
    .refine((items) => new Set(items.map((item) => item.productId)).size === items.length, {
      message: "同じ商品を重複して指定できません",
    }),
});

export function createApp(store: Store) {
  const app = express();
  app.disable("x-powered-by");
  app.use(
    helmet({
      contentSecurityPolicy: {
        directives: {
          defaultSrc: ["'self'"],
          imgSrc: ["'self'", "data:"],
          styleSrc: ["'self'"],
          scriptSrc: ["'self'"],
          // Phase 3もScaling観察を優先してALBをHTTP公開し、機密Dataは扱わない。
          // Helmet enables this directive by default, which would rewrite relative assets to HTTPS.
          upgradeInsecureRequests: null,
        },
      },
    }),
  );
  app.use(express.json({ limit: "32kb" }));
  app.use((request, response, next) => {
    const startedAt = performance.now();
    const requestId = request.header("x-request-id") ?? randomUUID();
    response.setHeader("x-request-id", requestId);
    response.on("finish", () => {
      // ALBとDockerが定期実行するlivenessは大量になるため、通常のAccess Logから除外する。
      // RDS依存を確認する/readyzは障害調査に必要なのでLogへ残す。
      if (request.path !== "/livez") {
        console.log(
          JSON.stringify({
            level: "info",
            event: "request_completed",
            requestId,
            method: request.method,
            path: request.path,
            status: response.statusCode,
            durationMs: Math.round(performance.now() - startedAt),
          }),
        );
      }
    });
    next();
  });

  // ProcessがHTTP Requestを処理できることだけを確認するliveness。
  // RDS障害を理由に正常なECS Taskを作り直さないよう、外部依存へ接続しない。
  app.get("/livez", (_request, response) => {
    response.json({ status: "ok" });
  });

  // ApplicationがRDSを使ったRequestを処理できることを確認するreadiness。
  // ALBのTask置換判定には使わず、依存先障害の監視と切り分けに利用する。
  app.get("/readyz", async (_request, response) => {
    try {
      await store.healthCheck();
      response.json({ status: "ready" });
    } catch {
      response.status(503).json({ status: "not_ready" });
    }
  });

  app.get("/api/products", async (_request, response, next) => {
    try {
      response.json(await store.listProducts());
    } catch (error) {
      next(error);
    }
  });

  app.get("/api/products/:id", async (request, response, next) => {
    try {
      const product = await store.getProduct(request.params.id);
      if (!product) {
        response.status(404).json({ error: "商品が見つかりません" });
        return;
      }
      response.json(product);
    } catch (error) {
      next(error);
    }
  });

  app.post("/api/orders", async (request, response, next) => {
    try {
      const input = orderSchema.parse(request.body);
      response.status(201).json(await store.createOrder(input));
    } catch (error) {
      next(error);
    }
  });

  app.get("/api/orders", async (request, response, next) => {
    try {
      const customerId = customerIdSchema.parse(request.query.customerId);
      response.json(await store.listOrders(customerId));
    } catch (error) {
      next(error);
    }
  });

  app.use(express.static("public", { index: "index.html", maxAge: "1h" }));
  app.get("/{*path}", (_request, response) => response.sendFile("index.html", { root: "public" }));

  app.use((error: unknown, _request: express.Request, response: express.Response, _next: express.NextFunction) => {
    if (error instanceof z.ZodError) {
      response.status(400).json({ error: "入力が不正です", details: error.issues });
      return;
    }
    if (error instanceof DomainError) {
      response.status(error.code === "PRODUCT_NOT_FOUND" ? 404 : 400).json({ error: error.message });
      return;
    }
    console.error(error);
    response.status(500).json({ error: "サーバー内部でエラーが発生しました" });
  });

  return app;
}
