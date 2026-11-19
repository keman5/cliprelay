const maxWire = 10_080_000;
const reply = (status, body = null) => new Response(body, {status, headers: {"Cache-Control":"no-store"}});
async function digest(value) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))).toHex();
}
async function readBody(request, length) {
  if (!request.body) return null;
  const reader = request.body.getReader();
  const bytes = new Uint8Array(length);
  let offset = 0;
  try {
    for (;;) {
      const {done, value} = await reader.read();
      if (done) return offset === length ? bytes : null;
      if (value.length > length - offset) {
        await reader.cancel();
        return null;
      }
      bytes.set(value, offset);
      offset += value.length;
    }
  } finally { reader.releaseLock(); }
}
export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (path === "/health" && request.method === "GET") return reply(200, "ClipRelay/1");
    if (!env.RELAY_TOKEN || request.headers.get("Authorization") !== "Bearer " + env.RELAY_TOKEN) return reply(401);
    const route = /^\/v1\/box\/([a-f0-9]{64})(?:\/([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}))?$/.exec(path);
    if (!route) return reply(404);
    if (!(await env.LIMIT.limit({key: request.headers.get("CF-Connecting-IP") || "local"})).success) return reply(429);
    const [,box, id] = route;
    const prefix = "v1/" + box + "/";
    if (request.method === "PUT" && id) {
      const length = Number(request.headers.get("Content-Length"));
      if (!Number.isSafeInteger(length) || length < 1 || length > maxWire) return reply(413);
      // An immutable event can be safely retried after a lost acknowledgement.
      const body = await readBody(request, length);
      if (!body) return reply(400);
      const added = await env.BOX.put(prefix + id, body, {onlyIf:{etagDoesNotMatch:"*"}});
      if (!added) {
        const previous = await env.BOX.get(prefix + id);
        if (!previous || previous.size !== length) return reply(409);
        const a = new Uint8Array(await previous.arrayBuffer()), b = new Uint8Array(body);
        if (!a.every((v,i) => b[i] === v)) return reply(409);
      }
      return reply(204);
    }
    const reader = request.headers.get("X-ClipRelay-Reader") || "";
    if (!/^[a-f0-9]{64}$/.test(reader) || await digest(reader) !== box) return reply(403);
    if (!id && request.method === "GET") {
      const cursor = new URL(request.url).searchParams.get("cursor") || undefined;
      const result = await env.BOX.list({prefix, limit:30, cursor});
      return Response.json({ids:result.objects.map(o=>o.key.slice(prefix.length)),cursor:result.truncated?result.cursor:null},{headers:{"Cache-Control":"no-store"}});
    }
    if (id && request.method === "GET") {
      const object = await env.BOX.get(prefix + id);
      return object ? reply(200,object.body) : reply(404);
    }
    if (id && request.method === "DELETE") { await env.BOX.delete(prefix + id); return reply(204); }
    return reply(405);
  }
};
