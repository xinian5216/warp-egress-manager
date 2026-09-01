import assert from "node:assert/strict";
import test from "node:test";

import worker from "../src/index.js";

const token = "warp-only-test-token";
const objects = new Map([
  ["public/install.sh", "#!/usr/bin/env bash\necho install\n"],
  ["releases/warp3xui/warp-3xui.sh", "#!/usr/bin/env bash\necho manager\n"],
  ["releases/warp3xui/warp-3xui.sha256", "abc123\n"],
]);

const env = {
  INSTALL_TOKEN: token,
  BUNDLES: {
    async get(key) {
      const content = objects.get(key);
      if (content === undefined) return null;

      return {
        body: content,
        httpEtag: '"test-etag"',
        size: new TextEncoder().encode(content).byteLength,
        writeHttpMetadata(headers) {
          headers.set("content-type", "application/octet-stream");
        },
      };
    },
  },
};

function request(path, options = {}) {
  return new Request(`https://warp-3xui-download.example${path}`, options);
}

test("rejects the bootstrap without authorization", async () => {
  const result = await worker.fetch(request("/install.sh"), env);
  assert.equal(result.status, 401);
  assert.equal(result.headers.get("www-authenticate"), "Bearer");
  assert.equal(result.headers.get("cache-control"), "no-store");
});

test("serves the authenticated bootstrap without public caching", async () => {
  const result = await worker.fetch(
    request("/install.sh", {
      headers: { Authorization: `Bearer ${token}` },
    }),
    env,
  );
  assert.equal(result.status, 200);
  assert.match(await result.text(), /echo install/);
  assert.equal(result.headers.get("cache-control"), "private, no-store");
});

test("rejects a protected object without the dedicated token", async () => {
  const result = await worker.fetch(
    request("/releases/warp3xui/warp-3xui.sh"),
    env,
  );
  assert.equal(result.status, 401);
  assert.equal(result.headers.get("www-authenticate"), "Bearer");
});

test("serves a protected object with the dedicated token", async () => {
  const result = await worker.fetch(
    request("/releases/warp3xui/warp-3xui.sh", {
      headers: { Authorization: `Bearer ${token}` },
    }),
    env,
  );
  assert.equal(result.status, 200);
  assert.match(await result.text(), /echo manager/);
  assert.equal(result.headers.get("cache-control"), "private, no-store");
});

test("HEAD returns metadata without a body", async () => {
  const result = await worker.fetch(
    request("/install.sh", {
      method: "HEAD",
      headers: { Authorization: `Bearer ${token}` },
    }),
    env,
  );
  assert.equal(result.status, 200);
  assert.equal(await result.text(), "");
  assert.equal(result.headers.get("etag"), '"test-etag"');
});

test("returns 404 for every unlisted path", async () => {
  const result = await worker.fetch(request("/warp3xui/install.sh"), env);
  assert.equal(result.status, 404);
});

test("rejects unsupported methods", async () => {
  const result = await worker.fetch(
    request("/install.sh", { method: "POST" }),
    env,
  );
  assert.equal(result.status, 405);
  assert.equal(result.headers.get("allow"), "GET, HEAD");
});
