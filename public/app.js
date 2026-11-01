const state = {
  products: [],
  cart: readCart(),
  customerId: localStorage.getItem("sap-commerce-customer") ?? createCustomerId(),
};
localStorage.setItem("sap-commerce-customer", state.customerId);

const yen = new Intl.NumberFormat("ja-JP", { style: "currency", currency: "JPY" });
const dateTime = new Intl.DateTimeFormat("ja-JP", { dateStyle: "medium", timeStyle: "short" });

function createCustomerId() {
  // randomUUID() requires a secure context, while getRandomValues() also works on the HTTP-only Phase 1 ALB.
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return `guest-${Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

function readCart() {
  try {
    const value = JSON.parse(localStorage.getItem("sap-commerce-cart") ?? "{}");
    return value && typeof value === "object" && !Array.isArray(value) ? value : {};
  } catch {
    return {};
  }
}

function text(tag, value, className) {
  const element = document.createElement(tag);
  element.textContent = value;
  if (className) element.className = className;
  return element;
}

async function api(path, options) {
  const response = await fetch(path, {
    ...options,
    headers: { "Content-Type": "application/json", ...options?.headers },
  });
  const body = await response.json();
  if (!response.ok) throw new Error(body.error ?? "リクエストに失敗しました");
  return body;
}

async function loadProducts() {
  const status = document.querySelector("#product-status");
  try {
    state.products = await api("/api/products");
    status.textContent = `${state.products.length}商品`;
    renderProducts();
    renderCart();
  } catch (error) {
    status.textContent = error.message;
  }
}

function renderProducts() {
  const list = document.querySelector("#product-list");
  list.replaceChildren();
  for (const product of state.products) {
    const card = document.createElement("article");
    card.className = "product-card";
    const image = document.createElement("img");
    image.src = product.imageUrl;
    image.alt = "";
    card.append(image, text("h3", product.name), text("p", product.description));
    const actions = document.createElement("div");
    actions.className = "card-actions";
    actions.append(text("strong", yen.format(product.price)));
    const detail = text("button", "詳細を見る", "secondary");
    detail.type = "button";
    detail.addEventListener("click", () => showProduct(product));
    const add = text("button", "追加", "primary");
    add.type = "button";
    add.addEventListener("click", () => addToCart(product.id));
    actions.append(detail, add);
    card.append(actions);
    list.append(card);
  }
}

function showProduct(product) {
  const dialog = document.querySelector("#product-dialog");
  dialog.querySelector("#dialog-image").src = product.imageUrl;
  dialog.querySelector("#dialog-name").textContent = product.name;
  dialog.querySelector("#dialog-description").textContent = product.description;
  dialog.querySelector("#dialog-price").textContent = yen.format(product.price);
  dialog.querySelector("#dialog-add").onclick = () => {
    addToCart(product.id);
    dialog.close();
  };
  dialog.showModal();
}

function addToCart(productId) {
  state.cart[productId] = Math.min((state.cart[productId] ?? 0) + 1, 20);
  persistCart();
}

function changeQuantity(productId, quantity) {
  if (quantity <= 0) delete state.cart[productId];
  else state.cart[productId] = Math.min(quantity, 20);
  persistCart();
}

function persistCart() {
  localStorage.setItem("sap-commerce-cart", JSON.stringify(state.cart));
  renderCart();
}

function renderCart() {
  const container = document.querySelector("#cart-items");
  const entries = Object.entries(state.cart)
    .map(([id, quantity]) => ({ product: state.products.find((item) => item.id === id), quantity }))
    .filter((entry) => entry.product);
  container.replaceChildren();

  if (entries.length === 0) container.append(text("p", "カートは空です。", "empty"));
  let total = 0;
  let count = 0;
  for (const { product, quantity } of entries) {
    total += product.price * quantity;
    count += quantity;
    const row = document.createElement("div");
    row.className = "cart-row";
    const description = document.createElement("div");
    description.append(text("strong", product.name), text("span", yen.format(product.price)));
    const controls = document.createElement("div");
    controls.className = "quantity";
    const decrease = text("button", "−", "icon-button");
    decrease.type = "button";
    decrease.setAttribute("aria-label", `${product.name}を1個減らす`);
    decrease.onclick = () => changeQuantity(product.id, quantity - 1);
    const increase = text("button", "+", "icon-button");
    increase.type = "button";
    increase.setAttribute("aria-label", `${product.name}を1個増やす`);
    increase.onclick = () => changeQuantity(product.id, quantity + 1);
    controls.append(decrease, text("span", String(quantity)), increase);
    row.append(description, controls, text("strong", yen.format(product.price * quantity)));
    container.append(row);
  }
  document.querySelector("#cart-total").textContent = yen.format(total);
  document.querySelector("#cart-count").textContent = String(count);
  document.querySelector("#checkout-button").disabled = entries.length === 0;
}

async function checkout() {
  const button = document.querySelector("#checkout-button");
  const status = document.querySelector("#checkout-status");
  button.disabled = true;
  status.textContent = "注文を登録しています…";
  try {
    const items = Object.entries(state.cart).map(([productId, quantity]) => ({ productId, quantity }));
    const order = await api("/api/orders", {
      method: "POST",
      body: JSON.stringify({ customerId: state.customerId, items }),
    });
    state.cart = {};
    persistCart();
    status.textContent = `注文 ${order.id.slice(0, 8)} を登録しました。`;
    await loadOrders();
  } catch (error) {
    status.textContent = error.message;
    button.disabled = false;
  }
}

async function loadOrders() {
  const container = document.querySelector("#order-list");
  try {
    const orders = await api(`/api/orders?customerId=${encodeURIComponent(state.customerId)}`);
    container.replaceChildren();
    if (orders.length === 0) {
      container.append(text("p", "注文履歴はありません。", "empty"));
      return;
    }
    for (const order of orders) {
      const card = document.createElement("article");
      card.className = "order-card";
      const heading = document.createElement("div");
      heading.className = "order-heading";
      heading.append(text("strong", `注文 ${order.id.slice(0, 8)}`), text("span", dateTime.format(new Date(order.createdAt))));
      const itemList = document.createElement("ul");
      for (const item of order.items) {
        itemList.append(text("li", `${item.productName} × ${item.quantity} — ${yen.format(item.unitPrice * item.quantity)}`));
      }
      card.append(heading, itemList, text("strong", `合計 ${yen.format(order.total)}`));
      container.append(card);
    }
  } catch (error) {
    container.replaceChildren(text("p", error.message, "message"));
  }
}

document.querySelector("#checkout-button").addEventListener("click", checkout);
document.querySelector("#refresh-orders").addEventListener("click", loadOrders);
document.querySelector(".dialog-close").addEventListener("click", () => document.querySelector("#product-dialog").close());

await Promise.all([loadProducts(), loadOrders()]);
