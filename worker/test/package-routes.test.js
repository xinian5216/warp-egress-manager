import assert from "node:assert/strict";
import test from "node:test";

import worker from "../src/index.js";

function makeEnv(expectedKey) {
  return {
    INSTALL_TOKEN: "test-token",
    BUNDLES: {
      async get(key) {
        assert.equal(key, expectedKey);
        return {
          body: "package",
          size: 7,
          httpEtag: '"etag"',
          writeHttpMetadata(headers) {
            headers.set("content-type", "application/octet-stream");
          },
        };
      },
    },
  };
}

test("R2 WARP package routes require the bearer token", async () => {
  const request = new Request(
    "https://example.com/packages/cloudflare-warp/deb/bookworm/amd64/latest/cloudflare-warp.deb",
  );
  const response = await worker.fetch(request, makeEnv("unused"));
  assert.equal(response.status, 401);
});

test("authorized R2 WARP package route maps to the same object key", async () => {
  const key =
    "packages/cloudflare-warp/deb/bookworm/amd64/latest/cloudflare-warp.deb";
  const request = new Request(`https://example.com/${key}`, {
    headers: { Authorization: "Bearer test-token" },
  });
  const response = await worker.fetch(request, makeEnv(key));
  assert.equal(response.status, 200);
  assert.equal(await response.text(), "package");
  assert.equal(response.headers.get("cache-control"), "private, no-store");
});

test("package route rejects encoded or empty path components", async () => {
  const request = new Request(
    "https://example.com/packages/cloudflare-warp/deb/bookworm/amd64/latest/%2e%2e%2fsecret",
    { headers: { Authorization: "Bearer test-token" } },
  );
  const response = await worker.fetch(request, makeEnv("unused"));
  assert.equal(response.status, 404);
});
