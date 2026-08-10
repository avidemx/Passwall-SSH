module("luci.controller.passwall-ssh", package.seeall)

function index()
    entry({"admin", "services", "passwall-ssh"}, cbi("passwall-ssh/main"), "Passwall-SSH", 60)
    entry({"admin", "services", "passwall-ssh", "edit"}, cbi("passwall-ssh/edit"), nil).leaf = true
    entry({"admin", "services", "passwall-ssh", "check_ip"}, call("action_check_ip")).leaf = true
    entry({"admin", "services", "passwall-ssh", "check_conn"}, call("action_check_conn"))
    entry({"admin", "services", "passwall-ssh", "check_services"}, call("action_check_services"))
    entry({"admin", "services", "passwall-ssh", "get_log"}, call("action_get_log"))
    entry({"admin", "services", "passwall-ssh", "clear_log"}, call("action_clear_log"))
end

-- Fungsi bantuan (Helper) untuk I/O file yang ringan
local function read_file(path)
    local f = io.open(path, "r")
    if f then
        local data = f:read("*all"):gsub("%s+", "")
        f:close()
        return data
    end
    return ""
end

local function write_file(path, data)
    local f = io.open(path, "w")
    if f then
        f:write(data)
        f:close()
    end
end

function action_check_services()
    local sys = require "luci.sys"
    local uci = require "luci.model.uci".cursor()
    
    local active_profile = uci:get("passwall-ssh", "main", "selected_profile") or "No Profile"

    -- Cek status core (badvpn-tun2socks)
    local core = sys.call("pidof badvpn-tun2socks >/dev/null 2>&1") == 0 and "1" or "0"

    local iface = "tun0"
    local rx = "0"
    local tx = "0"
    local start_time = "0"

    if core == "1" then
        -- 1. Ambil RX & TX saat ini
        local cur_rx = read_file("/sys/class/net/" .. iface .. "/statistics/rx_bytes")
        local cur_tx = read_file("/sys/class/net/" .. iface .. "/statistics/tx_bytes")
        
        if cur_rx ~= "" then rx = cur_rx end
        if cur_tx ~= "" then tx = cur_tx end
        
        write_file("/tmp/etc/passwall-ssh_current_rx", rx)
        write_file("/tmp/etc/passwall-ssh_current_tx", tx)

        -- 2. Ambil Start Time Epoch dari PID
        local pid = sys.exec("pidof badvpn-tun2socks | awk '{print $1}' 2>/dev/null"):gsub("%s+", "")
        if pid ~= "" then
            start_time = sys.exec("stat -c %Y /proc/" .. pid .. " 2>/dev/null"):gsub("%s+", "")
            if start_time == "" or not tonumber(start_time) then
                local cmd = "awk -v btime=$(awk '/btime/ {print $2}' /proc/stat) '{print btime + int($22 / 100)}' /proc/" .. pid .. "/stat 2>/dev/null"
                start_time = sys.exec(cmd):gsub("%s+", "")
            end
            if start_time == "" or not tonumber(start_time) then start_time = "0" end
        end

        -- 3. Hitung durasi berjalannya koneksi & simpan ke file 'current'
        if start_time ~= "0" and tonumber(start_time) then
            local current_duration = os.time() - tonumber(start_time)
            if current_duration < 0 then current_duration = 0 end
            write_file("/tmp/etc/passwall-ssh_current_conn", tostring(current_duration))
        end
    else
        -- 4. Jika VPN mati, pindahkan semua file 'Current' menjadi 'Last'
        local check_rx = read_file("/tmp/etc/passwall-ssh_current_rx")
        if check_rx ~= "" and check_rx ~= "0" then
            os.rename("/tmp/etc/passwall-ssh_current_rx", "/tmp/etc/passwall-ssh_last_rx")
            os.rename("/tmp/etc/passwall-ssh_current_tx", "/tmp/etc/passwall-ssh_last_tx")
            os.rename("/tmp/etc/passwall-ssh_current_conn", "/tmp/etc/passwall-ssh_last_conn")
        end
    end

    -- 5. Baca data history (Last RX, TX, dan Conn)
    local last_rx = read_file("/tmp/etc/passwall-ssh_last_rx")
    local last_tx = read_file("/tmp/etc/passwall-ssh_last_tx")
    local last_conn = read_file("/tmp/etc/passwall-ssh_last_conn")
    
    if last_rx == "" then last_rx = "0" end
    if last_tx == "" then last_tx = "0" end
    if last_conn == "" then last_conn = "0" end

    luci.http.prepare_content("text/plain")
    
    -- Format output (core, dummy, dummy, profile, rx, tx, start_time, last_conn, last_rx, last_tx)
    luci.http.write(core .. ",0,0," .. active_profile .. "," .. rx .. "," .. tx .. "," .. start_time .. "," .. last_conn .. "," .. last_rx .. "," .. last_tx)
end

function action_check_conn()
    local host = luci.http.formvalue("host")
    local cmd = "curl --connect-timeout 3 -o /dev/null -I -sk -w '%{http_code}:%{time_appconnect}' \"" .. host .. "\""
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
    local logfile = "/tmp/etc/passwall-ssh.log" 
    local f = io.open(logfile, "r")
    if f then
        local data = f:read("*all")
        f:close()
        luci.http.prepare_content("text/plain")
        luci.http.write(data)
    else
        luci.http.prepare_content("text/plain")
        luci.http.write("Menunggu log...")
    end
end

function action_check_ip()
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    
    local ip_raw = sys.exec("curl --interface tun0 -s -m 3 http://ip-api.com/json/?fields=status,country,countryCode,isp,query")
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

function action_clear_log()
    local sys = require "luci.sys"
    -- Mengosongkan file log tanpa menghapus filenya
    sys.exec("echo '' > /tmp/etc/passwall-ssh.log")
    
    luci.http.prepare_content("text/plain")
    luci.http.write("OK")
end
