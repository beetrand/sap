// Browserを起動せず、Terraform HTML Templateの壊れやすい部分を確認するScript。
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const template = await readFile(join(projectRoot, "web", "index.html.tftpl"), "utf8");
const apiToken = "${jsonencode(api_url)}";

// TerraformがAPI URLを埋め込むTokenは正確に1つ必要。
assert.equal(template.split(apiToken).length - 1, 1, "The API URL Terraform token must occur exactly once.");

// JavaScriptが参照するElement IDがHTMLから消えていないか確認する。
for (const id of ["event-title", "seats", "customer-name", "reserve", "message"]) {
  assert.match(template, new RegExp(`id=["']${id}["']`), `Required UI element is missing: ${id}`);
}

// 仮URLを埋め、Inline Scriptをnew FunctionでCompileして構文Errorを検出する。
const rendered = template.replace(apiToken, JSON.stringify("https://example.invalid"));
const scripts = [...rendered.matchAll(/<script>([\s\S]*?)<\/script>/g)];
assert.equal(scripts.length, 1, "Expected one inline application script.");
new Function(scripts[0][1]);

console.log("Ticketing UI template checks passed.");
