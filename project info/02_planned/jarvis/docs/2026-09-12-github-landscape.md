# Mac-first 个人 Agent：GitHub 项目调研

调研日期：2026-09-12。目标是为“运行在一台 Mac 上、可处理编程和网页办公、后台执行并在关键节点要求确认”的个人 Agent 寻找**可借鉴和可复用**的开源设计。以下结论以项目自己的 README、源码和 GitHub API 为准；热度仅作维护信号，不作为安全或质量证明。

## 结论先行

没有一个现成项目可以安全地直接充当目标产品。最值得采用的是“自己拥有 Mac 壳、任务状态机和授权策略；按领域嵌入成熟执行器”的组合，而不是把全权限交给一个通用 Agent。

建议的基线：

```text
SwiftUI 菜单栏应用 / 全局快捷键
           │  (XPC / localhost, 仅本机)
任务服务：计划、状态机、审计、显式 approval gate、SQLite
     ├── 模型编排：OpenAI Agents SDK 或 LangGraph
     ├── 编程/终端：受目录与命令策略约束的本地 worker
     ├── 网页：Playwright（确定性）→ browser-use（需要模型判断时）
     ├── GUI 兜底：Peekaboo（或自研 macOS Accessibility + ScreenCaptureKit worker）
     └── 记忆：SQLite 原始事实/授权记录 + 可替换的 Mem0 检索层
```

这实现了“API/命令优先、浏览器自动化其次、屏幕点按最后”的可靠性排序；任何会对外发送、上传、提交、删除或扩大权限的工具调用，都由**非 LLM 的策略层**拦截并要求批准。

## 候选项目比较

| 项目 | 已验证的设计/能力 | 维护信号（调研日） | 建议 |
|---|---|---|---|
| [OpenClaw](https://github.com/openclaw/openclaw) | 本机 Gateway 统一会话、工具、事件和通道；README 明确列出 macOS 原生应用、可替换模型、技能/插件，以及“本机状态、记忆和凭据”。同时明确警告：主会话工具默认在主机执行，连接外部用户前应配置 sandbox。 | API 显示未归档，主分支在 2026-09-12 有推送；README 有 CI、安装与安全文档入口。[源码](https://github.com/openclaw/openclaw) [API](https://api.github.com/repos/openclaw/openclaw) | **重点参考/可做探索性 PoC**：借鉴 Gateway、节点和插件边界。第一版不要直接把它作为全权限核心：它面向大量聊天通道，而本项目先只服务单 Mac；其 README 本身也提示宿主工具风险。 |
| [OpenAI Agents SDK](https://github.com/openai/openai-agents-python) | Agent、工具、guardrail、handoff、human-in-the-loop、session 和 tracing 都是明确的一等概念；另有可在 macOS/Linux 使用的 `UnixLocalSandboxClient` 示例。 | API 显示未归档，2026-09-12 有推送，MIT 许可。[README](https://github.com/openai/openai-agents-python/blob/main/README.md) [API](https://api.github.com/repos/openai/openai-agents-python) | **推荐复用编排 SDK**（若接受 Python/该 SDK）。但批准策略、凭据边界和任务持久化仍应由产品自有服务实现，不能只靠 prompt/guardrail。 |
| [LangGraph](https://github.com/langchain-ai/langgraph) | README 将其定义为低层长运行、有状态 Agent 编排框架，强调 durable execution、human-in-the-loop、memory 和可观测性。 | API 显示未归档，2026-09-11 有推送，MIT 许可。[README](https://github.com/langchain-ai/langgraph/blob/main/README.md) [API](https://api.github.com/repos/langchain-ai/langgraph) | **可替代 Agents SDK 的编排层**，尤其适合把“等待批准/恢复任务”建模为持久图。首版只选一个编排框架，避免双栈。 |
| [Playwright](https://github.com/microsoft/playwright) | 官方 README 说明它以单一 API 自动化 Chromium、Firefox、WebKit；这是 DOM/网络可观测的网页执行器，而非视觉猜坐标。 | API 显示未归档，2026-09-11 有推送，Apache-2.0 许可。[README](https://github.com/microsoft/playwright/blob/main/README.md) [API](https://api.github.com/repos/microsoft/playwright) | **推荐作为网页办公的默认执行器**。把登录、付款、发送、上传等步骤标成审批节点；持久 profile/身份凭据需单独隔离。 |
| [browser-use](https://github.com/browser-use/browser-use) | 项目把自身定位为浏览器 Agent；README 明确提供本地/云浏览器连接的 CLI 与 Python 库，并可在自有应用中使用自定义工具、结构化输出和自选模型。 | API 显示未归档，2026-09-12 有推送，MIT 许可。[README](https://github.com/browser-use/browser-use/blob/main/README.md) [API](https://api.github.com/repos/browser-use/browser-use) | **作为 Playwright 之上的“困难网页任务”适配层**，而非主执行路径。它仍会面临页面变化、登录/CAPTCHA 和模型误判；确定步骤应沉淀为 Playwright workflow。 |
| [Peekaboo](https://github.com/openclaw/Peekaboo) | Swift 的 macOS CLI/菜单栏应用；README 列出屏幕录制、Accessibility 与 synthetic input 权限引导，以及屏幕/AX 检查、点击、输入、按键和窗口/菜单栏控制。它也提供独立 Agent 与 MCP。 | API 显示未归档，主分支和 v4.3.4 release 都在 2026-09-12 更新，MIT 许可。[README](https://github.com/openclaw/Peekaboo/blob/main/README.md) [源码目录](https://github.com/openclaw/Peekaboo/tree/main/Apps) [release](https://github.com/openclaw/Peekaboo/releases/tag/v4.3.4) [API](https://api.github.com/repos/openclaw/Peekaboo) | **推荐作为 Mac GUI 兜底执行器或权限/工具边界的代码参考**，优先通过 MCP/CLI 接入而非 fork 整套 UI。其 macOS 15+、Swift 6.2+、Node 22+ 要求和“执行层而非任务系统”的定位须纳入评估。 |
| [Mem0](https://github.com/mem0ai/mem0) | README 提供添加、搜索、更新、删除记忆的 API，并称其可作为 Agent memory layer。 | API 显示未归档，2026-09-11 有推送，Apache-2.0 许可。[README](https://github.com/mem0ai/mem0/blob/main/README.md) [API](https://api.github.com/repos/mem0ai/mem0) | **可选检索层**。不要让其成为唯一事实库：项目、待办、凭据引用、授权和审计必须保存在可查询、版本化的本地 SQLite 数据模型中。 |
| [Letta](https://github.com/letta-ai/letta) | README 将其定位为有状态 Agent server，并提供长期记忆、工具调用、REST API 与自托管部署。 | API 显示未归档，2026-09-12 有推送，Apache-2.0 许可。[README](https://github.com/letta-ai/letta/blob/main/README.md) [API](https://api.github.com/repos/letta-ai/letta) | **仅在将来需要独立、持续运行的 memory-agent 服务时评估**。首版不宜同时引入它、Mem0 和编排框架；运维和状态归属会过度复杂。 |
| [OpenHands Agent Canvas](https://github.com/OpenHands/OpenHands) | README 展示本地/远程/云 Agent backend 切换、自动化与 Agent Server/Automation Server 分层；也明确警告“不使用 sandbox 会给 agent 完整文件系统权限”。 | API 显示未归档，2026-09-12 有推送，MIT 许可。[README](https://github.com/OpenHands/OpenHands/blob/main/README.md) [API](https://api.github.com/repos/OpenHands/OpenHands) | **参考工程任务 UI、运行记录和 server/automation 分层**。不建议直接作为全能个人助理底座：它的产品重心是软件工程控制中心，浏览器办公、Mac 原生交互和个人权限模型仍须另建。 |

## 不建议作为第一版主干的方向

- **纯 CUA / 纯屏幕点按**：它缺少 DOM、文件与命令的结构化反馈，稳定性、速度、可审计性均不如前述执行优先级。它只应处理传统桌面软件或没有可用 API/DOM 的最后一公里。
- **直接暴露 OpenClaw 的消息通道或 OpenHands 的无沙箱模式**：两者官方 README 都明确说明宿主执行或完整文件系统访问的风险；在单人 Mac MVP 中没有必要先引入外部入站面。[OpenClaw 安全说明](https://github.com/openclaw/openclaw/blob/main/README.md#security) [OpenHands 警告](https://github.com/OpenHands/OpenHands/blob/main/README.md#option-1-without-a-sandbox)
- **陈旧研究型框架做底座**：例如 [AgentVerse](https://github.com/OpenBMB/AgentVerse) 的 GitHub API 显示最近推送为 2024-09-09，尽管仓库未归档；不适合作为需要跟随浏览器、模型和 Mac 权限变化的执行底座。[API](https://api.github.com/repos/OpenBMB/AgentVerse)

## Mac 原生层：应自行开发，而非寻找“万能壳”

macOS 的安全与交互边界是产品的核心差异，建议用 Swift/SwiftUI 做菜单栏、全局快捷键、通知、审批窗和任务时间线。GUI worker 只获得用户明确授予的辅助功能与屏幕录制权限，并把每次动作前后的目标、截图引用和结果写入审计记录。Peekaboo 已给出这类权限和工具边界的可运行参考，但最终授权仍应在本产品策略层裁决。[Peekaboo README](https://github.com/openclaw/Peekaboo/blob/main/README.md) Apple 对 [Accessibility API](https://developer.apple.com/documentation/applicationservices/axuielement) 和 [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) 的官方文档是实现这些能力的权威来源。

应将能力封装为有声明副作用的工具：`read`、`local-write`、`external-send`、`delete`、`credential`、`money`。策略层按副作用和目标匹配批准规则，而不是让模型自行判断“是否危险”。

## 推荐的 MVP 切分

1. **壳与安全（先完成）**：菜单栏 + 快捷键；本地任务队列；可视时间线；批准/拒绝/中止；SQLite 审计；受限工作目录和命令 allowlist。
2. **编程工作流**：读取项目、运行测试、起草补丁、展示 diff；写入项目与 `git commit` 分别审批。此阶段可选择 Agents SDK *或* LangGraph。
3. **网页办公**：先用 Playwright 实现可重复的登录后工作流；未知网页再交给 browser-use；发送、上传和提交表单强制暂停。
4. **记忆与主动任务**：先存结构化偏好、项目、任务和授权；再加 Mem0 语义检索。定时任务只能提出建议或执行已被预先授权的低风险操作。
5. **GUI/CUA 兜底**：限定应用白名单、单步可观察执行、可立即中止；不要把它作为第一版“自动完成一切”的承诺。

## 需要在研发前做出的两个决定

1. 编排层选择：更偏“轻量 SDK + 自有状态服务”选 Agents SDK；更偏“长工作流持久图”选 LangGraph。
2. OpenClaw 的定位：只作为架构样本，还是另开一个隔离 PoC 验证其 macOS 节点与 Gateway。无论哪种，都不应把其外部聊天通道纳入 MVP。
