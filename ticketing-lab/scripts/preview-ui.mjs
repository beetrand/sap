// AWSへDeployする前に、実APIの代わりとなるMock Serverで画面を試すScript。
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";

const port = 4173;
const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const template = await readFile(join(projectRoot, "web", "index.html.tftpl"), "utf8");
// Terraform TokenへLocal URLを入れ、Browserで実行できるHTMLへ変換する。
const html = template.replace("${jsonencode(api_url)}", JSON.stringify(`http://127.0.0.1:${port}`));
// Event 1件・Seat 20件をMemory上に用意する。AWSやDBは使わない。
const eventId = "00000000-0000-4000-8000-000000000001";
const seats = Array.from({ length: 20 }, (_, index) => ({
  id: `00000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
  seat_label: `A-${String(index + 1).padStart(2, "0")}`,
  price_yen: index < 5 ? 12000 : 8000,
  status: [6, 12, 16].includes(index) ? "held" : "available",
}));
// Mock予約もMemory上に保持し、非同期確定の画面PollをLocalで確認する。
const reservations = new Map();

createServer(async (request, response) => {
  // Previewでも本番APIに近いResponse Headerを返す。
  response.setHeader("access-control-allow-origin", "*");
  response.setHeader("content-type", "application/json; charset=utf-8");

  // 予約画面本体を返す。
  if (request.method === "GET" && request.url === "/") {
    response.setHeader("content-type", "text/html; charset=utf-8");
    return response.end(html);
  }

  // 本番LambdaのGET /eventsと同じShapeのMock Response。
  if (request.method === "GET" && request.url === "/events") {
    return response.end(JSON.stringify({ events: [{ id: eventId, name: "NEON HORIZON 2026", venue: "有明アリーナ", starts_at: "2026-12-12T09:00:00.000Z" }] }));
  }

  if (request.method === "GET" && request.url === `/events/${eventId}/seats`) {
    return response.end(JSON.stringify({ seats }));
  }

  // 選択Seatをheldにし、再選択時は409を返して競合を再現する。
  if (request.method === "POST" && request.url === "/reservations") {
    let body = "";
    for await (const chunk of request) body += chunk;
    const input = JSON.parse(body);
    const seat = seats.find((candidate) => candidate.id === input.seatId);
    if (!seat || seat.status !== "available") {
      response.statusCode = 409;
      return response.end(JSON.stringify({ message: "この座席はすでに予約されています。" }));
    }
    seat.status = "held";
    const reservation = {
      id: randomUUID(),
      status: "pending",
      seat_label: seat.seat_label,
    };
    reservations.set(reservation.id, reservation);
    // Step Functionsの代わりに1秒後、決済とSeat確定が成功した状態へ進める。
    setTimeout(() => {
      reservation.status = "confirmed";
      seat.status = "sold";
    }, 1000);
    response.statusCode = 201;
    return response.end(JSON.stringify(reservation));
  }

  const reservationMatch = request.url?.match(/^\/reservations\/([^/]+)$/);
  if (request.method === "GET" && reservationMatch) {
    const reservation = reservations.get(reservationMatch[1]);
    if (!reservation) {
      response.statusCode = 404;
      return response.end(JSON.stringify({ message: "Reservation not found." }));
    }
    return response.end(JSON.stringify(reservation));
  }

  response.statusCode = 404;
  response.end(JSON.stringify({ message: "Not found" }));
}).listen(port, "127.0.0.1", () => {
  console.log(`Ticketing UI preview: http://127.0.0.1:${port}`);
});
