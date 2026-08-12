import assert from "node:assert/strict";
import test from "node:test";

import worker from "../src/index.js";

function bundleObject(body, contentType = "application/octet-stream") {
  return {
    body,
    size: new TextEncoder().encode(body).byteLength,
    httpEtag: '"etag"',
    async text() {
      return body;
    },
    writeHttpMetadata(headers) {
      headers.set("content-type", contentType);
    },
  };
}

function makeEnv(entries, requestedKeys = []) {
  const objects = new Map(entries);
  return {
    INSTALL_TOKEN: "test-token",
    BUNDLES: {
      async get(key) {
        requestedKeys.push(key);
        return objects.get(key) || null;
      },
    },
  };
}

test("R2 WARP package routes require the bearer token", async () => {
  const request = new Request(
    "https://example.com/packages/cloudflare-warp/deb/bookworm/amd64/latest/cloudflare-warp.deb",
  );
  const response = await worker.fetch(request, makeEnv([]));
  assert.equal(response.status, 401);
});

test("authorized latest package route resolves its versioned archive", async () => {
  const latestKey =
    "packages/cloudflare-warp/deb/bookworm/amd64/latest/cloudflare-warp.deb";
  const versionKey =
    "packages/cloudflare-warp/deb/bookworm/amd64/latest/version";
  const archiveKey =
    "packages/cloudflare-warp/deb/bookworm/amd64/archive/2026.6.880.0/cloudflare-warp.deb";
  const requestedKeys = [];
  const request = new Request(`https://example.com/${latestKey}`, {
    headers: { Authorization: "Bearer test-token" },
  });
  const response = await worker.fetch(
    request,
    makeEnv(
      [
        [versionKey, bundleObject("2026.6.880.0\n", "text/plain")],
        [archiveKey, bundleObject("package")],
      ],
      requestedKeys,
    ),
  );
  assert.equal(response.status, 200);
  assert.equal(await response.text(), "package");
  assert.equal(response.headers.get("cache-control"), "private, no-store");
  assert.equal(
    response.headers.get("x-warpm-package-layout"),
    "archive-pointer-v1",
  );
  assert.deepEqual(requestedKeys, [versionKey, archiveKey]);
});

test("latest package route falls back during pointer migration", async () => {
  const latestKey =
    "packages/cloudflare-warp/deb/bookworm/amd64/latest/cloudflare-warp.deb";
  const versionKey =
    "packages/cloudflare-warp/deb/bookworm/amd64/latest/version";
  const requestedKeys = [];
  const request = new Request(`https://example.com/${latestKey}`, {
    headers: { Authorization: "Bearer test-token" },
  });
  const response = await worker.fetch(
    request,
    makeEnv([[latestKey, bundleObject("legacy-package")]], requestedKeys),
  );
  assert.equal(response.status, 200);
  assert.equal(await response.text(), "legacy-package");
  assert.deepEqual(requestedKeys, [versionKey, latestKey]);
});

test("latest checksum route resolves the matching archive", async () => {
  const latestKey =
    "packages/cloudflare-warp/deb/noble/amd64/latest/cloudflare-warp.sha256";
  const versionKey =
    "packages/cloudflare-warp/deb/noble/amd64/latest/version";
  const archiveKey =
    "packages/cloudflare-warp/deb/noble/amd64/archive/2026.6.880.0/cloudflare-warp.sha256";
  const request = new Request(`https://example.com/${latestKey}`, {
    headers: { Authorization: "Bearer test-token" },
  });
  const response = await worker.fetch(
    request,
    makeEnv([
      [versionKey, bundleObject("2026.6.880.0\n", "text/plain")],
      [archiveKey, bundleObject("abc123\n", "text/plain")],
    ]),
  );
  assert.equal(response.status, 200);
  assert.equal(await response.text(), "abc123\n");
});

test("invalid latest pointer never becomes an archive path", async () => {
  const latestKey =
    "packages/cloudflare-warp/deb/bookworm/amd64/latest/cloudflare-warp.deb";
  const versionKey =
    "packages/cloudflare-warp/deb/bookworm/amd64/latest/version";
  const requestedKeys = [];
  const request = new Request(`https://example.com/${latestKey}`, {
    headers: { Authorization: "Bearer test-token" },
  });
  const response = await worker.fetch(
    request,
    makeEnv(
      [[versionKey, bundleObject("../../secret\n", "text/plain")]],
      requestedKeys,
    ),
  );
  assert.equal(response.status, 404);
  assert.deepEqual(requestedKeys, [versionKey, latestKey]);
});

test("package route rejects encoded or empty path components", async () => {
  const request = new Request(
    "https://example.com/packages/cloudflare-warp/deb/bookworm/amd64/latest/%2e%2e%2fsecret",
    { headers: { Authorization: "Bearer test-token" } },
  );
  const response = await worker.fetch(request, makeEnv([]));
  assert.equal(response.status, 404);
});
