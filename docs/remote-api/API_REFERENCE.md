# OpenWrt 远程访问 API 接口参考文档

> 版本：v1.0  
> 基础路径：`https://<router_ip>:8443/api/v1`（HTTPS）或 `http://<router_ip>:8080/api/v1`（HTTP）

---

## 目录

- [通用规范](#通用规范)
- [认证接口](#认证接口)
- [系统接口](#系统接口)
- [网络接口](#网络接口)
- [WiFi 接口](#wifi-接口)
- [DHCP/DNS 接口](#dhcpdns-接口)
- [防火墙接口](#防火墙接口)
- [错误码参考](#错误码参考)

---

## 通用规范

### 请求格式

- **Content-Type**：`application/json`
- **字符集**：UTF-8
- **认证方式**：HTTP Bearer Token

```
Authorization: Bearer <token>
```

### 响应格式

所有接口统一返回格式：

```json
{
  "code": 0,
  "message": "ok",
  "data": { ... }
}
```

### 通用字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `code` | int | 0 = 成功，非 0 = 错误 |
| `message` | string | 人类可读的状态描述 |
| `data` | object/array/null | 响应数据体 |

### CORS 支持

服务默认返回以下 CORS 头（可在配置中调整）：

```
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS
Access-Control-Allow-Headers: Content-Type, Authorization
```

---

## 认证接口

### POST /auth/token — 获取访问 Token

不需要认证。使用路由器管理员用户名密码换取 API Token。

**请求体：**

```json
{
  "username": "root",
  "password": "password"
}
```

**成功响应（200）：**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "token": "1711891234.root.a3f8b2c1d4e5f6a7b8c9d0e1f2a3b4c5",
    "expires_at": 1714483234,
    "expires_in": 2592000
  }
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `token` | string | 访问令牌（格式：`timestamp.user.signature`） |
| `expires_at` | int | Token 过期 Unix 时间戳 |
| `expires_in` | int | 有效期秒数（默认 30 天）|

**失败响应（401）：**

```json
{
  "code": 401,
  "message": "invalid credentials",
  "data": null
}
```

---

### DELETE /auth/token — 注销 Token

需要认证。注销当前 Token（服务端记录黑名单）。

**响应（200）：**

```json
{
  "code": 0,
  "message": "token revoked",
  "data": null
}
```

---

### POST /auth/refresh — 刷新 Token

需要认证。用有效的旧 Token 换取新 Token（延长有效期）。

**成功响应（200）：**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "token": "1712891234.root.d4e5f6a7b8c9...",
    "expires_at": 1715483234,
    "expires_in": 2592000
  }
}
```

---

## 系统接口

### GET /system/info — 系统基本信息

**响应示例：**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "hostname": "OpenWrt",
    "model": "Phicomm K3",
    "firmware_version": "R24.1.1",
    "kernel_version": "6.6.1",
    "arch": "aarch64_cortex-a53",
    "uptime": 86420,
    "uptime_human": "1 day, 0:00:20",
    "localtime": "2024-04-01 10:00:20",
    "timezone": "Asia/Shanghai"
  }
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `hostname` | string | 主机名 |
| `model` | string | 设备型号 |
| `firmware_version` | string | 固件版本 |
| `kernel_version` | string | Linux 内核版本 |
| `arch` | string | CPU 架构 |
| `uptime` | int | 已运行秒数 |
| `uptime_human` | string | 可读的运行时间 |
| `localtime` | string | 本地时间（ISO 8601）|
| `timezone` | string | 时区 |

---

### GET /system/status — 系统资源状态

**响应示例：**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "cpu": {
      "usage_percent": 12.5,
      "cores": 4,
      "frequency_mhz": 1800,
      "temperature_celsius": 45.2
    },
    "memory": {
      "total_kb": 524288,
      "free_kb": 312400,
      "used_kb": 211888,
      "usage_percent": 40.4,
      "buffers_kb": 8192,
      "cached_kb": 40960
    },
    "swap": {
      "total_kb": 0,
      "free_kb": 0
    },
    "load": {
      "1min": 0.12,
      "5min": 0.08,
      "15min": 0.05
    },
    "disk": [
      {
        "mountpoint": "/",
        "filesystem": "overlayfs",
        "total_kb": 51200,
        "used_kb": 30720,
        "free_kb": 20480,
        "usage_percent": 60.0
      }
    ]
  }
}
```

---

### POST /system/reboot — 重启设备

**请求体（可选）：**

```json
{
  "delay_seconds": 3
}
```

**响应：**

```json
{
  "code": 0,
  "message": "rebooting in 3 seconds",
  "data": null
}
```

---

### GET /system/logs — 系统日志

**查询参数：**

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `lines` | int | 100 | 返回最后 N 行 |
| `level` | string | all | 日志级别过滤：`debug`, `info`, `warn`, `error` |

**响应示例：**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "lines": [
      {
        "timestamp": "2024-04-01T10:00:00+08:00",
        "level": "info",
        "facility": "kernel",
        "message": "eth0: renamed from wan"
      }
    ],
    "total": 100
  }
}
```

---

### GET /system/upgrade/check — 检查固件更新

**响应示例：**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "current_version": "R24.1.1",
    "latest_version": "R24.2.0",
    "update_available": true,
    "changelog": "修复若干安全漏洞，更新内核至 6.6.2"
  }
}
```

---

## 网络接口

### GET /network/interfaces — 所有网络接口

**响应示例：**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "interfaces": [
      {
        "name": "wan",
        "device": "eth1",
        "proto": "dhcp",
        "up": true,
        "ipv4_address": "203.0.113.1",
        "ipv4_mask": "255.255.255.0",
        "ipv6_addresses": ["2001:db8::1/64"],
        "gateway": "203.0.113.254",
        "dns_servers": ["8.8.8.8", "8.8.4.4"],
        "rx_bytes": 12345678,
        "tx_bytes": 9876543,
        "uptime_seconds": 86400
      },
      {
        "name": "lan",
        "device": "br-lan",
        "proto": "static",
        "up": true,
        "ipv4_address": "192.168.1.1",
        "ipv4_mask": "255.255.255.0",
        "ipv6_addresses": [],
        "rx_bytes": 98765432,
        "tx_bytes": 123456789,
        "uptime_seconds": 86420
      }
    ]
  }
}
```

---

### GET /network/interfaces/{name} — 特定接口状态

**路径参数：** `name` — 接口名（如 `wan`, `lan`, `wlan0`）

**响应示例：** 同上单个接口对象

---

### POST /network/interfaces/{name}/up — 启用接口

**响应：**

```json
{
  "code": 0,
  "message": "interface wan is up",
  "data": null
}
```

---

### POST /network/interfaces/{name}/down — 禁用接口

**响应：**

```json
{
  "code": 0,
  "message": "interface wan is down",
  "data": null
}
```

---

### GET /network/traffic — 流量统计

**查询参数：**

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `interface` | string | all | 指定接口名，不填返回全部 |

**响应示例：**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "wan": {
      "rx_bytes": 12345678,
      "tx_bytes": 9876543,
      "rx_packets": 9876,
      "tx_packets": 6789,
      "rx_rate_bps": 1024000,
      "tx_rate_bps": 512000
    },
    "lan": {
      "rx_bytes": 98765432,
      "tx_bytes": 123456789,
      "rx_packets": 876543,
      "tx_packets": 123456,
      "rx_rate_bps": 2048000,
      "tx_rate_bps": 4096000
    }
  }
}
```

---

## WiFi 接口

### GET /wifi/status — WiFi 状态概览

**响应示例：**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "radios": [
      {
        "name": "radio0",
        "phy": "phy0",
        "band": "2.4GHz",
        "channel": 6,
        "frequency_mhz": 2437,
        "txpower_dbm": 20,
        "enabled": true,
        "interfaces": [
          {
            "ifname": "wlan0",
            "ssid": "HomeNetwork",
            "bssid": "AA:BB:CC:DD:EE:FF",
            "encryption": "psk2",
            "hidden": false,
            "mode": "ap",
            "clients": 3
          }
        ]
      },
      {
        "name": "radio1",
        "phy": "phy1",
        "band": "5GHz",
        "channel": 149,
        "frequency_mhz": 5745,
        "txpower_dbm": 23,
        "enabled": true,
        "interfaces": [
          {
            "ifname": "wlan1",
            "ssid": "HomeNetwork_5G",
            "bssid": "AA:BB:CC:DD:EE:00",
            "encryption": "psk2",
            "hidden": false,
            "mode": "ap",
            "clients": 2
          }
        ]
      }
    ]
  }
}
```

---

### GET /wifi/clients — 已连接 WiFi 客户端

**响应示例：**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "clients": [
      {
        "mac": "AA:BB:CC:11:22:33",
        "hostname": "android-device",
        "ip": "192.168.1.100",
        "interface": "wlan0",
        "ssid": "HomeNetwork",
        "signal_dbm": -60,
        "noise_dbm": -95,
        "snr_db": 35,
        "rx_rate_mbps": 144,
        "tx_rate_mbps": 72,
        "rx_bytes": 123456,
        "tx_bytes": 234567,
        "connected_seconds": 3600
      }
    ],
    "total": 1
  }
}
```

---

### POST /wifi/scan — 扫描周边 WiFi

**请求体（可选）：**

```json
{
  "radio": "radio0"
}
```

**响应示例：**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "networks": [
      {
        "ssid": "Neighbor_WiFi",
        "bssid": "11:22:33:44:55:66",
        "channel": 11,
        "frequency_mhz": 2462,
        "signal_dbm": -72,
        "quality": 38,
        "encryption": "psk2",
        "mode": "Master"
      }
    ],
    "total": 1
  }
}
```

---

### PUT /wifi/config — 修改 WiFi 配置

**请求体：**

```json
{
  "radio": "radio0",
  "ssid": "NewSSID",
  "password": "newpassword123",
  "encryption": "psk2",
  "hidden": false,
  "channel": "auto"
}
```

**响应：**

```json
{
  "code": 0,
  "message": "wifi configuration applied",
  "data": {
    "restart_required": true
  }
}
```

---

## DHCP/DNS 接口

### GET /dhcp/leases — DHCP 租约列表

**响应示例：**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "leases": [
      {
        "ip": "192.168.1.100",
        "mac": "AA:BB:CC:11:22:33",
        "hostname": "android-phone",
        "expires_at": 1714483234,
        "interface": "lan"
      }
    ],
    "total": 1
  }
}
```

---

### GET /dhcp/static — 静态 DHCP 绑定

**响应示例：**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "hosts": [
      {
        "name": "nas-server",
        "mac": "11:22:33:44:55:66",
        "ip": "192.168.1.50"
      }
    ]
  }
}
```

---

### POST /dhcp/static — 添加静态绑定

**请求体：**

```json
{
  "name": "my-device",
  "mac": "AA:BB:CC:DD:EE:FF",
  "ip": "192.168.1.200"
}
```

---

## 防火墙接口

### GET /firewall/rules — 防火墙规则列表

**响应示例：**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "rules": [
      {
        "name": "Allow-DHCP-Renew",
        "src": "wan",
        "dest": "",
        "proto": "udp",
        "src_port": "68",
        "dest_port": "67",
        "target": "ACCEPT",
        "enabled": true
      }
    ]
  }
}
```

---

### GET /firewall/port-forwards — 端口转发规则

**响应示例：**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "redirects": [
      {
        "name": "API-Remote",
        "src": "wan",
        "proto": "tcp",
        "src_dport": "8443",
        "dest_ip": "192.168.1.1",
        "dest_port": "8443",
        "enabled": true
      }
    ]
  }
}
```

---

### POST /firewall/port-forwards — 添加端口转发

**请求体：**

```json
{
  "name": "My-Forward",
  "proto": "tcp",
  "src_dport": "9000",
  "dest_ip": "192.168.1.100",
  "dest_port": "9000"
}
```

---

## 错误码参考

| code | HTTP Status | 说明 |
|------|-------------|------|
| 0 | 200 | 成功 |
| 400 | 400 | 请求参数错误 |
| 401 | 401 | 未认证（Token 缺失或无效） |
| 403 | 403 | 无权限执行此操作 |
| 404 | 404 | 接口不存在或资源未找到 |
| 429 | 429 | 请求频率超限（rate limit exceeded） |
| 500 | 500 | 服务器内部错误 |
| 503 | 503 | 依赖服务不可用（ubus/rpcd 未运行）|

### 错误响应示例

```json
{
  "code": 401,
  "message": "token expired",
  "data": {
    "expired_at": 1711891234,
    "hint": "call POST /api/v1/auth/token to get a new token"
  }
}
```

---

## SDK 示例代码

### Android (Kotlin)

```kotlin
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import org.json.JSONObject

class OpenWrtApiClient(
    private val baseUrl: String,
    private var token: String? = null
) {
    private val client = OkHttpClient.Builder()
        // 自签名证书：在生产环境中应替换为正式证书或证书固定
        .hostnameVerifier { _, _ -> true }
        .build()

    private val JSON = "application/json; charset=utf-8".toMediaType()

    fun login(username: String, password: String): String? {
        val body = JSONObject().apply {
            put("username", username)
            put("password", password)
        }
        val request = Request.Builder()
            .url("$baseUrl/auth/token")
            .post(RequestBody.create(JSON, body.toString()))
            .build()

        client.newCall(request).execute().use { response ->
            if (response.isSuccessful) {
                val json = JSONObject(response.body!!.string())
                token = json.getJSONObject("data").getString("token")
                return token
            }
        }
        return null
    }

    fun getSystemInfo(): JSONObject? {
        val request = Request.Builder()
            .url("$baseUrl/system/info")
            .header("Authorization", "Bearer $token")
            .get()
            .build()

        client.newCall(request).execute().use { response ->
            if (response.isSuccessful) {
                val json = JSONObject(response.body!!.string())
                if (json.getInt("code") == 0) {
                    return json.getJSONObject("data")
                }
            }
        }
        return null
    }
}

// 使用示例
val api = OpenWrtApiClient("https://192.168.1.1:8443/api/v1")
api.login("root", "password")
val info = api.getSystemInfo()
println("Hostname: ${info?.getString("hostname")}")
```

### 微信小程序 (JavaScript)

```javascript
// utils/openwrt-api.js
const BASE_URL = 'https://your-domain.com:8443/api/v1';
let token = wx.getStorageSync('openwrt_token');

function request(method, path, data) {
  return new Promise((resolve, reject) => {
    wx.request({
      url: `${BASE_URL}${path}`,
      method: method,
      data: data,
      header: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${token}`
      },
      success: (res) => {
        if (res.data.code === 0) {
          resolve(res.data.data);
        } else if (res.data.code === 401) {
          // Token 失效，跳转登录页
          wx.navigateTo({ url: '/pages/login/login' });
          reject(new Error('unauthorized'));
        } else {
          reject(new Error(res.data.message));
        }
      },
      fail: reject
    });
  });
}

export async function login(username, password) {
  const res = await new Promise((resolve, reject) => {
    wx.request({
      url: `${BASE_URL}/auth/token`,
      method: 'POST',
      data: { username, password },
      header: { 'Content-Type': 'application/json' },
      success: (res) => resolve(res.data),
      fail: reject
    });
  });
  if (res.code === 0) {
    token = res.data.token;
    wx.setStorageSync('openwrt_token', token);
    return token;
  }
  throw new Error(res.message);
}

export const getSystemInfo = () => request('GET', '/system/info', null);
export const getSystemStatus = () => request('GET', '/system/status', null);
export const getInterfaces = () => request('GET', '/network/interfaces', null);
export const getWifiStatus = () => request('GET', '/wifi/status', null);
export const getWifiClients = () => request('GET', '/wifi/clients', null);
export const getDhcpLeases = () => request('GET', '/dhcp/leases', null);
export const reboot = () => request('POST', '/system/reboot', {});
```
