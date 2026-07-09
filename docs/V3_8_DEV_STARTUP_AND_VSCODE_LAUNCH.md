# V3.8 开发服务启动治理与 VSCode Launch 方案

## 背景

前后端服务在 Windows 下多次手动启动、隐藏启动、`uvicorn --reload` 混用后，容易留下多个父子进程。结果是同一个端口上出现多个监听记录，接口可能命中旧服务，表现为：

- `127.0.0.1:8018` 和局域网 IP 返回速度不一致。
- Vite 代理命中旧后端。
- 自选股切换和行情请求变慢。
- 数据缓存策略明明已修正，但页面仍像在读旧逻辑。

## 固定方案

### 1. 后端默认不使用 reload

默认脚本：

```powershell
npm run dev:backend
```

实际命令：

```powershell
python -m uvicorn backend.app.main:app --host 0.0.0.0 --port 8018
```

原因：

- `--reload` 在 Windows 下会生成父子进程。
- 隐藏窗口和反复启动时，父进程可能继续拉起子进程。
- 手动开发阶段优先稳定，后端代码变更后手动重启即可。

如确实需要热重载，可显式使用：

```powershell
npm run dev:backend:reload
```

### 2. 前端继续使用 Vite

```powershell
npm run dev:frontend
```

监听：

- `0.0.0.0:5175`

### 3. Vite 代理恢复为本机后端

默认代理：

```text
http://127.0.0.1:8018
```

如需临时指定其他后端：

```powershell
$env:API_PROXY_TARGET="http://192.168.22.22:8018"
npm run dev:frontend
```

### 4. 启动前先清端口

新增脚本：

```powershell
npm run stop:dev
```

它会清理：

- `5175`
- `8018`
- `8018`
- 当前工作区下的后端/前端开发进程

脚本路径：

- `scripts/stop-dev.ps1`

## VSCode 使用方式

新增：

- `.vscode/launch.json`
- `.vscode/tasks.json`

在 VSCode 的 Run and Debug 面板选择：

```text
LazyPerson Dev
```

启动流程：

1. 执行 `Stop LazyPerson Dev Ports`。
2. 启动 `Backend 8018`。
3. 启动 `Frontend 5175`。

## 当前机器注意事项

本机曾出现 `netstat` 显示多个 `8018 LISTENING`，但进程表查不到对应 PID 的异常状态。这类残留不是项目代码能完全处理的普通进程问题。

如果再次遇到：

- `npm run stop:dev` 后仍看到不存在 PID 的 `8018 LISTENING`。
- `127.0.0.1:8018` 卡住，但局域网 IP 正常。

建议：

1. 关闭所有 VSCode / PowerShell / Node / Python 开发窗口。
2. 重新执行 `npm run stop:dev`。
3. 如果仍残留，重启 Windows。
4. 重启后只使用 VSCode 的 `LazyPerson Dev` 启动。

## 验收标准

- `npm run test` 通过。
- `npm run build` 通过。
- VSCode 可通过 `LazyPerson Dev` 一键启动前后端。
- 默认前端访问地址为 `http://127.0.0.1:5175/`。
- 局域网访问地址为 `http://<本机局域网IP>:5175/`。
