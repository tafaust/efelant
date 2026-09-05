import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));

test("esm bundle exports the public client", async () => {
  const mod = await import(join(root, "../dist/efelant.esm.js"));
  assert.equal(typeof mod.EfelantClient, "function");
  assert.equal(typeof mod.createGatewayTransport, "function");
});

test("cjs bundle is present", () => {
  const src = readFileSync(join(root, "../dist/efelant.cjs.js"), "utf8");
  assert.match(src, /EfelantClient/);
});
