/**
 * api.uc — OpenWrt Remote Access REST API handler
 *
 * Runs as a uhttpd ucode handler. Provides REST endpoints under /api/v1/*
 * translating to ubus JSON-RPC calls with token-based authentication.
 *
 * Token format: <issued_at>.<username>.<expire_at>.<hmac_sha256_signature>
 */

'use strict';

import { connect as ubus_connect } from 'ubus';
import { open, stat, readfile, writefile, unlink } from 'fs';
import { cursor } from 'uci';

// ── Constants ─────────────────────────────────────────────────────────────────

const SECRET_FILE    = '/etc/remote-api.secret';
const CONF_DIR       = '/var/run/remote-api';
const REVOKED_FILE   = CONF_DIR + '/revoked_tokens';
const RL_DIR         = '/var/run/remote-api-rl';
const API_PREFIX     = '/api/v1';

// ── Helpers ───────────────────────────────────────────────────────────────────

function json_response(code, message, data) {
	return {
		code:    code,
		message: message,
		data:    data ?? null,
	};
}

function send(status_code, obj) {
	uhttpd.send(
		'Status: ' + status_code + '\r\n' +
		'Content-Type: application/json\r\n' +
		'Access-Control-Allow-Origin: ' + (get_cors_origin()) + '\r\n' +
		'Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\n' +
		'Access-Control-Allow-Headers: Content-Type, Authorization\r\n' +
		'\r\n' +
		sprintf('%J', obj) + '\n'
	);
}

function get_cors_origin() {
	let f = open(CONF_DIR + '/cors_origin', 'r');
	if (f) {
		let v = trim(f.read('all') ?? '*');
		f.close();
		return v || '*';
	}
	return '*';
}

function get_rate_limit() {
	let f = open(CONF_DIR + '/rate_limit', 'r');
	if (f) {
		let v = int(trim(f.read('all') ?? '60'));
		f.close();
		return v > 0 ? v : 60;
	}
	return 60;
}

function get_secret() {
	let content = readfile(SECRET_FILE);
	if (!content) return null;
	return trim(content);
}

// Simple rate limiting: count requests per remote IP per minute using files
function check_rate_limit(remote_ip) {
	let limit = get_rate_limit();
	if (limit <= 0) return true; // disabled

	let safe_ip = replace(remote_ip, /[^a-zA-Z0-9._-]/, '_');
	let rl_file = RL_DIR + '/' + safe_ip;
	let now     = int(time());
	let window  = 60; // 1 minute window

	let data = readfile(rl_file);
	let count = 0;
	let window_start = now - window;

	if (data) {
		// Format: "window_start:count"
		let parts = split(trim(data), ':');
		if (length(parts) == 2 && int(parts[0]) > window_start) {
			count = int(parts[1]);
		}
	}

	if (count >= limit) return false;

	writefile(rl_file, (now - window + 1) + ':' + (count + 1));
	return true;
}

// HMAC-SHA256 via openssl command (available on all OpenWrt builds)
function hmac_sha256(secret, data) {
	let cmd = sprintf(
		"printf '%%s' %s | openssl dgst -sha256 -hmac %s -hex 2>/dev/null",
		shellescape(data),
		shellescape(secret)
	);
	let result = trim(system(cmd + ' | awk \'{print $NF}\''));
	return result;
}

function shellescape(s) {
	return "'" + replace(s, "'", "'\\''") + "'";
}

// Verify token; returns username on success, null on failure
function verify_token(token) {
	if (!token) return null;

	let secret = get_secret();
	if (!secret) return null;

	// Token: <issued_at>.<username>.<expire_at>.<signature>
	let parts = split(token, '.');
	if (length(parts) != 4) return null;

	let issued_at = parts[0];
	let username  = parts[1];
	let expire_at = parts[2];
	let sig       = parts[3];

	// Check expiry
	let now = int(time());
	if (int(expire_at) < now) return null;

	// Check revocation list
	let revoked = readfile(REVOKED_FILE);
	if (revoked && index(revoked, token) >= 0) return null;

	// Verify HMAC
	let payload       = issued_at + '.' + username + '.' + expire_at;
	let expected_sig  = hmac_sha256(secret, payload);
	if (!expected_sig || expected_sig != sig) return null;

	return username;
}

// Generate a new token for a user
function generate_token(username) {
	let secret = get_secret();
	if (!secret) return null;

	let uci_cursor  = cursor();
	let expire_secs = int(uci_cursor.get('remote_api', 'main', 'token_expire') ?? '2592000');
	let now         = int(time());
	let expire_at   = now + expire_secs;

	let payload = now + '.' + username + '.' + expire_at;
	let sig     = hmac_sha256(secret, payload);
	if (!sig) return null;

	return {
		token:      payload + '.' + sig,
		expires_at: expire_at,
		expires_in: expire_secs,
	};
}

// Revoke a specific token
function revoke_token(token) {
	let existing = readfile(REVOKED_FILE) ?? '';
	writefile(REVOKED_FILE, existing + token + '\n');
}

// ── Request parsing ───────────────────────────────────────────────────────────

let request_method  = uhttpd.getenv('REQUEST_METHOD') ?? 'GET';
let path_info       = uhttpd.getenv('PATH_INFO') ?? '/';
let query_string    = uhttpd.getenv('QUERY_STRING') ?? '';
let remote_addr     = uhttpd.getenv('REMOTE_ADDR') ?? '0.0.0.0';
let content_length  = int(uhttpd.getenv('CONTENT_LENGTH') ?? '0');
let auth_header     = uhttpd.getenv('HTTP_AUTHORIZATION') ?? '';

// Handle CORS preflight
if (request_method == 'OPTIONS') {
	uhttpd.send(
		'Status: 204\r\n' +
		'Access-Control-Allow-Origin: ' + get_cors_origin() + '\r\n' +
		'Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\n' +
		'Access-Control-Allow-Headers: Content-Type, Authorization\r\n' +
		'Content-Length: 0\r\n' +
		'\r\n'
	);
	exit(0);
}

// Strip API prefix
if (substr(path_info, 0, length(API_PREFIX)) != API_PREFIX) {
	send(404, json_response(404, 'not found', null));
	exit(0);
}
let api_path = substr(path_info, length(API_PREFIX));

// URL-decode a percent-encoded string (RFC 3986)
function url_decode(s) {
	// Replace + with space, then decode %XX sequences
	s = replace(s, '+', ' ');
	s = replace(s, /%([0-9A-Fa-f]{2})/g, function(m, hex) {
		return chr(int('0x' + hex));
	});
	return s;
}

// Parse query string into a map (values are URL-decoded)
function parse_qs(qs) {
	let result = {};
	for (let pair in split(qs, '&')) {
		let eq = index(pair, '=');
		if (eq >= 0) {
			let k = url_decode(substr(pair, 0, eq));
			let v = url_decode(substr(pair, eq + 1));
			result[k] = v;
		}
	}
	return result;
}
let query = parse_qs(query_string);

// Read request body
let body_str = '';
if (content_length > 0) {
	body_str = uhttpd.recv(content_length) ?? '';
}

function parse_body() {
	if (!body_str) return {};
	return json(body_str) ?? {};
}

// Extract Bearer token
function get_bearer_token() {
	if (!auth_header) return null;
	let m = match(auth_header, /^[Bb]earer\s+(\S+)/);
	return m ? m[1] : null;
}

// Rate limit check
if (!check_rate_limit(remote_addr)) {
	send(429, json_response(429, 'rate limit exceeded', null));
	exit(0);
}

// ── Route table ───────────────────────────────────────────────────────────────

let ubus = null;

function get_ubus() {
	if (!ubus) ubus = ubus_connect();
	return ubus;
}

// POST /auth/token — login
function route_auth_token_post() {
	let body = parse_body();
	let username = body.username ?? '';
	let password = body.password ?? '';

	if (!username || !password) {
		send(400, json_response(400, 'username and password required', null));
		return;
	}

	// Validate via rpcd / ubus_rpc_session
	let conn = get_ubus();
	let res  = conn.call('session', 'login', {
		username: username,
		password: password,
		timeout:  300,
	});

	if (!res || !res['ubus_rpc_session']) {
		send(401, json_response(401, 'invalid credentials', null));
		return;
	}

	let tok = generate_token(username);
	if (!tok) {
		send(500, json_response(500, 'failed to generate token; run: remote-api-ctl generate-secret', null));
		return;
	}

	send(200, json_response(0, 'ok', tok));
}

// DELETE /auth/token — logout
function route_auth_token_delete(username) {
	let token = get_bearer_token();
	if (token) revoke_token(token);
	send(200, json_response(0, 'token revoked', null));
}

// POST /auth/refresh — refresh token
function route_auth_refresh(username) {
	let tok = generate_token(username);
	if (!tok) {
		send(500, json_response(500, 'failed to generate token', null));
		return;
	}
	// Optionally revoke old token
	let old_token = get_bearer_token();
	if (old_token) revoke_token(old_token);
	send(200, json_response(0, 'ok', tok));
}

// GET /system/info
function route_system_info() {
	let conn = get_ubus();

	let sys_info = conn.call('system', 'info') ?? {};
	let board    = conn.call('system', 'board') ?? {};

	let uptime_s = sys_info.uptime ?? 0;
	let days   = int(uptime_s / 86400);
	let hours  = int((uptime_s % 86400) / 3600);
	let mins   = int((uptime_s % 3600) / 60);
	let uptime_human = sprintf('%d days, %d:%02d', days, hours, mins);

	send(200, json_response(0, 'ok', {
		hostname:         board.hostname ?? 'OpenWrt',
		model:            board.model ?? 'Unknown',
		firmware_version: board.release?.version ?? 'Unknown',
		kernel_version:   sys_info.kernel ?? 'Unknown',
		arch:             board.system ?? 'Unknown',
		uptime:           uptime_s,
		uptime_human:     uptime_human,
		localtime:        strftime('%Y-%m-%d %H:%M:%S', time()),
		timezone:         getenv('TZ') ?? 'UTC',
	}));
}

// GET /system/status
function route_system_status() {
	let conn     = get_ubus();
	let sys_info = conn.call('system', 'info') ?? {};

	let mem     = sys_info.memory ?? {};
	let total   = mem.total   ?? 0;
	let free    = mem.free    ?? 0;
	let shared  = mem.shared  ?? 0;
	let buffered = mem.buffered ?? 0;
	let used    = total - free;
	let usage_pct = total > 0 ? (used / total * 100.0) : 0.0;

	// CPU load via /proc/loadavg
	let load_data = readfile('/proc/loadavg') ?? '0 0 0';
	let load_parts = split(trim(load_data), /\s+/);

	// CPU usage approximation via /proc/stat
	let cpu_usage = 0.0;
	let stat_data = readfile('/proc/stat');
	if (stat_data) {
		let line = split(stat_data, '\n')[0];
		let fields = split(trim(line), /\s+/);
		if (length(fields) >= 5) {
			let user   = int(fields[1]);
			let nice   = int(fields[2]);
			let sys    = int(fields[3]);
			let idle   = int(fields[4]);
			let iowait = int(fields[5] ?? 0);
			let total_t = user + nice + sys + idle + iowait;
			let busy    = total_t - idle - iowait;
			cpu_usage = total_t > 0 ? (busy / total_t * 100.0) : 0.0;
		}
	}

	// Temperature (optional)
	let temp = null;
	let temp_raw = readfile('/sys/class/thermal/thermal_zone0/temp');
	if (temp_raw) temp = int(trim(temp_raw)) / 1000.0;

	// Disk usage for /
	let disk = [];
	let df = popen('df -k / 2>/dev/null | tail -1', 'r');
	if (df) {
		let line = trim(df.read('all') ?? '');
		df.close();
		let fields = split(line, /\s+/);
		if (length(fields) >= 6) {
			let total_kb = int(fields[1]);
			let used_kb  = int(fields[2]);
			let free_kb  = int(fields[3]);
			push(disk, {
				mountpoint:   fields[5],
				total_kb:     total_kb,
				used_kb:      used_kb,
				free_kb:      free_kb,
				usage_percent: total_kb > 0 ? (used_kb / total_kb * 100.0) : 0.0,
			});
		}
	}

	// CPU core count from /proc/cpuinfo
	let cpu_cores = 0;
	let cpuinfo = readfile('/proc/cpuinfo');
	if (cpuinfo) {
		for (let line in split(cpuinfo, '\n')) {
			if (match(line, /^processor\s*:/)) cpu_cores++;
		}
	}
	if (cpu_cores == 0) cpu_cores = 1;

	// CPU frequency (kHz) from cpufreq, first core
	let cpu_freq_mhz = null;
	let freq_raw = readfile('/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq');
	if (freq_raw) {
		let freq_khz = int(trim(freq_raw));
		if (freq_khz > 0) cpu_freq_mhz = freq_khz / 1000;
	}

	send(200, json_response(0, 'ok', {
		cpu: {
			usage_percent:       cpu_usage,
			cores:               cpu_cores,
			frequency_mhz:       cpu_freq_mhz,
			temperature_celsius: temp,
		},
		memory: {
			total_kb:     int(total / 1024),
			free_kb:      int(free / 1024),
			used_kb:      int(used / 1024),
			usage_percent: usage_pct,
			buffers_kb:   int(buffered / 1024),
		},
		load: {
			'1min':  float(load_parts[0] ?? '0'),
			'5min':  float(load_parts[1] ?? '0'),
			'15min': float(load_parts[2] ?? '0'),
		},
		disk: disk,
	}));
}

// POST /system/reboot
function route_system_reboot() {
	let conn  = get_ubus();
	let body  = parse_body();
	let delay = int(body.delay_seconds ?? 3);
	if (delay < 1) delay = 1;
	if (delay > 60) delay = 60;

	// Trigger reboot asynchronously
	system('(sleep ' + delay + '; reboot) &');
	send(200, json_response(0, 'rebooting in ' + delay + ' seconds', null));
}

// GET /system/logs
function route_system_logs() {
	let lines = int(query.lines ?? '100');
	if (lines < 1) lines = 1;
	if (lines > 1000) lines = 1000;

	let log_entries = [];
	let f = popen('logread -l ' + lines + ' 2>/dev/null', 'r');
	if (f) {
		let line;
		while ((line = f.read('line')) != null) {
			line = trim(line);
			if (line) push(log_entries, { message: line });
		}
		f.close();
	}

	send(200, json_response(0, 'ok', {
		lines: log_entries,
		total: length(log_entries),
	}));
}

// GET /network/interfaces
function route_network_interfaces() {
	let conn  = get_ubus();
	let dump  = conn.call('network.interface', 'dump') ?? { interface: [] };
	let ifaces = [];

	for (let iface in (dump.interface ?? [])) {
		let rx = 0; let tx = 0;
		let dev = iface.l3_device ?? iface.device ?? '';
		if (dev) {
			let stats = conn.call('network.device', 'status', { name: dev }) ?? {};
			rx = stats.statistics?.rx_bytes ?? 0;
			tx = stats.statistics?.tx_bytes ?? 0;
		}
		let ipv4 = (iface['ipv4-address'] ?? [])[0];
		push(ifaces, {
			name:           iface.interface,
			device:         dev,
			proto:          iface.proto ?? 'unknown',
			up:             iface.up ?? false,
			ipv4_address:   ipv4?.address,
			ipv4_mask:      ipv4 ? ('' + ipv4.mask) : null,
			ipv6_addresses: map(iface['ipv6-address'] ?? [], a => a.address + '/' + a.mask),
			gateway:        iface.route ? (iface.route[0]?.nexthop) : null,
			dns_servers:    iface['dns-server'] ?? [],
			rx_bytes:       rx,
			tx_bytes:       tx,
			uptime_seconds: iface.uptime ?? 0,
		});
	}

	send(200, json_response(0, 'ok', { interfaces: ifaces }));
}

// GET /network/interfaces/:name
function route_network_interface(name) {
	let conn = get_ubus();
	let status = conn.call('network.interface.' + name, 'status') ?? {};
	if (!status || !status.interface) {
		send(404, json_response(404, 'interface not found', null));
		return;
	}
	let ipv4 = (status['ipv4-address'] ?? [])[0];
	send(200, json_response(0, 'ok', {
		name:         name,
		device:       status.l3_device ?? status.device ?? '',
		proto:        status.proto ?? 'unknown',
		up:           status.up ?? false,
		ipv4_address: ipv4?.address,
		uptime_seconds: status.uptime ?? 0,
	}));
}

// POST /network/interfaces/:name/up or /down
function route_network_if_updown(name, action) {
	let conn = get_ubus();
	if (action == 'up') {
		conn.call('network.interface.' + name, 'up');
	} else {
		conn.call('network.interface.' + name, 'down');
	}
	send(200, json_response(0, 'interface ' + name + ' ' + action, null));
}

// GET /network/traffic
function route_network_traffic() {
	let conn   = get_ubus();
	let iface  = query.interface;
	let result = {};

	let devices_to_check = [];
	if (iface) {
		push(devices_to_check, iface);
	} else {
		let dump = conn.call('network.device', 'status') ?? {};
		for (let dev in keys(dump)) {
			push(devices_to_check, dev);
		}
	}

	for (let dev in devices_to_check) {
		let stats = conn.call('network.device', 'status', { name: dev }) ?? {};
		let s = stats.statistics ?? {};
		result[dev] = {
			rx_bytes:   s.rx_bytes   ?? 0,
			tx_bytes:   s.tx_bytes   ?? 0,
			rx_packets: s.rx_packets ?? 0,
			tx_packets: s.tx_packets ?? 0,
		};
	}

	send(200, json_response(0, 'ok', result));
}

// GET /wifi/status
function route_wifi_status() {
	let conn = get_ubus();
	let radios = [];

	let uci_cursor = cursor();

	// Enumerate radios via uci wireless
	uci_cursor.foreach('wireless', 'wifi-device', function(s) {
		let radio_name = s['.name'];
		let info = conn.call('iwinfo', 'info', { device: radio_name }) ?? {};
		let radio = {
			name:          radio_name,
			phy:           info.phy ?? radio_name,
			band:          info.frequency > 4000 ? '5GHz' : '2.4GHz',
			channel:       info.channel ?? 0,
			frequency_mhz: info.frequency ?? 0,
			txpower_dbm:   info.txpower ?? 0,
			enabled:       true,
			interfaces:    [],
		};

		uci_cursor.foreach('wireless', 'wifi-iface', function(iface) {
			if (iface.device != radio_name) return;
			let ifname = iface.ifname ?? (radio_name == 'radio0' ? 'wlan0' : 'wlan1');
			let iface_info = conn.call('iwinfo', 'info', { device: ifname }) ?? {};
			push(radio.interfaces, {
				ifname:     ifname,
				ssid:       iface_info.ssid ?? iface.ssid ?? '',
				bssid:      iface_info.bssid ?? '',
				encryption: iface.encryption ?? 'none',
				hidden:     iface.hidden == '1',
				mode:       iface.mode ?? 'ap',
			});
		});

		push(radios, radio);
	});

	send(200, json_response(0, 'ok', { radios: radios }));
}

// GET /wifi/clients
function route_wifi_clients() {
	let conn    = get_ubus();
	let clients = [];

	// Get all WiFi interfaces
	let uci_cursor = cursor();
	let ifaces_seen = {};

	uci_cursor.foreach('wireless', 'wifi-iface', function(iface) {
		let radio = iface.device ?? 'radio0';
		let ifname = iface.ifname ?? (radio == 'radio0' ? 'wlan0' : 'wlan1');
		if (ifaces_seen[ifname]) return;
		ifaces_seen[ifname] = true;

		let assoc_list = conn.call('iwinfo', 'assoclist', { device: ifname }) ?? {};
		for (let client in (assoc_list.results ?? [])) {
			push(clients, {
				mac:               client.mac,
				interface:         ifname,
				ssid:              iface.ssid ?? '',
				signal_dbm:        client.signal ?? 0,
				noise_dbm:         client.noise  ?? 0,
				rx_rate_mbps:      (client.rx?.rate ?? 0) / 1000.0,
				tx_rate_mbps:      (client.tx?.rate ?? 0) / 1000.0,
				rx_bytes:          client.rx?.bytes ?? 0,
				tx_bytes:          client.tx?.bytes ?? 0,
				connected_seconds: client.inactive ?? 0,
			});
		}
	});

	send(200, json_response(0, 'ok', { clients: clients, total: length(clients) }));
}

// POST /wifi/scan
function route_wifi_scan() {
	let conn  = get_ubus();
	let body  = parse_body();
	let radio = body.radio ?? 'radio0';
	let ifname = (radio == 'radio0') ? 'wlan0' : 'wlan1';

	let scan_result = conn.call('iwinfo', 'scan', { device: ifname }) ?? {};
	let networks = [];

	for (let net in (scan_result.results ?? [])) {
		push(networks, {
			ssid:          net.ssid,
			bssid:         net.bssid,
			channel:       net.channel ?? 0,
			frequency_mhz: net.frequency ?? 0,
			signal_dbm:    net.signal ?? 0,
			quality:       net.quality ?? 0,
			encryption:    net.encryption?.enabled ? (net.encryption?.auth_suites?.[0] ?? 'psk') : 'none',
			mode:          net.mode ?? 'Master',
		});
	}

	send(200, json_response(0, 'ok', { networks: networks, total: length(networks) }));
}

// PUT /wifi/config
function route_wifi_config() {
	let conn       = get_ubus();
	let body       = parse_body();
	let uci_cursor = cursor();
	let radio      = body.radio ?? 'radio0';

	// Find the wifi-iface for this radio
	let target_section = null;
	uci_cursor.foreach('wireless', 'wifi-iface', function(s) {
		if (s.device == radio) target_section = s['.name'];
	});

	if (!target_section) {
		send(404, json_response(404, 'wifi interface not found for radio: ' + radio, null));
		return;
	}

	if (body.ssid)       uci_cursor.set('wireless', target_section, 'ssid', body.ssid);
	if (body.password)   uci_cursor.set('wireless', target_section, 'key', body.password);
	if (body.encryption) uci_cursor.set('wireless', target_section, 'encryption', body.encryption);
	if (body.hidden != null)
		uci_cursor.set('wireless', target_section, 'hidden', body.hidden ? '1' : '0');

	if (body.channel) {
		uci_cursor.set('wireless', radio, 'channel', '' + body.channel);
	}

	uci_cursor.commit('wireless');
	conn.call('network', 'reload');

	send(200, json_response(0, 'wifi configuration applied', { restart_required: true }));
}

// GET /dhcp/leases
function route_dhcp_leases() {
	let leases = [];
	let f = open('/tmp/dhcp.leases', 'r');
	if (f) {
		let line;
		while ((line = f.read('line')) != null) {
			line = trim(line);
			if (!line) continue;
			// Format: expire_ts mac ip hostname client_id
			let parts = split(line, /\s+/);
			if (length(parts) >= 4) {
				push(leases, {
					expires_at: int(parts[0]),
					mac:        parts[1],
					ip:         parts[2],
					hostname:   parts[3] != '*' ? parts[3] : null,
				});
			}
		}
		f.close();
	}
	send(200, json_response(0, 'ok', { leases: leases, total: length(leases) }));
}

// GET /dhcp/static
function route_dhcp_static() {
	let uci_cursor = cursor();
	let hosts = [];
	uci_cursor.foreach('dhcp', 'host', function(s) {
		push(hosts, {
			name: s.name,
			mac:  s.mac,
			ip:   s.ip,
		});
	});
	send(200, json_response(0, 'ok', { hosts: hosts }));
}

// POST /dhcp/static
function route_dhcp_static_post() {
	let body       = parse_body();
	let uci_cursor = cursor();

	if (!body.mac || !body.ip) {
		send(400, json_response(400, 'mac and ip are required', null));
		return;
	}

	let section = uci_cursor.add('dhcp', 'host');
	if (body.name) uci_cursor.set('dhcp', section, 'name', body.name);
	uci_cursor.set('dhcp', section, 'mac', body.mac);
	uci_cursor.set('dhcp', section, 'ip', body.ip);
	uci_cursor.commit('dhcp');

	let conn = get_ubus();
	conn.call('service', 'list', { name: 'dnsmasq' });

	send(200, json_response(0, 'static DHCP host added', { section: section }));
}

// GET /firewall/rules
function route_firewall_rules() {
	let uci_cursor = cursor();
	let rules = [];
	uci_cursor.foreach('firewall', 'rule', function(s) {
		push(rules, {
			name:      s.name,
			src:       s.src,
			dest:      s.dest,
			proto:     s.proto,
			src_port:  s.src_port,
			dest_port: s.dest_port,
			target:    s.target,
			enabled:   s.enabled != '0',
		});
	});
	send(200, json_response(0, 'ok', { rules: rules }));
}

// GET /firewall/port-forwards
function route_firewall_redirects() {
	let uci_cursor = cursor();
	let redirects = [];
	uci_cursor.foreach('firewall', 'redirect', function(s) {
		push(redirects, {
			name:      s.name,
			src:       s.src,
			proto:     s.proto,
			src_dport: s.src_dport,
			dest_ip:   s.dest_ip,
			dest_port: s.dest_port,
			enabled:   s.enabled != '0',
		});
	});
	send(200, json_response(0, 'ok', { redirects: redirects }));
}

// POST /firewall/port-forwards
function route_firewall_redirects_post() {
	let body       = parse_body();
	let uci_cursor = cursor();

	if (!body.src_dport || !body.dest_ip || !body.dest_port) {
		send(400, json_response(400, 'src_dport, dest_ip, and dest_port are required', null));
		return;
	}

	let section = uci_cursor.add('firewall', 'redirect');
	uci_cursor.set('firewall', section, 'target',    'DNAT');
	uci_cursor.set('firewall', section, 'src',       'wan');
	if (body.name)      uci_cursor.set('firewall', section, 'name',      body.name);
	if (body.proto)     uci_cursor.set('firewall', section, 'proto',     body.proto);
	uci_cursor.set('firewall', section, 'src_dport', body.src_dport);
	uci_cursor.set('firewall', section, 'dest_ip',   body.dest_ip);
	uci_cursor.set('firewall', section, 'dest_port', body.dest_port);
	uci_cursor.commit('firewall');

	let conn = get_ubus();
	conn.call('service', 'list', { name: 'firewall' });

	send(200, json_response(0, 'port forward added', { section: section }));
}

// ── Router ────────────────────────────────────────────────────────────────────

// Routes that do NOT require authentication
let public_routes = {
	'POST /auth/token': route_auth_token_post,
};

let route_key = request_method + ' ' + api_path;

if (public_routes[route_key]) {
	public_routes[route_key]();
	exit(0);
}

// All other routes require a valid Bearer token
let bearer = get_bearer_token();
let auth_user = verify_token(bearer);

if (!auth_user) {
	send(401, json_response(401, 'unauthorized: missing or invalid token', null));
	exit(0);
}

// Authenticated routes
let path_parts = filter(split(api_path, '/'), l => length(l) > 0);
let p0 = path_parts[0] ?? '';
let p1 = path_parts[1] ?? '';
let p2 = path_parts[2] ?? '';
let p3 = path_parts[3] ?? '';

// Auth
if (p0 == 'auth' && p1 == 'token' && request_method == 'DELETE') {
	route_auth_token_delete(auth_user);
} else if (p0 == 'auth' && p1 == 'refresh' && request_method == 'POST') {
	route_auth_refresh(auth_user);

// System
} else if (p0 == 'system' && p1 == 'info' && request_method == 'GET') {
	route_system_info();
} else if (p0 == 'system' && p1 == 'status' && request_method == 'GET') {
	route_system_status();
} else if (p0 == 'system' && p1 == 'reboot' && request_method == 'POST') {
	route_system_reboot();
} else if (p0 == 'system' && p1 == 'logs' && request_method == 'GET') {
	route_system_logs();

// Network
} else if (p0 == 'network' && p1 == 'interfaces' && !p2 && request_method == 'GET') {
	route_network_interfaces();
} else if (p0 == 'network' && p1 == 'interfaces' && p2 && !p3 && request_method == 'GET') {
	route_network_interface(p2);
} else if (p0 == 'network' && p1 == 'interfaces' && p2 && p3 == 'up' && request_method == 'POST') {
	route_network_if_updown(p2, 'up');
} else if (p0 == 'network' && p1 == 'interfaces' && p2 && p3 == 'down' && request_method == 'POST') {
	route_network_if_updown(p2, 'down');
} else if (p0 == 'network' && p1 == 'traffic' && request_method == 'GET') {
	route_network_traffic();

// WiFi
} else if (p0 == 'wifi' && p1 == 'status' && request_method == 'GET') {
	route_wifi_status();
} else if (p0 == 'wifi' && p1 == 'clients' && request_method == 'GET') {
	route_wifi_clients();
} else if (p0 == 'wifi' && p1 == 'scan' && request_method == 'POST') {
	route_wifi_scan();
} else if (p0 == 'wifi' && p1 == 'config' && request_method == 'PUT') {
	route_wifi_config();

// DHCP / DNS
} else if (p0 == 'dhcp' && p1 == 'leases' && request_method == 'GET') {
	route_dhcp_leases();
} else if (p0 == 'dhcp' && p1 == 'static' && !p2 && request_method == 'GET') {
	route_dhcp_static();
} else if (p0 == 'dhcp' && p1 == 'static' && request_method == 'POST') {
	route_dhcp_static_post();

// Firewall
} else if (p0 == 'firewall' && p1 == 'rules' && request_method == 'GET') {
	route_firewall_rules();
} else if (p0 == 'firewall' && p1 == 'port-forwards' && !p2 && request_method == 'GET') {
	route_firewall_redirects();
} else if (p0 == 'firewall' && p1 == 'port-forwards' && request_method == 'POST') {
	route_firewall_redirects_post();

// 404
} else {
	send(404, json_response(404, 'endpoint not found: ' + request_method + ' ' + api_path, null));
}
