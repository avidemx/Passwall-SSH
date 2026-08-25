module("luci.controller.passwall-ssh", package.seeall)

function index()
    entry({"admin", "services", "passwall-ssh"}, cbi("passwall-ssh/main"), "Passwall-SSH", 60)
    entry({"admin", "services", "passwall-ssh", "edit"}, cbi("passwall-ssh/edit"), nil).leaf = true
    entry({"admin", "services", "passwall-ssh", "check_ip"}, call("action_check_ip")).leaf = true
    entry({"admin", "services", "passwall-ssh", "check_conn"}, call("action_check_conn"))
    entry({"admin", "services", "passwall-ssh", "check_services"}, call("action_check_services"))
    entry({"admin", "services", "passwall-ssh", "get_log"}, call("action_get_log"))
    entry({"admin", "services", "passwall-ssh", "clear_log"}, call("action_clear_log"))
    entry({"admin", "services", "passwall-ssh", "get_app_info"}, call("action_get_app_info")).leaf = true
    entry({"admin", "services", "passwall-ssh", "get_update_status"}, call("action_get_update_status")).leaf = true
    entry({"admin", "services", "passwall-ssh", "do_app_update"}, call("action_do_app_update")).leaf = true
end

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

-- ==========================================
-- HELPER: DETEKSI OS & ARSITEKTUR LENGKAP
-- ==========================================
local function get_system_info()
    local sys = require "luci.sys"
    local os_rel = sys.exec("cat /etc/os-release 2>/dev/null") or ""
    local owrt_rel = sys.exec("cat /etc/openwrt_release 2>/dev/null") or ""

    local os_ver = os_rel:match('VERSION_ID="([%d]+)') or ""
    local fw_ver = os_rel:match('VERSION_ID="([^"]+)"') or "Unknown"
    local has_apk = (sys.call("command -v apk >/dev/null 2>&1") == 0)
    
    if os_ver == "" then
        os_ver = has_apk and "25" or "24"
    end
    
    local is_apk = (os_ver == "25") or has_apk
    local pkg_ext = is_apk and "apk" or "ipk"
    
    local arch = owrt_rel:match("DISTRIB_ARCH=['\"]?([^'\"%s\n]+)") or ""
    
    if arch == "" then
        if not is_apk then
            arch = sys.exec("opkg print-architecture 2>/dev/null | grep -vE '(all|noarch)' | sort -n -k 2 -r | head -n 1 | awk '{print $2}'"):gsub("%s+", "")
        else
            arch = sys.exec("apk --print-arch 2>/dev/null"):gsub("%s+", "")
        end
    end
    
    if arch == "" then
        arch = sys.exec("uname -m 2>/dev/null"):gsub("%s+", "")
    end

    if arch == "x86-64" then arch = "x86_64" end

    local cur_ver = ""
    if type(read_file) == "function" then
        cur_ver = read_file("/usr/share/passwall-ssh/version") or ""
    end

    if cur_ver == "" then
        if is_apk then
            local raw = sys.exec("apk info passwall-ssh 2>/dev/null | head -n 1"):gsub("%s+", " ")
            cur_ver = raw:match("passwall%-ssh%-([%d%.%-_r]+)") or ""
        else
            cur_ver = sys.exec("opkg status passwall-ssh 2>/dev/null | grep -i '^Version:' | awk '{print $2}'"):gsub("%s+", "")
            if cur_ver == "" then
                cur_ver = sys.exec("opkg list-installed passwall-ssh 2>/dev/null | awk '{print $3}'"):gsub("%s+", "")
            end
        end
    end

    cur_ver = cur_ver:gsub("^v", ""):gsub("%-r%d+", ""):gsub("%-%d+$", ""):gsub("%s+", "")
    if cur_ver == "" then cur_ver = "Unknown" end

    return {
        os_ver = os_ver,
        fw_ver = fw_ver,
        pkg_ext = pkg_ext,
        arch = arch,
        cur_ver = cur_ver
    }
end

function action_get_app_info()
    local info = get_system_info()
    local resp = {
        arch = info.arch,
        version = info.cur_ver,
        os_ver = info.os_ver,
        fw_ver = info.fw_ver
    }
    luci.http.prepare_content("application/json")
    luci.http.write_json(resp)
end

-- ==========================================
-- BACA CACHE UPDATE & AUTO-CHECK DENGAN NOTIF
-- ==========================================
function action_get_update_status()
    local sys = require "luci.sys"
    local fs = require "nixio.fs"
    local cache_file = "/etc/passwall-ssh_update.json"
    
    local stat = fs.stat(cache_file)
    local current_time = os.time()
    local needs_update = false
    
    if not stat then
        needs_update = true
    else
        math.randomseed(current_time)
        
        local base_expiry = 86400
        local jitter = math.random(-14400, 14400)
        local target_expiry = base_expiry + jitter
        
        local mtime = stat.mtime or 0
        if (current_time - mtime) > target_expiry then
            needs_update = true
        end
    end
    
    if needs_update then
        sys.call("/usr/bin/lua -e 'require(\"luci.controller.passwall-ssh\").do_background_update_check()' >/dev/null 2>&1 &")
    end
    
    local f = io.open(cache_file, "r")
    
    luci.http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    luci.http.header("Pragma", "no-cache")
    luci.http.header("Expires", "0")
    
    if f then
        local content = f:read("*all")
        f:close()
        luci.http.prepare_content("application/json")
        luci.http.write(content)
    else
        luci.http.prepare_content("application/json")
        luci.http.write('{"has_update": false}')
    end
end

-- ==========================================
-- FUNGSI CHECK UPDATE
-- ==========================================
function do_background_update_check()
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local sys_info = get_system_info()
    
    local proxy_url = "https://passwall-ssh.avidemuxvegas.workers.dev/"
    local cmd = string.format("curl -sIL -m 10 '%shttps://github.com/avidemx/Passwall-SSH/releases/latest' 2>/dev/null | grep -i '^location:' | tail -n 1 | awk '{print $2}'", proxy_url)
    local loc_header = sys.exec(cmd) or ""
    loc_header = loc_header:gsub("[\r\n%s]+", "")
    
    local raw_tag = loc_header:match("/releases/tag/([^/?#]+)")
    if not raw_tag or raw_tag == "" then
        local api_cmd = "curl -skLf -m 8 -H 'User-Agent: OpenWrt' 'https://api.github.com/repos/avidemx/Passwall-SSH/releases/latest' 2>/dev/null"
        local api_res = sys.exec(api_cmd) or ""
        local api_json = json.parse(api_res)
        if api_json and api_json.tag_name then
            raw_tag = api_json.tag_name
        end
    end

    local result = { has_update = false }

    if raw_tag and raw_tag ~= "" then
        local latest_tag = raw_tag:gsub("^v", "")
        local target_file = string.format("passwall-ssh_%s_%s_%s.%s", 
            sys_info.os_ver, latest_tag, sys_info.arch, sys_info.pkg_ext
        )
        local dl_url = string.format("%shttps://github.com/avidemx/Passwall-SSH/releases/download/%s/%s", 
            proxy_url, raw_tag, target_file
        )
        
        local clean_cur = tostring(sys_info.cur_ver):gsub("^v", ""):gsub("%-r%d+", ""):gsub("%-%d+$", ""):gsub("%s+", "")
        local clean_latest = tostring(latest_tag):gsub("^v", ""):gsub("%-r%d+", ""):gsub("%-%d+$", ""):gsub("%s+", "")
        
        if clean_latest ~= clean_cur then
            result.has_update = true
            result.latest_version = latest_tag
            result.download_url = dl_url
        end
    end
    
    local f = io.open("/etc/passwall-ssh_update.json", "w")
    if f then
        f:write(json.stringify(result))
        f:close()
    end
end

function action_do_app_update()
    local sys = require "luci.sys"
    local dl_url = luci.http.formvalue("url") or ""
    
    local sys_info = get_system_info()
    local ext = sys_info.pkg_ext
    
    local sh_script = string.format([[
        #!/bin/sh
        URL="%s"
        EXT="%s"
        PKG_FILE="/tmp/passwall_update_pkg.${EXT}"
        LOG_FILE="/tmp/etc/passwall-ssh.log"

        echo "=== [UPDATE] Memulai Proses Update ===" > "$LOG_FILE"

        # 1. Download / Copy Package
        rm -f /tmp/passwall_update_pkg*
        if [ -f "$URL" ]; then
            cp -f "$URL" "$PKG_FILE"
        else
            echo "Downloading package..." >> "$LOG_FILE"
            curl -skL -m 60 "$URL" -o "$PKG_FILE" >> "$LOG_FILE" 2>&1
        fi

        if [ ! -s "$PKG_FILE" ]; then
            echo "ERROR: Download gagal atau file kosong" >> "$LOG_FILE"
            exit 1
        fi
        
        # 2. Backup Config Settingan & Cek Status Aktif
        echo "Membackup konfigurasi..." >> "$LOG_FILE"
        cp -f /etc/config/passwall-ssh /tmp/passwall-ssh.bak 2>/dev/null
        ENABLED=$(uci -q get passwall-ssh.main.enabled || echo "0")
        
        # 3. Stop Service Lama
        echo "Menghentikan service lama..." >> "$LOG_FILE"
        if [ -x "/etc/init.d/passwall-ssh" ]; then
            /etc/init.d/passwall-ssh stop >/dev/null 2>&1
            /etc/init.d/firewall restart >/dev/null 2>&1
        fi
        
        sleep 6
                
        # 4. Install Package
        echo "Mengekstrak dan Menginstal Package..." >> "$LOG_FILE"
        INSTALL_STATUS=0
        if [ "$EXT" = "apk" ] || command -v apk >/dev/null 2>&1; then
            apk add --repositories-file /dev/null --no-network --allow-untrusted --force-overwrite "$PKG_FILE" >> "$LOG_FILE" 2>&1
            INSTALL_STATUS=$?
        else
            opkg install --force-overwrite "$PKG_FILE" >> "$LOG_FILE" 2>&1
            INSTALL_STATUS=$?
        fi
        
        if [ $INSTALL_STATUS -ne 0 ]; then
            if grep -q "Installing file to" "$LOG_FILE"; then
                echo "Warning: Error pada script post-upgrade apk (127). Diabaikan karena file sukses terinstal." >> "$LOG_FILE"
                INSTALL_STATUS=0
            else
                echo "ERROR: Install gagal dengan kode $INSTALL_STATUS" >> "$LOG_FILE"
                [ -f /tmp/passwall-ssh.bak ] && cp -f /tmp/passwall-ssh.bak /etc/config/passwall-ssh
                exit 1
            fi
        fi
        
        # 5. Restore Config & Hapus Notifikasi
        echo "Mengembalikan konfigurasi..." >> "$LOG_FILE"
        if [ -f /tmp/passwall-ssh.bak ]; then
            cp -f /tmp/passwall-ssh.bak /etc/config/passwall-ssh
            rm -f /tmp/passwall-ssh.bak
        fi
        
        # Menghapus file cache status notifikasi supaya tombol menghilang
        rm -f /etc/passwall-ssh_update.json
        
        # 6. Bersihkan cache
        rm -f "$PKG_FILE" /tmp/do_pw_update.sh /etc/config/passwall-ssh-opkg /etc/config/passwall-ssh.apk-new
        rm -rf /tmp/luci-indexcache /tmp/luci-modulecache /tmp/luci-indexcache.*
        
        # 7. Start kembali jika sebelumnya aktif
        if [ "$ENABLED" = "1" ] && [ -x "/etc/init.d/passwall-ssh" ]; then
            echo "Menjalankan ulang service..." >> "$LOG_FILE"
            /etc/init.d/passwall-ssh enable >/dev/null 2>&1
            /etc/init.d/passwall-ssh restart >/dev/null 2>&1 &
        fi
        
        echo "=== [UPDATE] Berhasil Diselesaikan ===" >> "$LOG_FILE"
        exit 0
    ]], dl_url, ext)
    
    local f = io.open("/tmp/do_pw_update.sh", "w")
    if f then
        f:write(sh_script)
        f:close()
    else
        luci.http.prepare_content("application/json")
        luci.http.write_json({ status = "error", message = "Gagal membuat script update" })
        return
    end
    
    local ret = sys.call("sh /tmp/do_pw_update.sh")
    
    luci.http.prepare_content("application/json")
    if ret == 0 then
        luci.http.write_json({ status = "success" })
    else
        luci.http.write_json({ status = "error", message = "Update gagal. Silahkan periksa Log." })
    end
end

function action_check_services()
    local sys = require "luci.sys"
    local uci = require "luci.model.uci".cursor()
    local active_profile = uci:get("passwall-ssh", "main", "selected_profile") or "No Profile"

    sys.exec("mkdir -p /tmp/state/passwall-ssh")
    local core = sys.call("pidof badvpn-tun2socks >/dev/null 2>&1") == 0 and "1" or "0"
    local iface = "tun0"
    local rx = "0"
    local tx = "0"
    local start_time = "0"

    if core == "1" then
        local cur_rx = read_file("/sys/class/net/" .. iface .. "/statistics/rx_bytes")
        local cur_tx = read_file("/sys/class/net/" .. iface .. "/statistics/tx_bytes")
        if cur_rx ~= "" then rx = cur_rx end
        if cur_tx ~= "" then tx = cur_tx end
        
        write_file("/tmp/state/passwall-ssh/current_rx", rx)
        write_file("/tmp/state/passwall-ssh/current_tx", tx)

        local pid = sys.exec("pidof badvpn-tun2socks | awk '{print $1}' 2>/dev/null"):gsub("%s+", "")
        if pid ~= "" then
            start_time = sys.exec("stat -c %Y /proc/" .. pid .. " 2>/dev/null"):gsub("%s+", "")
            if start_time == "" or not tonumber(start_time) then
                local cmd = "awk -v btime=$(awk '/btime/ {print $2}' /proc/stat) '{print btime + int($22 / 100)}' /proc/" .. pid .. "/stat 2>/dev/null"
                start_time = sys.exec(cmd):gsub("%s+", "")
            end
            if start_time == "" or not tonumber(start_time) then start_time = "0" end
        end

        if start_time ~= "0" and tonumber(start_time) then
            local current_duration = os.time() - tonumber(start_time)
            if current_duration < 0 then current_duration = 0 end
            write_file("/tmp/state/passwall-ssh/current_conn", tostring(current_duration))
        end
    else
        local check_rx = read_file("/tmp/state/passwall-ssh/current_rx")
        if check_rx ~= "" and check_rx ~= "0" then
            local check_tx = read_file("/tmp/state/passwall-ssh/current_tx")
            local check_conn = read_file("/tmp/state/passwall-ssh/current_conn")

            write_file("/usr/share/passwall-ssh/last_rx", check_rx)
            write_file("/usr/share/passwall-ssh/last_tx", check_tx)
            write_file("/usr/share/passwall-ssh/last_conn", check_conn)

            os.remove("/tmp/state/passwall-ssh/current_rx")
            os.remove("/tmp/state/passwall-ssh/current_tx")
            os.remove("/tmp/state/passwall-ssh/current_conn")
        end
    end

    local last_rx = read_file("/usr/share/passwall-ssh/last_rx")
    local last_tx = read_file("/usr/share/passwall-ssh/last_tx")
    local last_conn = read_file("/usr/share/passwall-ssh/last_conn")
    
    if last_rx == "" then last_rx = "0" end
    if last_tx == "" then last_tx = "0" end
    if last_conn == "" then last_conn = "0" end

    luci.http.prepare_content("text/plain")
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
        luci.http.write("Loading...")
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
    sys.exec("echo '' > /tmp/etc/passwall-ssh.log")
    luci.http.prepare_content("text/plain")
    luci.http.write("OK")
end
