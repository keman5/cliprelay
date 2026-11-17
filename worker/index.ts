import { normalizeUsername, validateUsername, validatePassword, MAX_CONTENT_LENGTH, MAX_ITEMS_PER_ACCOUNT, type ClipboardItem } from '../src/utils/clipboardLogic';

interface Env {
  DB: D1Database;
  ASSETS: Fetcher;
  AUTH_LIMITER: RateLimit;
}
interface User {
  id: string; username: string; display_name: string; password_hash: string; salt: string;
  failed_attempts: number; locked_until: number; lock_level: number; categories: string; revision: number; created_at: string;
}
const defaults = ['未分类', '代码片段', '终端命令', '常用链接', '文案灵感'];
const encoder = new TextEncoder();
const hex = (bytes: ArrayBuffer | Uint8Array) => Array.from(new Uint8Array(bytes), b => b.toString(16).padStart(2, '0')).join('');
const random = () => hex(crypto.getRandomValues(new Uint8Array(32)));
const digest = async (value: string) => hex(await crypto.subtle.digest('SHA-256', encoder.encode(value)));
export async function hashPassword(password: string, salt: string) {
  const key = await crypto.subtle.importKey('raw', encoder.encode(password), 'PBKDF2', false, ['deriveBits']);
  return hex(await crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt: encoder.encode(salt), iterations: 100000 }, key, 256));
}
const json = (data: unknown, status = 200, headers: HeadersInit = {}) => Response.json(data, { status, headers: { 'Cache-Control': 'no-store', ...headers } });
const fail = (error: string, status = 400) => json({ error }, status);
function cookie(token: string, remember: boolean, clear = false) {
  return `__Host-clipnote=${token}; Path=/; HttpOnly; Secure; SameSite=Lax${clear ? '; Max-Age=0' : remember ? '; Max-Age=2592000' : ''}`;
}
async function tokenHash(request: Request) {
  const token = request.headers.get('Cookie')?.match(/(?:^|;\s*)__Host-clipnote=([a-f0-9]{64})(?:;|$)/)?.[1];
  return token ? digest(token) : '';
}
async function workspace(env: Env, user: User, remember: boolean) {
  const rows = await env.DB.prepare('SELECT data FROM items WHERE user_id = ? ORDER BY id').bind(user.id).all<{ data: string }>();
  const items = rows.results.map(row => JSON.parse(row.data) as ClipboardItem).sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  return { account: { username: user.display_name, categories: JSON.parse(user.categories), items, createdAt: user.created_at }, revision: user.revision, remember };
}
async function startSession(request: Request, env: Env, user: User, remember: boolean) {
  const token = random();
  const now = Date.now();
  const oldHash = await tokenHash(request);
  const results = await env.DB.batch([
    env.DB.prepare('DELETE FROM sessions WHERE expires_at <= ? OR token_hash = ?').bind(now, oldHash),
    env.DB.prepare('INSERT INTO sessions (token_hash, user_id, expires_at, remember) SELECT ?, id, ?, ? FROM users WHERE id = ? AND locked_until <= ?').bind(await digest(token), now + (remember ? 30 : 1) * 86400000, remember ? 1 : 0, user.id, now),
  ]);
  if (!results[1].meta.changes) return fail('账号登录已暂停，请稍后重试', 429);
  return json(await workspace(env, user, remember), 200, { 'Set-Cookie': cookie(token, remember) });
}
export function validWorkspace(body: any): body is { categories: string[]; items: ClipboardItem[]; revision: number } {
  if (!body || !Number.isSafeInteger(body.revision) || body.revision < 0 || !Array.isArray(body.categories) || !Array.isArray(body.items)) return false;
  const { categories, items } = body;
  const text = (v: unknown, max: number) => typeof v === 'string' && v.trim().length > 0 && v.length <= max;
  return categories.length > 0 && categories.length <= 100 && categories.includes('未分类') &&
    categories.every((c: string) => text(c, 16) && !['全部', '收藏', 'ALL', 'FAVORITES'].includes(c)) &&
    new Set(categories.map((c: string) => c.toLowerCase())).size === categories.length &&
    items.length <= MAX_ITEMS_PER_ACCOUNT && new Set(items.map((i: ClipboardItem) => i?.id)).size === items.length &&
    items.every((i: ClipboardItem) => i && text(i.id, 100) && text(i.content, MAX_CONTENT_LENGTH) && categories.includes(i.category) &&
      typeof i.favorite === 'boolean' && typeof i.createdAt === 'string' && i.createdAt.length <= 40 && Number.isFinite(Date.parse(i.createdAt)) &&
      Array.isArray(i.tags) && i.tags.length <= 100 && i.tags.every((t: string) => text(t, 24)));
}
async function api(request: Request, env: Env) {
  const path = new URL(request.url).pathname;
  if (request.method !== 'GET') {
    if (request.headers.get('Origin') !== new URL(request.url).origin) return fail('请求来源无效', 403);
    if (!request.headers.get('Content-Type')?.startsWith('application/json')) return fail('请使用 JSON 请求', 415);
  }
  if ((path === '/api/register' || path === '/api/login') && request.method === 'POST') {
    const limit = await env.AUTH_LIMITER.limit({ key: request.headers.get('CF-Connecting-IP') || 'local' });
    if (!limit.success) return fail('操作过于频繁，请一分钟后重试', 429);
    const body = await request.json() as any;
    if (!body || typeof body.username !== 'string' || typeof body.password !== 'string' || typeof body.remember !== 'boolean') return fail('账号信息无效');
    const { username, password, remember } = body;
    const usernameCheck = validateUsername(username);
    if (!usernameCheck.valid) return fail(usernameCheck.error!);
    if (path === '/api/register' && !validatePassword(password).valid) return fail('密码需 12-20 个字符');
    if (!password || password.length > 1000) return fail('请输入有效密码');
    const key = normalizeUsername(username);
    let user = await env.DB.prepare('SELECT * FROM users WHERE username = ?').bind(key).first<User>();
    if (path === '/api/register') {
      if (user) return fail('该账号已被注册，不可重复注册', 409);
      const salt = random();
      const id = crypto.randomUUID();
      const created = new Date().toISOString();
      const result = await env.DB.prepare('INSERT INTO users (id, username, display_name, password_hash, salt, categories, created_at) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(username) DO NOTHING')
        .bind(id, key, username.trim(), await hashPassword(password, salt), salt, JSON.stringify(defaults), created).run();
      if (!result.meta.changes) return fail('该账号已被注册，不可重复注册', 409);
      user = (await env.DB.prepare('SELECT * FROM users WHERE id = ?').bind(id).first<User>())!;
    } else {
      if (!user) { await hashPassword(password, 'unknown-account'); return fail('账号或密码错误', 401); }
      const paused = (until: number) => json({ error: `登录已暂停，请于 ${new Date(until).toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai', hour12: false })}（北京时间）后重试`, retryAt: until }, 429, { 'Retry-After': String(Math.max(1, Math.ceil((until - Date.now()) / 1000))) });
      if (user.locked_until > Date.now()) return paused(user.locked_until);
      if (await hashPassword(password, user.salt) !== user.password_hash) {
        // shortcut: cap at JavaScript's last valid date; revisit if dates beyond year 275760 are needed.
        const results = await env.DB.batch([
          env.DB.prepare(`UPDATE users SET failed_attempts = failed_attempts + 1,
            locked_until = CASE WHEN failed_attempts >= 2 THEN MIN(8640000000000000, ? + 14400000 * (1 << MIN(lock_level, 30))) ELSE 0 END,
            lock_level = CASE WHEN failed_attempts >= 2 THEN MIN(lock_level + 1, 31) ELSE lock_level END
            WHERE id = ? AND locked_until <= ?`).bind(Date.now(), user.id, Date.now()),
          env.DB.prepare('SELECT locked_until FROM users WHERE id = ?').bind(user.id),
        ]);
        const until = (results[1].results[0] as { locked_until: number }).locked_until;
        if (until > Date.now()) return paused(until);
        return fail('账号或密码错误，连续输错 3 次暂停登录 4 小时，之后每次输错暂停时间翻倍', 401);
      }
      const reset = await env.DB.prepare('UPDATE users SET failed_attempts = 0, lock_level = 0, locked_until = 0 WHERE id = ? AND locked_until <= ?').bind(user.id, Date.now()).run();
      if (!reset.meta.changes) return fail('账号登录已暂停，请稍后重试', 429);
    }
    return startSession(request, env, user, remember);
  }
  const hash = await tokenHash(request);
  if (path === '/api/logout' && request.method === 'POST') {
    await env.DB.prepare('DELETE FROM sessions WHERE token_hash = ?').bind(hash).run();
    return json({ ok: true }, 200, { 'Set-Cookie': cookie('', false, true) });
  }
  const session = await env.DB.prepare('SELECT users.*, sessions.remember FROM sessions JOIN users ON users.id = sessions.user_id WHERE token_hash = ? AND expires_at > ?').bind(hash, Date.now()).first<User & { remember: number }>();
  if (path === '/api/session' && request.method === 'GET') return json(session ? await workspace(env, session, !!session.remember) : null);
  if (!session) return fail('登录已过期，请重新登录', 401);
  if (path === '/api/workspace' && request.method === 'PUT') {
    const body = await request.json();
    if (!validWorkspace(body)) return fail('剪切板数据无效或超出容量上限');
    const before = await env.DB.prepare('SELECT id, data FROM items WHERE user_id = ?').bind(session.id).all<{ id: string; data: string }>();
    // Guard every write by the same revision so a stale tab cannot overwrite newer data.
    const guard = 'EXISTS (SELECT 1 FROM users WHERE id = ? AND revision = ?)';
    const params = [session.id, body.revision];
    const next = new Map(body.items.map(item => [item.id, JSON.stringify(item)]));
    const previous = new Map(before.results.map(row => [row.id, row.data]));
    const statements: D1PreparedStatement[] = [];
    const removed = [...previous.keys()].filter(id => !next.has(id));
    if (removed.length) statements.push(env.DB.prepare(`DELETE FROM items WHERE user_id = ? AND id IN (SELECT value FROM json_each(?)) AND ${guard}`).bind(session.id, JSON.stringify(removed), ...params));
    const changed = [...next].filter(([id, data]) => previous.get(id) !== data).map(([, data]) => JSON.parse(data));
    for (let i = 0; i < changed.length; i += 50) statements.push(env.DB.prepare(`INSERT INTO items (user_id, id, data) SELECT ?, json_extract(value, '$.id'), value FROM json_each(?) WHERE ${guard} ON CONFLICT(user_id, id) DO UPDATE SET data = excluded.data`).bind(session.id, JSON.stringify(changed.slice(i, i + 50)), ...params));
    statements.push(env.DB.prepare('UPDATE users SET categories = ?, revision = revision + 1 WHERE id = ? AND revision = ?').bind(JSON.stringify(body.categories), ...params));
    const results = await env.DB.batch(statements);
    if (!results.at(-1)!.meta.changes) return fail('云端数据已有更新，请重新加载后再操作', 409);
    return json({ revision: body.revision + 1 });
  }
  return fail('接口不存在', 404);
}
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (url.pathname.startsWith('/api/')) {
        if (Number(request.headers.get('Content-Length')) > 20000000) return fail('请求内容过大', 413);
        return await api(request, env);
      }
      return env.ASSETS.fetch(request);
    } catch (error) {
      if (error instanceof SyntaxError) return fail('请求 JSON 无效');
      console.error('ClipNote API error', error instanceof Error ? error.message : 'unknown');
      return fail('服务暂时不可用，请稍后重试', 503);
    }
  },
} satisfies ExportedHandler<Env>;
