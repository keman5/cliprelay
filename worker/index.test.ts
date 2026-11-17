import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { hashPassword, validWorkspace } from './index';

test('password hashing is salted, deterministic and never plaintext', async () => {
  const hash = await hashPassword('ValidPassword123', 'one');
  assert.equal(hash.length, 64);
  assert.equal(hash, await hashPassword('ValidPassword123', 'one'));
  assert.notEqual(hash, await hashPassword('ValidPassword123', 'two'));
});
test('workspace validation rejects malformed and oversized data', () => {
  const data = { revision: 0, categories: ['未分类'], items: [{ id: 'one', content: 'hello', category: '未分类', tags: [], favorite: false, createdAt: new Date().toISOString() }] };
  assert.equal(validWorkspace(data), true);
  assert.equal(validWorkspace({ ...data, revision: -1 }), false);
  assert.equal(validWorkspace({ ...data, categories: ['未分类', '未分类'] }), false);
  assert.equal(validWorkspace({ ...data, items: [null] }), false);
  assert.equal(validWorkspace({ ...data, items: [...data.items, ...data.items] }), false);
  assert.equal(validWorkspace({ ...data, items: [{ ...data.items[0], content: 'x'.repeat(5001) }] }), false);
  assert.equal(validWorkspace({ ...data, items: [{ ...data.items[0], category: 'other' }] }), false);
  assert.equal(validWorkspace({ ...data, items: [{ ...data.items[0], favorite: 'false' }] }), false);
});
test('cross-origin writes fail before reaching the database', async () => {
  const response = await worker.fetch(new Request('https://clipnote.macseek.cc/api/register', { method: 'POST', headers: { Origin: 'https://other.example', 'Content-Type': 'application/json' }, body: '{}' }), {} as any);
  assert.equal(response.status, 403);
});
