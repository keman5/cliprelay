import test from 'node:test';
import assert from 'node:assert/strict';
import {
  validatePassword,
  registerAccount,
  authenticateAccount,
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

test('account registration prevents duplicate usernames and requires 12-20 char password', () => {
  const db = createInitialDatabase();
  const res1 = registerAccount(db, 'alice_dev', 'ValidPass12345');
  assert.equal(res1.ok, true);
  assert.equal(res1.account?.username, 'alice_dev');

  // Duplicate username (even with different casing) must be rejected
  const resDup = registerAccount(db, 'Alice_Dev', 'AnotherValid1234');
  assert.equal(resDup.ok, false);
  assert.match(resDup.error || '', /已被注册/);
});

test('account authentication locks account after 3 consecutive failed attempts', () => {
  const db = createInitialDatabase();
  registerAccount(db, 'lock_tester', 'CorrectPass1234');

  // 1st wrong attempt
  const a1 = authenticateAccount(db, 'lock_tester', 'WrongPass00001');
  assert.equal(a1.ok, false);
  assert.equal(a1.locked, false);
  assert.equal(a1.remainingAttempts, 2);

  // 2nd wrong attempt
  const a2 = authenticateAccount(db, 'lock_tester', 'WrongPass00002');
  assert.equal(a2.ok, false);
  assert.equal(a2.locked, false);
  assert.equal(a2.remainingAttempts, 1);

  // 3rd wrong attempt -> account locked
  const a3 = authenticateAccount(db, 'lock_tester', 'WrongPass00003');
  assert.equal(a3.ok, false);
  assert.equal(a3.locked, true);
  assert.equal(a3.remainingAttempts, 0);

  // Even correct password must fail once locked
  const a4 = authenticateAccount(db, 'lock_tester', 'CorrectPass1234');
  assert.equal(a4.ok, false);
  assert.equal(a4.locked, true);
});

test('successful login before 3 strikes resets failedAttempts counter', () => {
  const db = createInitialDatabase();
  registerAccount(db, 'reset_tester', 'CorrectPass1234');

  authenticateAccount(db, 'reset_tester', 'WrongPass00001');
  authenticateAccount(db, 'reset_tester', 'WrongPass00002');

  const okLogin = authenticateAccount(db, 'reset_tester', 'CorrectPass1234');
  assert.equal(okLogin.ok, true);
  assert.equal(okLogin.account?.failedAttempts, 0);
});

test('clipboard item enforces 5000 char limit and 1000 item account limit', () => {
  const db = createInitialDatabase();
  const reg = registerAccount(db, 'clip_user', 'ValidPassword123');
  const account = reg.account!;

  // Empty content rejected
  assert.equal(addClipboardItem(account, { content: '   ' }).ok, false);

  // 5001 chars rejected
  const tooLong = 'a'.repeat(5001);
  assert.equal(addClipboardItem(account, { content: tooLong }).ok, false);

  // 5000 chars accepted
  const exact5000 = 'b'.repeat(5000);
  const ok5000 = addClipboardItem(account, { content: exact5000, category: '代码片段', tags: ['#test', 'long'] });
  assert.equal(ok5000.ok, true);
  assert.deepEqual(ok5000.item?.tags, ['test', 'long']);

  // Fill up to 1000 items
  for (let i = account.items.length; i < MAX_ITEMS_PER_ACCOUNT; i++) {
    account.items.push({
      id: `bulk_${i}`,
      content: `item ${i}`,
      category: '未分类',
      tags: [],
      favorite: false,
      createdAt: new Date().toISOString(),
    });
  }
  assert.equal(account.items.length, 1000);

  // 1001st item must be rejected
  const overQuota = addClipboardItem(account, { content: 'one too many' });
  assert.equal(overQuota.ok, false);
  assert.match(overQuota.error || '', /1000/);
});

test('tags, categories, favorites, delete, and clear all work accurately', () => {
  const db = createInitialDatabase();
  const account = registerAccount(db, 'cat_user', 'ValidPassword123').account!;
  const item = addClipboardItem(account, { content: 'hello world', category: '代码片段' }).item!;

  toggleFavoriteItem(account, item.id);
  assert.equal(account.items[0].favorite, true);

  addTagToItem(account, item.id, '#typescript');
  addTagToItem(account, item.id, 'react');
  assert.deepEqual(account.items[0].tags, ['typescript', 'react']);

  removeTagFromItem(account, item.id, 'typescript');
  assert.deepEqual(account.items[0].tags, ['react']);

  assert.equal(addCategory(account, '工作笔记').valid, true);
  assert.equal(renameCategory(account, '代码片段', '核心代码').valid, true);
  assert.equal(account.items[0].category, '核心代码');

  assert.equal(deleteCategory(account, '核心代码'), true);
  assert.equal(account.items[0].category, '未分类');

  assert.equal(deleteClipboardItem(account, item.id), true);
  assert.equal(account.items.length, 0);

  addClipboardItem(account, { content: 'a' });
  addClipboardItem(account, { content: 'b' });
  assert.equal(clearAllClipboardItems(account), 2);
  assert.equal(account.items.length, 0);
});

test('timeline bucketing groups items by date in current month, 上个月, and earlier months (几月)', () => {
  const fixedNow = new Date(2026, 10, 17, 15, 0, 0); // Nov 17, 2026
  const db = createInitialDatabase(fixedNow);
  const demo = db.accounts['demo_creator'];
  const buckets = buildTimelineBuckets(demo.items, fixedNow);

  const labels = buckets.map((b) => b.label);
  assert.ok(labels.includes('今天'), 'Should include 今天');
  assert.ok(labels.includes('上个月'), 'Should include 上个月');
  assert.ok(labels.includes('9月'), 'Should include 9月');
  assert.ok(labels.includes('8月'), 'Should include 8月');

  // Check pagination & filtering
  const page1 = filterAndPaginateItems(demo.items, {
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
