import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import worker from './index';

test('login cooldown grows 4 → 8 → 16 hours, preserves records, and resets on success', async (t) => {
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  for (const file of ['0001_initial.sql', '0002_exponential_login_cooldown.sql']) {
    db.exec(readFileSync(new URL('../migrations/' + file, import.meta.url), 'utf8'));
  }
  const prepare = (sql: string) => {
    let args: any[] = [];
    const stmt = {
      bind: (...values: any[]) => { args = values; return stmt; },
      first: async () => db.prepare(sql).get(...args) ?? null,
      all: async () => ({ results: db.prepare(sql).all(...args) }),
      run: async () => ({ meta: { changes: Number(db.prepare(sql).run(...args).changes) } }),
      execute: () => sql.startsWith('SELECT') ? { results: db.prepare(sql).all(...args) } : { meta: { changes: Number(db.prepare(sql).run(...args).changes) } },
    };
    return stmt;
  };
  const env = { DB: { prepare, batch: async (statements: ReturnType<typeof prepare>[]) => {
    db.exec('BEGIN');
    try { const results = statements.map(s => s.execute()); db.exec('COMMIT'); return results; }
    catch (error) { db.exec('ROLLBACK'); throw error; }
  } }, AUTH_LIMITER: { limit: async () => ({ success: true }) } } as any;
  let now = Date.now();
  t.mock.method(Date, 'now', () => now);
  const call = (path: string, body: unknown) => worker.fetch(new Request('https://clipnote.macseek.cc/api/' + path, {
    method: 'POST', headers: { Origin: 'https://clipnote.macseek.cc', 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  }), env);
  const credentials = { username: 'cooldown.test+clipnote@example.com', password: 'ValidPassword123', remember: false };
  assert.equal((await call('register', credentials)).status, 200);
  assert.equal((await call('register', { ...credentials, username: credentials.username.toUpperCase() })).status, 409);
  assert.equal((await call('login', { ...credentials, username: ' ' + credentials.username.toUpperCase() + ' ' })).status, 200);
  const user = () => db.prepare('SELECT * FROM users').get()!;
  db.prepare('INSERT INTO items VALUES (?, ?, ?)').run(user().id!, 'kept', '{"content":"keep me"}');
  const wrong = () => call('login', { ...credentials, password: 'wrong' });
  assert.equal((await wrong()).status, 401);
  // A successful login before the third failure clears the consecutive-failure counter.
  assert.equal((await call('login', credentials)).status, 200);
  assert.equal(user().failed_attempts, 0);
  assert.equal((await wrong()).status, 401);
  assert.equal((await wrong()).status, 401);
  for (const hours of [4, 8, 16]) {
    const response = await wrong();
    assert.equal(response.status, 429);
    assert.equal(response.headers.get('Retry-After'), String(hours * 3600));
    assert.equal(user().locked_until, now + hours * 3600000);
    const attempts = user().failed_attempts;
    assert.equal((await wrong()).status, 429);
    assert.equal((await call('login', credentials)).status, 429);
    assert.equal(user().failed_attempts, attempts, 'blocked requests must not extend the cooldown');
    now += hours * 3600000;
  }
  assert.equal((await call('login', credentials)).status, 200);
  assert.equal(user().lock_level, 0);
  assert.equal(user().failed_attempts, 0);
  assert.equal(user().locked_until, 0);
  assert.equal((db.prepare('SELECT COUNT(*) AS n FROM items').get()!).n, 1);
  assert.ok(Number((db.prepare('SELECT COUNT(*) AS n FROM sessions').get()!).n) > 0);
  assert.equal((await wrong()).status, 401);
  assert.equal((await wrong()).status, 401);
  assert.equal((await wrong()).status, 429);
  assert.equal(user().locked_until, now + 4 * 3600000);
});
