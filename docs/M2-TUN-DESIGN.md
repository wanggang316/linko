# M2 — TUN 全局模式设计

## 目标

让 linko 接管**全部**流量（含不遵守系统代理的应用），而不只是系统代理模式。
通过 NetworkExtension System Extension 内嵌 sing-box（libbox）实现，参考 sing-box 官方
Apple 客户端架构。保持 SIP 开启，走 Developer ID 签名路径。

## 架构

```
┌─────────────────────────┐         ┌──────────────────────────────────┐
│ LinkoApp (主 App)        │  IPC    │ LinkoTunnel (NE System Extension) │
│ 菜单栏 / Dashboard       │ ──────▶ │ NEPacketTunnelProvider            │
│ AppState / 配置生成       │ 启停隧道 │  └ libbox.BoxService(tun inbound) │
│ NETunnelProviderManager  │ ◀────── │     packetFlow ⇄ sing-box 网络栈   │
└─────────────────────────┘  状态    └──────────────────────────────────┘
        │ 共享配置                              │ 读同一份配置
        └──────────── App Group 容器 ───────────┘
                group.com.gumpw.linko
```

## 部件

### 1. 双 target
- `LinkoApp`：主 App（已存在）。新增对 NETunnelProviderManager 的管理。
- `LinkoTunnel`：NE System Extension（新增），bundle id `com.gumpw.linko.tunnel`，
  type=app extension（打包为 system extension）。entitlement：
  `com.apple.developer.networking.networkextension = [packet-tunnel-provider]`。
- 两者共享 App Group `group.com.gumpw.linko`（entitlement `com.apple.security.application-groups`），
  用于传递配置文件与读写状态。
- `DEVELOPMENT_TEAM = HC438T2B8P`（两个 target）。

### 2. libbox 集成
- `libbox.xcframework`（gomobile bind，全功能 tags）vendored 到 `vendor/libbox/`。
- 扩展内：实现 `LibboxPlatformInterface`（提供 tun fd / 网络监听 / 写日志），
  用 `libbox.NewService(configJSON, platformInterface)` 启动；sing-box 配置里 tun inbound
  的 fd 由 NEPacketTunnelFlow 提供（libbox 的 TunInterface 桥接 packetFlow）。
- 配置生成复用 LinkoKit `SingBoxConfigBuilder`，但 inbound 从 `mixed` 换成 `tun`
  （`SingBoxConfigBuilder` 增加一个 `mode: .systemProxy | .tun` 开关，tun 模式产出
  tun inbound + auto_route + fake-ip DNS）。

### 3. 模式切换（AppState）
- 偏好新增 `proxyMode: .systemProxy | .tun`。
- `.systemProxy`：现有路径（子进程 sing-box + networksetup）。
- `.tun`：通过 NETunnelProviderManager 启停 LinkoTunnel，不再起子进程、不写系统代理。
- TUN 模式下 Dashboard 仍通过 Clash API 读状态（扩展内开 clash_api，监听 127.0.0.1）。

### 4. 配置传递
- 主 App 生成配置 JSON → 写入 App Group 容器 → 通过
  `NETunnelProviderProtocol.providerConfiguration` 或容器文件传给扩展。
- 扩展 `startTunnel` 时读配置、启动 libbox service；`stopTunnel` 优雅关闭。

## 签名与运行（需要 Gump 操作）
1. project.yml 配 `DEVELOPMENT_TEAM=HC438T2B8P` + entitlements（已自动）。
2. Xcode 需登录 Apple ID（automatic signing 注册 App ID 的 NetworkExtension + App Group 能力）。
   或用 App Store Connect API key 做 `xcodebuild -allowProvisioningUpdates`。
3. SIP 保持开启。首次启用 TUN 时系统弹窗 → 「系统设置 → 隐私与安全性」点「允许」加载扩展。
4. 店外分发再加 Developer ID 签名 + 公证（`packet-tunnel-provider-systemextension`）。

## 验证边界
- 我能自动验证到：libbox 构建、扩展与主 App 编译（CODE_SIGNING_ALLOWED=NO）、
  tun 配置经 `sing-box check` 合法。
- 真正加载系统扩展 + 跑通 TUN 需要 Gump 的 Apple ID 签名 + 手动批准——届时联调。
