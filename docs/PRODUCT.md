# linko 产品文档

## 产品定位

linko 是一款开源的 macOS 原生代理客户端：SwiftUI 菜单栏应用（无 Dock 图标），以 [sing-box](https://github.com/SagerNet/sing-box) 作为代理内核。目标是「轻量、透明、可信」——配置生成、内核管理、系统代理切换全部开源可审计，不捆绑任何订阅服务或商业组件。

- 许可证：GPL-3.0（与 sing-box 兼容）
- 平台：macOS 14.0+，Apple Silicon / Intel
- 形态：菜单栏常驻应用（MenuBarExtra，LSUIElement）

## 目标用户

- 已有机场/自建节点订阅（Clash YAML 格式）、需要在 macOS 上稳定使用代理的开发者与进阶用户
- 希望客户端行为透明可审计、不愿使用闭源商业客户端的用户
- 熟悉 sing-box 但不想手写 JSON 配置的用户

## 核心流程

1. **导入订阅**：粘贴订阅 URL → 下载并解析 Clash YAML → 得到节点列表，持久化到本地（`~/Library/Application Support/linko/`）。
2. **选择节点**：菜单栏列表展示所有节点；选中节点写入偏好设置，运行中通过 Clash API 实时切换。
3. **开启代理**：打开「系统代理」开关 → 生成 sing-box JSON 配置 → 启动 sing-box 子进程 → 通过 `networksetup` 将系统 HTTP/HTTPS/SOCKS 代理指向本地混合端口。
4. **延迟测试**：通过 Clash API 对节点逐一测延迟，列表中显示延迟徽标。
5. **关闭代理**：还原系统代理到开启前的状态，干净地终止内核子进程。

## MVP 功能列表（Milestone 1）

- 菜单栏应用：状态头部、「系统代理」开关、节点选择列表（含延迟徽标）、订阅导入入口、设置入口、退出
- 订阅导入：Clash YAML 解析，支持 ss / vmess / trojan / vless / hysteria2 / tuic；未知类型与缺字段条目跳过并给出警告，不崩溃
- 配置生成：mixed 入站（默认 127.0.0.1:7890）、每节点一个出站、`proxy` selector、direct 出站、`route.final = "proxy"`、Clash API（默认 127.0.0.1:9090）
- 内核生命周期：子进程方式运行 `sing-box run -c <config>`，日志写入 Application Support 目录，配置变更自动重启，退出时干净终止
- 内核二进制发现：用户自定义路径 → 仓库 `vendor/sing-box/` → Homebrew 路径；缺失时 UI 给出获取指引
- 系统代理：`networksetup` 设置/还原所有启用网络服务的 web / secure web / SOCKS 代理
- 节点延迟测试与运行中切换（Clash API）
- 设置窗口：混合端口、Clash API 端口、sing-box 二进制路径覆盖
- 本地持久化：偏好设置与订阅/节点 JSON 文件，无 CoreData

## 非目标（MVP 不做）

- TUN / 增强模式（NetworkExtension System Extension）——Milestone 2
- 规则分流管理、rule_set 编辑 ——Milestone 3
- 应用内自动更新（Sparkle）、签名与公证分发 ——Milestone 4
- 订阅格式：非 Clash YAML 的订阅（如 base64 节点列表、sing-box 原生订阅）
- iOS / Windows / Linux 客户端
- 任何形式的节点售卖、内置订阅推荐
