import assert from 'node:assert/strict';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const config = process.env.CLIPRELAY_CONFIG_DIR ?? join(homedir(), '.config', 'cliprelay-test');
const { RELAY_TOKEN } = JSON.parse(readFileSync(join(config, 'worker-secrets.json'), 'utf8'));
assert.match(RELAY_TOKEN, /^[a-f0-9]{64}$/);
const reader = randomBytes(32).toString('hex');
const box = createHash('sha256').update(reader).digest('hex');
const endpoint = 'https://cliprelay-test.macseek.cc/v1/box/' + box;
const object = endpoint + '/' + randomUUID();
const auth = { Authorization: 'Bearer ' + RELAY_TOKEN };
const owner = { ...auth, 'X-ClipRelay-Reader': reader };
const bytes = randomBytes(256);
const request = (url, method, headers, body) => fetch(url, { method, headers, body, redirect: 'error', signal: AbortSignal.timeout(30000) });
assert.equal((await request(endpoint, 'GET', {})).status, 401);
assert.equal((await request(endpoint, 'GET', auth)).status, 403);
try {
  assert.equal((await request(object, 'PUT', auth, bytes)).status, 204);
  assert.equal((await request(object, 'PUT', auth, bytes)).status, 204);
  assert.equal((await request(object, 'PUT', auth, randomBytes(bytes.length))).status, 409);
  assert.equal((await request(object, 'DELETE', { ...auth, 'X-ClipRelay-Reader': '0'.repeat(64) })).status, 403);
  const response = await request(object, 'GET', owner);
  assert.equal(response.status, 200);
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), bytes);
} finally {
  assert.equal((await request(object, 'DELETE', owner)).status, 204);
}
assert.deepEqual((await (await request(endpoint, 'GET', owner)).json()).ids, []);
console.log('PASS live Worker authentication, reader isolation, immutable retry, conflict, cleanup');
