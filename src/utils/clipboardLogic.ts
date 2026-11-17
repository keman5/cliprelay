export const MIN_PASSWORD_LENGTH = 12;
export const MAX_PASSWORD_LENGTH = 20;
export const MAX_FAILED_ATTEMPTS = 3;
export const MAX_CONTENT_LENGTH = 5000;
export const MAX_ITEMS_PER_ACCOUNT = 1000;

export interface ClipboardItem {
  id: string;
  content: string;
  category: string;
  tags: string[];
  favorite: boolean;
  createdAt: string; // ISO string
}

export interface UserAccount {
  username: string;
  categories: string[];
  items: ClipboardItem[];
  createdAt: string;
}

export interface ClipboardDatabase {
  accounts: Record<string, UserAccount>;
}

export interface ValidationResult {
  valid: boolean;
  error?: string;
}

export interface AddItemInput {
  content: string;
  category?: string;
  tags?: string[];
  now?: Date;
}

export interface AddItemResult {
  ok: boolean;
  error?: string;
  item?: ClipboardItem;
  account?: UserAccount;
}

export interface TimelineBucket {
  key: string;
  label: string;       // e.g., "今天", "11月14日", "上个月", "9月", "8月"
  subLabel: string;    // e.g., "11月17日", "周六", "10月", "2026年"
  kind: 'date' | 'last-month' | 'month';
  count: number;
  latestTimestamp: number;
}

export interface FilterOptions {
  categoryTab: string; // 'ALL' | 'FAVORITES' | category name
  timelineKey: string; // 'ALL' | bucket.key
  tagFilter: string;   // '' | tag name
  searchQuery: string;
  page: number;
  pageSize: number;
  now?: Date;
}

export interface PaginatedResult {
  filteredItems: ClipboardItem[];
  pageItems: ClipboardItem[];
  totalFiltered: number;
  totalPages: number;
  currentPage: number;
}

export function normalizeUsername(username: string): string {
  return username.trim().toLowerCase();
}

export function validateUsername(username: string): ValidationResult {
  const trimmed = username.trim();
  if (!trimmed) {
    return { valid: false, error: '请输入账号名称' };
  }
  if (trimmed.length < 3 || trimmed.length > 24) {
    return { valid: false, error: '账号名称长度需为 3-24 个字符' };
  }
  if (!/^[a-zA-Z0-9_\-\u4e00-\u9fa5]+$/.test(trimmed)) {
    return { valid: false, error: '账号仅支持字母、数字、中文、下划线与连字符' };
  }
  return { valid: true };
}

export function validatePassword(password: string): ValidationResult {
  if (!password) {
    return { valid: false, error: '请输入密码（12-20 个字符）' };
  }
  if (password.length < MIN_PASSWORD_LENGTH || password.length > MAX_PASSWORD_LENGTH) {
    return {
      valid: false,
      error: `密码长度必须为 ${MIN_PASSWORD_LENGTH}-${MAX_PASSWORD_LENGTH} 个字符（当前 ${password.length} 个字符）`,
    };
  }
  return { valid: true };
}

export function normalizeTags(tags: string[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const raw of tags) {
    const cleaned = raw.trim().replace(/^#+/, '').trim();
    if (cleaned && !seen.has(cleaned.toLowerCase())) {
      seen.add(cleaned.toLowerCase());
      result.push(cleaned.slice(0, 24));
    }
  }
  return result;
}

export function addClipboardItem(
  account: UserAccount,
  input: AddItemInput
): AddItemResult {
  const rawContent = input.content ?? '';
  if (!rawContent.trim()) {
    return { ok: false, error: '剪切板内容不能为空' };
  }
  if (rawContent.length > MAX_CONTENT_LENGTH) {
    return {
      ok: false,
      error: `单条内容最长支持 ${MAX_CONTENT_LENGTH} 个字符（当前 ${rawContent.length} 个字符）`,
    };
  }
  if (account.items.length >= MAX_ITEMS_PER_ACCOUNT) {
    return {
      ok: false,
      error: `每个账号最多保存 ${MAX_ITEMS_PER_ACCOUNT} 条记录，请先删除部分旧记录或清空`,
    };
  }

  const now = input.now ?? new Date();
  const category = (input.category || '未分类').trim() || '未分类';
  if (!account.categories.includes(category)) {
    account.categories.push(category);
  }

  const newItem: ClipboardItem = {
    id: `clip_${now.getTime()}_${Math.random().toString(36).slice(2, 8)}`,
    content: rawContent,
    category,
    tags: normalizeTags(input.tags ?? []),
    favorite: false,
    createdAt: now.toISOString(),
  };

  account.items = [newItem, ...account.items];
  return { ok: true, item: newItem, account };
}

export function toggleFavoriteItem(account: UserAccount, itemId: string): boolean {
  const target = account.items.find((it) => it.id === itemId);
  if (!target) return false;
  target.favorite = !target.favorite;
  return true;
}

export function deleteClipboardItem(account: UserAccount, itemId: string): boolean {
  const before = account.items.length;
  account.items = account.items.filter((it) => it.id !== itemId);
  return account.items.length < before;
}

export function clearAllClipboardItems(account: UserAccount, categoryFilter?: string): number {
  const before = account.items.length;
  if (!categoryFilter || categoryFilter === 'ALL') {
    account.items = [];
  } else if (categoryFilter === 'FAVORITES') {
    account.items = account.items.filter((it) => !it.favorite);
  } else {
    account.items = account.items.filter((it) => it.category !== categoryFilter);
  }
  return before - account.items.length;
}

export function addTagToItem(account: UserAccount, itemId: string, newTag: string): boolean {
  const item = account.items.find((it) => it.id === itemId);
  if (!item) return false;
  const cleaned = newTag.trim().replace(/^#+/, '').trim();
  if (!cleaned) return false;
  item.tags = normalizeTags([...item.tags, cleaned]);
  return true;
}

export function removeTagFromItem(account: UserAccount, itemId: string, tagToRemove: string): boolean {
  const item = account.items.find((it) => it.id === itemId);
  if (!item) return false;
  item.tags = item.tags.filter((t) => t.toLowerCase() !== tagToRemove.toLowerCase());
  return true;
}

export function updateItemCategory(account: UserAccount, itemId: string, newCategory: string): boolean {
  const item = account.items.find((it) => it.id === itemId);
  if (!item) return false;
  const cat = newCategory.trim() || '未分类';
  if (!account.categories.includes(cat)) {
    account.categories.push(cat);
  }
  item.category = cat;
  return true;
}

export function addCategory(account: UserAccount, categoryName: string): ValidationResult {
  const trimmed = categoryName.trim();
  if (!trimmed) {
    return { valid: false, error: '分类名称不能为空' };
  }
  if (trimmed.length > 16) {
    return { valid: false, error: '分类名称最多 16 个字符' };
  }
  if (['全部', '收藏', 'ALL', 'FAVORITES'].includes(trimmed)) {
    return { valid: false, error: '该分类名称为系统保留名称' };
  }
  if (account.categories.some((c) => c.toLowerCase() === trimmed.toLowerCase())) {
    return { valid: false, error: '该分类已存在' };
  }
  account.categories.push(trimmed);
  return { valid: true };
}

export function renameCategory(account: UserAccount, oldName: string, newName: string): ValidationResult {
  if (oldName === '未分类') {
    return { valid: false, error: '默认“未分类”不可重命名' };
  }
  const trimmed = newName.trim();
  if (!trimmed) {
    return { valid: false, error: '新分类名称不能为空' };
  }
  if (trimmed.length > 16) {
    return { valid: false, error: '分类名称最多 16 个字符' };
  }
  if (account.categories.some((c) => c !== oldName && c.toLowerCase() === trimmed.toLowerCase())) {
    return { valid: false, error: '同名分类已存在' };
  }
  account.categories = account.categories.map((c) => (c === oldName ? trimmed : c));
  account.items.forEach((it) => {
    if (it.category === oldName) {
      it.category = trimmed;
    }
  });
  return { valid: true };
}

export function deleteCategory(account: UserAccount, categoryName: string): boolean {
  if (categoryName === '未分类') return false;
  const exists = account.categories.includes(categoryName);
  if (!exists) return false;
  account.categories = account.categories.filter((c) => c !== categoryName);
  if (!account.categories.includes('未分类')) {
    account.categories.unshift('未分类');
  }
  account.items.forEach((it) => {
    if (it.category === categoryName) {
      it.category = '未分类';
    }
  });
  return true;
}

/**
 * Computes the timeline bucket descriptor for a given item timestamp relative to `now`.
 * - Entries in the current calendar month are grouped by specific date ("今天", "昨天", "11月14日", etc.).
 * - Entries in the immediately preceding calendar month are grouped under "上个月" (with subLabel e.g. "10月").
 * - Entries from earlier months are grouped by month ("9月", "8月", or "2025年12月").
 */
export function getItemTimelineBucket(isoDate: string, now: Date = new Date()): Omit<TimelineBucket, 'count' | 'latestTimestamp'> {
  const d = new Date(isoDate);
  const nowYear = now.getFullYear();
  const nowMonth = now.getMonth(); // 0-indexed
  const nowDay = now.getDate();

  const itemYear = d.getFullYear();
  const itemMonth = d.getMonth();
  const itemDay = d.getDate();

  const mm = String(itemMonth + 1).padStart(2, '0');
  const dd = String(itemDay).padStart(2, '0');

  // Same year and same month -> group by specific Date (按日期)
  if (itemYear === nowYear && itemMonth === nowMonth) {
    const key = `date-${itemYear}-${mm}-${dd}`;
    if (itemDay === nowDay) {
      return {
        key,
        label: '今天',
        subLabel: `${itemMonth + 1}月${itemDay}日`,
        kind: 'date',
      };
    }
    const yesterday = new Date(nowYear, nowMonth, nowDay - 1);
    if (
      yesterday.getFullYear() === itemYear &&
      yesterday.getMonth() === itemMonth &&
      yesterday.getDate() === itemDay
    ) {
      return {
        key,
        label: '昨天',
        subLabel: `${itemMonth + 1}月${itemDay}日`,
        kind: 'date',
      };
    }
    const weekdays = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    return {
      key,
      label: `${itemMonth + 1}月${itemDay}日`,
      subLabel: weekdays[d.getDay()],
      kind: 'date',
    };
  }

  // Check if it is the immediately preceding month (上个月)
  const prevMonthDate = new Date(nowYear, nowMonth - 1, 1);
  if (itemYear === prevMonthDate.getFullYear() && itemMonth === prevMonthDate.getMonth()) {
    return {
      key: `last-month-${itemYear}-${mm}`,
      label: '上个月',
      subLabel: `${itemMonth + 1}月`,
      kind: 'last-month',
    };
  }

  // Otherwise group by Month (几月)
  const sameYear = itemYear === nowYear;
  return {
    key: `month-${itemYear}-${mm}`,
    label: sameYear ? `${itemMonth + 1}月` : `${itemYear}年${itemMonth + 1}月`,
    subLabel: `${itemYear}年`,
    kind: 'month',
  };
}

export function buildTimelineBuckets(items: ClipboardItem[], now: Date = new Date()): TimelineBucket[] {
  const map = new Map<string, TimelineBucket>();

  for (const item of items) {
    const ts = new Date(item.createdAt).getTime();
    const desc = getItemTimelineBucket(item.createdAt, now);
    const existing = map.get(desc.key);
    if (existing) {
      existing.count += 1;
      if (ts > existing.latestTimestamp) {
        existing.latestTimestamp = ts;
      }
    } else {
      map.set(desc.key, {
        ...desc,
        count: 1,
        latestTimestamp: ts,
      });
    }
  }

  return Array.from(map.values()).sort((a, b) => b.latestTimestamp - a.latestTimestamp);
}

export function filterAndPaginateItems(
  items: ClipboardItem[],
  options: FilterOptions
): PaginatedResult {
  const now = options.now ?? new Date();
  const query = options.searchQuery.trim().toLowerCase();
  const tagQuery = options.tagFilter.trim().toLowerCase();

  const filteredItems = items.filter((item) => {
    // Category tab filter
    if (options.categoryTab === 'FAVORITES') {
      if (!item.favorite) return false;
    } else if (options.categoryTab && options.categoryTab !== 'ALL') {
      if (item.category !== options.categoryTab) return false;
    }

    // Timeline filter
    if (options.timelineKey && options.timelineKey !== 'ALL') {
      const bucket = getItemTimelineBucket(item.createdAt, now);
      if (bucket.key !== options.timelineKey) return false;
    }

    // Tag filter
    if (tagQuery) {
      const hasTag = item.tags.some((t) => t.toLowerCase() === tagQuery);
      if (!hasTag) return false;
    }

    // Search query
    if (query) {
      const inContent = item.content.toLowerCase().includes(query);
      const inCategory = item.category.toLowerCase().includes(query);
      const inTags = item.tags.some((t) => t.toLowerCase().includes(query));
      if (!inContent && !inCategory && !inTags) return false;
    }

    return true;
  });

  const totalFiltered = filteredItems.length;
  const pageSize = Math.max(1, options.pageSize || 10);
  const totalPages = Math.max(1, Math.ceil(totalFiltered / pageSize));
  const currentPage = Math.min(Math.max(1, options.page || 1), totalPages);
  const startIndex = (currentPage - 1) * pageSize;
  const pageItems = filteredItems.slice(startIndex, startIndex + pageSize);

  return {
    filteredItems,
    pageItems,
    totalFiltered,
    totalPages,
    currentPage,
  };
}

export function createInitialDatabase(): ClipboardDatabase {
  return { accounts: {} };
}
