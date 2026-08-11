const PUBLIC_ROUTES = new Map([["/install.sh", "public/install.sh"]]);

const PROTECTED_ROUTES = new Map([
  ["/releases/warpm/warpm.sh", "releases/warpm/warpm.sh"],
  ["/releases/warpm/warpm.sha256", "releases/warpm/warpm.sha256"],
  ["/releases/warp3xui/warp-3xui.sh", "releases/warp3xui/warp-3xui.sh"],
  ["/releases/warp3xui/warp-3xui.sha256", "releases/warp3xui/warp-3xui.sha256"],
]);

function packageObjectKey(pathname) {
  if (!pathname.startsWith("/packages/cloudflare-warp/")) return "";
  const objectKey = pathname.slice(1);
  if (!/^[0-9A-Za-z._/+:~-]+$/.test(objectKey)) return "";
  if (
    objectKey.split("/").some((part) => !part || part === "." || part === "..")
  ) {
    return "";
  }
  return objectKey;
}

async function secureEqual(left, right) {
  if (!left || !right) return false;

  const encoder = new TextEncoder();
  const [leftHash, rightHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(left)),
    crypto.subtle.digest("SHA-256", encoder.encode(right)),
  ]);

  const a = new Uint8Array(leftHash);
  const b = new Uint8Array(rightHash);
  let diff = a.length ^ b.length;

  for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
    diff |= (a[i] || 0) ^ (b[i] || 0);
  }

  return diff === 0;
}

function textResponse(message, status, extraHeaders = {}) {
  return new Response(`${message}\n`, {
    status,
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      ...extraHeaders,
    },
  });
}

function bearerToken(request) {
  const authorization = request.headers.get("Authorization") || "";
  return authorization.startsWith("Bearer ")
    ? authorization.slice(7).trim()
    : "";
}

export default {
  async fetch(request, env) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return textResponse("Method Not Allowed", 405, { Allow: "GET, HEAD" });
    }

    const pathname = new URL(request.url).pathname;
    const publicKey = PUBLIC_ROUTES.get(pathname);
    const protectedKey =
      PROTECTED_ROUTES.get(pathname) || packageObjectKey(pathname);

    if (!publicKey && !protectedKey) {
      return textResponse("Not Found", 404);
    }

    if (
      protectedKey &&
      !(await secureEqual(bearerToken(request), env.INSTALL_TOKEN))
    ) {
      return textResponse("Unauthorized", 401, {
        "www-authenticate": "Bearer",
      });
    }

    const objectKey = publicKey || protectedKey;
    const object = await env.BUNDLES.get(objectKey);

    if (!object) {
      return textResponse("Object Not Found", 404);
    }

    const headers = new Headers();
    object.writeHttpMetadata(headers);
    headers.set("etag", object.httpEtag);
    headers.set("content-length", String(object.size));
    headers.set("x-content-type-options", "nosniff");
    headers.set(
      "cache-control",
      publicKey ? "public, max-age=300" : "private, no-store",
    );

    if (publicKey) {
      headers.set("content-type", "text/x-shellscript; charset=utf-8");
    } else {
      const filename = pathname.split("/").pop();
      headers.set("content-disposition", `attachment; filename="${filename}"`);
    }

    return new Response(request.method === "HEAD" ? null : object.body, {
      status: 200,
      headers,
    });
  },
};
