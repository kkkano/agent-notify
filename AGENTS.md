# agent-notify 架构说明

## 目录结构

```text
D:\agent-notify\
|-- notify.mjs           # 通知入口、事件归一化、队列、飞书发送器
|-- install.ps1          # 安装器：写入 Claude hooks，包装 Codex notify
|-- uninstall.ps1        # 卸载器：移除 Claude hooks，恢复 Codex notify
|-- .gitignore           # 防止本机 webhook 与运行态泄露到仓库
|-- config.example.json  # 示例配置与默认开关
|-- config.json          # 本机配置，安装后生成
|-- images\              # README 截图，提交前必须确认已打码
|-- state\               # 运行态：队列、token 缓存、日志、Codex 原始配置记录
`-- README.md            # 使用说明
```

## 模块边界

`notify.mjs` 是唯一运行时入口。它不启动 HTTP 服务，不监听端口，只在 hook 触发时运行一次。

`install.ps1` 只负责配置落盘：Claude 走 `settings.json` hooks，Codex 走 `config.toml` 的 hooks 和 `notify` fanout。安装器必须备份既有配置。

`uninstall.ps1` 只恢复安装器造成的改动。不得删除用户自己的 Claude/Codex 其他配置。

`state/` 是可丢弃运行态，但 `state/codex-notify-original.json` 和 `state/codex-hooks-original.json` 是 Codex 恢复依据，卸载前不要删除。

`images/` 只保存 README 截图。截图若含 webhook、路径、用户名等敏感信息，必须先打码再提交。

`.gitignore` 是安全边界：`config.json`、`state/` 默认都不进仓库。

## 依赖关系

```text
Claude Code hooks -------> notify.mjs --> Feishu
Codex hooks -------------> notify.mjs --> Feishu
Codex notify fanout -----> notify.mjs
                              |
                              `--> original Codex notify
```

## 设计原则

通知是旁路能力，不是 agent 能力。不要把它做成 skill、MCP 或长提示词。

失败必须静默。通知失败只写日志和队列，不能污染上下文，不能阻塞 coding agent。

新增 Telegram / 企业微信时，只能新增 provider 适配器，不要改动事件归一化主干。

## 变更日志

- 2026-04-26: 创建轻量通知器，首版支持飞书 webhook 与飞书自建应用两种模式。
- 2026-04-26: 重写 README 为傻瓜式安装说明，并加入 gitignore 防止 webhook 泄露。
- 2026-04-26: 将已打码截图纳入 README，辅助新用户按图配置。
- 2026-05-03: 通知归一化增加完成/需处理分类，默认屏蔽阶段完成和子任务完成提醒。
