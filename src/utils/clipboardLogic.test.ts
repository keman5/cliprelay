import test from 'node:test';
import assert from 'node:assert/strict';
import {
  validatePassword,
  addClipboardItem,
  toggleFavoriteItem,
  deleteClipboardItem,
  clearAllClipboardItems,
  addTagToItem,
  removeTagFromItem,
  addCategory,
  renameCategory,
  deleteCategory,
  buildTimelineBuckets,
  filterAndPaginateItems,
  createInitialDatabase,
  MAX_ITEMS_PER_ACCOUNT,
} from './clipboardLogic';

test('password validation strictly enforces 12-20 characters', () => {
  assert.equal(validatePassword('short123456').valid, false); // 11 chars
  assert.equal(validatePassword('exact12chars').valid, true); // 12 chars
  assert.equal(validatePassword('twenty_characters_20').valid, true); // 20 chars
  assert.equal(validatePassword('twenty_one_chars_1234').valid, false); // 21 chars
});

function account() {
  return { username: 'test_user', categories: ['未分类', '代码片段'], items: [], createdAt: new Date().toISOString() } as import('./clipboardLogic').UserAccount;
}

test('initial database has no public accounts or sample records', () => {
  assert.deepEqual(createInitialDatabase(), { accounts: {} });
});

test('clipboard item enforces 5000 char limit and 1000 item account limit', () => {
  const user = account();

  // Empty content rejected
  assert.equal(addClipboardItem(user, { content: '   ' }).ok, false);

  // 5001 chars rejected
  const tooLong = 'a'.repeat(5001);
  assert.equal(addClipboardItem(user, { content: tooLong }).ok, false);

  // 5000 chars accepted
  const exact5000 = 'b'.repeat(5000);
  const ok5000 = addClipboardItem(user, { content: exact5000, category: '代码片段', tags: ['#test', 'long'] });
  assert.equal(ok5000.ok, true);
  assert.deepEqual(ok5000.item?.tags, ['test', 'long']);

  // Fill up to 1000 items
  for (let i = user.items.length; i < MAX_ITEMS_PER_ACCOUNT; i++) {
    user.items.push({
      id: `bulk_${i}`,
      content: `item ${i}`,
      category: '未分类',
      tags: [],
      favorite: false,
      createdAt: new Date().toISOString(),
    });
  }
  assert.equal(user.items.length, 1000);

  // 1001st item must be rejected
  const overQuota = addClipboardItem(user, { content: 'one too many' });
  assert.equal(overQuota.ok, false);
  assert.match(overQuota.error || '', /1000/);
});

test('tags, categories, favorites, delete, and clear all work accurately', () => {
  const user = account();
  const item = addClipboardItem(user, { content: 'hello world', category: '代码片段' }).item!;

  toggleFavoriteItem(user, item.id);
  assert.equal(user.items[0].favorite, true);

  addTagToItem(user, item.id, '#typescript');
  addTagToItem(user, item.id, 'react');
  assert.deepEqual(user.items[0].tags, ['typescript', 'react']);

  removeTagFromItem(user, item.id, 'typescript');
  assert.deepEqual(user.items[0].tags, ['react']);

  assert.equal(addCategory(user, '工作笔记').valid, true);
  assert.equal(renameCategory(user, '代码片段', '核心代码').valid, true);
  assert.equal(user.items[0].category, '核心代码');

  assert.equal(deleteCategory(user, '核心代码'), true);
  assert.equal(user.items[0].category, '未分类');

  assert.equal(deleteClipboardItem(user, item.id), true);
  assert.equal(user.items.length, 0);

  addClipboardItem(user, { content: 'a' });
  addClipboardItem(user, { content: 'b' });
  assert.equal(clearAllClipboardItems(user), 2);
  assert.equal(user.items.length, 0);
});

test('timeline bucketing groups items by date in current month, 上个月, and earlier months (几月)', () => {
  const fixedNow = new Date(2026, 10, 17, 15, 0, 0); // Nov 17, 2026
  const items = Array.from({ length: 18 }, (_, i) => ({ id: String(i), content: 'test', category: '未分类', tags: [], favorite: false, createdAt: new Date(2026, 10 - (i % 4), 17, 12).toISOString() }));
  const buckets = buildTimelineBuckets(items, fixedNow);

  const labels = buckets.map((b) => b.label);
  assert.ok(labels.includes('今天'), 'Should include 今天');
  assert.ok(labels.includes('上个月'), 'Should include 上个月');
  assert.ok(labels.includes('9月'), 'Should include 9月');
  assert.ok(labels.includes('8月'), 'Should include 8月');

  // Check pagination & filtering
  const page1 = filterAndPaginateItems(items, {
    categoryTab: 'ALL',
    timelineKey: 'ALL',
    tagFilter: '',
    searchQuery: '',
    page: 1,
    pageSize: 6,
    now: fixedNow,
  });
  assert.equal(page1.pageItems.length, 6);
  assert.equal(page1.totalPages, 3);
});
