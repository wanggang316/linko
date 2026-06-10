# Surge 功能对齐矩阵

> 目标：功能上向 Surge Mac 对齐；定位差异：linko 是「代理客户端」，不做 Surge 的
> 「Web 调试代理」路线（MITM/重写/脚本）。状态列：✅ 已有 / 🚧 本轮 / 计划里程碑 / ❌ 非目标。

## 1. 流量接管

| Surge 功能 | 说明 | linko 状态 |
|---|---|---|
| 系统代理（HTTP/SOCKS 监听） | 写系统代理设置 | ✅ M1 |
| 增强模式（TUN 虚拟网卡） | 接管全部流量，含不走系统代理的进程 | M2（NE System Extension + 内核 tun） |
| 网关模式 / DHCP / 端口转发 | 作为局域网网关管理设备 | ❌ 非目标 |

## 2. 规则引擎

| Surge 功能 | sing-box 对应 | linko 状态 |
|---|---|---|
| DOMAIN / SUFFIX / KEYWORD | domain / domain_suffix / domain_keyword | M3 |
| IP-CIDR / GEOIP / ASN | ip_cidr / rule_set(geoip) | M3 |
| RULE-SET 远程规则集 | rule_set（remote, srs） | M3 |
| PROCESS-NAME 按进程分流 | process_name | M3 |
| LOGICAL（AND/OR/NOT） | logical 规则 | M3 |
| SUBNET（按网络环境切换） | 无直接对应 | M4（客户端层实现） |
| FINAL | route.final | ✅ M1（固定指向选择器） |

内核已全部支持，缺口在 linko 的配置模型与规则编辑 UI。

## 3. 策略系统

| Surge 功能 | sing-box 对应 | linko 状态 |
|---|---|---|
| 多协议节点 | ss/vmess/vless/trojan/hysteria2/tuic 等 | ✅ M1（订阅导入） |
| WireGuard / SSH 策略 | endpoint / ssh outbound | M4 |
| Snell | 无 | ❌（Surge 私有协议） |
| select 策略组 | selector | ✅ M1（单组） |
| url-test 自动测速 | urltest | M3 |
| fallback / load-balance | urltest 近似 / 无 | M4 评估 |
| 策略嵌套、多策略组 | selector 嵌套 | M3 |

## 4. DNS

| Surge 功能 | linko 状态 |
|---|---|
| 自定义 DNS / DoH | M3（设置页 + 内核 dns 模块） |
| 本地映射 / hosts | M4 |
| fake-ip（TUN 场景） | M2 随 TUN 落地 |

## 5. 可观测性（本轮重点）

| Surge 功能 | 数据来源 | linko 状态 |
|---|---|---|
| Dashboard 主窗口 | — | 🚧 本轮 |
| 实时连接列表（含进程/规则/链路） | Clash API /connections | 🚧 本轮 |
| 实时流量速率/总量 | Clash API /traffic | 🚧 本轮 |
| 日志查看 | Clash API /logs | 🚧 本轮 |
| 延迟测试 | /proxies/{}/delay | ✅ M1 |
| 按 App/策略流量统计 | connections 聚合 | M3 |

## 6. HTTP 处理与调试（定位差异，非目标）

MITM HTTPS 解密、请求捕获、URL/Header/Body 重写、Map Local、JavaScript 脚本、
模块系统 —— ❌ 均为 Surge「调试代理」定位的能力，linko 不做。

## 7. 配置与系统集成

| Surge 功能 | linko 状态 |
|---|---|
| 多 Profile 切换 / 托管配置 | M4 |
| 订阅管理（更新/删除/多订阅） | ✅ 基础已有，🚧 本轮补管理 UI |
| 菜单栏 UI | ✅，🚧 本轮原生化重做 |
| 开机自启 | M4（SMAppService） |
| 自动更新 | M4（Sparkle，随签名公证分发） |
| CLI / HTTP API / URL Scheme | M5 评估 |
| Ponte 设备组网 | ❌ 非目标 |
