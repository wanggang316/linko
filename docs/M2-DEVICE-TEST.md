# M2 TUN 设备联调指南

代码已完成、双 target 编译通过（CODE_SIGNING_ALLOWED=NO）。要真正加载系统扩展、
跑通 TUN，需要在本机用 Gump 的 Apple 账号签名并手动批准一次。SIP 保持开启。

## 前置
- libbox 框架已在 `vendor/libbox/Libbox.xcframework`（若缺失：`./scripts/build-libbox.sh`）。
- Team ID 已配进 project.yml：`HC438T2B8P`。

## 步骤

### 1. Xcode 登录 Apple ID（让自动签名签发描述文件）
NetworkExtension 与 System Extension 能力需要带该 capability 的描述文件，automatic
signing 会自动注册 App ID 并签发，但前提是 Xcode 里登录了 Apple ID：
- Xcode → Settings → Accounts → 用 Gump 的 Apple ID 登录（Team: HC438T2B8P）。

### 2. 生成工程并用真实签名构建
```bash
make gen
xcodebuild -project Linko.xcodeproj -scheme LinkoApp -configuration Debug \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=HC438T2B8P build
```
`-allowProvisioningUpdates` 让 Xcode 在线注册 networkextension / system-extension /
App Group 三个 capability 并签发描述文件。若报某个 capability 未启用，到
developer.apple.com 的 Identifiers 里给 `com.gumpw.linko` 和 `com.gumpw.linko.tunnel`
勾上 App Groups + Network Extensions，再重试。

### 3. 放进 /Applications（系统扩展激活要求 app 在受信任位置）
把构建出的 `Linko.app` 拷到 `/Applications/`（系统扩展从 DerivedData 里激活会被拒）。

### 4. 启用 TUN，批准扩展
- 打开 Linko → 设置 → 模式选「TUN 全局」→ 打开开关。
- 系统弹窗「Linko 想要添加系统扩展」→ 点「允许」→ 系统设置 → 隐私与安全性 →
  底部「允许」LinkoTunnel。可能需要输入密码 / 重启扩展守护。
- 再次打开 TUN 开关，应连接成功（菜单栏状态变为已连接，Dashboard 出现连接/流量）。

## 排错（在 Console.app 过滤 "LinkoTunnel" 或 "neagent"）
- **扩展不加载**：确认 app 在 /Applications；`systemextensionsctl list` 看状态。
- **NEMachServiceName 报错**：当前为 `group.com.gumpw.linko.tunnel`（App Group 加 .tunnel
  后缀）。若 loader 拒绝，改成与某个 App Group 完全一致或调整前缀。
- **描述文件缺 capability**：见步骤 2 末尾，去 developer portal 勾选。
- **TUN 起来但不通**：Console 看 libbox 日志；用 `./vendor/sing-box/sing-box check -c`
  校验主 App 写到 App Group 容器里的 config.json。

## 分发（之后）
店外分发需 Developer ID 签名 + 公证（notarytool），entitlement 用
`packet-tunnel-provider-systemextension`（已配）。可加 Sparkle 自更新（M4）。
