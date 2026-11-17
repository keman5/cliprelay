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
  password: string;
  failedAttempts: number;
  locked: boolean;
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

export interface AuthResult {
  ok: boolean;
  error?: string;
  account?: UserAccount;
  remainingAttempts?: number;
  locked?: boolean;
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

export function registerAccount(
  db: ClipboardDatabase,
  username: string,
  password: string,
  now: Date = new Date()
): AuthResult {
  const userCheck = validateUsername(username);
  if (!userCheck.valid) {
    return { ok: false, error: userCheck.error };
  }
  const passCheck = validatePassword(password);
  if (!passCheck.valid) {
    return { ok: false, error: passCheck.error };
  }

  const key = normalizeUsername(username);
  if (db.accounts[key]) {
    return {
      ok: false,
      error: '该账号已被注册，不可重复注册',
    };
  }

  const newAccount: UserAccount = {
    username: username.trim(),
    password,
    failedAttempts: 0,
    locked: false,
    categories: ['未分类', '代码片段', '终端命令', '常用链接', '文案灵感'],
    items: [],
    createdAt: now.toISOString(),
  };

  db.accounts[key] = newAccount;
  return { ok: true, account: newAccount, remainingAttempts: MAX_FAILED_ATTEMPTS, locked: false };
}

export function authenticateAccount(
  db: ClipboardDatabase,
  username: string,
  password: string
): AuthResult {
  const trimmed = username.trim();
  if (!trimmed) {
    return { ok: false, error: '请输入账号名称' };
  }
  if (!password) {
    return { ok: false, error: '请输入密码' };
  }

  const key = normalizeUsername(trimmed);
  const account = db.accounts[key];
  if (!account) {
    return { ok: false, error: '账号不存在，请先注册账号' };
  }

  if (account.locked || account.failedAttempts >= MAX_FAILED_ATTEMPTS) {
    account.locked = true;
    return {
      ok: false,
      locked: true,
      remainingAttempts: 0,
      error: '该账号因密码连续输入错误 3 次已被锁定，无法登录',
    };
  }

  if (account.password !== password) {
    account.failedAttempts += 1;
    const remaining = Math.max(0, MAX_FAILED_ATTEMPTS - account.failedAttempts);
    if (account.failedAttempts >= MAX_FAILED_ATTEMPTS) {
      account.locked = true;
      return {
        ok: false,
        locked: true,
        remainingAttempts: 0,
        error: '密码连续输入错误 3 次，账号已被安全锁定',
      };
    }
    return {
      ok: false,
      locked: false,
      remainingAttempts: remaining,
      error: `密码错误，连续输错 ${MAX_FAILED_ATTEMPTS} 次将锁定账号（剩余 ${remaining} 次机会）`,
    };
  }

  // Successful login resets consecutive failed attempts
  account.failedAttempts = 0;
  return {
    ok: true,
    account,
    remainingAttempts: MAX_FAILED_ATTEMPTS,
    locked: false,
  };
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

/**
 * Generates deterministic seed data for the public demo account (`demo_creator`)
 * so that timeline buckets ("今天", specific dates like "11月14日", "上个月", "9月", "8月"),
 * category tabs, tags, favorites, and multi-page pagination work out of the box.
 */
export function createInitialDatabase(now: Date = new Date()): ClipboardDatabase {
  const y = now.getFullYear();
  const m = now.getMonth();
  const d = now.getDate();

  const makeDate = (monthOffset: number, day: number, hour: number, minute: number) => {
    const dt = new Date(y, m + monthOffset, day, hour, minute, 0);
    return dt.toISOString();
  };

  const today1 = new Date(now.getTime() - 15 * 60 * 1000).toISOString();
  const today2 = new Date(now.getTime() - 95 * 60 * 1000).toISOString();
  const today3 = new Date(now.getTime() - 210 * 60 * 1000).toISOString();

  // Safe days within current month (if d > 3, use d-1, d-3, d-6; otherwise use 1)
  const earlierDay1 = Math.max(1, d - 1);
  const earlierDay2 = Math.max(1, d - 3);
  const earlierDay3 = Math.max(1, d - 7);

  const seedItems: ClipboardItem[] = [
    {
      id: 'seed_01',
      content: 'curl -X POST https://api.clipnote.dev/v1/sync -H "Authorization: Bearer cn_live_98a7f6d5" -d \'{"mode":"instant"}\'',
      category: '终端命令',
      tags: ['curl', 'api', '调试'],
      favorite: true,
      createdAt: today1,
    },
    {
      id: 'seed_02',
      content: 'const useDebounce = <T,>(value: T, delay = 250): T => {\n  const [debounced, setDebounced] = useState(value);\n  useEffect(() => {\n    const timer = setTimeout(() => setDebounced(value), delay);\n    return () => clearTimeout(timer);\n  }, [value, delay]);\n  return debounced;\n};',
      category: '代码片段',
      tags: ['react', 'hooks', 'typescript'],
      favorite: true,
      createdAt: today2,
    },
    {
      id: 'seed_03',
      content: '设计原则：少即是多（Less, but better）。去除一切非必要的胶囊边框与装饰圆点，用字重、留白和 1px 分割线构建清晰的阅读层级。',
      category: '文案灵感',
      tags: ['设计规范', '极简主义'],
      favorite: false,
      createdAt: today3,
    },
    {
      id: 'seed_04',
      content: 'git log --graph --pretty=format:"%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset" --abbrev-commit -n 15',
      category: '终端命令',
      tags: ['git', '效率'],
      favorite: true,
      createdAt: makeDate(0, earlierDay1, 16, 40),
    },
    {
      id: 'seed_05',
      content: 'https://developer.mozilla.org/zh-CN/docs/Web/API/Clipboard_API — Web Clipboard API 异步读写剪贴板规范文档与权限参考',
      category: '常用链接',
      tags: ['mdn', '文档', '前端'],
      favorite: false,
      createdAt: makeDate(0, earlierDay1, 11, 20),
    },
    {
      id: 'seed_06',
      content: 'SELECT account_id, COUNT(*) AS clip_count, MAX(created_at) AS last_active\nFROM clipboard_entries\nWHERE is_deleted = FALSE\nGROUP BY account_id\nHAVING COUNT(*) <= 1000\nORDER BY last_active DESC;',
      category: '代码片段',
      tags: ['sql', '数据库'],
      favorite: false,
      createdAt: makeDate(0, earlierDay2, 18, 15),
    },
    {
      id: 'seed_07',
      content: 'docker compose -f docker-compose.prod.yml up -d --build --remove-orphans && docker system prune -f',
      category: '终端命令',
      tags: ['docker', '运维'],
      favorite: false,
      createdAt: makeDate(0, earlierDay2, 10, 5),
    },
    {
      id: 'seed_08',
      content: '产品发布清单：1. 验证 12-20 位密码校验；2. 测试连续 3 次密码错误自动锁定；3. 检查 5000 字长文本粘贴与回车立即入库；4. 确认时间线按日期、上个月、几月准确归档。',
      category: '文案灵感',
      tags: ['清单', '测试'],
      favorite: true,
      createdAt: makeDate(0, earlierDay3, 15, 30),
    },
    {
      id: 'seed_09',
      content: 'ssh -i ~/.ssh/id_ed25519_prod deploy@10.24.88.142 -L 5432:localhost:5432 -N',
      category: '终端命令',
      tags: ['ssh', '隧道'],
      favorite: false,
      createdAt: makeDate(-1, 24, 19, 10),
    },
    {
      id: 'seed_10',
      content: 'export function formatBytes(bytes: number, decimals = 2): string {\n  if (!+bytes) return "0 Bytes";\n  const k = 1024;\n  const sizes = ["Bytes", "KB", "MB", "GB"];\n  const i = Math.floor(Math.log(bytes) / Math.log(k));\n  return `${parseFloat((bytes / Math.pow(k, i)).toFixed(decimals))} ${sizes[i]}`;\n}',
      category: '代码片段',
      tags: ['typescript', '工具函数'],
      favorite: false,
      createdAt: makeDate(-1, 18, 14, 22),
    },
    {
      id: 'seed_11',
      content: 'https://tc39.es/ecma262/ — ECMAScript 最新语言规范标准全文在线查阅',
      category: '常用链接',
      tags: ['javascript', '标准'],
      favorite: false,
      createdAt: makeDate(-1, 11, 9, 45),
    },
    {
      id: 'seed_12',
      content: '真正高效的工具应当像空气一样自然：打开网页即刻粘贴，敲击回车瞬间归档，点击任意条目毫秒级复制回系统剪贴板。',
      category: '文案灵感',
      tags: ['产品思考', '体验'],
      favorite: true,
      createdAt: makeDate(-1, 5, 21, 0),
    },
    {
      id: 'seed_13',
      content: 'lsof -i tcp:3000 | awk \'NR!=1 {print $2}\' | xargs kill -9',
      category: '终端命令',
      tags: ['macos', 'linux', '端口'],
      favorite: false,
      createdAt: makeDate(-2, 22, 17, 12),
    },
    {
      id: 'seed_14',
      content: 'type DeepReadonly<T> = {\n  readonly [P in keyof T]: T[P] extends object ? DeepReadonly<T[P]> : T[P];\n};',
      category: '代码片段',
      tags: ['typescript', '类型体操'],
      favorite: false,
      createdAt: makeDate(-2, 14, 13, 50),
    },
    {
      id: 'seed_15',
      content: 'https://www.w3.org/WAI/WCAG21/quickref/ — WCAG 2.1 无障碍对比度与键盘焦点导航速查手册',
      category: '常用链接',
      tags: ['a11y', '设计'],
      favorite: false,
      createdAt: makeDate(-2, 6, 10, 30),
    },
    {
      id: 'seed_16',
      content: 'rsync -avzP --exclude="node_modules" --exclude=".git" ./ user@backup-server:/var/backups/workspace/',
      category: '终端命令',
      tags: ['备份', 'rsync'],
      favorite: false,
      createdAt: makeDate(-3, 19, 16, 5),
    },
    {
      id: 'seed_17',
      content: '排版细节检查：所有数字计数器、字符统计、日期时间戳与分页页码均启用 font-variant-numeric: tabular-nums 等宽数字对齐。',
      category: '未分类',
      tags: ['排版', '字体'],
      favorite: false,
      createdAt: makeDate(-3, 8, 11, 18),
    },
  ];

  // Sort newest first
  seedItems.sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime());

  return {
    accounts: {
      demo_creator: {
        username: 'demo_creator',
        password: 'DemoClip2026!@#', // 15 chars (within 12-20)
        failedAttempts: 0,
        locked: false,
        categories: ['未分类', '代码片段', '终端命令', '常用链接', '文案灵感'],
        items: seedItems,
        createdAt: makeDate(-3, 1, 9, 0),
      },
    },
  };
}
