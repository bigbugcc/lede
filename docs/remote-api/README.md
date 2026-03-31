# OpenWrt 远程访问 API 开发文档

> 适用于 Lean's LEDE (bigbugcc/lede fork)  
> 面向 Android 原生应用 / 微信小程序远程管理

---

## 目录

1. [项目背景与可行性分析](#1-项目背景与可行性分析)
2. [系统架构分析](#2-系统架构分析)
3. [远程访问挑战与解决方案](#3-远程访问挑战与解决方案)
4. [总体实施方案](#4-总体实施方案)
5. [技术选型](#5-技术选型)
6. [快速开始](#6-快速开始)
7. [安全设计](#7-安全设计)
8. [目录结构](#8-目录结构)

---

## 1. 项目背景与可行性分析

### 1.1 项目概述

本项目（bigbugcc/lede）是 [Lean's LEDE](https://github.com/coolsnowwolf/lede) 的定制分支，
是基于 OpenWrt 的 Linux 嵌入式路由器固件。目标是在其基础上，构建一套
**供 Android 应用或微信小程序远程访问、管理路由器的 API 系统**。

### 1.2 现有技术基础

OpenWrt 本身已具备完整的本地 API 体系：

| 组件 | 作用 | 接口 |
|------|------|------|
| **uhttpd** | 轻量 HTTP 服务器（端口 80/443） | HTTP/HTTPS |
| **uhttpd-mod-ubus** | HTTP→JSON-RPC 桥接模块 | `/ubus/call` POST |
| **rpcd** | RPC 守护进程，身份认证 + 鉴权 | ubus socket |
| **ubusd** | 进程间通信消息总线 | UNIX socket |
| **uci** | 统一配置接口 | CLI / C API / Lua |
| **LuCI** | Web 管理界面（Lua/ucode 实现） | `/cgi-bin/luci/` |

### 1.3 可行性结论

**✅ 技术可行性：高**

- OpenWrt 已有 JSON-RPC API（`/ubus/call`），可直接被移动端调用
- rpcd + ACL 体系提供精细权限控制
- uhttpd 支持 CORS、HTTPS、自定义 ucode 处理器
- 所有主流路由功能（网络、WiFi、DNS、防火墙）均有 ubus 暴露

**⚠️ 主要挑战：网络访问层**

- 路由器通常部署于 LAN 内网，无公网 IP 或 IP 动态变化
- NAT 穿透是核心问题，需要额外方案

**✅ 经济可行性：高**

- 现有 OpenWrt 软件包机制成熟，可复用大量已有代码
- 可以按需选择方案（DDNS 直接访问、WireGuard VPN、云中继）

---

## 2. 系统架构分析

### 2.1 本地 API 调用栈

```
移动端 App / 小程序
        │
        │  HTTPS/HTTP
        ▼
┌─────────────────────┐
│    uhttpd :443/80   │  轻量 Web 服务器
│  + uhttpd-mod-ubus  │  HTTP→JSON-RPC 桥接
└──────────┬──────────┘
           │  JSON-RPC over UNIX Socket
           ▼
┌─────────────────────┐
│       rpcd          │  RPC 守护进程
│  身份认证 + ACL 鉴权  │  /etc/config/rpcd
└──────────┬──────────┘
           │  ubus IPC
           ▼
┌─────────────────────┐
│      ubusd          │  消息总线
└──┬──────┬──────┬────┘
   │      │      │
   ▼      ▼      ▼
network  system  iwinfo ...
interface info    WiFi
status   reboot   scan
```

### 2.2 现有 JSON-RPC API 端点

| 端点 | 说明 |
|------|------|
| `POST /ubus/call` | 全部 ubus 方法（需 session token） |
| `POST /cgi-bin/luci/rpc/auth` | LuCI 认证接口 |
| `POST /cgi-bin/luci/rpc/*` | LuCI JSON-RPC 接口 |

### 2.3 新增 REST API 层

本项目在现有基础上新增一个 **REST API 层**：

```
移动端 App / 小程序
        │
        │  HTTPS POST/GET
        ▼
┌─────────────────────┐
│  REST API 服务      │  运行在 :8080 (HTTP) / :8443 (HTTPS)
│  /api/v1/*          │  ucode 处理器 (uhttpd 独立实例)
│  + CORS             │  JWT 风格 Token 认证
│  + 速率限制         │
└──────────┬──────────┘
           │  调用现有 ubus JSON-RPC
           ▼
      (原有 rpcd/ubus 体系)
```

---

## 3. 远程访问挑战与解决方案

### 3.1 核心问题：NAT 穿透

家用路由器通常：
1. 位于 ISP NAT 之后，没有公网 IP
2. 即使有公网 IP，也是动态 IP
3. 防火墙默认阻止入站连接

### 3.2 三种解决方案对比

#### 方案 A：DDNS + 端口转发（最简单）

```
Internet ──→ ISP公网IP:8443 ──→ [NAT] ──→ 路由器:8443
                     ↑
               DDNS域名解析
```

**优点：** 无需额外服务器，延迟低  
**缺点：** 需要 ISP 支持端口映射；动态 IP 需要 DDNS；不是所有 ISP 允许

**适用场景：** 有公网 IP 的家庭宽带或企业网络

**配置步骤：**
1. 路由器开启 DDNS（阿里云 / DNSPod 已有内置包）
2. 在路由器防火墙添加 8443 → 192.168.1.1:8443 端口转发
3. 移动端通过 `https://your-domain.com:8443/api/v1/...` 访问

#### 方案 B：WireGuard VPN（最安全）

```
Android App ──[WireGuard VPN]──→ 路由器 WireGuard Server
                                      │
                              通过 VPN 隧道访问
                              http://192.168.1.1/api/v1/...
```

**优点：** 端对端加密，无需暴露端口  
**缺点：** 需要在 Android/小程序端安装 WireGuard；微信小程序不支持 VPN

**适用场景：** Android 原生应用（可使用 WireGuard SDK）

**配置步骤：**
1. 路由器安装 WireGuard（OpenWrt 已有包：`luci-app-wireguard`）
2. 生成 WireGuard 客户端配置（公私钥对）
3. Android App 集成 [WireGuard Android SDK](https://github.com/WireGuard/wireguard-android)
4. 连接 VPN 后直接访问内网 API

#### 方案 C：云中继（最通用，推荐微信小程序）

```
微信小程序 / Android App
        │  HTTPS
        ▼
┌─────────────────┐
│   云中继服务器    │  公网服务器（云主机）
│   :443 HTTPS    │  WebSocket 中继
└────────┬────────┘
         │  WebSocket (出站连接，路由器主动建立)
         ▼
┌─────────────────┐
│  路由器（LAN）   │  relay-client 守护进程
│  远程API服务     │  主动连接中继服务器
└─────────────────┘
```

**优点：** 不需要公网 IP；微信小程序支持；即插即用  
**缺点：** 需要一台公网云服务器（轻量云主机即可）；增加延迟

**适用场景：** 微信小程序、无公网 IP 的场景

---

## 4. 总体实施方案

### 4.1 实施路线图

```
阶段 1：本地 REST API（已实现）
  └─ luci-app-remote-api 包
     ├─ 独立 uhttpd 实例（:8080/:8443）
     ├─ ucode REST 处理器
     ├─ Token 认证（HMAC-SHA256）
     └─ LuCI 管理界面

阶段 2：远程访问（已实现）
  ├─ 方案 A: DDNS 集成（修改现有 ddns-scripts 配置）
  ├─ 方案 B: WireGuard（依赖现有 wireguard 包）
  └─ 方案 C: remote-api-relay 包
              ├─ relay-client 守护进程
              ├─ WebSocket/SSH 隧道
              └─ 自动重连

阶段 3：移动端集成（文档+示例代码）
  ├─ Android SDK 示例（Kotlin/Java）
  └─ 微信小程序示例（JavaScript）
```

### 4.2 新增的 OpenWrt 包

本项目新增两个 OpenWrt 包：

| 包名 | 功能 | 依赖 |
|------|------|------|
| `luci-app-remote-api` | REST API 服务 + LuCI 管理界面 | uhttpd, rpcd, ubus, luci-compat |
| `remote-api-relay` | 云中继客户端 | ubus, autossh 或 wsproxy |

---

## 5. 技术选型

### 5.1 API 协议

| 特性 | 选择 | 原因 |
|------|------|------|
| 协议 | HTTPS REST | Android/小程序均支持，简单 |
| 数据格式 | JSON | 通用，移动端原生支持 |
| 认证 | API Token（HMAC-SHA256） | 适合长期会话的移动端 |
| API 版本化 | URL 路径前缀 `/api/v1/` | 便于向后兼容 |
| CORS | 允许所有来源（可配置） | 小程序访问需要 |

### 5.2 认证机制

不同于 Web 管理界面的短期 session（15 分钟），移动端 API 使用更长有效期的 Token：

```
Token 格式: <timestamp>.<user>.<hmac_signature>
有效期: 默认 30 天（可配置）
密钥: 存储于 /etc/remote-api.secret（随机生成）
算法: HMAC-SHA256
```

**Token 获取流程：**

```
App                    路由器API
 │                        │
 │  POST /api/v1/auth/token│
 │  {username, password}  │
 │─────────────────────→  │
 │                        │─→ rpcd: ubus_rpc_session.login
 │                        │←─ session token
 │                        │─→ 生成 API Token（HMAC签名）
 │  {token, expires_at}   │
 │←─────────────────────  │
 │                        │
 │  GET /api/v1/system/info│
 │  Authorization: Bearer  │
 │  <token>                │
 │─────────────────────→  │
 │                        │─→ 验证 Token（HMAC验签 + 过期检查）
 │                        │─→ ubus: system info
 │  {data: {...}}          │
 │←─────────────────────  │
```

### 5.3 ucode 选择原因

ucode 是 OpenWrt 现代化的脚本语言（类 JavaScript），相比 Lua 的优势：
- 原生支持 ubus、uci、fs 模块
- JSON 处理更简洁
- OpenWrt 23.05+ 官方推荐
- 性能优于 Lua

---

## 6. 快速开始

### 6.1 在 OpenWrt 设备上安装

```bash
# 通过 opkg 安装（编译后）
opkg update
opkg install luci-app-remote-api

# 可选：安装云中继客户端
opkg install remote-api-relay
```

### 6.2 初始配置

```bash
# 生成 API 密钥（首次配置必须）
remote-api-ctl generate-secret

# 查看配置
uci show remote_api

# 设置 API 端口（默认 8080）
uci set remote_api.main.port=8080
uci commit remote_api

# 启动服务
/etc/init.d/remote_api enable
/etc/init.d/remote_api start
```

### 6.3 获取 API Token

```bash
curl -k -X POST https://192.168.1.1:8443/api/v1/auth/token \
  -H "Content-Type: application/json" \
  -d '{"username":"root","password":"password"}'
```

响应：
```json
{
  "code": 0,
  "data": {
    "token": "1711891234.root.a3f8b2c1d4e5f6...",
    "expires_at": 1714483234,
    "expires_in": 2592000
  }
}
```

### 6.4 使用 Token 调用 API

```bash
TOKEN="1711891234.root.a3f8b2c1d4e5f6..."

# 获取系统信息
curl -k -H "Authorization: Bearer $TOKEN" \
  https://192.168.1.1:8443/api/v1/system/info

# 获取网络接口状态
curl -k -H "Authorization: Bearer $TOKEN" \
  https://192.168.1.1:8443/api/v1/network/interfaces
```

---

## 7. 安全设计

### 7.1 通信安全

- **HTTPS 强制**：API 服务运行在 HTTPS 端口（8443），自动生成自签名证书
- **证书固定（Certificate Pinning）**：客户端可在首次连接时记录服务器证书指纹
- **HTTP→HTTPS 重定向**：HTTP 请求自动跳转 HTTPS

### 7.2 认证安全

- Token 使用 HMAC-SHA256 签名，防篡改
- Secret key 存储在 `/etc/remote-api.secret`（权限 0600，仅 root 可读）
- Token 有过期时间，防止长期泄露
- 支持 Token 吊销（删除 secret 即可使所有 Token 失效）

### 7.3 访问控制

- rpcd ACL 限制可调用的 ubus 方法
- 速率限制：默认每分钟 60 次请求
- 白名单 IP（可选）：仅允许特定 IP 段访问
- 操作审计日志：记录到 syslog

### 7.4 建议的生产配置

```
# 启用 HTTPS 并禁用 HTTP
uci set remote_api.main.enable_https=1
uci set remote_api.main.enable_http=0
uci set remote_api.main.https_port=8443

# 限制访问 IP（如只允许国内 IP 或 VPN IP）
uci add_list remote_api.main.allowed_networks=192.168.0.0/16
uci add_list remote_api.main.allowed_networks=10.0.0.0/8

# 降低速率限制（高安全要求）
uci set remote_api.main.rate_limit=30

uci commit remote_api
/etc/init.d/remote_api restart
```

---

## 8. 目录结构

```
docs/remote-api/
├── README.md                   本文档（项目分析与总体方案）
├── API_REFERENCE.md            API 接口完整参考文档
├── ANDROID_GUIDE.md            Android 集成开发指南
└── MINIPROGRAM_GUIDE.md        微信小程序集成指南

package/lean/
├── luci-app-remote-api/        REST API 服务 + LuCI 管理界面包
│   ├── Makefile
│   ├── files/
│   │   ├── etc/config/remote_api       UCI 配置
│   │   ├── etc/init.d/remote_api       启动脚本
│   │   ├── usr/bin/remote-api-ctl      控制工具
│   │   ├── usr/lib/remote-api/api.uc   ucode REST API 处理器
│   │   └── usr/share/rpcd/acl.d/       ACL 权限定义
│   └── luasrc/
│       ├── controller/remote_api.lua   LuCI 控制器
│       └── model/cbi/remote_api.lua    LuCI 配置模型
│
└── remote-api-relay/           云中继客户端包
    ├── Makefile
    ├── files/
    │   ├── etc/config/relay_client     中继配置
    │   ├── etc/init.d/relay_client     中继服务启动
    │   └── usr/bin/relay-client        中继连接脚本
    └── README.md
```

---

## 参考资料

- [OpenWrt ubus 文档](https://openwrt.org/docs/techref/ubus)
- [OpenWrt rpcd 文档](https://openwrt.org/docs/techref/rpcd)
- [OpenWrt uhttpd 文档](https://openwrt.org/docs/guide-developer/uhttpd)
- [OpenWrt ucode 文档](https://github.com/jow-/ucode)
- [OpenWrt WireGuard 配置](https://openwrt.org/docs/guide-user/services/vpn/wireguard/start)
- [LuCI 开发指南](https://openwrt.org/docs/guide-developer/luci)
