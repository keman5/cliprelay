import React, { useState } from 'react';
import { X, Plus, Trash2, Edit2, Check, FolderKanban } from 'lucide-react';
import { ClipboardItem } from '../utils/clipboardLogic';

interface CategoryManagerModalProps {
  isOpen: boolean;
  categories: string[];
  items: ClipboardItem[];
  onClose: () => void;
  onAddCategory: (name: string) => { valid: boolean; error?: string };
  onRenameCategory: (oldName: string, newName: string) => { valid: boolean; error?: string };
  onDeleteCategory: (name: string) => void;
}

export const CategoryManagerModal: React.FC<CategoryManagerModalProps> = ({
  isOpen,
  categories,
  items,
  onClose,
  onAddCategory,
  onRenameCategory,
  onDeleteCategory,
}) => {
  const [newCategoryName, setNewCategoryName] = useState('');
  const [editingCat, setEditingCat] = useState<string | null>(null);
  const [editingValue, setEditingValue] = useState('');
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  if (!isOpen) return null;

  const getCategoryCount = (cat: string) =>
    items.filter((it) => it.category === cat).length;

  const handleAdd = (e: React.FormEvent) => {
    e.preventDefault();
    setErrorMsg(null);
    const res = onAddCategory(newCategoryName);
    if (!res.valid) {
      setErrorMsg(res.error || '添加分类失败');
    } else {
      setNewCategoryName('');
    }
  };

  const handleStartRename = (cat: string) => {
    setErrorMsg(null);
    setEditingCat(cat);
    setEditingValue(cat);
  };

  const handleConfirmRename = (oldName: string) => {
    setErrorMsg(null);
    if (editingValue.trim() === oldName) {
      setEditingCat(null);
      return;
    }
    const res = onRenameCategory(oldName, editingValue);
    if (!res.valid) {
      setErrorMsg(res.error || '重命名失败');
    } else {
      setEditingCat(null);
    }
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-neutral-950/40 backdrop-blur-[2px] p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="category-modal-title"
    >
      <div className="w-full max-w-md bg-white border border-neutral-200 rounded-lg p-6">
        <div className="flex items-center justify-between pb-4 border-b border-neutral-200">
          <div className="flex items-center gap-2">
            <FolderKanban className="w-4 h-4 text-neutral-700" />
            <h2 id="category-modal-title" className="text-base font-semibold text-neutral-900">
              分类管理
            </h2>
          </div>
          <button
            type="button"
            onClick={onClose}
            aria-label="关闭分类管理窗口"
            className="p-2 text-neutral-500 hover:text-neutral-900 rounded-md transition-colors"
          >
            <X className="w-4 h-4" />
          </button>
        </div>

        {/* Add Category Form */}
        <form onSubmit={handleAdd} className="mt-4 flex items-center gap-2">
          <label htmlFor="new-category-input" className="sr-only">
            新增分类名称
          </label>
          <input
            id="new-category-input"
            type="text"
            value={newCategoryName}
            onChange={(e) => {
              setNewCategoryName(e.target.value);
              if (errorMsg) setErrorMsg(null);
            }}
            placeholder="输入新分类名称（最多 16 字）..."
            maxLength={16}
            className="flex-1 px-3 py-2 text-sm bg-white border border-neutral-300 rounded-md focus:outline-none focus:border-neutral-900 transition-colors"
          />
          <button
            type="submit"
            className="py-2 px-4 text-xs font-medium text-white bg-neutral-900 hover:bg-neutral-800 rounded-md transition-colors flex items-center gap-1.5 whitespace-nowrap shrink-0"
          >
            <Plus className="w-3.5 h-3.5" />
            新增分类
          </button>
        </form>

        {errorMsg && (
          <p role="alert" className="mt-2 text-xs text-red-600">
            {errorMsg}
          </p>
        )}

        {/* Categories List */}
        <div className="mt-4 divide-y divide-neutral-200 border-t border-b border-neutral-200 max-h-72 overflow-y-auto">
          {categories.map((cat) => {
            const count = getCategoryCount(cat);
            const isDefault = cat === '未分类';
            const isEditing = editingCat === cat;

            return (
              <div
                key={cat}
                className="py-2.5 flex items-center justify-between gap-3 text-sm"
              >
                {isEditing ? (
                  <div className="flex-1 flex items-center gap-2">
                    <input
                      type="text"
                      value={editingValue}
                      onChange={(e) => setEditingValue(e.target.value)}
                      onKeyDown={(e) => {
                        if (e.key === 'Enter') handleConfirmRename(cat);
                        if (e.key === 'Escape') setEditingCat(null);
                      }}
                      aria-label={`修改分类 ${cat} 名称`}
                      className="flex-1 px-2.5 py-1 text-sm bg-white border border-neutral-900 rounded focus:outline-none"
                      autoFocus
                    />
                    <button
                      type="button"
                      onClick={() => handleConfirmRename(cat)}
                      aria-label={`确认重命名 ${cat}`}
                      className="p-1.5 text-emerald-700 hover:bg-emerald-50 rounded"
                    >
                      <Check className="w-4 h-4" />
                    </button>
                    <button
                      type="button"
                      onClick={() => setEditingCat(null)}
                      aria-label="取消重命名"
                      className="p-1.5 text-neutral-500 hover:bg-neutral-100 rounded"
                    >
                      <X className="w-4 h-4" />
                    </button>
                  </div>
                ) : (
                  <>
                    <div className="flex items-center gap-2 min-w-0">
                      <span className="font-medium text-neutral-900 truncate">{cat}</span>
                      <span className="text-neutral-300" aria-hidden="true">·</span>
                      <span className="text-xs text-neutral-500 font-mono tabular-nums">
                        {count} 条
                      </span>
                      {isDefault && (
                        <>
                          <span className="text-neutral-300" aria-hidden="true">·</span>
                          <span className="text-xs text-neutral-400">默认分类</span>
                        </>
                      )}
                    </div>

                    {!isDefault && (
                      <div className="flex items-center gap-1 shrink-0">
                        <button
                          type="button"
                          onClick={() => handleStartRename(cat)}
                          aria-label={`重命名分类 ${cat}`}
                          className="p-1.5 text-neutral-500 hover:text-neutral-900 hover:bg-neutral-100 rounded transition-colors"
                        >
                          <Edit2 className="w-3.5 h-3.5" />
                        </button>
                        <button
                          type="button"
                          onClick={() => onDeleteCategory(cat)}
                          aria-label={`删除分类 ${cat}`}
                          className="p-1.5 text-neutral-500 hover:text-red-600 hover:bg-red-50 rounded transition-colors"
                        >
                          <Trash2 className="w-3.5 h-3.5" />
                        </button>
                      </div>
                    )}
                  </>
                )}
              </div>
            );
          })}
        </div>

        <div className="mt-4 flex items-center justify-between text-xs text-neutral-500">
          <span>删除分类后，其下条目会自动归入“未分类”</span>
          <button
            type="button"
            onClick={onClose}
            className="py-1.5 px-3 font-medium text-neutral-800 bg-neutral-100 hover:bg-neutral-200 rounded transition-colors"
          >
            完成
          </button>
        </div>
      </div>
    </div>
  );
};
