import React, { useState } from 'react';
import { Lock, User, Eye, EyeOff, X, Check, AlertCircle, LogOut } from 'lucide-react';
import {
  MIN_PASSWORD_LENGTH,
  MAX_PASSWORD_LENGTH,
  UserAccount,
} from '../utils/clipboardLogic';

interface AuthModalProps {
  isOpen: boolean;
  canClose: boolean;
  currentUser: UserAccount | null;
  rememberMe: boolean;
  onClose: () => void;
  onLogin: (username: string, password: string, remember: boolean) => Promise<{ ok: boolean; error?: string }>;
  onRegister: (username: string, password: string, remember: boolean) => Promise<{ ok: boolean; error?: string }>;
  onLogout: () => void;
}

export const AuthModal: React.FC<AuthModalProps> = ({
  isOpen,
  canClose,
  currentUser,
  rememberMe: initialRemember,
  onClose,
  onLogin,
  onRegister,
  onLogout,
}) => {
  const [pending, setPending] = useState(false);
  const [mode, setMode] = useState<'login' | 'register'>('login');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [remember, setRemember] = useState(initialRemember);
  const [showPassword, setShowPassword] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [successMsg, setSuccessMsg] = useState<string | null>(null);

  if (!isOpen) return null;

  const passwordLen = password.length;
  const isPasswordLengthValid =
    passwordLen >= MIN_PASSWORD_LENGTH && passwordLen <= MAX_PASSWORD_LENGTH;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (pending) return;
    setPending(true);
    setErrorMsg(null);
    setSuccessMsg(null);
    try {
      const res = await (mode === 'register' ? onRegister : onLogin)(username, password, remember);
      if (!res.ok) setErrorMsg(res.error || '操作失败');
      else { setUsername(''); setPassword(''); }
    } catch {
      setErrorMsg('连接失败，请重试');
    } finally { setPending(false); }
  };

  const switchMode = (nextMode: 'login' | 'register') => {
    setMode(nextMode);
    setErrorMsg(null);
    setSuccessMsg(null);
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-neutral-950/40 backdrop-blur-[2px] p-4"
      onKeyDown={(e) => { if (e.key === 'Escape' && canClose) onClose(); }}
      role="dialog"
      aria-modal="true"
      aria-labelledby="auth-dialog-title"
    >
      <div className="w-full max-w-md bg-white border border-neutral-200 rounded-lg p-6">
        {/* Header */}
        <div className="flex items-center justify-between pb-4 border-b border-neutral-200">
          <div>
            <h2 id="auth-dialog-title" className="text-base font-semibold text-neutral-900">
              {mode === 'login' ? '账号登录与切换' : '注册新剪切板账号'}
            </h2>
            <p className="text-xs text-neutral-500 mt-0.5">
              无需邮箱验证 · 密码 12-20 位 · 连续输错 3 次暂停登录 15 分钟
            </p>
          </div>
          {canClose && (
            <button
              type="button"
              onClick={onClose}
              aria-label="关闭账号窗口"
              className="p-2 text-neutral-500 hover:text-neutral-900 rounded-md transition-colors"
            >
              <X className="w-4 h-4" />
            </button>
          )}
        </div>

        {/* Current logged-in status bar if active */}
        {currentUser && (
          <div className="mt-4 p-3 bg-neutral-50 border border-neutral-200 rounded-md flex items-center justify-between gap-3">
            <div className="min-w-0">
              <div className="text-xs text-neutral-500">当前已登录账号</div>
              <div className="text-sm font-semibold text-neutral-900 truncate flex items-center gap-2">
                <span>@{currentUser.username}</span>
                <span className="text-neutral-300" aria-hidden="true">·</span>
                <span className="text-xs font-normal text-neutral-600 tabular-nums">
                  {currentUser.items.length} / 1000 条记录
                </span>
              </div>
            </div>
            <button
              type="button"
              onClick={() => {
                setErrorMsg(null);
                setSuccessMsg(null);
                onLogout();
              }}
              className="px-3 py-1.5 text-xs font-medium text-neutral-700 bg-white border border-neutral-200 rounded hover:bg-neutral-100 transition-colors flex items-center gap-1.5 whitespace-nowrap shrink-0"
            >
              <LogOut className="w-3.5 h-3.5" />
              退出登录
            </button>
          </div>
        )}

        {/* Mode Segmented Control */}
        <div className="mt-4 grid grid-cols-2 gap-1 p-1 bg-neutral-100 rounded-md">
          <button
            type="button"
            onClick={() => switchMode('login')}
            className={`py-2 px-4 text-xs font-medium rounded transition-colors whitespace-nowrap ${
              mode === 'login'
                ? 'bg-white text-neutral-900 shadow-xs'
                : 'text-neutral-600 hover:text-neutral-900'
            }`}
          >
            登录已有账号
          </button>
          <button
            type="button"
            onClick={() => switchMode('register')}
            className={`py-2 px-4 text-xs font-medium rounded transition-colors whitespace-nowrap ${
              mode === 'register'
                ? 'bg-white text-neutral-900 shadow-xs'
                : 'text-neutral-600 hover:text-neutral-900'
            }`}
          >
            免邮箱注册账号
          </button>
        </div>

        {/* Form */}
        <form onSubmit={handleSubmit} className="mt-4 space-y-4" noValidate>
          <div>
            <label
              htmlFor="auth-username-input"
              className="block text-xs font-medium text-neutral-700 mb-1.5"
            >
              账号名称 {mode === 'register' && <span className="text-neutral-400 font-normal">（注册后不可重复注册）</span>}
            </label>
            <div className="relative">
              <User className="w-4 h-4 text-neutral-400 absolute left-3 top-1/2 -translate-y-1/2 pointer-events-none" />
              <input
                id="auth-username-input"
                type="text"
                value={username}
                onChange={(e) => {
                  setUsername(e.target.value);
                  if (errorMsg) setErrorMsg(null);
                }}
                placeholder="输入 3-24 位账号名，如 studio_user"
                autoComplete="username"
                className="w-full pl-9 pr-3 py-2 text-sm bg-white border border-neutral-300 rounded-md focus:outline-none focus:border-neutral-900 transition-colors"
              />
            </div>
          </div>

          <div>
            <div className="flex items-center justify-between mb-1.5">
              <label
                htmlFor="auth-password-input"
                className="block text-xs font-medium text-neutral-700"
              >
                访问密码（12-20 个字符）
              </label>
              <span
                className={`text-xs font-mono tabular-nums ${
                  passwordLen === 0
                    ? 'text-neutral-400'
                    : isPasswordLengthValid
                    ? 'text-emerald-700'
                    : 'text-amber-700'
                }`}
              >
                {passwordLen} / 12-20 位
              </span>
            </div>
            <div className="relative">
              <Lock className="w-4 h-4 text-neutral-400 absolute left-3 top-1/2 -translate-y-1/2 pointer-events-none" />
              <input
                id="auth-password-input"
                type={showPassword ? 'text' : 'password'}
                value={password}
                onChange={(e) => {
                  setPassword(e.target.value);
                  if (errorMsg) setErrorMsg(null);
                }}
                placeholder="请输入 12 至 20 个字符的密码"
                autoComplete={mode === 'register' ? 'new-password' : 'current-password'}
                className="w-full pl-9 pr-10 py-2 text-sm font-mono bg-white border border-neutral-300 rounded-md focus:outline-none focus:border-neutral-900 transition-colors"
              />
              <button
                type="button"
                onClick={() => setShowPassword((prev) => !prev)}
                aria-label={showPassword ? '隐藏密码' : '显示密码'}
                className="absolute right-2.5 top-1/2 -translate-y-1/2 p-1 text-neutral-400 hover:text-neutral-700"
              >
                {showPassword ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
              </button>
            </div>
          </div>

          {/* Remember Login Checkbox */}
          <div className="flex items-center justify-between pt-1">
            <label
              htmlFor="auth-remember-checkbox"
              className="inline-flex items-center gap-2 text-xs text-neutral-700 cursor-pointer select-none"
            >
              <input
                id="auth-remember-checkbox"
                type="checkbox"
                checked={remember}
                onChange={(e) => setRemember(e.target.checked)}
                className="w-4 h-4 rounded border-neutral-300 text-neutral-900 focus:ring-neutral-900"
              />
              <span>记住登录状态（下次打开自动登录）</span>
            </label>
          </div>

          {/* Validation / Lockout Error */}
          {errorMsg && (
            <div
              role="alert"
              className="p-3 bg-red-50 border border-red-200 rounded-md flex items-start gap-2 text-xs text-red-700"
            >
              <AlertCircle className="w-4 h-4 shrink-0 mt-0.5 text-red-600" />
              <span>{errorMsg}</span>
            </div>
          )}

          {successMsg && (
            <div
              role="status"
              className="p-3 bg-emerald-50 border border-emerald-200 rounded-md flex items-center gap-2 text-xs text-emerald-800"
            >
              <Check className="w-4 h-4 shrink-0 text-emerald-600" />
              <span>{successMsg}</span>
            </div>
          )}

          <button
            type="submit"
            disabled={pending}
            className="w-full py-2.5 px-4 text-sm font-medium text-white bg-neutral-900 hover:bg-neutral-800 rounded-md transition-colors whitespace-nowrap"
          >
            {pending ? '正在连接…' : mode === 'login' ? '立即登录' : '完成注册并登录'}
          </button>
        </form>

      </div>
    </div>
  );
};
