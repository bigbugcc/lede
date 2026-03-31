local m, s, o

m = Map("remote_api",
    translate("Remote API"),
    translate("Configure the remote access REST API for Android/mini-program clients."))

s = m:section(TypedSection, "main", translate("General Settings"))
s.anonymous = true

o = s:option(Flag, "enabled", translate("Enable"))
o.default = "1"
o.rmempty = false

o = s:option(Value, "port", translate("HTTP Port"))
o.datatype = "port"
o.default = "8080"
o.placeholder = "8080"

o = s:option(Flag, "enable_http", translate("Enable HTTP"))
o.default = "1"

o = s:option(Value, "https_port", translate("HTTPS Port"))
o.datatype = "port"
o.default = "8443"
o.placeholder = "8443"

o = s:option(Flag, "enable_https", translate("Enable HTTPS"))
o.default = "1"

o = s:option(Value, "token_expire", translate("Token Expiry (seconds)"))
o.datatype = "uinteger"
o.default = "2592000"
o.placeholder = "2592000"
o.description = translate("Default: 30 days (2592000 seconds)")

o = s:option(Value, "rate_limit",
    translate("Rate Limit (requests/minute)"))
o.datatype = "uinteger"
o.default = "60"
o.placeholder = "60"

o = s:option(Value, "cors_origin",
    translate("CORS Origin"),
    translate("Allowed origin for Cross-Origin requests. Use * to allow all."))
o.default = "*"
o.placeholder = "*"

o = s:option(Flag, "log_access",
    translate("Log API Access"),
    translate("Log all API requests to syslog."))
o.default = "1"

-- API key management section
s2 = m:section(TypedSection, "_dummy",
    translate("Token Management"),
    translate("Generate and manage API tokens for mobile clients."))
s2.anonymous = true
s2.addremove = false
s2.template = "remote_api/token_mgmt"

return m
