# 微信小程序集成开发指南

> 适用于微信小程序访问 OpenWrt 远程管理 API

---

## 目录

1. [微信小程序限制与解决方案](#1-微信小程序限制与解决方案)
2. [网络配置](#2-网络配置)
3. [API 封装模块](#3-api-封装模块)
4. [页面示例](#4-页面示例)
5. [数据存储与 Token 管理](#5-数据存储与-token-管理)
6. [错误处理](#6-错误处理)
7. [最佳实践](#7-最佳实践)

---

## 1. 微信小程序限制与解决方案

### 1.1 主要限制

| 限制 | 说明 | 解决方案 |
|------|------|---------|
| **HTTPS 必须** | 小程序只允许访问 HTTPS 接口 | 路由器 API 开启 HTTPS（端口 8443）|
| **合法域名校验** | 请求域名需在微信后台配置为合法域名 | 使用 DDNS 域名 + 配置到微信后台 |
| **无法访问内网 IP** | 生产环境不能直接访问 192.168.1.1 | 使用 DDNS 域名或云中继 |
| **无法使用 VPN** | 不支持系统 VPN | 使用云中继方案 |

### 1.2 推荐方案：云中继 + DDNS

```
微信小程序
    │  HTTPS（合法域名）
    ▼
中继服务器（公网云主机）
your-domain.com:443
    │  WebSocket（路由器主动连接）
    ▼
路由器 relay-client（LAN 内）
    │  本地调用
    ▼
API 服务（192.168.1.1:8443）
```

### 1.3 开发阶段（本地调试）

开发时可在微信开发者工具中勾选 **"不校验合法域名"**，直接访问局域网 IP：

```javascript
// 开发配置
const CONFIG = {
  baseUrl: 'https://192.168.1.1:8443/api/v1',  // 开发时直接访问内网
  ignoreSslError: true  // 开发者工具中允许忽略 SSL 错误
};
```

---

## 2. 网络配置

### 2.1 微信小程序后台配置

1. 登录 [微信公众平台](https://mp.weixin.qq.com)
2. 进入 **开发** → **开发管理** → **开发设置**
3. 在 **服务器域名** → **request 合法域名** 中添加：
   - `https://your-router-domain.com`（DDNS 域名或云中继域名）
4. 保存并重新发布小程序

### 2.2 云中继服务器 nginx 配置示例

```nginx
# /etc/nginx/conf.d/openwrt-relay.conf
server {
    listen 443 ssl;
    server_name your-router-domain.com;

    ssl_certificate /etc/letsencrypt/live/your-router-domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/your-router-domain.com/privkey.pem;

    # 代理 API 请求到通过 WebSocket 连接的路由器
    location /api/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 30s;
    }

    # WebSocket 中继端点（路由器 relay-client 连接到这里）
    location /relay/ {
        proxy_pass http://127.0.0.1:8765;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
    }
}
```

---

## 3. API 封装模块

### 3.1 配置文件

```javascript
// config/api.js
const isDev = __wxConfig.envVersion === 'develop';

module.exports = {
  // 生产环境使用云中继域名，开发时可使用内网 IP
  BASE_URL: isDev
    ? 'https://192.168.1.1:8443/api/v1'
    : 'https://your-router-domain.com/api/v1',

  // 开发时忽略 SSL 证书验证（仅限开发阶段）
  IGNORE_SSL: isDev,

  // Token 在本地存储的 key
  TOKEN_STORAGE_KEY: 'openwrt_api_token',
  TOKEN_EXPIRES_KEY: 'openwrt_token_expires',
  ROUTER_URL_KEY: 'openwrt_router_url',

  // 请求超时（毫秒）
  TIMEOUT: 15000,
};
```

### 3.2 HTTP 请求封装

```javascript
// utils/request.js
const config = require('../config/api');

// 存储 token
let cachedToken = wx.getStorageSync(config.TOKEN_STORAGE_KEY) || null;

/**
 * 基础请求方法
 */
function request(options) {
  return new Promise((resolve, reject) => {
    const token = cachedToken || wx.getStorageSync(config.TOKEN_STORAGE_KEY);

    wx.request({
      url: `${config.BASE_URL}${options.url}`,
      method: options.method || 'GET',
      data: options.data || null,
      header: {
        'Content-Type': 'application/json',
        'Authorization': token ? `Bearer ${token}` : '',
        ...(options.headers || {})
      },
      timeout: config.TIMEOUT,
      success(res) {
        const { statusCode, data } = res;

        if (statusCode === 200 && data.code === 0) {
          resolve(data.data);
        } else if (statusCode === 401 || data.code === 401) {
          // Token 过期，跳转登录
          cachedToken = null;
          wx.removeStorageSync(config.TOKEN_STORAGE_KEY);
          wx.navigateTo({ url: '/pages/login/login' });
          reject(new Error('token_expired'));
        } else if (statusCode === 429) {
          reject(new Error('rate_limit_exceeded'));
        } else {
          reject(new Error(data.message || `HTTP ${statusCode}`));
        }
      },
      fail(err) {
        if (err.errMsg && err.errMsg.includes('timeout')) {
          reject(new Error('请求超时，请检查网络连接'));
        } else if (err.errMsg && err.errMsg.includes('ssl')) {
          reject(new Error('SSL 证书验证失败'));
        } else {
          reject(new Error(err.errMsg || '网络请求失败'));
        }
      }
    });
  });
}

module.exports = { request };
```

### 3.3 认证 API

```javascript
// api/auth.js
const { request } = require('../utils/request');
const config = require('../config/api');

/**
 * 登录获取 Token
 */
async function login(username, password) {
  return new Promise((resolve, reject) => {
    wx.request({
      url: `${config.BASE_URL}/auth/token`,
      method: 'POST',
      data: { username, password },
      header: { 'Content-Type': 'application/json' },
      timeout: config.TIMEOUT,
      success(res) {
        if (res.statusCode === 200 && res.data.code === 0) {
          const { token, expires_at } = res.data.data;

          // 持久化存储 Token
          wx.setStorageSync(config.TOKEN_STORAGE_KEY, token);
          wx.setStorageSync(config.TOKEN_EXPIRES_KEY, expires_at);

          resolve(res.data.data);
        } else {
          reject(new Error(res.data.message || '登录失败'));
        }
      },
      fail(err) {
        reject(new Error(err.errMsg || '网络错误'));
      }
    });
  });
}

/**
 * 注销
 */
async function logout() {
  try {
    await request({ url: '/auth/token', method: 'DELETE' });
  } finally {
    wx.removeStorageSync(config.TOKEN_STORAGE_KEY);
    wx.removeStorageSync(config.TOKEN_EXPIRES_KEY);
  }
}

/**
 * 检查 Token 是否有效
 */
function isTokenValid() {
  const token = wx.getStorageSync(config.TOKEN_STORAGE_KEY);
  const expiresAt = wx.getStorageSync(config.TOKEN_EXPIRES_KEY);
  if (!token || !expiresAt) return false;
  return Math.floor(Date.now() / 1000) < (expiresAt - 300); // 提前 5 分钟认为过期
}

module.exports = { login, logout, isTokenValid };
```

### 3.4 系统 API

```javascript
// api/system.js
const { request } = require('../utils/request');

module.exports = {
  /** 获取系统信息 */
  getInfo: () => request({ url: '/system/info' }),

  /** 获取系统状态（CPU、内存、负载）*/
  getStatus: () => request({ url: '/system/status' }),

  /** 获取系统日志 */
  getLogs: (lines = 50) => request({ url: `/system/logs?lines=${lines}` }),

  /** 重启路由器 */
  reboot: () => request({ url: '/system/reboot', method: 'POST', data: {} }),

  /** 检查固件更新 */
  checkUpgrade: () => request({ url: '/system/upgrade/check' }),
};
```

### 3.5 网络 API

```javascript
// api/network.js
const { request } = require('../utils/request');

module.exports = {
  /** 获取所有网络接口 */
  getInterfaces: () => request({ url: '/network/interfaces' }),

  /** 获取指定接口 */
  getInterface: (name) => request({ url: `/network/interfaces/${name}` }),

  /** 获取流量统计 */
  getTraffic: (iface) => request({
    url: iface ? `/network/traffic?interface=${iface}` : '/network/traffic'
  }),

  /** 启用接口 */
  ifUp: (name) => request({ url: `/network/interfaces/${name}/up`, method: 'POST' }),

  /** 禁用接口 */
  ifDown: (name) => request({ url: `/network/interfaces/${name}/down`, method: 'POST' }),
};
```

### 3.6 WiFi API

```javascript
// api/wifi.js
const { request } = require('../utils/request');

module.exports = {
  /** 获取 WiFi 状态 */
  getStatus: () => request({ url: '/wifi/status' }),

  /** 获取已连接客户端 */
  getClients: () => request({ url: '/wifi/clients' }),

  /** 扫描周边 WiFi */
  scan: (radio) => request({
    url: '/wifi/scan',
    method: 'POST',
    data: radio ? { radio } : {}
  }),

  /** 修改 WiFi 配置 */
  setConfig: (cfg) => request({
    url: '/wifi/config',
    method: 'PUT',
    data: cfg
  }),
};
```

---

## 4. 页面示例

### 4.1 登录页面

```javascript
// pages/login/login.js
const authApi = require('../../api/auth');
const config = require('../../config/api');

Page({
  data: {
    routerUrl: wx.getStorageSync(config.ROUTER_URL_KEY) || 'https://your-domain.com',
    username: 'root',
    password: '',
    loading: false,
    errorMsg: ''
  },

  onLoad() {
    // 已登录则跳转首页
    if (authApi.isTokenValid()) {
      wx.switchTab({ url: '/pages/index/index' });
    }
  },

  async onLogin() {
    const { routerUrl, username, password } = this.data;
    if (!password) {
      this.setData({ errorMsg: '请输入密码' });
      return;
    }

    // 保存路由器地址
    wx.setStorageSync(config.ROUTER_URL_KEY, routerUrl);

    this.setData({ loading: true, errorMsg: '' });
    try {
      await authApi.login(username, password);
      wx.showToast({ title: '登录成功', icon: 'success' });
      wx.switchTab({ url: '/pages/index/index' });
    } catch (e) {
      this.setData({ errorMsg: e.message || '登录失败，请检查用户名和密码' });
    } finally {
      this.setData({ loading: false });
    }
  },

  onInputRouterUrl(e) { this.setData({ routerUrl: e.detail.value }); },
  onInputUsername(e) { this.setData({ username: e.detail.value }); },
  onInputPassword(e) { this.setData({ password: e.detail.value }); }
});
```

```xml
<!-- pages/login/login.wxml -->
<view class="container">
  <view class="logo">
    <image src="/images/openwrt-logo.png" mode="aspectFit" />
    <text class="title">OpenWrt 管理</text>
  </view>

  <view class="form">
    <view class="form-item">
      <text class="label">路由器地址</text>
      <input
        class="input"
        value="{{routerUrl}}"
        placeholder="https://your-domain.com"
        bindinput="onInputRouterUrl"
      />
    </view>

    <view class="form-item">
      <text class="label">用户名</text>
      <input
        class="input"
        value="{{username}}"
        placeholder="root"
        bindinput="onInputUsername"
      />
    </view>

    <view class="form-item">
      <text class="label">密码</text>
      <input
        class="input"
        type="password"
        placeholder="路由器密码"
        bindinput="onInputPassword"
      />
    </view>

    <text class="error" wx:if="{{errorMsg}}">{{errorMsg}}</text>

    <button
      class="btn-login"
      loading="{{loading}}"
      bindtap="onLogin"
      disabled="{{loading}}"
    >
      {{loading ? '登录中...' : '登录'}}
    </button>
  </view>
</view>
```

### 4.2 概览仪表盘页面

```javascript
// pages/index/index.js
const systemApi = require('../../api/system');
const networkApi = require('../../api/network');

Page({
  data: {
    systemInfo: null,
    systemStatus: null,
    interfaces: [],
    loading: true,
    refreshing: false
  },

  onLoad() {
    this.loadDashboard();
  },

  onPullDownRefresh() {
    this.setData({ refreshing: true });
    this.loadDashboard().finally(() => {
      this.setData({ refreshing: false });
      wx.stopPullDownRefresh();
    });
  },

  async loadDashboard() {
    this.setData({ loading: true });
    try {
      const [info, status, ifacesData] = await Promise.all([
        systemApi.getInfo(),
        systemApi.getStatus(),
        networkApi.getInterfaces()
      ]);

      this.setData({
        systemInfo: info,
        systemStatus: {
          ...status,
          cpuPercent: Math.round(status.cpu.usage_percent),
          memPercent: Math.round(status.memory.usage_percent),
          memUsedMB: Math.round(status.memory.used_kb / 1024),
          memTotalMB: Math.round(status.memory.total_kb / 1024)
        },
        interfaces: ifacesData.interfaces || []
      });
    } catch (e) {
      wx.showToast({ title: e.message || '加载失败', icon: 'none' });
    } finally {
      this.setData({ loading: false });
    }
  },

  onReboot() {
    wx.showModal({
      title: '确认重启',
      content: '确定要重启路由器吗？重启后约需 60 秒恢复。',
      confirmText: '确定重启',
      confirmColor: '#e74c3c',
      success: async (res) => {
        if (res.confirm) {
          try {
            await systemApi.reboot();
            wx.showToast({ title: '路由器正在重启', icon: 'none' });
          } catch (e) {
            wx.showToast({ title: e.message, icon: 'none' });
          }
        }
      }
    });
  },

  formatBytes(bytes) {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
    return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }
});
```

```xml
<!-- pages/index/index.wxml -->
<view class="dashboard">
  <view wx:if="{{loading}}" class="loading">
    <view class="loading-spinner" />
    <text>加载中...</text>
  </view>

  <block wx:else>
    <!-- 设备信息卡片 -->
    <view class="card">
      <view class="card-header">
        <text class="card-title">{{systemInfo.hostname}}</text>
        <text class="badge badge-online">在线</text>
      </view>
      <view class="card-body info-grid">
        <view class="info-item">
          <text class="info-label">型号</text>
          <text class="info-value">{{systemInfo.model}}</text>
        </view>
        <view class="info-item">
          <text class="info-label">固件</text>
          <text class="info-value">{{systemInfo.firmware_version}}</text>
        </view>
        <view class="info-item">
          <text class="info-label">运行时间</text>
          <text class="info-value">{{systemInfo.uptime_human}}</text>
        </view>
        <view class="info-item">
          <text class="info-label">本地时间</text>
          <text class="info-value">{{systemInfo.localtime}}</text>
        </view>
      </view>
    </view>

    <!-- 资源使用卡片 -->
    <view class="card" wx:if="{{systemStatus}}">
      <view class="card-header">
        <text class="card-title">资源使用</text>
      </view>
      <view class="card-body">
        <!-- CPU 进度条 -->
        <view class="resource-item">
          <view class="resource-label">
            <text>CPU</text>
            <text>{{systemStatus.cpuPercent}}%</text>
          </view>
          <progress
            percent="{{systemStatus.cpuPercent}}"
            stroke-width="8"
            color="{{systemStatus.cpuPercent > 80 ? '#e74c3c' : '#2ecc71'}}"
          />
        </view>

        <!-- 内存进度条 -->
        <view class="resource-item">
          <view class="resource-label">
            <text>内存 {{systemStatus.memUsedMB}}MB / {{systemStatus.memTotalMB}}MB</text>
            <text>{{systemStatus.memPercent}}%</text>
          </view>
          <progress
            percent="{{systemStatus.memPercent}}"
            stroke-width="8"
            color="{{systemStatus.memPercent > 80 ? '#e74c3c' : '#3498db'}}"
          />
        </view>
      </view>
    </view>

    <!-- 网络接口卡片 -->
    <view class="card">
      <view class="card-header">
        <text class="card-title">网络接口</text>
      </view>
      <view class="card-body">
        <view class="interface-item" wx:for="{{interfaces}}" wx:key="name">
          <view class="if-header">
            <view class="if-status {{item.up ? 'up' : 'down'}}" />
            <text class="if-name">{{item.name}} ({{item.device}})</text>
          </view>
          <text class="if-ip" wx:if="{{item.ipv4_address}}">{{item.ipv4_address}}</text>
        </view>
      </view>
    </view>

    <!-- 操作按钮 -->
    <view class="action-buttons">
      <button class="btn btn-danger" bindtap="onReboot">重启路由器</button>
    </view>
  </block>
</view>
```

---

## 5. 数据存储与 Token 管理

```javascript
// utils/storage.js
const config = require('../config/api');

module.exports = {
  saveToken(token, expiresAt) {
    wx.setStorageSync(config.TOKEN_STORAGE_KEY, token);
    wx.setStorageSync(config.TOKEN_EXPIRES_KEY, expiresAt);
  },

  getToken() {
    return wx.getStorageSync(config.TOKEN_STORAGE_KEY) || null;
  },

  clearToken() {
    wx.removeStorageSync(config.TOKEN_STORAGE_KEY);
    wx.removeStorageSync(config.TOKEN_EXPIRES_KEY);
  },

  isTokenValid() {
    const token = this.getToken();
    if (!token) return false;
    const expiresAt = wx.getStorageSync(config.TOKEN_EXPIRES_KEY);
    return expiresAt && Math.floor(Date.now() / 1000) < (expiresAt - 300);
  },

  saveRouterUrl(url) {
    wx.setStorageSync(config.ROUTER_URL_KEY, url);
  },

  getRouterUrl() {
    return wx.getStorageSync(config.ROUTER_URL_KEY) || config.BASE_URL;
  }
};
```

---

## 6. 错误处理

```javascript
// utils/error.js
/**
 * 统一错误处理
 */
function handleApiError(error) {
  const msg = error.message || '未知错误';

  const errorMap = {
    'token_expired': '登录已过期，请重新登录',
    'rate_limit_exceeded': '操作太频繁，请稍后再试',
    '网络请求失败': '无法连接到路由器，请检查网络',
    'timeout': '请求超时，请检查网络连接',
    'invalid credentials': '用户名或密码错误',
    'unauthorized': '无权限，请重新登录',
  };

  for (const [key, friendlyMsg] of Object.entries(errorMap)) {
    if (msg.includes(key)) {
      return friendlyMsg;
    }
  }

  return msg;
}

/**
 * 显示错误提示
 */
function showError(error) {
  const friendlyMsg = handleApiError(error);
  wx.showToast({
    title: friendlyMsg,
    icon: 'none',
    duration: 3000
  });
}

module.exports = { handleApiError, showError };
```

---

## 7. 最佳实践

### 7.1 小程序分包加载

将路由器管理功能放入子包，减少主包体积：

```json
// app.json
{
  "pages": [
    "pages/login/login",
    "pages/index/index"
  ],
  "subpackages": [
    {
      "root": "packages/router",
      "pages": [
        "pages/wifi/wifi",
        "pages/dhcp/dhcp",
        "pages/firewall/firewall",
        "pages/logs/logs"
      ]
    }
  ]
}
```

### 7.2 数据缓存策略

```javascript
// 对不频繁变化的数据做本地缓存（如系统信息）
async function getCachedSystemInfo(maxAge = 30) {
  const cached = wx.getStorageSync('cached_system_info');
  const cachedAt = wx.getStorageSync('cached_system_info_at');
  const now = Math.floor(Date.now() / 1000);

  if (cached && cachedAt && (now - cachedAt) < maxAge) {
    return JSON.parse(cached);
  }

  const fresh = await systemApi.getInfo();
  wx.setStorageSync('cached_system_info', JSON.stringify(fresh));
  wx.setStorageSync('cached_system_info_at', now);
  return fresh;
}
```

### 7.3 轮询实时数据

```javascript
// 定时轮询系统状态（每 5 秒）
let pollingTimer = null;

function startPolling(callback, interval = 5000) {
  if (pollingTimer) clearInterval(pollingTimer);
  pollingTimer = setInterval(async () => {
    try {
      const status = await systemApi.getStatus();
      callback(null, status);
    } catch (e) {
      callback(e, null);
    }
  }, interval);
  return pollingTimer;
}

function stopPolling() {
  if (pollingTimer) {
    clearInterval(pollingTimer);
    pollingTimer = null;
  }
}

// 在页面隐藏时停止轮询
// onHide() { stopPolling(); }
// 在页面显示时重启轮询
// onShow() { startPolling(this.onStatusUpdate.bind(this)); }
```

### 7.4 网络状态检测

```javascript
// 检测网络类型，提示用户
wx.getNetworkType({
  success(res) {
    if (res.networkType === 'none') {
      wx.showToast({ title: '无网络连接', icon: 'none' });
    } else if (res.networkType === '2g' || res.networkType === '3g') {
      wx.showToast({ title: '网络信号较弱，可能影响连接', icon: 'none' });
    }
  }
});

// 监听网络状态变化
wx.onNetworkStatusChange((res) => {
  if (!res.isConnected) {
    wx.showToast({ title: '网络已断开', icon: 'none' });
  }
});
```
