# 发布与自动更新（Sparkle）

Linko 通过 [Sparkle 2](https://sparkle-project.org) 分发应用内更新,以 Developer ID
签名 + 公证的 DMG 形式发布到 GitHub Releases。整条流水线由 `scripts/release.sh`
（`make release`）驱动:从归档、签名、公证到打 DMG、生成签名 appcast 一气呵成。

**Appcast 托管采用 GitHub 的 `releases/latest/download` 永久重定向**:
`SUFeedURL`（见 `project.yml`）固定为
`https://github.com/wanggang316/linko/releases/latest/download/appcast.xml`,
它始终解析到最新一个**非预发布** Release 上名为 `appcast.xml` 的附件。因此 feed URL
终身不变,发布流程只需把更新后的 `appcast.xml` 重新附加到每个稳定 Release 即可。

---

## 1. 一次性准备

### 1.1 EdDSA 签名密钥（已完成）

Sparkle 2 用 EdDSA（ed25519）对每个更新包签名。本仓库的公钥已写入 `project.yml`
的 `INFOPLIST_KEY_SUPublicEDKey`,**私钥仅存在于登录钥匙串**（条目
`Private key for signing Sparkle updates`），绝不入库。

新机器上恢复 / 导出离线备份:

```sh
# Sparkle 的工具随 SPM 解析进 DerivedData;也可从
# https://github.com/sparkle-project/Sparkle/releases 下载发行包取得 bin/。
generate_keys -x sparkle-private-key-backup.txt   # 导出,离线保存后删除
generate_keys -f sparkle-private-key-backup.txt   # 在新机器导入
```

> CI 用同一把私钥的 base64 文本作为 secret `SPARKLE_PRIVATE_KEY`（见第 5 节）。

### 1.2 公证凭据（需本人配置一次）

`scripts/notarize.sh` 默认用钥匙串 profile `linko-notary`。用 App 专用密码或
App Store Connect API Key 存一次（涉及 Apple ID 凭据,请自行执行,不要把密码写进仓库）:

```sh
xcrun notarytool store-credentials linko-notary \
  --apple-id <your-apple-id> --team-id HC438T2B8P
# 按提示粘贴 App 专用密码（appleid.apple.com 生成）
```

### 1.3 Developer ID 证书与描述文件

本机钥匙串需有 **Developer ID Application** 证书,且已安装两个 Developer ID 描述文件:
`Linko DeveloperID`（App）与 `LinkoTunnel DeveloperID`（系统扩展）。后者携带
`packet-tunnel-provider-systemextension` 这一受描述文件管控的 entitlement。
`project.yml` 已为两个 target 配好 Manual + Developer ID + 对应描述文件;
归档时不在命令行覆盖签名身份,正是为了保住系统扩展这条 entitlement。

---

## 2. 准备内核依赖（`vendor/` 为 gitignored 构建产物）

发布归档前必须确保两个 vendored 产物存在（首次或升级内核时执行）:

```sh
make fetch-core          # 下载 sing-box darwin 二进制 -> vendor/sing-box/
./scripts/build-libbox.sh # 用 Go + gomobile 构建 Libbox.xcframework（系统扩展依赖）
```

`build-libbox.sh` 需要 Go 工具链;它在 sing-box 的 tagged checkout 内构建以使用其
锁定的 sing-tun 版本（`SING_BOX_VERSION` 默认 v1.13.13）。

---

## 3. 发布一个版本（本地）

```sh
# 1) 提版本:改写 project.yml 的 MARKETING_VERSION + CURRENT_PROJECT_VERSION
#    （build 号走 YYYYMMDDNNN,自动查已发布 appcast 的最高值 +1）并重生工程。
make bump-version VERSION=0.2.0

# 2) 切 CHANGELOG:把 [Unreleased] 下的条目移到新的
#    `## [0.2.0] - YYYY-MM-DD` 小节,顶部保留空的 [Unreleased]（六个分区标题）。
#    这一节文本即 Sparkle 更新弹窗展示给用户的说明。

# 3) 提交版本与 changelog（保持原子,二者一起）。
git add project.yml CHANGELOG.md && git commit -m "chore(release): bump to 0.2.0"
git tag v0.2.0

# 4) 跑完整流水线:archive → 公证 App → 签名 DMG → 公证 DMG → 生成签名 appcast。
make release
# 产物:.build/release/Linko-0.2.0.dmg(+ .sha256) 与 .build/release/appcast.xml

# 5) 建 GitHub Release 并上传三件套(DMG、其 .sha256、appcast.xml)。
gh release create v0.2.0 \
  --title v0.2.0 \
  --notes-file <(sed -n '/^## \[0.2.0\]/,/^## \[/p' CHANGELOG.md | sed '$d') \
  .build/release/Linko-0.2.0.dmg \
  .build/release/Linko-0.2.0.dmg.sha256 \
  .build/release/appcast.xml
```

发布后,所有已安装客户端会在
`releases/latest/download/appcast.xml` 拉到新版本;用户也可在「设置 › 关于 › 检查更新…」
或菜单栏底部手动触发。仅当更新包的 EdDSA 签名与内置 `SUPublicEDKey` 匹配时才会安装。

> **不要手工编辑 appcast 的 `<item>`** —— 它由 `generate_appcast` 用钥匙串私钥
> 自动生成与签名。仓库根的 `appcast.xml` 仅为结构模板。

---

## 4. 单步子命令

`scripts/release.sh` 也可分步运行,便于调试:

| 命令 | 作用 |
| --- | --- |
| `release.sh archive` | 归档 + 从 xcarchive 取出已签名 App + 重签嵌套 helper |
| `release.sh notarize <path>` | 提交 .app/.dmg 公证并 staple |
| `release.sh dmg [version]` | 把 App 打成签名 DMG（+ `.sha256`） |
| `release.sh appcast [version]` | 为该 DMG 生成签名 appcast.xml |
| `release.sh release` | 以上全流程 |

---

## 5. CI 自动化（计划中）

目标是把第 2–3 节搬进 `.github/workflows/`：`v*` tag 触发 → 在 runner 上
`build-libbox`（Go/gomobile）+ 归档签名 → 公证 → 打包 → `generate_appcast`
（私钥取自 secret `SPARKLE_PRIVATE_KEY`，`--ed-key-file -` 不落盘）→ 从 CHANGELOG 注入
release notes → 起草 Release。另一条 `update-cask.yml` 在 Release 发布后把渲染好的
Homebrew cask 推到 tap 仓库。需要的 secrets:Developer ID 证书 p12、其密码、两个描述
文件、ASC API key、`SPARKLE_PRIVATE_KEY`、tap token。**尚未落地**,详见对齐参考
`/Users/wanggang/dev/00/touch-code` 的 release 流水线。

---

## 6. 代码与脚本位置

- `apps/LinkoApp/Sources/UpdaterController.swift` —— 封装 `SPUStandardUpdaterController`，
  启动即开始定时检查;暴露 `checkForUpdates()` 与 `automaticallyChecksForUpdates`。
- `apps/LinkoApp/Sources/SettingsView.swift`、`MenuContentView.swift` —— 「检查更新…」入口。
- `project.yml` —— Sparkle SPM 依赖（仅 App 目标）、`SUFeedURL`/`SUPublicEDKey`/自动检查键，
  以及全局共享的 `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`。
- `scripts/release.sh`、`resign-nested.sh`、`notarize.sh`、`make-dmg.sh`、`bump-version.sh`
  —— 发布流水线。
- `CHANGELOG.md` —— 面向用户的版本说明,发布时注入 Release 与 appcast。
- `appcast.xml` —— appcast 结构模板（占位,发布时由 `generate_appcast` 生成真实内容）。
