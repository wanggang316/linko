# User-Test Patterns

> 运行时用户级验证的项目级约定。在 `/harness-stack:fdd-validation-contract` 首次运行（Step 0: Bootstrap）时撰写。在撰写或探测某个 plan 的 validation contract 之前先读这份；契约 assertion 存放于 `.harness-runtime/plans/<slug>/validation-contract.md`。

## Status

**Status:** Approved
**Last updated:** 2026-07-03

## Platforms in Scope

- **macOS app（menu bar + Dashboard 窗口）** — Linko 是 LSUIElement 菜单栏应用（SwiftUI `MenuBarExtra` + 独立 Window scene），一切面向用户的交互都在这里。
- **本地 HTTP（Clash API）** — 运行中核心暴露 `127.0.0.1:<clashAPIPort>`（默认 9090），可只读探测代理组、连接与规则命中。
- **生成的 sing-box 配置（文件界面）** — `SingBoxConfigBuilder` 产出的 config JSON 是可断言的外部产物（规则顺序、字段、action）。
- **LinkoKit 库（Swift package）** — 非 UI 逻辑全在 LinkoKit；库的公开 API 经 `swift test` fixture 探测即为其可观测界面。

**不在范围**：iOS（移植进行中，无可测 app）；网络扩展内部状态（只经它的用户可见效果观测）。

## Tooling per Platform

### macOS app（GUI）

- **Primary:** computer-use MCP（`mcp__computer-use__*`）——screenshot + 点击/键入驱动菜单栏面板与窗口
- **Fallback:** `osascript`（AppleScript/System Events）做定点操作；仅读验证用 screenshot
- **Invocation:** `request_access` 申请 Linko + 目标浏览器 → `screenshot` / `left_click` / `type`
- **Ready signal:** 菜单栏出现 Linko 状态图标（screenshot 可见）；app 进程存在（`pgrep -x Linko`）
- **注意:** 涉及 Apple Events/TCC 的行为（读浏览器 URL）必须用**签名运行**的 app 验证——`make build`（CODE_SIGNING_ALLOWED=NO）不产生可信的 TCC 行为。TCC 授权弹窗需人工点击，探测前声明。
- **Cost tier:** expensive

### 本地 HTTP（Clash API）

- **Primary:** `curl` + `jq`
- **Fallback:** 无（该界面本身就是 fallback 观测手段）
- **Invocation:** `curl -sS http://127.0.0.1:9090/proxies | jq`、`/connections`、`/configs`
- **Ready signal:** `GET /version` 返回 200
- **Cost tier:** cheap（只读）

### 生成的 sing-box 配置（文件）

- **Primary:** 读运行目录下最新生成的 config JSON（`~/Library/Application Support/linko/` 下，核心启动/重载时写出）+ `jq` 断言
- **Fallback:** LinkoKit 单测直接调 `SingBoxConfigBuilder.build` 断言 JSON
- **Invocation:** `jq '.route.rules[0]' <config.json>`；或 `swift test --filter <TestName>`
- **Ready signal:** 文件 mtime 晚于触发动作的时刻（证明重载确实重写了配置）
- **Cost tier:** cheap

### LinkoKit 库

- **Primary:** `make test`（= `cd packages/LinkoKit && swift test`；可 `--filter` 单测）
- **Fallback:** 无
- **Invocation:** `cd packages/LinkoKit && swift test --filter <TestClass>`
- **Ready signal:** 编译通过即绪
- **已知坑:** worktree 复用旧 `.build` 会报 ModuleCache 旧路径错误；删 `packages/LinkoKit/.build/arm64-apple-macosx/debug/ModuleCache` 重跑。
- **Cost tier:** cheap

### LinkoApp 应用层单测

- **Primary:** `make test-app`（= xcodebuild -scheme LinkoAppTests test，CODE_SIGNING_ALLOWED=NO，免宿主：app 源码直接编入测试 bundle，不启动真实 app）
- **Fallback:** 无
- **Invocation:** `make gen && make test-app`
- **Ready signal:** 编译通过即绪；无签名可跑
- **已知坑:** xcodebuild（`make build`/`make test-app`）会把 app 的 Sparkle pin 顺带写进 `packages/LinkoKit/Package.resolved`；属 incidental churn，提交前还原该文件。
- **Cost tier:** cheap-medium（xcodebuild 首跑编译较慢）

## Case Dimensions

| 维度 | 是否必须？ | 检查什么 |
|---|---|---|
| Happy path | Mandatory | 本 case 的主要成功流 |
| Error path | Mandatory | 至少一种声明的失败模式（浏览器不可用、TCC 拒绝、超时、核心未运行） |
| Edge values | Mandatory | 空 / IP 主机 / 单标签主机 / 超长域名等边界输入 |
| Accessibility | UI case 建议 | 控件有可见文本标签；键盘可提交表单 |
| Performance budget | 有声明时必须 | plan 声明的「菜单点击 → 窗口出现 ≤ ~1s」 |
| i18n | Optional | UI 文案跟随项目现有中文语境 |
| Security/Privacy | 涉及 URL/权限的 case 必须 | URL 不落日志；entitlement 最小化；TCC 拒绝后功能可降级 |

## Selector and Assertion Rules

### Allowed selectors（macOS GUI）

- 可见文本/控件标题：「点击标题为『为当前网页添加规则…』的菜单项」
- 窗口标题、可见 placeholder、按钮文字
- Screenshot 中用户可辨认的状态（图标、开关位置、列表首行内容）
- Clash API JSON 字段：`.proxies["proxy"].now`
- 生成配置 JSON 路径：`.route.rules[0].domain_suffix`

### Forbidden selectors

- SwiftUI 视图类型名 / 源码文件路径 / 函数名——实现细节
- Accessibility identifier 若未在 UI 上有对应可见文本（内部 id 会腐烂）
- 屏幕绝对坐标写死在 assertion 里（探测时可用，但 assertion 不得以坐标定义行为）

### Allowed assertions

- 二元：PASS 或 FAIL，没有「looks good」
- 具体：写明期望值（`domain_suffix == "google.com"`），而非模糊匹配
- 独立：每条 assertion 一次探测

## State Isolation

- **Preferences reset:** 探测前备份 `~/Library/Application Support/linko/preferences.json`，探测后恢复；破坏性 case（写入规则）必须在结束时删除自己插入的规则或整体恢复备份。
- **App lifecycle:** 需要干净状态的 case 先 `pkill -x Linko` 再重启 app；依赖运行中核心的 case 声明「代理已开启」为前置。
- **No cross-case state:** case 不得依赖另一个 case 插入的规则/节点；顺序无关。
- **External services:** 不打真实订阅源；节点数据用手动添加的本地 fixture 节点。浏览器页面用稳定 URL（如 `https://example.com`）。

## Surface Cost Tiers

| Tier | 代价 | 隔离策略 | 示例界面（本项目） |
|---|---|---|---|
| **cheap** | 一次探测，无共享状态，亚秒级 | 每个验证步骤一个 case | `swift test --filter`；config JSON `jq` 断言；Clash API 只读 curl |
| **medium** | 一个可共享的运行中 app 会话 | 共享同一次 app 启动 + 代理会话；组间恢复 preferences | `make build` 编译闸；不触发 TCC 的 GUI 观察（screenshot 读状态） |
| **expensive** | 需签名运行 / TCC 人工授权 / 整环境 reset | 批处理到一次签名运行内完成；破坏性 case 排批次末尾 | Apple Events 读浏览器 URL 的端到端 GUI 流 |

拿不准时默认 tier：**medium**。

## Personas

单用户桌面应用；persona 即「app + 系统所处的状态」，validator 据此搭建前置。

- `fresh_user` — Linko 已安装并运行，代理未开启，规则列表为空或仅默认；未授予 Apple Events 权限。
- `proxied_user` — Linko 运行中，系统代理模式已开启，至少一个可用节点、一个策略组；Apple Events 已授权。
- `tun_user` — 同 `proxied_user` 但为 TUN 模式（系统扩展已批准）。
- `denied_user` — Linko 运行中，Apple Events 权限已被用户在 TCC 中**拒绝**。

## Fixtures and Test Data

**Naming:** `<scenario>.<format>`——例如 `single-node-prefs.json`、`rules-with-groups.json`。

**Rule:** fixture 是静态数据，不 import 代码。LinkoKit 单测 fixture 放 `packages/LinkoKit/Tests/LinkoKitTests/`（内联或资源）；GUI 探测用的 preferences fixture 放 `.harness-runtime/plans/<slug>/fixtures/`（gitignored，探测时拷入 Application Support）。

## Artifacts

**Location:** `.harness-runtime/plans/<slug>/validation/<scope>/artifacts/<case-id>/`

**Each FAIL must produce:**

- `report.md`——失败的 assertion + diff（期望 vs 观测）
- `repro.sh`——可运行脚本（或人工步骤清单，GUI case）复现该探测
- `screenshot.png`（GUI case）——失败发生的那一刻
- `config.json` / `api-response.json`（配置/API case）——完整抓取

**Retention:** 保留最近 10 次运行。

## Anti-Patterns

### Hallucinated assertion

**Looks like:** 断言「表单显示规则命中统计」而 plan 从未提及。
**Why wrong:** 出自想象而非契约；PASS 给虚假信心。
**Do instead:** 每条 assertion 追溯到 plan 的一条 requirement。

### Selector drift / implementation coupling

**Looks like:** 断言引用 `QuickAddRuleView` 视图名或 `AppState.updateRouting` 函数名。
**Why wrong:** 重构即失效，且说明不了用户看到什么。
**Do instead:** 引用可见文本、窗口标题、config JSON 字段。

### Unsigned-build TCC 幻觉

**Looks like:** 用 `CODE_SIGNING_ALLOWED=NO` 的 build 验证 Apple Events 授权流程并报 PASS。
**Why wrong:** 无签名 build 的 TCC 行为与签名 app 不一致，结论不可信。
**Do instead:** TCC 相关 case 声明「签名运行」前置；无法满足时判 INCONCLUSIVE 而非 PASS。

### State leak between cases

**Looks like:** case A 插入的 `google.com` 规则被 case B 当作已有状态使用。
**Why wrong:** 单独运行 case B 即失败；顺序必须无关。
**Do instead:** 每个 case 自带 preferences fixture，结束时恢复备份。

### Tool-loop exhaustion

**Looks like:** GUI 探测对同一坐标重试 50 次直到预算耗尽，报 timeout。
**Why wrong:** 从未做出判定。
**Do instead:** 重试上限 3 次，仍不稳定判 INCONCLUSIVE 并附尝试日志。

## Knowledge Persistence

**Who writes here:** runtime validator，在一次运行之后，记录寿命超过单次运行的事实。

**Format:** `- [YYYY-MM-DD] <surface / step>: <fact>. <what to do next time>.`

- [2026-07-03] LinkoKit swift test: worktree 复用旧 `.build` 报 ModuleCache 旧路径错误；删 `packages/LinkoKit/.build/arm64-apple-macosx/debug/ModuleCache` 重跑即可。
