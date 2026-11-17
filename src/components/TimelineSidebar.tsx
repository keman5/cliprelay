import React from 'react';
import { Clock } from 'lucide-react';
import { TimelineBucket, MAX_ITEMS_PER_ACCOUNT } from '../utils/clipboardLogic';

interface TimelineSidebarProps {
  buckets: TimelineBucket[];
  activeTimelineKey: string;
  totalItemsCount: number;
  favoriteCount: number;
  username: string;
  rememberMe: boolean;
  onSelectTimeline: (key: string) => void;
}

export const TimelineSidebar: React.FC<TimelineSidebarProps> = ({
  buckets,
  activeTimelineKey,
  totalItemsCount,
  favoriteCount,
  username,
  rememberMe,
  onSelectTimeline,
}) => {
  const dateBuckets = buckets.filter((b) => b.kind === 'date');
  const lastMonthBuckets = buckets.filter((b) => b.kind === 'last-month');
  const earlierMonthBuckets = buckets.filter((b) => b.kind === 'month');

  const renderBucketButton = (bucket: TimelineBucket) => {
    const isActive = activeTimelineKey === bucket.key;
    return (
      <button
        key={bucket.key}
        type="button"
        onClick={() => onSelectTimeline(bucket.key)}
        className={`group relative w-full text-left pl-4 pr-3 py-2 rounded-md text-xs transition-colors flex items-center justify-between gap-2 ${
          isActive
            ? 'bg-neutral-900 text-white font-medium'
            : 'text-neutral-600 hover:text-neutral-900 hover:bg-neutral-100'
        }`}
      >
        <div className="flex items-center gap-2 min-w-0">
          <span className="truncate">{bucket.label}</span>
          {bucket.subLabel && bucket.label !== bucket.subLabel && (
            <>
              <span
                className={isActive ? 'text-neutral-400' : 'text-neutral-300'}
                aria-hidden="true"
              >
                ·
              </span>
              <span
                className={`font-mono tabular-nums truncate ${
                  isActive ? 'text-neutral-300' : 'text-neutral-400'
                }`}
              >
                {bucket.subLabel}
              </span>
            </>
          )}
        </div>
        <span
          className={`font-mono tabular-nums shrink-0 ${
            isActive ? 'text-neutral-200' : 'text-neutral-400 group-hover:text-neutral-700'
          }`}
        >
          {bucket.count}
        </span>
      </button>
    );
  };

  return (
    <aside
      aria-label="时间线归档导航"
      className="order-2 lg:order-1 w-full lg:w-64 shrink-0 flex flex-col justify-between bg-white border border-neutral-200 rounded-lg p-4"
    >
      <div>
        {/* Timeline Header */}
        <div className="flex items-center justify-between pb-3 mb-3 border-b border-neutral-200">
          <div className="flex items-center gap-2 text-xs font-semibold text-neutral-900">
            <Clock className="w-3.5 h-3.5 text-neutral-600" />
            <span>时间线归档</span>
          </div>
          <span className="text-xs font-mono tabular-nums text-neutral-400">
            {buckets.length} 个节点
          </span>
        </div>

        {/* All Time Button */}
        <div className="space-y-1">
          <button
            type="button"
            onClick={() => onSelectTimeline('ALL')}
            className={`w-full text-left px-3 py-2 rounded-md text-xs transition-colors flex items-center justify-between ${
              activeTimelineKey === 'ALL'
                ? 'bg-neutral-900 text-white font-medium'
                : 'text-neutral-700 hover:text-neutral-900 hover:bg-neutral-100'
            }`}
          >
            <span>全部时间记录</span>
            <span
              className={`font-mono tabular-nums ${
                activeTimelineKey === 'ALL' ? 'text-neutral-200' : 'text-neutral-400'
              }`}
            >
              {totalItemsCount}
            </span>
          </button>
        </div>

        {/* Vertical Timeline Axis */}
        <div className="mt-4 relative pl-2 border-l border-neutral-200 space-y-4">
          {/* Group 1: 按日期 (Current Month Dates) */}
          {dateBuckets.length > 0 && (
            <div>
              <div className="px-2 mb-1.5 text-[11px] font-medium text-neutral-400">
                按日期（本月）
              </div>
              <div className="space-y-0.5">{dateBuckets.map(renderBucketButton)}</div>
            </div>
          )}

          {/* Group 2: 上个月 (Last Month) */}
          {lastMonthBuckets.length > 0 && (
            <div>
              <div className="px-2 mb-1.5 text-[11px] font-medium text-neutral-400">
                上个月
              </div>
              <div className="space-y-0.5">{lastMonthBuckets.map(renderBucketButton)}</div>
            </div>
          )}

          {/* Group 3: 几月 (Earlier Months) */}
          {earlierMonthBuckets.length > 0 && (
            <div>
              <div className="px-2 mb-1.5 text-[11px] font-medium text-neutral-400">
                更早月份
              </div>
              <div className="space-y-0.5">{earlierMonthBuckets.map(renderBucketButton)}</div>
            </div>
          )}

          {buckets.length === 0 && (
            <div className="py-6 px-2 text-xs text-neutral-400">
              暂无历史时间节点，粘贴文本回车后将按日期、上个月、月份自动生成时间线。
            </div>
          )}
        </div>
      </div>

      {/* Account Quota & Security Footer */}
      <div className="mt-6 pt-4 border-t border-neutral-200 space-y-2.5 text-xs text-neutral-500">
        <div className="flex items-center justify-between">
          <span>账号容量上限</span>
          <span className="font-mono tabular-nums text-neutral-900 font-medium">
            {totalItemsCount} / {MAX_ITEMS_PER_ACCOUNT}
          </span>
        </div>
        <div className="w-full h-1 bg-neutral-100 rounded-full overflow-hidden">
          <div
            className="h-full bg-neutral-900 transition-transform duration-150 origin-left"
            style={{
              transform: `scaleX(${Math.min(1, totalItemsCount / MAX_ITEMS_PER_ACCOUNT)})`,
            }}
          />
        </div>
        <div className="flex items-center justify-between pt-1 text-[11px] text-neutral-400">
          <span>@{username}</span>
          <span aria-hidden="true">·</span>
          <span>收藏 {favoriteCount} 条</span>
          <span aria-hidden="true">·</span>
          <span>{rememberMe ? '已记住登录' : '单次会话'}</span>
        </div>
      </div>
    </aside>
  );
};
