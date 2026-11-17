import React, { useState, useEffect, useRef } from 'react';
import {
  CornerDownLeft,
  Search,
  Trash2,
  FolderKanban,
  ClipboardPaste,
  AlertCircle,
  Check,
  X,
  ChevronLeft,
  ChevronRight,
} from 'lucide-react';
import {
  ClipboardDatabase,
  ClipboardItem,
  MAX_CONTENT_LENGTH,
  MAX_ITEMS_PER_ACCOUNT,
  createInitialDatabase,
  normalizeUsername,
  addClipboardItem,
  toggleFavoriteItem,
  deleteClipboardItem,
  clearAllClipboardItems,
  addTagToItem,
  removeTagFromItem,
  updateItemCategory,
  addCategory,
  renameCategory,
  deleteCategory,
  buildTimelineBuckets,
  filterAndPaginateItems,
} from './utils/clipboardLogic';
import { TimelineSidebar } from './components/TimelineSidebar';
import { ClipboardItemRow } from './components/ClipboardItemRow';
import { AuthModal } from './components/AuthModal';
import { CategoryManagerModal } from './components/CategoryManagerModal';

import { api, type SessionData } from './utils/api';

export default function App() {
  const [db, setDb] = useState<ClipboardDatabase>(createInitialDatabase);
  const [activeUserKey, setActiveUserKey] = useState<string | null>(null);
  const [rememberMe, setRememberMe] = useState(false);
  const [loading, setLoading] = useState(true);
  const [networkError, setNetworkError] = useState<string | null>(null);
  const busy = useRef(false);
  const [saving, setSaving] = useState(false);
  const revision = useRef(0);

  // Composer state
  const [composerContent, setComposerContent] = useState('');
  const [composerCategory, setComposerCategory] = useState('未分类');
  const [composerTagsInput, setComposerTagsInput] = useState('');
  const [composerNotice, setComposerNotice] = useState<{
    type: 'error' | 'success';
    text: string;
  } | null>(null);

  // Filter & Pagination state
  const [categoryTab, setCategoryTab] = useState<string>('ALL');
  const [timelineKey, setTimelineKey] = useState<string>('ALL');
  const [tagFilter, setTagFilter] = useState<string>('');
  const [searchQuery, setSearchQuery] = useState<string>('');
  const [page, setPage] = useState<number>(1);
  const [pageSize, setPageSize] = useState<number>(8);

  // UI Modals & Confirmation state
  const [isAuthModalOpen, setIsAuthModalOpen] = useState<boolean>(false);
  const [isCategoryModalOpen, setIsCategoryModalOpen] = useState<boolean>(false);
  const [confirmClearAll, setConfirmClearAll] = useState<boolean>(false);
  const [copiedId, setCopiedId] = useState<string | null>(null);

  const composerTextareaRef = useRef<HTMLTextAreaElement | null>(null);

  const currentUser = activeUserKey ? db.accounts[activeUserKey] ?? null : null;

  const applySession = (data: SessionData) => {
    const key = normalizeUsername(data.account.username);
    revision.current = data.revision;
    setDb({ accounts: { [key]: data.account } });
    setActiveUserKey(key);
    setRememberMe(data.remember);
    setNetworkError(null);
  };

  useEffect(() => {
    api<SessionData | null>('/session').then((data) => {
      if (data) applySession(data);
    }).catch((error) => setNetworkError(error.message)).finally(() => setLoading(false));
  }, []);

  const saveDatabase = async (next: ClipboardDatabase): Promise<boolean> => {
    if (!activeUserKey || busy.current) { setNetworkError('正在保存，请稍后再试'); return false; }
    busy.current = true;
    setSaving(true);
    try {
      const data = await api<{ revision: number }>('/workspace', {
        method: 'PUT', body: JSON.stringify({ ...next.accounts[activeUserKey], revision: revision.current }),
      });
      revision.current = data.revision;
      setDb(next);
      setNetworkError(null);
      return true;
    } catch (error) {
      setNetworkError(error instanceof Error ? error.message : '保存失败，请重试');
      return false;
    } finally { busy.current = false; setSaving(false); }
  };

  const mutateDb = async (updater: (draft: ClipboardDatabase) => void) => {
    const clone = structuredClone(db);
    updater(clone);
    return saveDatabase(clone);
  };

  const handleAuth = async (mode: 'login' | 'register', username: string, password: string, remember: boolean) => {
    if (busy.current || loading) return { ok: false, error: '正在连接，请稍后再试' };
    busy.current = true;
    try {
      const data = await api<SessionData>('/' + mode, { method: 'POST', body: JSON.stringify({ username, password, remember }) });
      applySession(data);
      setCategoryTab('ALL'); setTimelineKey('ALL'); setTagFilter(''); setPage(1);
      setComposerContent(''); setComposerTagsInput(''); setComposerNotice(null);
      setIsAuthModalOpen(false);
      return { ok: true };
    } catch (error) { return { ok: false, error: error instanceof Error ? error.message : '连接失败' }; }
    finally { busy.current = false; }
  };
  const handleLogin = (username: string, password: string, remember: boolean) => handleAuth('login', username, password, remember);
  const handleRegister = (username: string, password: string, remember: boolean) => handleAuth('register', username, password, remember);
  const handleLogout = async () => {
    if (busy.current) return;
    busy.current = true;
    try {
      await api('/logout', { method: 'POST' });
      setActiveUserKey(null); setDb(createInitialDatabase());
      setComposerContent(''); setComposerTagsInput(''); setComposerNotice(null);
      setIsAuthModalOpen(true);
    } catch (error) { setNetworkError(error instanceof Error ? error.message : '退出失败'); }
    finally { busy.current = false; }
  };

  // Clipboard Entry Creation
  const handleCreateEntry = async (overrideText?: string) => {
    if (!currentUser || !activeUserKey) {
      setIsAuthModalOpen(true);
      return;
    }

    const contentToSave = overrideText !== undefined ? overrideText : composerContent;
    const rawTags = composerTagsInput
      .split(/[,，\s]+/)
      .map((t) => t.trim())
      .filter(Boolean);

    const clone: ClipboardDatabase = JSON.parse(JSON.stringify(db));
    const account = clone.accounts[activeUserKey];
    const result = addClipboardItem(account, {
      content: contentToSave,
      category: composerCategory,
      tags: rawTags,
    });

    if (!result.ok) {
      setComposerNotice({ type: 'error', text: result.error || '保存失败' });
      return;
    }

    if (!await saveDatabase(clone)) return;
    setComposerContent('');
    setComposerTagsInput('');
    setTimelineKey('ALL');
    setPage(1);
    setComposerNotice({
      type: 'success',
      text: `已归档至「${result.item?.category}」（共 ${account.items.length} / ${MAX_ITEMS_PER_ACCOUNT} 条）`,
    });
  };

  const handleComposerKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleCreateEntry();
    }
  };

  const handlePasteFromSystemClipboard = async () => {
    try {
      const text = await navigator.clipboard.readText();
      if (text) {
        const sliced = text.slice(0, MAX_CONTENT_LENGTH);
        setComposerContent(sliced);
        composerTextareaRef.current?.focus();
      } else {
        composerTextareaRef.current?.focus();
      }
    } catch {
      composerTextareaRef.current?.focus();
      setComposerNotice({
        type: 'error',
        text: '请在输入框内直接按 Ctrl+V / Cmd+V 粘贴文本，按回车立即生成记录',
      });
    }
  };

  // Copy Item Handler
  const handleCopyItem = async (item: ClipboardItem) => {
    try {
      await navigator.clipboard.writeText(item.content);
    } catch {
      // Fallback copy via temporary textarea
      const temp = document.createElement('textarea');
      temp.value = item.content;
      temp.style.position = 'fixed';
      temp.style.opacity = '0';
      document.body.appendChild(temp);
      temp.select();
      document.execCommand('copy');
      document.body.removeChild(temp);
    }
    setCopiedId(item.id);
    setTimeout(() => {
      setCopiedId((prev) => (prev === item.id ? null : prev));
    }, 1800);
  };

  // Item Mutations
  const handleToggleFavorite = (itemId: string) => {
    if (!activeUserKey) return;
    mutateDb((draft) => {
      toggleFavoriteItem(draft.accounts[activeUserKey], itemId);
    });
  };

  const handleDeleteItem = (itemId: string) => {
    if (!activeUserKey) return;
    mutateDb((draft) => {
      deleteClipboardItem(draft.accounts[activeUserKey], itemId);
    });
  };

  const handleClearAllConfirmed = async () => {
    if (!activeUserKey) return;
    const saved = await mutateDb((draft) => {
      clearAllClipboardItems(draft.accounts[activeUserKey], categoryTab);
    });
    if (!saved) return;
    setConfirmClearAll(false);
    setPage(1);
  };

  const handleAddTag = (itemId: string, tag: string) => {
    if (!activeUserKey) return;
    mutateDb((draft) => {
      addTagToItem(draft.accounts[activeUserKey], itemId, tag);
    });
  };

  const handleRemoveTag = (itemId: string, tag: string) => {
    if (!activeUserKey) return;
    mutateDb((draft) => {
      removeTagFromItem(draft.accounts[activeUserKey], itemId, tag);
    });
  };

  const handleChangeItemCategory = (itemId: string, category: string) => {
    if (!activeUserKey) return;
    mutateDb((draft) => {
      updateItemCategory(draft.accounts[activeUserKey], itemId, category);
    });
  };

  // Category Management
  const handleAddCategory = async (name: string) => {
    if (!activeUserKey) return { valid: false, error: '未登录' };
    const clone: ClipboardDatabase = JSON.parse(JSON.stringify(db));
    const res = addCategory(clone.accounts[activeUserKey], name);
    if (res.valid) {
      if (!await saveDatabase(clone)) return { valid: false, error: '保存失败，请查看页面提示后重试' };
    }
    return res;
  };

  const handleRenameCategory = async (oldName: string, newName: string) => {
    if (!activeUserKey) return { valid: false, error: '未登录' };
    const clone: ClipboardDatabase = JSON.parse(JSON.stringify(db));
    const res = renameCategory(clone.accounts[activeUserKey], oldName, newName);
    if (res.valid) {
      if (!await saveDatabase(clone)) return { valid: false, error: '保存失败，请查看页面提示后重试' };
      if (categoryTab === oldName) {
        setCategoryTab(newName.trim());
      }
      if (composerCategory === oldName) {
        setComposerCategory(newName.trim());
      }
    }
    return res;
  };

  const handleDeleteCategory = (name: string) => {
    if (!activeUserKey) return;
    mutateDb((draft) => {
      deleteCategory(draft.accounts[activeUserKey], name);
    });
    if (categoryTab === name) {
      setCategoryTab('ALL');
    }
    if (composerCategory === name) {
      setComposerCategory('未分类');
    }
  };

  // Compute derived data
  const allItems = currentUser?.items ?? [];
  const categories = currentUser?.categories ?? ['未分类'];
  const timelineBuckets = buildTimelineBuckets(allItems);
  const favoriteCount = allItems.filter((it) => it.favorite).length;

  const paginated = filterAndPaginateItems(allItems, {
    categoryTab,
    timelineKey,
    tagFilter,
    searchQuery,
    page,
    pageSize,
  });

  return (
    <div className="min-h-screen flex flex-col bg-[#FAFAFA] text-neutral-900">
      {/* Strict 3-Zone Top Bar Contract */}
      <header className="flex flex-wrap items-center justify-between gap-4 px-4 sm:px-6 py-3.5 bg-white border-b border-neutral-200">
        {/* Zone 1: Single text element wordmark */}
        <a
          href="#top"
          onClick={(e) => {
            e.preventDefault();
            setCategoryTab('ALL');
            setTimelineKey('ALL');
            setTagFilter('');
            setSearchQuery('');
            setPage(1);
          }}
          className="text-base font-bold tracking-tight text-neutral-900 whitespace-nowrap shrink-0"
        >
          ClipNote 极简剪切板
        </a>

        {/* Zone 2: 4 concise single-line navigation links */}
        <nav
          aria-label="主导航"
          className="hidden md:flex items-center gap-6 text-xs font-medium text-neutral-600"
        >
          <button
            type="button"
            onClick={() => {
              setCategoryTab('ALL');
              setTimelineKey('ALL');
              setPage(1);
            }}
            className={`hover:text-neutral-900 transition-colors whitespace-nowrap shrink-0 ${
              categoryTab === 'ALL' && timelineKey === 'ALL'
                ? 'text-neutral-900 underline underline-offset-4'
                : ''
            }`}
          >
            全部记录
          </button>
          <button
            type="button"
            onClick={() => {
              setCategoryTab('FAVORITES');
              setPage(1);
            }}
            className={`hover:text-neutral-900 transition-colors whitespace-nowrap shrink-0 ${
              categoryTab === 'FAVORITES'
                ? 'text-neutral-900 underline underline-offset-4'
                : ''
            }`}
          >
            收藏夹 ({favoriteCount})
          </button>
          <button
            type="button"
            onClick={() => setIsCategoryModalOpen(true)}
            className="hover:text-neutral-900 transition-colors whitespace-nowrap shrink-0"
          >
            分类管理
          </button>
          <button
            type="button"
            onClick={() => setIsAuthModalOpen(true)}
            className="hover:text-neutral-900 transition-colors whitespace-nowrap shrink-0"
          >
            账号与安全
          </button>
        </nav>

        {/* Zone 3: 1 primary action button */}
        <div className="flex items-center shrink-0 max-w-full">
          <button
            type="button"
            onClick={() => setIsAuthModalOpen(true)}
            className="py-2 px-4 text-xs font-medium text-white bg-neutral-900 hover:bg-neutral-800 rounded-md transition-colors whitespace-nowrap shrink-0 max-w-full truncate"
          >
            {currentUser ? `切换账号 (@${currentUser.username})` : '登录 / 免邮箱注册'}
          </button>
        </div>
      </header>

      {/* Main Content Container */}
      <main className="flex-1 w-full max-w-[1360px] mx-auto px-4 sm:px-6 py-6">
        {saving && <p role="status" className="mb-3 text-sm text-neutral-500">正在保存到云端…</p>}
        {networkError && <p role="alert" className="mb-4 p-3 bg-red-50 text-red-700 text-sm">{networkError} <button type="button" className="underline" onClick={() => window.location.reload()}>重新加载云端数据</button></p>}
        {loading ? <p role="status" className="text-center p-12">正在连接 ClipNote…</p> : !currentUser ? (
          /* Logged-out Minimalist Landing Prompt */
          <div className="max-w-lg mx-auto my-12 bg-white border border-neutral-200 rounded-lg p-8 text-center space-y-4">
            <h1 className="text-xl font-semibold text-neutral-900">
              欢迎使用 ClipNote 云端剪切板
            </h1>
            <p className="text-sm text-neutral-600 leading-relaxed">
              无需邮箱验证即可注册专属账号（密码长度 12-20 个字符，已注册账号不可重复注册，密码连续输错 3 次暂停登录 15 分钟）。每个账号支持保存最多 1000 条记录。
            </p>
            <div className="flex items-center justify-center gap-3 pt-2">
              <button
                type="button"
                onClick={() => setIsAuthModalOpen(true)}
                className="py-2.5 px-5 text-xs font-medium text-white bg-neutral-900 hover:bg-neutral-800 rounded-md transition-colors whitespace-nowrap"
              >
                登录 / 注册新账号
              </button>

            </div>
          </div>
        ) : (
          <div inert={saving} aria-busy={saving} className="flex flex-col lg:flex-row items-stretch gap-6">
            {/* Left Sidebar: Chronological Timeline */}
            <TimelineSidebar
              buckets={timelineBuckets}
              activeTimelineKey={timelineKey}
              totalItemsCount={allItems.length}
              favoriteCount={favoriteCount}
              username={currentUser.username}
              rememberMe={rememberMe}
              onSelectTimeline={(key) => {
                setTimelineKey(key);
                setPage(1);
              }}
            />

            {/* Right Workspace Column */}
            <div className="order-1 lg:order-2 flex-1 min-w-0 space-y-5">
              {/* Instant Paste & Enter Composer */}
              <section
                aria-label="快速粘贴与新建剪切板条目"
                className="bg-white border border-neutral-200 rounded-lg p-4"
              >
                <div className="flex flex-wrap items-center justify-between gap-2 mb-2.5">
                  <label
                    htmlFor="clipboard-composer-textarea"
                    className="text-xs font-semibold text-neutral-900 flex flex-wrap items-center gap-1.5"
                  >
                    <span className="whitespace-nowrap shrink-0">快速录入剪切板</span>
                    <span className="text-neutral-300" aria-hidden="true">·</span>
                    <span className="font-normal text-neutral-500">
                      粘贴或输入文本后按 Enter 立即生成历史条目（Shift + Enter 换行）
                    </span>
                  </label>
                  <div className="flex items-center gap-3 text-xs font-mono tabular-nums text-neutral-500">
                    <span
                      className={
                        composerContent.length >= MAX_CONTENT_LENGTH
                          ? 'text-red-600 font-semibold'
                          : ''
                      }
                    >
                      {composerContent.length} / {MAX_CONTENT_LENGTH} 字符
                    </span>
                    <span className="text-neutral-300" aria-hidden="true">·</span>
                    <span>
                      容量 {allItems.length} / {MAX_ITEMS_PER_ACCOUNT}
                    </span>
                  </div>
                </div>

                <textarea
                  ref={composerTextareaRef}
                  id="clipboard-composer-textarea"
                  rows={3}
                  maxLength={MAX_CONTENT_LENGTH}
                  value={composerContent}
                  onChange={(e) => {
                    const val = e.target.value;
                    if (val.length <= MAX_CONTENT_LENGTH) {
                      setComposerContent(val);
                    } else {
                      setComposerContent(val.slice(0, MAX_CONTENT_LENGTH));
                    }
                    if (composerNotice) setComposerNotice(null);
                  }}
                  onKeyDown={handleComposerKeyDown}
                  placeholder="在此处粘贴或输入文本（最长 5000 个字符），按回车键 (Enter) 立即形成历史条目..."
                  className="w-full p-3 text-sm font-mono bg-neutral-50/70 border border-neutral-200 rounded-md focus:bg-white focus:outline-none focus:border-neutral-900 transition-colors resize-y"
                />

                {/* Composer Options & Submit Row */}
                <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
                  <div className="flex flex-wrap items-center gap-3">
                    {/* Pre-select Category */}
                    <div className="flex items-center gap-1.5 text-xs">
                      <label htmlFor="composer-category-select" className="text-neutral-500">
                        归属分类:
                      </label>
                      <select
                        id="composer-category-select"
                        value={composerCategory}
                        onChange={(e) => setComposerCategory(e.target.value)}
                        className="py-1.5 px-2.5 text-xs font-medium bg-neutral-100 border border-neutral-200 rounded-md text-neutral-800 focus:outline-none focus:border-neutral-900"
                      >
                        {categories.map((cat) => (
                          <option key={cat} value={cat}>
                            {cat}
                          </option>
                        ))}
                      </select>
                    </div>

                    {/* Optional Initial Tags */}
                    <div className="flex items-center gap-1.5 text-xs">
                      <label htmlFor="composer-tags-input" className="text-neutral-500">
                        标签:
                      </label>
                      <input
                        id="composer-tags-input"
                        type="text"
                        value={composerTagsInput}
                        onChange={(e) => setComposerTagsInput(e.target.value)}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter') {
                            e.preventDefault();
                            handleCreateEntry();
                          }
                        }}
                        placeholder="如 react, 命令（可选）"
                        className="w-40 py-1.5 px-2.5 text-xs bg-white border border-neutral-200 rounded-md focus:outline-none focus:border-neutral-900"
                      />
                    </div>
                  </div>

                  <div className="flex items-center gap-2 shrink-0">
                    <button
                      type="button"
                      onClick={handlePasteFromSystemClipboard}
                      className="py-2 px-3 text-xs font-medium text-neutral-700 bg-neutral-100 hover:bg-neutral-200 rounded-md transition-colors inline-flex items-center gap-1.5 whitespace-nowrap shrink-0"
                    >
                      <ClipboardPaste className="w-3.5 h-3.5" />
                      <span>读取剪贴板</span>
                    </button>
                    <button
                      type="button"
                      onClick={() => handleCreateEntry()}
                      className="py-2 px-4 text-xs font-medium text-white bg-neutral-900 hover:bg-neutral-800 rounded-md transition-colors inline-flex items-center gap-1.5 whitespace-nowrap shrink-0"
                    >
                      <CornerDownLeft className="w-3.5 h-3.5" />
                      <span>回车保存条目</span>
                    </button>
                  </div>
                </div>

                {/* Inline Composer Notice */}
                {composerNotice && (
                  <div
                    role={composerNotice.type === 'error' ? 'alert' : 'status'}
                    className={`mt-2.5 pt-2.5 border-t border-neutral-100 flex items-center justify-between text-xs ${
                      composerNotice.type === 'error' ? 'text-red-600' : 'text-emerald-700'
                    }`}
                  >
                    <div className="flex items-center gap-1.5">
                      {composerNotice.type === 'error' ? (
                        <AlertCircle className="w-3.5 h-3.5 shrink-0" />
                      ) : (
                        <Check className="w-3.5 h-3.5 shrink-0" />
                      )}
                      <span>{composerNotice.text}</span>
                    </div>
                    <button
                      type="button"
                      onClick={() => setComposerNotice(null)}
                      aria-label="关闭提示"
                      className="text-neutral-400 hover:text-neutral-700"
                    >
                      <X className="w-3.5 h-3.5" />
                    </button>
                  </div>
                )}
              </section>

              {/* Category Tabs & Filter / Action Toolbar */}
              <section
                aria-label="分类切换与筛选工具栏"
                className="bg-white border border-neutral-200 rounded-lg"
              >
                {/* Category Tabs Row */}
                <div className="flex items-center justify-between gap-4 px-4 pt-3 pb-2.5 border-b border-neutral-200 overflow-x-auto">
                  <div
                    role="tablist"
                    aria-label="剪切板分类切换"
                    className="flex items-center gap-1.5"
                  >
                    <button
                      type="button"
                      role="tab"
                      aria-selected={categoryTab === 'ALL'}
                      onClick={() => {
                        setCategoryTab('ALL');
                        setPage(1);
                      }}
                      className={`py-1.5 px-3 text-xs font-medium rounded-md transition-colors whitespace-nowrap shrink-0 ${
                        categoryTab === 'ALL'
                          ? 'bg-neutral-900 text-white'
                          : 'text-neutral-600 hover:text-neutral-900 hover:bg-neutral-100'
                      }`}
                    >
                      全部 ({allItems.length})
                    </button>

                    <button
                      type="button"
                      role="tab"
                      aria-selected={categoryTab === 'FAVORITES'}
                      onClick={() => {
                        setCategoryTab('FAVORITES');
                        setPage(1);
                      }}
                      className={`py-1.5 px-3 text-xs font-medium rounded-md transition-colors whitespace-nowrap shrink-0 ${
                        categoryTab === 'FAVORITES'
                          ? 'bg-neutral-900 text-white'
                          : 'text-neutral-600 hover:text-neutral-900 hover:bg-neutral-100'
                      }`}
                    >
                      收藏 ({favoriteCount})
                    </button>

                    {categories.map((cat) => {
                      const count = allItems.filter((it) => it.category === cat).length;
                      const isActive = categoryTab === cat;
                      return (
                        <button
                          key={cat}
                          type="button"
                          role="tab"
                          aria-selected={isActive}
                          onClick={() => {
                            setCategoryTab(cat);
                            setPage(1);
                          }}
                          className={`py-1.5 px-3 text-xs font-medium rounded-md transition-colors whitespace-nowrap shrink-0 ${
                            isActive
                              ? 'bg-neutral-900 text-white'
                              : 'text-neutral-600 hover:text-neutral-900 hover:bg-neutral-100'
                          }`}
                        >
                          {cat} ({count})
                        </button>
                      );
                    })}
                  </div>

                  <button
                    type="button"
                    onClick={() => setIsCategoryModalOpen(true)}
                    className="py-1.5 px-2.5 text-xs font-medium text-neutral-600 hover:text-neutral-900 hover:bg-neutral-100 rounded-md transition-colors inline-flex items-center gap-1 whitespace-nowrap shrink-0"
                  >
                    <FolderKanban className="w-3.5 h-3.5" />
                    <span>分类管理</span>
                  </button>
                </div>

                {/* Search, Active Filters & Clear All Row */}
                <div className="px-4 py-2.5 bg-neutral-50/50 border-b border-neutral-200 flex flex-wrap items-center justify-between gap-3">
                  <div className="flex flex-wrap items-center gap-3 flex-1 min-w-[220px]">
                    <div className="relative flex-1 max-w-xs">
                      <Search className="w-3.5 h-3.5 text-neutral-400 absolute left-2.5 top-1/2 -translate-y-1/2 pointer-events-none" />
                      <label htmlFor="clipboard-search-input" className="sr-only">
                        搜索剪切板内容或标签
                      </label>
                      <input
                        id="clipboard-search-input"
                        type="search"
                        value={searchQuery}
                        onChange={(e) => {
                          setSearchQuery(e.target.value);
                          setPage(1);
                        }}
                        placeholder="搜索内容、分类或 #标签..."
                        className="w-full pl-8 pr-3 py-1.5 text-xs bg-white border border-neutral-200 rounded-md focus:outline-none focus:border-neutral-900"
                      />
                    </div>

                    {/* Active Timeline or Tag Filter Clear Controls */}
                    {timelineKey !== 'ALL' && (
                      <button
                        type="button"
                        onClick={() => {
                          setTimelineKey('ALL');
                          setPage(1);
                        }}
                        className="text-xs text-neutral-700 hover:text-neutral-950 inline-flex items-center gap-1 underline underline-offset-4 whitespace-nowrap"
                      >
                        <span>
                          时间筛选:{' '}
                          {timelineBuckets.find((b) => b.key === timelineKey)?.label || timelineKey}
                        </span>
                        <X className="w-3 h-3" />
                      </button>
                    )}

                    {tagFilter && (
                      <button
                        type="button"
                        onClick={() => {
                          setTagFilter('');
                          setPage(1);
                        }}
                        className="text-xs font-mono text-neutral-700 hover:text-neutral-950 inline-flex items-center gap-1 underline underline-offset-4 whitespace-nowrap"
                      >
                        <span>标签: #{tagFilter}</span>
                        <X className="w-3 h-3" />
                      </button>
                    )}
                  </div>

                  {/* Clear All Controls */}
                  <div className="flex items-center gap-2 shrink-0">
                    <span className="text-xs text-neutral-500 font-mono tabular-nums">
                      筛选结果 {paginated.totalFiltered} 条
                    </span>
                    {allItems.length > 0 && (
                      <>
                        <span className="text-neutral-300" aria-hidden="true">·</span>
                        {confirmClearAll ? (
                          <div className="inline-flex items-center gap-1.5">
                            <span className="text-xs text-red-600 font-medium">
                              {categoryTab === 'ALL'
                                ? '确定清空全部记录？'
                                : `确定清空当前分类？`}
                            </span>
                            <button
                              type="button"
                              onClick={handleClearAllConfirmed}
                              className="py-1 px-2.5 text-xs font-medium text-white bg-red-600 hover:bg-red-700 rounded transition-colors whitespace-nowrap"
                            >
                              确认清空
                            </button>
                            <button
                              type="button"
                              onClick={() => setConfirmClearAll(false)}
                              className="py-1 px-2 text-xs text-neutral-600 hover:bg-neutral-200 rounded transition-colors whitespace-nowrap"
                            >
                              取消
                            </button>
                          </div>
                        ) : (
                          <button
                            type="button"
                            onClick={() => setConfirmClearAll(true)}
                            className="py-1 px-2.5 text-xs font-medium text-neutral-600 hover:text-red-600 hover:bg-red-50 rounded transition-colors inline-flex items-center gap-1 whitespace-nowrap shrink-0"
                          >
                            <Trash2 className="w-3.5 h-3.5" />
                            <span>全部清空</span>
                          </button>
                        )}
                      </>
                    )}
                  </div>
                </div>

                {/* Clipboard Entries List */}
                {paginated.pageItems.length > 0 ? (
                  <div className="divide-y divide-neutral-200">
                    {paginated.pageItems.map((item) => (
                      <ClipboardItemRow
                        key={item.id}
                        item={item}
                        categories={categories}
                        copiedId={copiedId}
                        activeTagFilter={tagFilter}
                        onCopy={handleCopyItem}
                        onToggleFavorite={handleToggleFavorite}
                        onDelete={handleDeleteItem}
                        onChangeCategory={handleChangeItemCategory}
                        onAddTag={handleAddTag}
                        onRemoveTag={handleRemoveTag}
                        onSelectTagFilter={(t) => {
                          setTagFilter(t);
                          setPage(1);
                        }}
                      />
                    ))}
                  </div>
                ) : (
                  <div className="py-14 px-6 text-center space-y-3">
                    <p className="text-sm font-medium text-neutral-700">
                      当前视图下暂无剪切板历史记录
                    </p>
                    <p className="text-xs text-neutral-500 max-w-md mx-auto">
                      在上方输入框中粘贴文本并按回车键 (Enter) 即可立即生成条目，支持点击直接复制、添加标签、分类管理与收藏。
                    </p>
                    {(categoryTab !== 'ALL' ||
                      timelineKey !== 'ALL' ||
                      tagFilter !== '' ||
                      searchQuery !== '') && (
                      <button
                        type="button"
                        onClick={() => {
                          setCategoryTab('ALL');
                          setTimelineKey('ALL');
                          setTagFilter('');
                          setSearchQuery('');
                          setPage(1);
                        }}
                        className="py-1.5 px-3.5 text-xs font-medium text-neutral-900 bg-neutral-100 hover:bg-neutral-200 rounded-md transition-colors"
                      >
                        重置全部筛选条件
                      </button>
                    )}
                  </div>
                )}

                {/* Pagination Footer */}
                <div className="px-5 py-3 border-t border-neutral-200 bg-neutral-50/40 flex flex-wrap items-center justify-between gap-4 text-xs text-neutral-600">
                  <div className="flex items-center gap-3 font-mono tabular-nums">
                    <span>
                      共 {paginated.totalFiltered} 条记录 · 第 {paginated.currentPage} /{' '}
                      {paginated.totalPages} 页
                    </span>
                    <span className="text-neutral-300" aria-hidden="true">·</span>
                    <label htmlFor="page-size-select" className="sr-only">
                      每页显示条数
                    </label>
                    <select
                      id="page-size-select"
                      value={pageSize}
                      onChange={(e) => {
                        setPageSize(Number(e.target.value));
                        setPage(1);
                      }}
                      className="bg-white border border-neutral-200 rounded px-2 py-1 text-xs font-mono tabular-nums focus:outline-none focus:border-neutral-900"
                    >
                      <option value={5}>5 条/页</option>
                      <option value={8}>8 条/页</option>
                      <option value={15}>15 条/页</option>
                      <option value={30}>30 条/页</option>
                    </select>
                  </div>

                  {/* Page Controls */}
                  <div className="flex items-center gap-1 font-mono tabular-nums">
                    <button
                      type="button"
                      disabled={paginated.currentPage <= 1}
                      onClick={() => setPage((p) => Math.max(1, p - 1))}
                      aria-label="上一页"
                      className="py-1 px-2.5 border border-neutral-200 bg-white rounded hover:bg-neutral-100 disabled:opacity-40 disabled:pointer-events-none inline-flex items-center gap-1 transition-colors whitespace-nowrap"
                    >
                      <ChevronLeft className="w-3.5 h-3.5" />
                      <span>上一页</span>
                    </button>

                    {Array.from({ length: paginated.totalPages }, (_, i) => i + 1)
                      .slice(
                        Math.max(0, paginated.currentPage - 3),
                        Math.min(paginated.totalPages, paginated.currentPage + 2)
                      )
                      .map((pageNum) => (
                        <button
                          key={pageNum}
                          type="button"
                          onClick={() => setPage(pageNum)}
                          aria-label={`第 ${pageNum} 页`}
                          aria-current={pageNum === paginated.currentPage ? 'page' : undefined}
                          className={`py-1 px-2.5 rounded border transition-colors ${
                            pageNum === paginated.currentPage
                              ? 'bg-neutral-900 text-white border-neutral-900 font-semibold'
                              : 'bg-white text-neutral-700 border-neutral-200 hover:bg-neutral-100'
                          }`}
                        >
                          {pageNum}
                        </button>
                      ))}

                    <button
                      type="button"
                      disabled={paginated.currentPage >= paginated.totalPages}
                      onClick={() =>
                        setPage((p) => Math.min(paginated.totalPages, p + 1))
                      }
                      aria-label="下一页"
                      className="py-1 px-2.5 border border-neutral-200 bg-white rounded hover:bg-neutral-100 disabled:opacity-40 disabled:pointer-events-none inline-flex items-center gap-1 transition-colors whitespace-nowrap"
                    >
                      <span>下一页</span>
                      <ChevronRight className="w-3.5 h-3.5" />
                    </button>
                  </div>
                </div>
              </section>
            </div>
          </div>
        )}
      </main>

      {/* Minimalist Footer */}
      <footer className="py-4 px-6 border-t border-neutral-200 bg-white text-xs text-neutral-400 flex flex-wrap items-center justify-between gap-2">
        <span>ClipNote 云端剪切板 · 单账号最高保存 1000 条记录 · 单条上限 5000 字符</span>
        <span>免邮箱注册 · 12-20 位密码保护 · 连续输错 3 次暂停 15 分钟</span>
      </footer>

      {/* Auth Modal */}
      <AuthModal
        isOpen={isAuthModalOpen}
        canClose={true}
        currentUser={currentUser}
        rememberMe={rememberMe}
        onClose={() => setIsAuthModalOpen(false)}
        onLogin={handleLogin}
        onRegister={handleRegister}
        onLogout={handleLogout}
      />

      {/* Category Manager Modal */}
      <CategoryManagerModal
        isOpen={isCategoryModalOpen}
        categories={categories}
        items={allItems}
        onClose={() => setIsCategoryModalOpen(false)}
        onAddCategory={handleAddCategory}
        onRenameCategory={handleRenameCategory}
        onDeleteCategory={handleDeleteCategory}
      />
    </div>
  );
}
