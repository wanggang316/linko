# 发布与自动更新（Sparkle）

Linko 通过 [Sparkle 2](https://sparkle-project.org) 分发更新。Sparkle 仅链接到
`LinkoApp` 目标（`LinkoKit` 不依赖 Sparkle）。本文档描述生成签名密钥、签名构建产物
以及托管 `appcast.xml` 的发布流程。

> 说明：本里程碑仅做**编译级**集成。真正的自动更新在运行时需要一个经过签名的发布包
> 和一个可访问的 appcast 主机。下方标注「发布步骤」的内容不在代码中实现。

---

## 1. 一次性：生成 EdDSA 签名密钥对

Sparkle 2 使用 EdDSA（ed25519）对更新包签名。每个发布渠道只需生成一次密钥对。

```sh
# 解析 SPM 依赖后，Sparkle 的工具位于 DerivedData 中的 artifacts 目录。
# 也可直接从 https://github.com/sparkle-project/Sparkle/releases 下载发行包，
# 其中包含 bin/generate_keys 与 bin/generate_appcast。
./bin/generate_keys
```

`generate_keys` 会：

- 将**私钥**写入登录用户的 **macOS 钥匙串**（条目名 `Private key for signing
  Sparkle updates`）。私钥**绝不**进入仓库、CI 日志或任何明文文件。
- 在终端打印**公钥**（一行 base64）。

将打印出的公钥填入 `project.yml`，替换占位符：

```yaml
INFOPLIST_KEY_SUPublicEDKey: <这里粘贴 generate_keys 打印的公钥>
```

公钥经 XcodeGen 写入生成的 Info.plist 的 `SUPublicEDKey` 键。公钥可公开；
Sparkle 用它来校验每个更新包的签名是否由对应私钥产生。

### 备份私钥

私钥仅存在于钥匙串中。导出离线备份并妥善保管（**不要**入库）：

```sh
./bin/generate_keys -x private-key-backup.txt   # 导出，离线保存后删除
# 在新机器上恢复：
./bin/generate_keys -f private-key-backup.txt
```

---

## 2. Info.plist 键（已在 `project.yml` 中配置）

XcodeGen 通过 `INFOPLIST_KEY_*` 设置把下列键写入生成的 Info.plist：

| 键 | 当前值 | 含义 |
| --- | --- | --- |
| `SUFeedURL` | `https://example.com/appcast.xml`（占位） | appcast 订阅地址，发布前替换为真实主机 URL |
| `SUPublicEDKey` | `REPLACE_WITH_REAL_SUPublicEDKey`（占位） | 第 1 步生成的 EdDSA 公钥 |
| `SUEnableAutomaticChecks` | `YES` | 启用 Sparkle 后台定时检查 |
| `SUScheduledCheckInterval` | `86400` | 后台检查间隔（秒，24 小时） |

修改 `project.yml` 后运行 `make gen`（或 `xcodegen generate`）重新生成工程，
键值才会进入构建产物。

---

## 3. 发布步骤：打包、签名、生成 appcast

> 以下为发布操作，不在本仓库代码中自动执行。

1. **构建并归档** Release 版本，导出 `Linko.app`，并完成开发者 ID 签名与
   公证（notarization）——这是 macОS Gatekeeper 的要求，独立于 Sparkle 签名。
2. **压缩**为更新包：
   ```sh
   ditto -c -k --keepParent Linko.app Linko-<version>.zip
   ```
3. 把所有发布归档放进一个目录（如 `releases/`），运行 `generate_appcast`：
   ```sh
   ./bin/generate_appcast releases/
   ```
   它会用钥匙串中的私钥为每个归档生成 EdDSA 签名，并在 `releases/appcast.xml`
   写入/更新 `<item>`（版本、长度、`sparkle:edSignature`、最低系统版本等）。
   **不要**手工编辑 `<item>`，仓库根目录的 `appcast.xml` 只是结构模板。

---

## 4. 发布步骤：托管

> 以下为发布操作，不在本仓库代码中自动执行。

把 `appcast.xml` 与各发布归档上传到一个 HTTPS 主机（GitHub Releases、对象存储或
任意静态主机均可），使其 URL 与 Info.plist 中的 `SUFeedURL` 一致。Sparkle 会：

- 按 `SUScheduledCheckInterval` 在后台拉取 appcast；
- 也可由用户在「设置 › 关于 › 检查更新…」或菜单栏底部的更新按钮手动触发；
- 仅在更新包的 EdDSA 签名与内置 `SUPublicEDKey` 匹配时才下载并安装。

---

## 代码集成位置

- `apps/LinkoApp/Sources/UpdaterController.swift` —— 封装
  `SPUStandardUpdaterController`，应用启动时即开始定时检查；暴露
  `checkForUpdates()` 与 `automaticallyChecksForUpdates`。
- `apps/LinkoApp/Sources/SettingsView.swift` —— 「关于」分区中的「检查更新…」
  按钮与「自动检查更新」开关。
- `apps/LinkoApp/Sources/MenuContentView.swift` —— 菜单栏底部的「检查更新…」按钮。
- `project.yml` —— Sparkle SPM 依赖（仅 `LinkoApp` 目标）与上述 Info.plist 键。
- `appcast.xml` —— appcast 结构模板（占位，发布时由 `generate_appcast` 生成真实内容）。
