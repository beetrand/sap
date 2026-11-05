export type Product = {
  id: string;
  name: string;
  description: string;
  price: number;
  imageUrl: string;
};

export type OrderItemInput = {
  productId: string;
  quantity: number;
};

export type OrderItem = OrderItemInput & {
  productName: string;
  unitPrice: number;
};

export type Order = {
  id: string;
  customerId: string;
  total: number;
  status: "placed";
  createdAt: string;
  items: OrderItem[];
};

export type NewOrder = {
  customerId: string;
  items: OrderItemInput[];
};

export interface Store {
  initialize(): Promise<void>;
  healthCheck(): Promise<void>;
  listProducts(): Promise<Product[]>;
  getProduct(id: string): Promise<Product | null>;
  createOrder(input: NewOrder): Promise<Order>;
  listOrders(customerId: string): Promise<Order[]>;
  close(): Promise<void>;
}

export class DomainError extends Error {
  constructor(
    message: string,
    public readonly code: "PRODUCT_NOT_FOUND" | "INVALID_ORDER",
  ) {
    super(message);
  }
}
