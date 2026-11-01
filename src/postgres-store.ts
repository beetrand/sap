import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import pg from "pg";
import type { NewOrder, Order, OrderItem, Product, Store } from "./domain.js";
import { DomainError } from "./domain.js";
import { seedProducts } from "./memory-store.js";

const { Pool } = pg;

type ProductRow = {
  id: string;
  name: string;
  description: string;
  price: string;
  image_url: string;
};

type OrderRow = {
  id: string;
  customer_id: string;
  total: string;
  status: "placed";
  created_at: Date;
};

type OrderItemRow = {
  order_id: string;
  product_id: string;
  product_name: string;
  unit_price: string;
  quantity: number;
};

export class PostgresStore implements Store {
  private readonly pool: pg.Pool;

  constructor() {
    this.pool = new Pool({
      host: requiredEnv("DATABASE_HOST"),
      port: Number(process.env.DATABASE_PORT ?? "5432"),
      database: requiredEnv("DATABASE_NAME"),
      user: requiredEnv("DATABASE_USER"),
      password: requiredEnv("DATABASE_PASSWORD"),
      max: Number(process.env.DATABASE_POOL_SIZE ?? "5"),
      ssl: createSslConfig(),
    });
  }

  async initialize(): Promise<void> {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      await client.query(`
      CREATE TABLE IF NOT EXISTS products (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT NOT NULL,
        price INTEGER NOT NULL CHECK (price >= 0),
        image_url TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS orders (
        id TEXT PRIMARY KEY,
        customer_id TEXT NOT NULL,
        total INTEGER NOT NULL CHECK (total >= 0),
        status TEXT NOT NULL CHECK (status = 'placed'),
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      );
      CREATE INDEX IF NOT EXISTS orders_customer_created_idx
        ON orders (customer_id, created_at DESC);
      CREATE TABLE IF NOT EXISTS order_items (
        order_id TEXT NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
        product_id TEXT NOT NULL REFERENCES products(id),
        product_name TEXT NOT NULL,
        unit_price INTEGER NOT NULL CHECK (unit_price >= 0),
        quantity INTEGER NOT NULL CHECK (quantity > 0),
        PRIMARY KEY (order_id, product_id)
      );
      `);

      for (const product of seedProducts) {
        await client.query(
        `INSERT INTO products (id, name, description, price, image_url)
         VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (id) DO UPDATE SET
           name = EXCLUDED.name,
           description = EXCLUDED.description,
           price = EXCLUDED.price,
           image_url = EXCLUDED.image_url`,
        [product.id, product.name, product.description, product.price, product.imageUrl],
        );
      }
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async healthCheck(): Promise<void> {
    await this.pool.query("SELECT 1");
  }

  async listProducts(): Promise<Product[]> {
    const result = await this.pool.query<ProductRow>("SELECT * FROM products ORDER BY name");
    return result.rows.map(mapProduct);
  }

  async getProduct(id: string): Promise<Product | null> {
    const result = await this.pool.query<ProductRow>("SELECT * FROM products WHERE id = $1", [id]);
    return result.rows[0] ? mapProduct(result.rows[0]) : null;
  }

  async createOrder(input: NewOrder): Promise<Order> {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const productIds = input.items.map((item) => item.productId);
      const productsResult = await client.query<ProductRow>(
        "SELECT * FROM products WHERE id = ANY($1::text[]) FOR SHARE",
        [productIds],
      );
      const products = new Map(productsResult.rows.map((row) => [row.id, mapProduct(row)]));
      const items: OrderItem[] = input.items.map((item) => {
        const product = products.get(item.productId);
        if (!product) {
          throw new DomainError(`商品が見つかりません: ${item.productId}`, "PRODUCT_NOT_FOUND");
        }
        return { ...item, productName: product.name, unitPrice: product.price };
      });
      const total = items.reduce((sum, item) => sum + item.unitPrice * item.quantity, 0);
      const id = randomUUID();
      const orderResult = await client.query<OrderRow>(
        `INSERT INTO orders (id, customer_id, total, status)
         VALUES ($1, $2, $3, 'placed')
         RETURNING *`,
        [id, input.customerId, total],
      );
      for (const item of items) {
        await client.query(
          `INSERT INTO order_items
             (order_id, product_id, product_name, unit_price, quantity)
           VALUES ($1, $2, $3, $4, $5)`,
          [id, item.productId, item.productName, item.unitPrice, item.quantity],
        );
      }
      await client.query("COMMIT");
      return mapOrder(orderResult.rows[0]!, items);
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async listOrders(customerId: string): Promise<Order[]> {
    const ordersResult = await this.pool.query<OrderRow>(
      "SELECT * FROM orders WHERE customer_id = $1 ORDER BY created_at DESC LIMIT 50",
      [customerId],
    );
    if (ordersResult.rows.length === 0) return [];
    const itemsResult = await this.pool.query<OrderItemRow>(
      "SELECT * FROM order_items WHERE order_id = ANY($1::text[]) ORDER BY product_name",
      [ordersResult.rows.map((order) => order.id)],
    );
    const grouped = new Map<string, OrderItem[]>();
    for (const row of itemsResult.rows) {
      const items = grouped.get(row.order_id) ?? [];
      items.push({
        productId: row.product_id,
        productName: row.product_name,
        unitPrice: Number(row.unit_price),
        quantity: row.quantity,
      });
      grouped.set(row.order_id, items);
    }
    return ordersResult.rows.map((row) => mapOrder(row, grouped.get(row.id) ?? []));
  }

  async close(): Promise<void> {
    await this.pool.end();
  }
}

function mapProduct(row: ProductRow): Product {
  return {
    id: row.id,
    name: row.name,
    description: row.description,
    price: Number(row.price),
    imageUrl: row.image_url,
  };
}

function mapOrder(row: OrderRow, items: OrderItem[]): Order {
  return {
    id: row.id,
    customerId: row.customer_id,
    total: Number(row.total),
    status: row.status,
    createdAt: row.created_at.toISOString(),
    items,
  };
}

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function createSslConfig(): false | { rejectUnauthorized: true; ca: string } {
  if (process.env.DATABASE_SSL !== "true") return false;
  return {
    rejectUnauthorized: true,
    ca: readFileSync(requiredEnv("DATABASE_CA_FILE"), "utf8"),
  };
}
