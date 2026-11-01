import request from "supertest";
import { describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import { MemoryStore } from "../src/memory-store.js";

describe("EC API", () => {
  it("lists products and returns a product detail", async () => {
    const app = createApp(new MemoryStore());
    const list = await request(app).get("/api/products").expect(200);
    expect(list.body).toHaveLength(3);
    await request(app).get(`/api/products/${list.body[0].id}`).expect(200);
  });

  it("adds an order using server-side prices and shows order history", async () => {
    const app = createApp(new MemoryStore());
    const created = await request(app)
      .post("/api/orders")
      .send({ customerId: "test-user", items: [{ productId: "coffee-beans", quantity: 2 }] })
      .expect(201);
    expect(created.body.total).toBe(2560);
    expect(created.body.status).toBe("placed");

    const history = await request(app).get("/api/orders?customerId=test-user").expect(200);
    expect(history.body).toHaveLength(1);
    expect(history.body[0].items[0].quantity).toBe(2);
  });

  it("rejects invalid quantities and unknown products", async () => {
    const app = createApp(new MemoryStore());
    await request(app)
      .post("/api/orders")
      .send({ customerId: "test-user", items: [{ productId: "coffee-beans", quantity: 0 }] })
      .expect(400);
    await request(app)
      .post("/api/orders")
      .send({ customerId: "test-user", items: [{ productId: "missing", quantity: 1 }] })
      .expect(404);
  });

  it("reports health", async () => {
    await request(createApp(new MemoryStore())).get("/healthz").expect(200, { status: "ok" });
  });

  it("does not force HTTP assets to HTTPS in the Phase 1 environment", async () => {
    const response = await request(createApp(new MemoryStore())).get("/").expect(200);

    expect(response.headers["content-security-policy"]).not.toContain("upgrade-insecure-requests");
  });

  it("serves frontend JavaScript that can create a customer ID over HTTP", async () => {
    const response = await request(createApp(new MemoryStore())).get("/app.js").expect(200);

    expect(response.text).toContain("crypto.getRandomValues");
    expect(response.text).not.toContain("crypto.randomUUID");
  });
});
