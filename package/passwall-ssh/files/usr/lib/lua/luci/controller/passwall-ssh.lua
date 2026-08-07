module("luci.controller.passwall-ssh", package.seeall)

function index()
    entry({"admin", "services", "passwall-ssh"}, cbi("passwall-ssh/main"), "PASSWALL-SSH", 60)
    entry({"admin", "services", "passwall-ssh", "edit"}, cbi("passwall-ssh/edit"), nil).leaf = true
    entry({"admin", "services", "passwall-ssh", "check_ip"}, call("action_check_ip")).leaf = true
    entry({"admin", "services", "passwall-ssh", "check_conn"}, call("action_check_conn"))
    entry({"admin", "services", "passwall-ssh", "check_services"}, call("action_check_services"))
    entry({"admin", "services", "passwall-ssh", "get_log"}, call("action_get_log"))
end

function action_check_services()
    -- Ambil profile dari uci
    local uci = require "luci.model.uci".cursor()
    local active_profile = uci:get("passwall-ssh", "main", "selected_profile") or "No Profile"

    -- Cek status service
    local tcp = luci.sys.call("pidof ssh >/dev/null 2>&1 || pidof stunnel >/dev/null 2>&1") == 0 and "1" or "0"
    local udp = luci.sys.call("pidof badvpn-tun2socks >/dev/null 2>&1 || pidof tun2socks >/dev/null 2>&1") == 0 and "1" or "0"
    local dns = luci.sys.call("pidof dnsproxy >/dev/null 2>&1") == 0 and "1" or "0"
    
    luci.http.prepare_content("text/plain")
    -- Tambahkan active_profile di bagian belakang menggunakan koma
    luci.http.write(tcp .. "," .. udp .. "," .. dns .. "," .. active_profile)
end

function action_check_conn()
    local host = luci.http.formvalue("host")
    if not host or host == "" then host = "www.google.com" end
    
    local cmd = "curl -k -I -s --connect-timeout 3 -m 3 http://" .. host .. " -o /dev/null -w '%{http_code}:%{time_total}'"
    local res = luci.sys.exec(cmd)
    
    if res and res ~= "" then
        local http_code, time_total = res:match("(%d+):([%d%.]+)")
        if http_code and http_code ~= "000" then
            local ms = math.floor(tonumber(time_total) * 1000)
            luci.http.prepare_content("text/plain")
            luci.http.write(tostring(ms))
            return
        end
    end
    
    luci.http.prepare_content("text/plain")
    luci.http.write("Failed")
end

function action_get_log()
    local logfile = "/tmp/passwall-ssh.log" 
    local f = io.open(logfile, "r")
    if f then
        local data = f:read("*all")
        f:close()
        luci.http.prepare_content("text/plain")
        luci.http.write(data)
    else
        luci.http.write("Menunggu log...")
    end
end

function action_check_ip()
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    
    local ip_raw = sys.exec("curl -s -m 3 http://ip-api.com/json/?fields=status,country,countryCode,isp,query")
    local data = json.parse(ip_raw) or {}

    if data.status ~= "success" then
        data = { flag = "unknown", ip = "Offline", country = "Offline", isp = "Offline" }
    else
        data.ip = data.query
        data.flag = string.lower(data.countryCode)
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json(data)
end