# V3.9 后端端口迁移到 8018

## 背景

启动后端时报错：

```text
[WinError 10048] 通常每个套接字地址(协议/网络地址/端口)只允许使用一次。
```

排查后发现：

- `netstat -ano | findstr :8018` 显示多个 `8018 LISTENING`。
- `taskkill /PID ... /T /F` 提示部分 PID 不存在。
- 进程表查不到这些 PID 的命令行。

这说明当前 Windows 会话里的 `8018` 端口状态已经异常。继续围绕 `8018` 清理会导致启动流程不稳定。

## 决策

后端开发端口从 `8018` 迁移到 `8018`。

保留 `8018` 在清理脚本里，作为历史残留端口清理对象。

## 改动

- `package.json`
  - `dev:backend` 改为 `8018`。
  - `dev:backend:reload` 改为 `8018`。
- `frontend/vite.config.ts`
  - 默认代理目标改为 `http://127.0.0.1:8018`。
- `scripts/stop-dev.ps1`
  - 清理端口包含 `5175`、`8018`、`8018`。
- `.vscode/launch.json`
  - 后端启动项改名为 `Backend 8018`。
  - compound 同步引用 `Backend 8018`。
- README 和 V3.8 启动文档同步更新。

## 使用方式

推荐只用 VSCode 启动：

```text
Run and Debug -> LazyPerson Dev
```

手动命令：

```powershell
npm run stop:dev
npm run dev
```

访问地址：

- 前端：`http://127.0.0.1:5175/`
- 后端健康检查：`http://127.0.0.1:8018/api/health`
- 局域网前端：`http://<本机局域网IP>:5175/`

## 注意

如果 Windows 重启后 `8018` 恢复正常，也不建议再切回。固定使用 `8018` 可以避免旧缓存、旧代理和旧进程路径再次混淆。
