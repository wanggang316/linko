# M2 TUN 设备联调指南（Developer ID 路径）

代码已完成、Debug+Release 双 target 编译通过。要真正加载系统扩展跑通 TUN，
**SIP 保持开启**，必须走 Developer ID 签名 + 公证（这是 macOS 硬性要求：SIP 开启时
系统扩展只能 Developer ID + notarize 加载，开发签名需关 SIP 故不走）。

## 已就绪（我已替你完成/确认）
- `vendor/libbox/Libbox.xcframework`（缺则 `./scripts/build-libbox.sh`）。
- Developer ID 证书：`Developer ID Application: WANG GANG (HC438T2B8P)`。
- 这台 Mac 已注册进开发者账号；App ID `com.gumpw.linko` 和 `com.gumpw.linko.tunnel` 已注册。
- entitlement 已按 Developer ID 配好（`packet-tunnel-provider-systemextension` + App Group + system-extension.install）。

## 为什么用 Xcode GUI 而不是 CLT
CLI 自动签名只会生成 **Mac 开发**描述文件（期望非 `-systemextension` 的 entitlement 值，
与我们不匹配）。系统扩展的 **Developer ID** 描述文件目前只能由 Xcode 分发流程或开发者
门户生成。下面用 Xcode GUI，一次走通。

## ⚠️ 签名方式：手动 Developer ID（已在 project.yml 配好）
自动签名会生成 Mac 开发描述文件（entitlement 值 `packet-tunnel-provider`），无法满足我们
的 `packet-tunnel-provider-systemextension`（这点与官方 sing-box-for-apple 一致，已核对）。
所以两个 target 改为**手动 Developer ID 签名**，需要先在门户创建两个 Developer ID 描述文件。

### 0. 先创建两个 Developer ID 描述文件（一次性）
去 [developer.apple.com](https://developer.apple.com/account/resources/profiles/list) →
Certificates, Identifiers & Profiles → **Profiles** → 点 **+**：
1. Profile 类型选 **Developer ID**（在 Distribution 分组下）→ 子类型选含系统扩展的那项 →
   Continue。
2. App ID 选 **com.gumpw.linko** → 选 Developer ID 证书（WANG GANG）→ 命名为
   **`Linko DeveloperID`**（名字必须完全一致，project.yml 里按这个名字引用）→ Generate → Download。
3. 重复一次，App ID 选 **com.gumpw.linko.tunnel** → 命名为 **`LinkoTunnel DeveloperID`** →
   Download。
4. 双击两个下载的 `.provisionprofile` 文件安装到本机。

> 若门户里两个 App ID 没有 App Groups / Network Extensions 能力：先到 Identifiers 里给它们
> 勾上这两个 capability，再创建描述文件。

## 步骤

### 1. 生成并打开工程
```bash
cd ~/dev/00/linko && make gen
open Linko.xcodeproj
```

### 2. 确认签名（两个 target）
- 选 `LinkoApp` target → Signing & Capabilities → Team = `WANG GANG (HC438T2B8P)`，
  勾 Automatically manage signing。对 `LinkoTunnel` target 同样设置。
- 若提示某 capability 未启用，点 Xcode 的「Enable」即可（它会在门户给两个 App ID
  勾上 App Groups + Network Extensions）。

### 3. Archive + Developer ID 分发（含公证）
- 顶部目标选 **Any Mac (Apple Silicon)** 或 My Mac → 菜单 **Product → Archive**。
- Organizer 弹出 → 选这个 archive → **Distribute App → Developer ID**：
  - Xcode 自动生成两个 **Developer ID** 描述文件（含 system-extension 能力）。
  - 选 **Upload**（让 Apple 公证）或 **Export** 后用 notarytool 公证。首次会要 Apple ID
    **专用密码**（appleid.apple.com 生成 app-specific password）。
  - 公证通过后 Xcode 会 staple。导出得到签名+公证的 `Linko.app`。

> 命令行公证备选（已有 archive 时）：
> ```bash
> xcrun notarytool store-credentials linko-notary --apple-id <你的AppleID> --team-id HC438T2B8P --password <专用密码>
> # Xcode Export 出 Linko.app 后：
> xcrun notarytool submit Linko.app.zip --keychain-profile linko-notary --wait
> xcrun stapler staple Linko.app
> ```

### 4. 安装并启用
- 把导出的 `Linko.app` 拷到 `/Applications/`（系统扩展从别处激活会被拒）。
- 打开 Linko → 设置 → 模式选「TUN 全局」→ 打开开关。
- 系统弹「Linko 想添加系统扩展」→ 系统设置 → 隐私与安全性 → 底部「允许」LinkoTunnel。
- 再开 TUN 开关，应连接成功（菜单栏状态=已连接，Dashboard 出现连接/流量曲线）。

## 排错（Console.app 过滤 `LinkoTunnel` 或 `sysextd`/`neagent`）
- **扩展不加载**：确认在 `/Applications`；`systemextensionsctl list` 看状态。
- **公证失败**：`xcrun notarytool log <submission-id> --keychain-profile linko-notary` 看原因
  （常见：未启用 hardened runtime——project.yml 已设 `ENABLE_HARDENED_RUNTIME=YES`）。
- **NEMachServiceName 报错**：当前 `group.com.gumpw.linko.tunnel`（App Group 加 .tunnel 后缀）。
  若 loader 拒绝，在 `apps/LinkoTunnel/Info.plist` 改成与某 App Group 完全一致后重打。
- **TUN 起来但不通**：Console 看 libbox 日志；主 App 写到 App Group 容器的 config.json 可用
  `./vendor/sing-box/sing-box check -c <该文件>` 校验。

把任何报错日志贴给我，我来定位修复。
