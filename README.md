# ClipNote

账号隔离的云端剪切板，React + Cloudflare Workers + D1。

- 账号名称 3–24 字符；密码 12–20 字符；PBKDF2-SHA256 哈希，不保存明文密码。
- HttpOnly / Secure / SameSite 会话 Cookie；记住登录 30 天，单次会话最多 24 小时。
- 连续输错三次暂停登录 15 分钟；登录、注册每 IP 每分钟最多 10 次。
- 每账号 1000 条、每条 5000 字符。分类、标签、收藏与内容保存在 D1；并发写入冲突会提示重新加载。
- 无演示账号，无浏览器本地账号认证。旧 demo 本地数据不会上传或自动迁移。
- 使用用户名注册，无邮箱和密码找回功能，请保存好密码。

## 本地开发

`npm ci`，然后 `bash build.sh`、`npx wrangler d1 migrations apply clipnote --local`，最后 `npx wrangler dev`。通过 Wrangler 提供页面和 API（单独 Vite 仅供静态界面开发）。

## 部署

Cloudflare 账号需拥有 macseek.cc DNS 权限。`npx wrangler login` 后创建 D1：`npx wrangler d1 create clipnote`，将返回 ID 填入 wrangler.jsonc。

执行 `bash deploy.sh`：本地检查、测试、清理 Go 编译缓存、递增版本、构建静态资源，再应用远程迁移并部署 Worker。自动绑定 https://clipnote.macseek.cc。不要在 VPS 构建。

## 验证

`npm test` 运行单元测试；`node scripts/verify-api.mjs [URL]` 验证注册、登录、账号隔离、冲突和锁定，本地额外验证 1000 条 × 5000 中文字符容量。

`node scripts/verify-browser.mjs [URL]` 使用本机 Edge 无头模式验收，默认复用本机 Codex runtime 的 Playwright，可用 `PLAYWRIGHT_MODULE` 指定其他已安装的模块路径。集成验证会创建输出名称的测试账号，验证后需通过 D1 清理。
