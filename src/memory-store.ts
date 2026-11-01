import { randomUUID } from "node:crypto";
import type { NewOrder, Order, Product, Store } from "./domain.js";
import { DomainError } from "./domain.js";

export const seedProducts: Product[] = [
  {
    id: "coffee-beans",
    name: "クラウドブレンド コーヒー豆",
    description: "学習の休憩に。中煎りでバランスのよい200gパックです。",
    price: 1280,
    imageUrl: "/images/coffee.svg",
  },
  {
    id: "architecture-notebook",
    name: "アーキテクチャ設計ノート",
    description: "構成図と設計判断を書き残せるA5方眼ノートです。",
    price: 780,
    imageUrl: "/images/notebook.svg",
  },
  {
    id: "serverless-mug",
    name: "Serverless マグ",
    description: "容量350ml。サーバー管理は不要ですが洗浄は必要です。",
    price: 1680,
    imageUrl: "/images/mug.svg",
  },
];

export class MemoryStore implements Store {
  private readonly orders: Order[] = [];

  async initialize(): Promise<void> {}
  async healthCheck(): Promise<void> {}
  async close(): Promise<void> {}

  async listProducts(): Promise<Product[]> {
    return structuredClone(seedProducts);
  }

  async getProduct(id: string): Promise<Product | null> {
    return structuredClone(seedProducts.find((product) => product.id === id) ?? null);
  }

  async createOrder(input: NewOrder): Promise<Order> {
    if (input.items.length === 0) {
      throw new DomainError("注文には商品が1つ以上必要です", "INVALID_ORDER");
    }

    const items = input.items.map((item) => {
      const product = seedProducts.find((candidate) => candidate.id === item.productId);
      if (!product) {
        throw new DomainError(`商品が見つかりません: ${item.productId}`, "PRODUCT_NOT_FOUND");
      }
      return {
        ...item,
        productName: product.name,
        unitPrice: product.price,
      };
    });

    const order: Order = {
      id: randomUUID(),
      customerId: input.customerId,
      total: items.reduce((sum, item) => sum + item.unitPrice * item.quantity, 0),
      status: "placed",
      createdAt: new Date().toISOString(),
      items,
    };
    this.orders.push(order);
    return structuredClone(order);
  }

  async listOrders(customerId: string): Promise<Order[]> {
    return structuredClone(this.orders.filter((order) => order.customerId === customerId).reverse());
  }
}
