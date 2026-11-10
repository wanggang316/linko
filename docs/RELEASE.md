# 发布与自动更新（Sparkle）

Linko 通过 [Sparkle 2](https://sparkle-project.org) 分发应用内更新,以 Developer ID
签名 + 公证的 DMG 形式发布到 GitHub Releases。正式版本**只在 CI 构建**:推送 `vX.Y.Z`
tag 触发 `.github/workflows/release.yml`,它调用 `scripts/release.sh`（`make release`）
完成归档、签名、公证、打 DMG、生成签名 appcast,并起草 Release。完整操作步骤见
`.claude/skills/release/SKILL.md`（release skill）。

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
锁定的 sing-tun 版本。sing-box 版本统一写在 `scripts/sing-box-version`，`build-libbox.sh` 和 `fetch-singbox.sh` 都读取它，保证扩展内核和配置校验用的二进制版本一致。

---

## 3. 发布一个版本

发布走 **release PR → 合并 → 在合并后的 commit 上打 tag → CI 构建 → 发布草稿**。
CI 强制以下契约,任一不满足即失败:

> tag `vX.Y.Z` ⇔ `project.yml` 的 `MARKETING_VERSION = X.Y.Z` ⇔
> `CHANGELOG.md` 有 `## [X.Y.Z] - YYYY-MM-DD` 小节。

```sh
# 1) 从 origin/main 开 release 分支（--no-track 避免裸 push 推到 main）。
git switch --no-track -c release/v0.3.0 origin/main

# 2) 写 release notes:把 [Unreleased] 整理成面向用户的条目,放进
#    `## [0.3.0] - YYYY-MM-DD`,顶部重建空的 [Unreleased];同时在
#    apps/website/src/data/changelog.zh.json 补中文译文。
#    版本号按 SemVer 由 notes 决定:只有 Fixed/Security → patch,否则 minor
#    （0.y.z 阶段破坏性变更也只升 minor）。`bump-version.sh --print` 给出候选。

# 3) 提版本（build 号走 YYYYMMDDNNN,自动查已发布 appcast 的最高值 +1）。
make bump-version VERSION=0.3.0

# 4) 一个提交,开 PR,等 pr-build 通过后合并（rebase）。
git add CHANGELOG.md project.yml apps/website/src/data/changelog.zh.json
git commit -m "chore(release): bump to 0.3.0"
git push -u origin release/v0.3.0
gh pr create --base main --title "chore(release): bump to 0.3.0" ...

# 5) 在合并后的 commit 上打 annotated tag 并推送,触发 release.yml。
git tag -a v0.3.0 -m "v0.3.0" <merged-sha>
git push origin v0.3.0

# 6) CI 通过且草稿带齐 DMG、.sha256、appcast.xml 后,用本人账号发布。
gh release edit v0.3.0 --draft=false --latest
```

发布必须用本人 token（`gh`）完成:由 workflow 的 `GITHUB_TOKEN` 发布的 Release
不会触发 `update-cask.yml`。**不要**在本地对已打 tag 的版本跑
`make release` + `gh release create`:CI 也会构建同一 tag,结果是一个 tag 对应两个
Release;`release.yml` 发现该 tag 已有 Release（含草稿）时会直接失败。

发布后,所有已安装客户端会在
`releases/latest/download/appcast.xml` 拉到新版本;用户也可在「设置 › 关于 › 检查更新…」
或菜单栏底部手动触发。仅当更新包的 EdDSA 签名与内置 `SUPublicEDKey` 匹配时才会安装。
appcast 的 `<description sparkle:format="markdown">` 来自该版本的 CHANGELOG 小节,
即更新弹窗里展示的说明（需要 Sparkle 2.9+）。

> **不要手工编辑 appcast 的 `<item>`** —— 它由 `release.sh appcast` 调用
> `generate_appcast` 生成并签名。仓库根的 `appcast.xml` 仅为结构模板。

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

## 5. CI

| Workflow | 触发 | 作用 |
| --- | --- | --- |
| `pr-build.yml` | PR / push 到 `main` | 构建 Libbox,跑 `make test`、`make test-app`,无签名 Release 构建 |
| `release.yml` | 推送 `v*` tag / 手动指定已有 tag | 校验契约 → 构建 Libbox → 签名归档 → 公证 → DMG → appcast → 起草 Release |
| `update-cask.yml` | Release 发布 | 渲染 Homebrew cask 推到 `wanggang316/homebrew-tap` |
| `pages.yml` | push 到 `main`（含 release PR 合并） | 构建并部署官网（读取 CHANGELOG 与版本号） |

`release.yml` 所需 secrets:`DEVELOPER_ID_CERT_P12_BASE64`、`DEVELOPER_ID_CERT_PASSWORD`、
`KEYCHAIN_PASSWORD`、`PROVISION_PROFILE_APP_BASE64`、`PROVISION_PROFILE_EXT_BASE64`、
`AC_API_KEY_ID`、`AC_API_ISSUER_ID`、`AC_API_KEY_P8`、`SPARKLE_PRIVATE_KEY`;
`update-cask.yml` 另需 `HOMEBREW_TAP_TOKEN`。第 1 节的本机凭据只用于本地调试
`release.sh` 的单步子命令。

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
