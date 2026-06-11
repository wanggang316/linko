# Changelog

Linko 的所有重要变更都记录在本文件中。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。1.0 之前每个版本都是开发预览版,尚未遵循语义化版本;发布以日期为准。每个版本的条目同时作为 Sparkle 更新弹窗中向用户展示的说明。

发布时由 release 流程把 `[Unreleased]` 切成带版本号与日期的小节,并将该小节注入对应 GitHub Release 与 appcast。请勿手工编辑各版本的 `<item>` —— appcast 由 `generate_appcast` 生成。

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

## [0.1.0] - 未发布

首个公开预览版,一款基于 sing-box 内核的原生 macOS 代理客户端。

### Added

- **系统代理模式**:菜单栏一键开关,自动配置 HTTP/SOCKS 系统代理。
- **订阅与配置**:导入并解析订阅,支持多份配置(Profile)之间无损切换。
- **规则分流**:完整的规则匹配(域名/IP/进程/逻辑组合)与策略组(url-test / fallback / 嵌套),支持导入 Surge、Clash 规则。
- **DNS 管理**:基于 sing-box 1.12+ typed-server 的 DNS 配置,含本地 Hosts 映射。
- **多种出站协议**:在订阅传输层之外补全 WireGuard、SSH 出站。
- **仪表盘**:概览、连接列表(搜索/过滤/关闭/详情)、实时流量与日志(可导出),以及按应用维度的流量统计。
- **网络环境自动切换**:按网段/网卡在不同 Profile 之间自动切换,无需定位权限。
- **`linko://` URL Scheme 与 CLI**:支持 on/off/toggle/mode/select/profile 等命令的脚本化控制。
- **应用内自动更新**:通过 Sparkle 2 分发,更新包经 EdDSA 签名校验后安装。
- **开机自启** 与启动前的 sing-box 配置预校验。
