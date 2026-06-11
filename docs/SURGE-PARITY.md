# Surge 功能对齐矩阵

> 目标：功能上向 Surge Mac 对齐并超越；定位差异：linko 是「代理客户端」，不做 Surge 的
> 「Web 调试代理」路线（MITM/重写/脚本）。
> 状态：✅ 已交付 / 🚧 进行中 / ⏳ 计划 / ❌ 非目标。

## 1. 流量接管

| Surge 功能 | sing-box 对应 | linko 状态 |
|---|---|---|
| 系统代理（HTTP/SOCKS 监听） | mixed inbound + 写系统代理 | ✅ |
| 增强模式（TUN 虚拟网卡，接管全部流量） | NE PacketTunnelProvider + libbox tun | 🔴 代码完成；macOS 26.5 上系统扩展激活有已知系统级障碍，已挂起 |
| 网关 / DHCP / 端口转发 | — | ❌ 非目标 |

## 2. 规则引擎

| Surge 功能 | sing-box 对应 | linko 状态 |
|---|---|---|
| DOMAIN / SUFFIX / KEYWORD / REGEX | domain / domain_suffix / domain_keyword / domain_regex | ✅ |
| IP-CIDR / IP-CIDR6 / SRC-IP | ip_cidr / source_ip_cidr | ✅ |
| GEOIP / GEOSITE / RULE-SET（远程） | rule_set（geoip/geosite/remote srs） | ✅ |
| PROCESS-NAME / PROCESS-PATH | process_name / process_path | ✅ |
| PORT / DEST-PORT / SRC-PORT | port / source_port | ✅ |
| LOGICAL（AND/OR/NOT） | logical 规则（mode + invert） | ✅ |
| FINAL | route.final | ✅ |
| 规则编辑器（增删 / 拖拽排序） | — | ✅ |
| 导入 Surge / Clash 规则 | — | ✅ |
| SUBNET（按网络环境切换策略） | 客户端层实现 | ⏳ M4 |

## 3. 策略系统

| Surge 功能 | sing-box 对应 | linko 状态 |
|---|---|---|
| 多协议节点（SS/VMess/VLESS/Trojan/Hy2/TUIC） | 对应 outbound | ✅ |
| 完整传输层（TLS/Reality/uTLS/ALPN/ws/grpc/http/obfs） | shared tls + v2ray-transport + plugin | ✅ |
| select 手动策略组 | selector | ✅ |
| url-test 自动测速 | urltest（url/interval/tolerance） | ✅ |
| 策略组嵌套、多策略组 | selector/urltest 嵌套 | ✅ |
| fallback / load-balance | 降级为 urltest（已标注） | ⚠️ 部分 |
| WireGuard / SSH 策略 | endpoint / ssh outbound | ✅ |
| Snell | — | ❌（Surge 私有协议） |

## 4. DNS

| Surge 功能 | linko 状态 |
|---|---|
| 自定义 DNS / DoH / DoT / DoQ | ✅（1.12+ typed-server 格式 + default_domain_resolver） |
| DNS 分流规则 | ✅（action-based rules） |
| fake-ip | ⏳ 随 M2 TUN 启用 |
| 本地映射 / hosts | ✅（sing-box `type:"hosts"` 预定义服务器 + 高优先级精确域名规则；DNS 关闭时也可独立生效） |

## 5. 可观测性

| Surge 功能 | 数据来源 | linko 状态 |
|---|---|---|
| Dashboard 主窗口 | — | ✅ |
| 实时连接列表（进程/目标/规则/链路/时长，排序） | Clash API /connections | ✅ |
| 连接搜索 / 过滤 / 关闭（单条+全部）/ 详情 | /connections (+DELETE) | ✅ |
| 实时流量速率 / 总量 / 内存 | /traffic | ✅ |
| 日志查看 / 导出 | /logs | ✅ |
| 延迟测试 | /proxies/{}/delay | ✅ |
| 按 App/策略流量统计 | connections 聚合 | ✅（应用 tab） |

## 6. HTTP 处理与调试（定位差异，非目标）

MITM HTTPS 解密、请求捕获、URL/Header/Body 重写、Map Local、JavaScript 脚本、
模块系统 —— ❌ 均为 Surge「调试代理」定位的能力，linko 不做。

## 7. 配置与系统集成

| Surge 功能 | linko 状态 |
|---|---|
| 订阅管理（多订阅 / 更新 / 自动更新 / 删除 / 重命名） | ✅ |
| **启动前配置校验（sing-box check 预检，拦截坏配置）** | ✅（超越 Surge 的安全网） |
| 菜单栏 UI / Dashboard | ✅（原生 SwiftUI） |
| 开机自启 | ✅（SMAppService） |
| 多 Profile 切换 / 托管配置 | ✅（无损迁移 + 切换重启） |
| 自动更新（App 自身） | 🟡 Sparkle 已集成，待发布服务器 + appcast |
| CLI / HTTP API / URL Scheme | ⏳ M5 评估 |
| Ponte 设备组网 | ❌ 非目标 |

---

## 里程碑

- **已交付**：系统代理 MVP、原生 Dashboard、规则引擎 + DNS + 策略组 + 传输层补全 +
  规则导入、生产硬化（启动前配置预校验、多订阅管理 + 自动更新、连接搜索/过滤/关闭/详情、开机自启）。
- **M2（挂起）**：TUN 全局模式代码完成、签名/公证/分发流水线打通；macOS 26.5 上 OSSystemExtensionRequest
  报 “Extension not found in App bundle”（bundle 已验证与可用扩展逐位对等、OS 认可为系统扩展），
  疑似 26.5 + Xcode 26.5 SDK 的系统级问题，非代码缺陷。见 docs/M2-DEVICE-TEST.md。
- **M4（已交付）**：WireGuard/SSH 出站、多 Profile、按 App 流量统计、Sparkle 自动更新（待发布基建）。
- **剩余**：SUBNET 按网络环境切换、hosts 本地映射、fake-ip（随 TUN）、CLI/HTTP API/URL Scheme。
