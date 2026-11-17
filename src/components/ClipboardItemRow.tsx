import React, { useState } from 'react';
import { Copy, Check, Star, Trash2, Plus, X } from 'lucide-react';
import { ClipboardItem, getItemTimelineBucket } from '../utils/clipboardLogic';

interface ClipboardItemRowProps {
  item: ClipboardItem;
  categories: string[];
  copiedId: string | null;
  activeTagFilter: string;
  onCopy: (item: ClipboardItem) => void;
  onToggleFavorite: (itemId: string) => void;
  onDelete: (itemId: string) => void;
  onChangeCategory: (itemId: string, category: string) => void;
  onAddTag: (itemId: string, tag: string) => void;
  onRemoveTag: (itemId: string, tag: string) => void;
  onSelectTagFilter: (tag: string) => void;
}

export const ClipboardItemRow: React.FC<ClipboardItemRowProps> = ({
  item,
  categories,
  copiedId,
  activeTagFilter,
  onCopy,
  onToggleFavorite,
  onDelete,
  onChangeCategory,
  onAddTag,
  onRemoveTag,
  onSelectTagFilter,
}) => {
  const [isAddingTag, setIsAddingTag] = useState(false);
  const [tagInput, setTagInput] = useState('');

  const isCopied = copiedId === item.id;
  const bucket = getItemTimelineBucket(item.createdAt);
  const createdDate = new Date(item.createdAt);
  const formattedTime = `${String(createdDate.getMonth() + 1).padStart(2, '0')}-${String(
    createdDate.getDate()
  ).padStart(2, '0')} ${String(createdDate.getHours()).padStart(2, '0')}:${String(
    createdDate.getMinutes()
  ).padStart(2, '0')}`;

  const previewTitle = item.content.slice(0, 20).replace(/\s+/g, ' ');

  const handleTagSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (tagInput.trim()) {
      onAddTag(item.id, tagInput);
    }
    setTagInput('');
    setIsAddingTag(false);
  };

  return (
    <article className="group py-4 px-5 hover:bg-neutral-50/80 transition-colors">
      {/* Top Row: Clean Unboxed Metadata & Action Controls */}
      <div className="flex flex-wrap items-center justify-between gap-3 mb-2">
        {/* Static Metadata rendered as clean unboxed inline text with · separators */}
        <div className="flex flex-wrap items-center gap-1.5 text-xs text-neutral-500">
          <span className="font-medium text-neutral-800">{bucket.label}</span>
          <span aria-hidden="true">·</span>
          <time dateTime={item.createdAt} className="font-mono tabular-nums">
            {formattedTime}
          </time>
          <span aria-hidden="true">·</span>
          <span className="font-mono tabular-nums">{item.content.length} 字符</span>
          <span aria-hidden="true">·</span>

          {/* Inline Category Selector */}
          <label htmlFor={`cat-select-${item.id}`} className="sr-only">
            条目分类
          </label>
          <select
            id={`cat-select-${item.id}`}
            value={item.category}
            onChange={(e) => onChangeCategory(item.id, e.target.value)}
            className="bg-transparent text-xs font-medium text-neutral-700 hover:text-neutral-950 focus:outline-none cursor-pointer underline decoration-neutral-300 underline-offset-4"
          >
            {categories.map((cat) => (
              <option key={cat} value={cat}>
                {cat}
              </option>
            ))}
          </select>

          {/* Tags as unboxed inline typography */}
          {item.tags.length > 0 && (
            <>
              <span aria-hidden="true">·</span>
              <div className="inline-flex flex-wrap items-center gap-2">
                {item.tags.map((tag) => {
                  const isTagSelected = activeTagFilter.toLowerCase() === tag.toLowerCase();
                  return (
                    <span key={tag} className="inline-flex items-center gap-0.5">
                      <button
                        type="button"
                        onClick={() => onSelectTagFilter(isTagSelected ? '' : tag)}
                        className={`text-xs font-mono transition-colors ${
                          isTagSelected
                            ? 'text-neutral-950 font-semibold underline underline-offset-4'
                            : 'text-neutral-600 hover:text-neutral-950'
                        }`}
                      >
                        #{tag}
                      </button>
                      <button
                        type="button"
                        onClick={() => onRemoveTag(item.id, tag)}
                        aria-label={`移除标签 ${tag}`}
                        className="text-neutral-400 hover:text-red-600 p-0.5"
                      >
                        <X className="w-3 h-3" />
                      </button>
                    </span>
                  );
                })}
              </div>
            </>
          )}

          {/* Add Tag Trigger / Inline Form */}
          <span aria-hidden="true">·</span>
          {isAddingTag ? (
            <form onSubmit={handleTagSubmit} className="inline-flex items-center gap-1">
              <input
                type="text"
                value={tagInput}
                onChange={(e) => setTagInput(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Escape') {
                    setIsAddingTag(false);
                    setTagInput('');
                  }
                }}
                placeholder="输入标签回车"
                aria-label="输入新标签名称"
                maxLength={16}
                autoFocus
                className="w-24 px-1.5 py-0.5 text-xs bg-white border border-neutral-300 rounded focus:outline-none focus:border-neutral-900"
              />
              <button
                type="submit"
                className="text-xs font-medium text-neutral-900 hover:underline px-1"
              >
                添加
              </button>
              <button
                type="button"
                onClick={() => {
                  setIsAddingTag(false);
                  setTagInput('');
                }}
                className="text-xs text-neutral-400 hover:text-neutral-700 px-1"
              >
                取消
              </button>
            </form>
          ) : (
            <button
              type="button"
              onClick={() => setIsAddingTag(true)}
              className="inline-flex items-center gap-0.5 text-xs text-neutral-500 hover:text-neutral-900 transition-colors whitespace-nowrap"
            >
              <Plus className="w-3 h-3" />
              <span>添加标签</span>
            </button>
          )}
        </div>

        {/* Right Action Buttons */}
        <div className="flex items-center gap-1.5 shrink-0">
          <button
            type="button"
            onClick={() => onCopy(item)}
            aria-label={`复制条目 ${previewTitle}`}
            className={`py-1 px-2.5 text-xs font-medium rounded transition-colors inline-flex items-center gap-1.5 whitespace-nowrap shrink-0 ${
              isCopied
                ? 'bg-emerald-700 text-white'
                : 'bg-neutral-100 text-neutral-800 hover:bg-neutral-900 hover:text-white'
            }`}
          >
            {isCopied ? (
              <>
                <Check className="w-3.5 h-3.5" />
                <span>已复制</span>
              </>
            ) : (
              <>
                <Copy className="w-3.5 h-3.5" />
                <span>复制</span>
              </>
            )}
          </button>

          <button
            type="button"
            onClick={() => onToggleFavorite(item.id)}
            aria-label={`${item.favorite ? '取消收藏' : '收藏'}条目 ${previewTitle}`}
            className={`py-1 px-2 text-xs font-medium rounded transition-colors inline-flex items-center gap-1 whitespace-nowrap shrink-0 ${
              item.favorite
                ? 'text-amber-600 bg-amber-50 hover:bg-amber-100'
                : 'text-neutral-500 hover:text-neutral-900 hover:bg-neutral-100'
            }`}
          >
            <Star className={`w-3.5 h-3.5 ${item.favorite ? 'fill-amber-500 text-amber-500' : ''}`} />
            <span>{item.favorite ? '已收藏' : '收藏'}</span>
          </button>

          <button
            type="button"
            onClick={() => onDelete(item.id)}
            aria-label={`删除条目 ${previewTitle}`}
            className="py-1 px-2 text-xs text-neutral-500 hover:text-red-600 hover:bg-red-50 rounded transition-colors inline-flex items-center gap-1 whitespace-nowrap shrink-0"
          >
            <Trash2 className="w-3.5 h-3.5" />
            <span>删除</span>
          </button>
        </div>
      </div>

      {/* Main Content Area — Clickable to directly copy */}
      <button
        type="button"
        onClick={() => onCopy(item)}
        title="点击直接复制全文"
        className="w-full text-left block group/content focus:outline-none focus-visible:ring-1 focus-visible:ring-neutral-900 rounded"
      >
        <pre className="text-sm text-neutral-900 font-mono whitespace-pre-wrap break-words leading-relaxed max-h-48 overflow-y-auto">
          {item.content}
        </pre>
      </button>
    </article>
  );
};
