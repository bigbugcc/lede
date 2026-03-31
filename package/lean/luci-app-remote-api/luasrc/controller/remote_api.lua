module("luci.controller.remote_api", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/remote_api") then
        return
    end

    local page = entry({"admin", "services", "remote_api"},
        cbi("remote_api"),
        _("Remote API"),
        60)
    page.dependent = true
    page.acl_depends = { "luci-app-remote-api" }
end
