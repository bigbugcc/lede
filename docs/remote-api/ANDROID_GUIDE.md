# Android 集成开发指南

> 适用于 Android 原生应用（Kotlin/Java）集成 OpenWrt 远程 API

---

## 目录

1. [环境要求](#1-环境要求)
2. [网络接入方案](#2-网络接入方案)
3. [依赖配置](#3-依赖配置)
4. [API 客户端实现](#4-api-客户端实现)
5. [WireGuard VPN 集成](#5-wireguard-vpn-集成)
6. [示例 Activity 实现](#6-示例-activity-实现)
7. [最佳实践](#7-最佳实践)

---

## 1. 环境要求

- Android API Level ≥ 21 (Android 5.0+)
- Kotlin 1.8+ 或 Java 11+
- Gradle 7.0+
- 网络权限：`INTERNET`, `ACCESS_NETWORK_STATE`

---

## 2. 网络接入方案

### 方案 A：DDNS + 端口转发（推荐，延迟最低）

```
Android App → DDNS域名:8443 → ISP公网IP:8443 → 路由器:8443
```

**优点：** 低延迟，无中间服务器  
**适用：** 运营商支持端口映射的网络

### 方案 B：WireGuard VPN（安全性最高）

```
Android App
  [WireGuard Android Library]
        │  UDP VPN 隧道
        ▼
路由器 WireGuard Server (UDP 51820)
        │
   访问 192.168.1.1:8443
```

**优点：** 端对端加密，不需要暴露管理端口  
**缺点：** 需要集成 WireGuard SDK

### 方案 C：云中继（无需公网 IP）

```
Android App → 云中继:443 → WebSocket → 路由器
```

**优点：** 适合无公网 IP 场景  

---

## 3. 依赖配置

在 `build.gradle.kts` 中添加：

```kotlin
dependencies {
    // HTTP 客户端
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")

    // JSON 序列化（Kotlinx 序列化）
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")

    // 协程
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")

    // ViewModel + LiveData
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.7.0")
    implementation("androidx.lifecycle:lifecycle-livedata-ktx:2.7.0")

    // 可选：WireGuard VPN
    implementation("com.wireguard.android:tunnel:1.0.20230706")
}
```

在 `AndroidManifest.xml` 中添加权限：

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<!-- WireGuard VPN（方案B） -->
<uses-permission android:name="android.permission.BIND_VPN_SERVICE" />
```

---

## 4. API 客户端实现

### 4.1 数据模型

```kotlin
// models/ApiModels.kt
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName

@Serializable
data class ApiResponse<T>(
    val code: Int,
    val message: String,
    val data: T? = null
)

@Serializable
data class AuthToken(
    val token: String,
    @SerialName("expires_at") val expiresAt: Long,
    @SerialName("expires_in") val expiresIn: Int
)

@Serializable
data class SystemInfo(
    val hostname: String,
    val model: String,
    @SerialName("firmware_version") val firmwareVersion: String,
    @SerialName("kernel_version") val kernelVersion: String,
    val arch: String,
    val uptime: Long,
    @SerialName("uptime_human") val uptimeHuman: String,
    val localtime: String,
    val timezone: String
)

@Serializable
data class SystemStatus(
    val cpu: CpuInfo,
    val memory: MemoryInfo,
    val load: LoadInfo
)

@Serializable
data class CpuInfo(
    @SerialName("usage_percent") val usagePercent: Double,
    val cores: Int,
    @SerialName("frequency_mhz") val frequencyMhz: Int,
    @SerialName("temperature_celsius") val temperatureCelsius: Double? = null
)

@Serializable
data class MemoryInfo(
    @SerialName("total_kb") val totalKb: Long,
    @SerialName("free_kb") val freeKb: Long,
    @SerialName("used_kb") val usedKb: Long,
    @SerialName("usage_percent") val usagePercent: Double
)

@Serializable
data class LoadInfo(
    @SerialName("1min") val oneMin: Double,
    @SerialName("5min") val fiveMin: Double,
    @SerialName("15min") val fifteenMin: Double
)

@Serializable
data class NetworkInterface(
    val name: String,
    val device: String,
    val proto: String,
    val up: Boolean,
    @SerialName("ipv4_address") val ipv4Address: String? = null,
    @SerialName("ipv4_mask") val ipv4Mask: String? = null,
    val gateway: String? = null,
    @SerialName("dns_servers") val dnsServers: List<String> = emptyList(),
    @SerialName("rx_bytes") val rxBytes: Long = 0,
    @SerialName("tx_bytes") val txBytes: Long = 0
)

@Serializable
data class WifiClient(
    val mac: String,
    val hostname: String? = null,
    val ip: String? = null,
    val interface_name: String,
    val ssid: String,
    @SerialName("signal_dbm") val signalDbm: Int,
    @SerialName("rx_rate_mbps") val rxRateMbps: Double,
    @SerialName("tx_rate_mbps") val txRateMbps: Double,
    @SerialName("connected_seconds") val connectedSeconds: Long
)

@Serializable
data class DhcpLease(
    val ip: String,
    val mac: String,
    val hostname: String? = null,
    @SerialName("expires_at") val expiresAt: Long
)
```

### 4.2 Token 存储

```kotlin
// storage/TokenStorage.kt
import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

class TokenStorage(context: Context) {
    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()

    private val prefs = EncryptedSharedPreferences.create(
        context,
        "openwrt_token_prefs",
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )

    var token: String?
        get() = prefs.getString("token", null)
        set(value) = prefs.edit().putString("token", value).apply()

    var expiresAt: Long
        get() = prefs.getLong("expires_at", 0L)
        set(value) = prefs.edit().putLong("expires_at", value).apply()

    var routerUrl: String
        get() = prefs.getString("router_url", "https://192.168.1.1:8443") ?: "https://192.168.1.1:8443"
        set(value) = prefs.edit().putString("router_url", value).apply()

    fun isTokenValid(): Boolean {
        val tok = token ?: return false
        return tok.isNotEmpty() && System.currentTimeMillis() / 1000 < expiresAt - 300
    }

    fun clear() {
        prefs.edit().clear().apply()
    }
}
```

### 4.3 HTTP 客户端（支持自签名证书）

```kotlin
// network/OpenWrtHttpClient.kt
import okhttp3.*
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.*

object OpenWrtHttpClient {

    /**
     * 创建信任自签名证书的 OkHttpClient
     * 在生产环境中，建议改为证书固定（Certificate Pinning）以防止中间人攻击
     */
    fun createTrustAllClient(): OkHttpClient {
        val trustAllCerts = arrayOf<TrustManager>(object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {}
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {}
            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        })

        val sslContext = SSLContext.getInstance("TLS").apply {
            init(null, trustAllCerts, java.security.SecureRandom())
        }

        return OkHttpClient.Builder()
            .sslSocketFactory(sslContext.socketFactory, trustAllCerts[0] as X509TrustManager)
            .hostnameVerifier { _, _ -> true }
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(10, TimeUnit.SECONDS)
            .addInterceptor(HttpLoggingInterceptor().apply {
                level = HttpLoggingInterceptor.Level.BODY
            })
            .build()
    }

    /**
     * 推荐：证书固定（记录服务器证书指纹，防止中间人攻击）
     * 首次连接时调用 saveCertificatePin(url) 记录指纹
     */
    fun createPinnedClient(pin: String): OkHttpClient {
        val certificatePinner = CertificatePinner.Builder()
            .add("your-router-domain.com", pin)
            .build()
        return OkHttpClient.Builder()
            .certificatePinner(certificatePinner)
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
    }
}
```

### 4.4 API 服务类

```kotlin
// network/OpenWrtApiService.kt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody

class OpenWrtApiService(
    private val storage: TokenStorage,
    private val httpClient: OkHttpClient = OpenWrtHttpClient.createTrustAllClient()
) {
    private val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()
    private val json = Json { ignoreUnknownKeys = true }

    private val baseUrl get() = "${storage.routerUrl}/api/v1"

    private fun buildRequest(method: String, path: String, body: String? = null): Request {
        val builder = Request.Builder()
            .url("$baseUrl$path")
            .header("Authorization", "Bearer ${storage.token ?: ""}")

        when (method.uppercase()) {
            "GET" -> builder.get()
            "POST" -> builder.post((body ?: "{}").toRequestBody(JSON_MEDIA))
            "PUT" -> builder.put((body ?: "{}").toRequestBody(JSON_MEDIA))
            "DELETE" -> builder.delete()
        }
        return builder.build()
    }

    private suspend inline fun <reified T> execute(request: Request): Result<T> =
        withContext(Dispatchers.IO) {
            runCatching {
                httpClient.newCall(request).execute().use { response ->
                    val bodyStr = response.body?.string() ?: throw Exception("empty response")
                    val apiResponse = json.decodeFromString<ApiResponse<T>>(bodyStr)
                    if (apiResponse.code != 0) throw Exception(apiResponse.message)
                    apiResponse.data ?: throw Exception("null data")
                }
            }
        }

    suspend fun login(username: String, password: String): Result<AuthToken> =
        withContext(Dispatchers.IO) {
            runCatching {
                val body = """{"username":"$username","password":"$password"}"""
                val request = Request.Builder()
                    .url("$baseUrl/auth/token")
                    .post(body.toRequestBody(JSON_MEDIA))
                    .build()
                httpClient.newCall(request).execute().use { response ->
                    val bodyStr = response.body?.string() ?: throw Exception("empty response")
                    val apiResponse = json.decodeFromString<ApiResponse<AuthToken>>(bodyStr)
                    if (apiResponse.code != 0) throw Exception(apiResponse.message)
                    val authToken = apiResponse.data ?: throw Exception("null token")
                    storage.token = authToken.token
                    storage.expiresAt = authToken.expiresAt
                    authToken
                }
            }
        }

    suspend fun logout(): Result<Unit> =
        execute<Unit>(buildRequest("DELETE", "/auth/token"))

    suspend fun getSystemInfo(): Result<SystemInfo> =
        execute(buildRequest("GET", "/system/info"))

    suspend fun getSystemStatus(): Result<SystemStatus> =
        execute(buildRequest("GET", "/system/status"))

    suspend fun reboot(): Result<Unit> =
        execute<Unit>(buildRequest("POST", "/system/reboot"))

    suspend fun getNetworkInterfaces(): Result<List<NetworkInterface>> =
        withContext(Dispatchers.IO) {
            runCatching {
                val request = buildRequest("GET", "/network/interfaces")
                httpClient.newCall(request).execute().use { response ->
                    val bodyStr = response.body?.string() ?: throw Exception("empty response")
                    data class InterfacesWrapper(val interfaces: List<NetworkInterface>)
                    val apiResponse = json.decodeFromString<ApiResponse<InterfacesWrapper>>(bodyStr)
                    if (apiResponse.code != 0) throw Exception(apiResponse.message)
                    apiResponse.data?.interfaces ?: emptyList()
                }
            }
        }

    suspend fun getWifiClients(): Result<List<WifiClient>> =
        withContext(Dispatchers.IO) {
            runCatching {
                val request = buildRequest("GET", "/wifi/clients")
                httpClient.newCall(request).execute().use { response ->
                    val bodyStr = response.body?.string() ?: throw Exception("empty response")
                    data class ClientsWrapper(val clients: List<WifiClient>)
                    val apiResponse = json.decodeFromString<ApiResponse<ClientsWrapper>>(bodyStr)
                    if (apiResponse.code != 0) throw Exception(apiResponse.message)
                    apiResponse.data?.clients ?: emptyList()
                }
            }
        }

    suspend fun getDhcpLeases(): Result<List<DhcpLease>> =
        withContext(Dispatchers.IO) {
            runCatching {
                val request = buildRequest("GET", "/dhcp/leases")
                httpClient.newCall(request).execute().use { response ->
                    val bodyStr = response.body?.string() ?: throw Exception("empty response")
                    data class LeasesWrapper(val leases: List<DhcpLease>)
                    val apiResponse = json.decodeFromString<ApiResponse<LeasesWrapper>>(bodyStr)
                    if (apiResponse.code != 0) throw Exception(apiResponse.message)
                    apiResponse.data?.leases ?: emptyList()
                }
            }
        }
}
```

---

## 5. WireGuard VPN 集成

以下代码展示了如何在 Android 应用中以编程方式管理 WireGuard VPN（适用于方案 B）：

```kotlin
// vpn/WireGuardManager.kt
import android.content.Context
import android.content.Intent
import android.net.VpnService
import com.wireguard.android.backend.*
import com.wireguard.config.*

class WireGuardManager(private val context: Context) {

    /**
     * 从路由器 API 获取 WireGuard 配置并建立 VPN 连接
     * 路由器生成的配置可从 /api/v1/vpn/wireguard/client-config 获取
     */
    suspend fun connect(configString: String): Boolean {
        val config = Config.parse(configString.reader().buffered())
        // 在实际 App 中使用 WireGuard Android Library 建立 VPN 隧道
        // 参考：https://github.com/WireGuard/wireguard-android
        return true
    }

    /**
     * 启动 VPN 授权请求
     */
    fun requestVpnPermission(activity: android.app.Activity, requestCode: Int) {
        val intent = VpnService.prepare(context)
        if (intent != null) {
            activity.startActivityForResult(intent, requestCode)
        }
    }
}
```

---

## 6. 示例 Activity 实现

```kotlin
// MainActivity.kt
import android.os.Bundle
import android.view.View
import android.widget.TextView
import android.widget.Toast
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.launch

class RouterViewModel(
    private val api: OpenWrtApiService
) : ViewModel() {

    fun loadDashboard(onResult: (SystemInfo?, SystemStatus?) -> Unit) {
        viewModelScope.launch {
            val info = api.getSystemInfo().getOrNull()
            val status = api.getSystemStatus().getOrNull()
            onResult(info, status)
        }
    }
}

class MainActivity : AppCompatActivity() {
    private val storage by lazy { TokenStorage(this) }
    private val apiService by lazy { OpenWrtApiService(storage) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        if (!storage.isTokenValid()) {
            // 跳转登录
            startActivity(Intent(this, LoginActivity::class.java))
            finish()
            return
        }

        loadDashboard()
    }

    private fun loadDashboard() {
        kotlinx.coroutines.MainScope().launch {
            val infoResult = apiService.getSystemInfo()
            infoResult.onSuccess { info ->
                findViewById<TextView>(R.id.tv_hostname).text = info.hostname
                findViewById<TextView>(R.id.tv_uptime).text = info.uptimeHuman
                findViewById<TextView>(R.id.tv_firmware).text = info.firmwareVersion
            }.onFailure { e ->
                Toast.makeText(this@MainActivity, "加载失败: ${e.message}", Toast.LENGTH_SHORT).show()
            }
        }
    }
}
```

---

## 7. 最佳实践

### 7.1 证书安全

```kotlin
// 生产环境推荐：记录并验证服务器证书指纹（证书固定）
// 首次连接时手动验证并记录，后续自动校验
fun saveCertificatePin(url: String, storage: TokenStorage) {
    // 使用 okhttp CertificatePinner 实现
}
```

### 7.2 Token 管理

- Token 使用 `EncryptedSharedPreferences` 加密存储，防止 Root 设备泄露
- 在应用启动时检查 Token 有效期，提前 5 分钟刷新（`/auth/refresh`）
- 捕获 401 响应，自动跳转登录界面

### 7.3 网络异常处理

```kotlin
// 建议统一异常处理
when {
    e is java.net.UnknownHostException -> "DNS 解析失败，请检查 DDNS 配置"
    e is java.net.ConnectException -> "连接被拒绝，请检查路由器是否在线或端口转发"
    e is javax.net.ssl.SSLHandshakeException -> "SSL 握手失败，请检查证书"
    e.message?.contains("timeout") == true -> "连接超时，请检查网络"
    else -> "未知错误: ${e.message}"
}
```

### 7.4 后台同步

```kotlin
// 使用 WorkManager 定期同步路由器状态（推送通知）
class RouterStatusWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result {
        val storage = TokenStorage(applicationContext)
        if (!storage.isTokenValid()) return Result.success()
        val api = OpenWrtApiService(storage)
        val status = api.getSystemStatus().getOrNull() ?: return Result.success()
        // 检查异常状态，发送本地通知
        if (status.cpu.usagePercent > 90) {
            NotificationHelper.sendAlert(applicationContext, "CPU 使用率过高: ${status.cpu.usagePercent}%")
        }
        return Result.success()
    }
}
```

### 7.5 局域网自动发现

```kotlin
// 当 App 连接到与路由器相同的 WiFi 时，自动发现路由器 IP
fun discoverRouterInLan(): String? {
    val wifiManager = context.getSystemService(Context.WIFI_SERVICE) as WifiManager
    val dhcpInfo = wifiManager.dhcpInfo
    val gateway = dhcpInfo.gateway
    // 将整型 IP 转换为字符串
    return String.format(
        "%d.%d.%d.%d",
        gateway and 0xff, (gateway shr 8) and 0xff,
        (gateway shr 16) and 0xff, (gateway shr 24) and 0xff
    )
}
```
