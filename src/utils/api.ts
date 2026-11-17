import type { UserAccount } from './clipboardLogic';

export interface SessionData { account: UserAccount; revision: number; remember: boolean }

export async function api<T = unknown>(path: string, options: RequestInit = {}): Promise<T> {
  const response = await fetch('/api' + path, {
    ...options, credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
  });
  const data = await response.json() as T & { error?: string };
  if (!response.ok) throw new Error(data.error || '连接失败，请重试');
  return data as T;
}
