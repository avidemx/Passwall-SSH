local fs = require "nixio.fs"
local sys = require "luci.sys"

m = Map("passwall-ssh")

-- SlowDNS has its own UCI package. Keep it outside Map("passwall-ssh"):
-- chaining a package with custom raw-HTML fields can let the main CBI save path
-- rewrite that package without those fields being parsed as CBI options.
local slowdns_conf_path = m.uci:get_confdir() .. "/passwall-ssh-slowdns"
if fs.stat(slowdns_conf_path, "type") ~= "reg" then
    fs.writefile(slowdns_conf_path, "config slowdns 'SlowDNS'\n")
end

local slowdns_uci = require("luci.model.uci").cursor()
slowdns_uci:load("passwall-ssh-slowdns")

-- Chain the independent SlowDNS package so this page can save both packages
-- directly without invoking LuCI's global configuration-apply overlay.
m.uci:load("passwall-ssh-slowdns")
m:chain("passwall-ssh-slowdns")

m.on_before_save = function(self)
    local requested_mode = luci.http.formvalue("transport_mode_selection")
    if requested_mode ~= "slowdns" then
        requested_mode = "ssh"
    end

    -- The init script defaults to SSH when transport_mode is absent.
    -- Avoid staging a redundant UCI write when the requested mode is unchanged.
    local stored_mode = self.uci:get("passwall-ssh", "main", "transport_mode") or "ssh"
    if stored_mode ~= requested_mode then
        self.uci:set("passwall-ssh", "main", "transport_mode", requested_mode)
    end

    -- Stage SlowDNS values in this Map's UCI cursor. The custom Save & Apply
    -- hook below commits both Passwall-SSH packages directly.
    if requested_mode == "slowdns" then
        local function form_value(name, option)
            local value = luci.http.formvalue(name)
            if value == nil then
                value = slowdns_uci:get("passwall-ssh-slowdns", "SlowDNS", option)
            end
            return tostring(value or "")
        end

        local sd_enabled = luci.http.formvalue("slowdns_enabled") == "1" and "1" or "0"
        local password = luci.http.formvalue("slowdns_SSH_PASSWORD")
        if password == nil or password == "" then
            password = slowdns_uci:get("passwall-ssh-slowdns", "SlowDNS", "SSH_PASSWORD") or ""
        end

        local dns_transport = string.upper(form_value("slowdns_DNS_TRANSPORT", "DNS_TRANSPORT"))
        if dns_transport == "DOH" then
            dns_transport = "DoH"
        elseif dns_transport == "DOT" then
            dns_transport = "DoT"
        else
            dns_transport = "UDP"
        end
        local dns_resolver = form_value("slowdns_DNS_RESOLVER", "DNS_RESOLVER")
        if dns_resolver == "" then
            dns_resolver = form_value("slowdns_DNS_UDP_IP", "DNS_UDP_IP")
        end
        if dns_resolver == "" then dns_resolver = "1.1.1.1" end

        local legacy_dns_ip = slowdns_uci:get("passwall-ssh-slowdns", "SlowDNS", "DNS_UDP_IP") or "1.1.1.1"
        if dns_transport == "UDP" then legacy_dns_ip = dns_resolver end

        local slowdns_values = {
            enabled = sd_enabled,
            DNS_TRANSPORT = dns_transport,
            DNS_RESOLVER = dns_resolver,
            DNS_UDP_IP = legacy_dns_ip,
            Type_DNS = form_value("slowdns_Type_DNS", "Type_DNS"),
            DNSTT_DOMAIN = form_value("slowdns_DNSTT_DOMAIN", "DNSTT_DOMAIN"),
            DNSTT_SERVER_PUBLIC_KEY = form_value("slowdns_DNSTT_SERVER_PUBLIC_KEY", "DNSTT_SERVER_PUBLIC_KEY"),
            SSH_USERNAME = form_value("slowdns_SSH_USERNAME", "SSH_USERNAME"),
            SSH_PASSWORD = tostring(password)
        }

        if not self.uci:get("passwall-ssh-slowdns", "SlowDNS") then
            self.uci:section("passwall-ssh-slowdns", "slowdns", "SlowDNS", {})
        end

        -- Remove legacy SSH host/port options from existing UCI configs.
        self.uci:delete("passwall-ssh-slowdns", "SlowDNS", "SSH_HOST")
        self.uci:delete("passwall-ssh-slowdns", "SlowDNS", "SSH_PORT")

        for option, value in pairs(slowdns_values) do
            local current = self.uci:get("passwall-ssh-slowdns", "SlowDNS", option)
            if current == nil or tostring(current) ~= tostring(value) then
                self.uci:set("passwall-ssh-slowdns", "SlowDNS", option, value)
            end
        end
    end
end

-- Custom Save & Apply: commit only the two Passwall-SSH UCI packages directly,
-- then restart the selected backend. This avoids LuCI's global apply modal and
-- does not apply unrelated pending UCI changes from other pages.
m.on_after_save = function(self)
    if luci.http.formvalue("custom_save_apply") ~= "1" then
        return
    end

    local slowdns_ok, slowdns_err = self.uci:commit("passwall-ssh-slowdns")
    if slowdns_ok == false then
        sys.call("logger -t passwall-ssh 'Failed to commit passwall-ssh-slowdns'")
        sys.call("echo '[Passwall-SSH] Failed to save /etc/config/passwall-ssh-slowdns; service was not restarted.' >> /tmp/etc/passwall-ssh.log")
        return
    end

    local main_ok, main_err = self.uci:commit("passwall-ssh")
    if main_ok == false then
        sys.call("logger -t passwall-ssh 'Failed to commit passwall-ssh'")
        sys.call("echo '[Passwall-SSH] Failed to save /etc/config/passwall-ssh; service was not restarted.' >> /tmp/etc/passwall-ssh.log")
        return
    end

    sys.call("mkdir -p /tmp/etc")
    sys.call("echo STARTING > /tmp/etc/passwall-ssh.state")
    sys.call("/etc/init.d/passwall-ssh enable >/dev/null 2>&1")
    -- init.d restart enters _start(), which stops the old backend before
    -- starting the newly selected SSH HTTP or SlowDNS backend.
    sys.call("/etc/init.d/passwall-ssh restart >/dev/null 2>&1 &")
    local selected_mode = self.uci:get("passwall-ssh", "main", "transport_mode") or "ssh"
    local active_tab = luci.http.formvalue("active_tab_selection") or ""
    local allowed_tabs = selected_mode == "slowdns"
        and { slowdns = true, update = true, log = true }
        or { main = true, dns = true, config = true, update = true, log = true }

    if not allowed_tabs[active_tab] then
        active_tab = selected_mode == "slowdns" and "slowdns" or "main"
    end

    local page_url = luci.dispatcher.build_url("admin", "services", "passwall-ssh")
    luci.http.redirect(page_url .. "#tab=" .. active_tab)
end

local active_profile_id = m.uci:get("passwall-ssh", "main", "selected_profile")
local ssh_profile_name = "No Profile"

if active_profile_id and active_profile_id ~= "" then
    ssh_profile_name = m.uci:get("passwall-ssh", active_profile_id, "alias") or active_profile_id
end

local active_transport_mode = m.uci:get("passwall-ssh", "main", "transport_mode") or "ssh"
local active_profile = active_transport_mode == "slowdns" and "SlowDNS" or ssh_profile_name

local initial_service_state = fs.readfile("/tmp/etc/passwall-ssh.state") or ""
initial_service_state = initial_service_state:gsub("%s+", "")
if initial_service_state == "" then initial_service_state = "STOPPED" end
local initial_service_locked = initial_service_state ~= "STOPPED"

local function slowdns_html_escape(value)
    value = tostring(value or "")
    value = value:gsub("&", "&amp;")
    value = value:gsub("<", "&lt;")
    value = value:gsub(">", "&gt;")
    value = value:gsub('"', "&quot;")
    value = value:gsub("'", "&#39;")
    return value
end

-- ==========================================
-- TOP STATUS PANEL & CUSTOM TABS 
-- ==========================================
local top_sec = m:section(SimpleSection)
local header_ui = top_sec:option(DummyValue, "_header")
header_ui.rawhtml = true
header_ui.cfgvalue = function()
    local initial_mode = active_transport_mode == "slowdns" and "slowdns" or "ssh"
    return [=[
    <style>
    .cbi-section-table { width: 100%; border-collapse: collapse; margin-top: 10px; background: transparent; border-radius: 4px; overflow: hidden; }
    .cbi-section-table th, .cbi-section-table td { padding: 12px; text-align: left; border-bottom: 1px solid rgba(128, 128, 128, 0.2); color: inherit; }
    .cbi-section-table th { background: rgba(128, 128, 128, 0.1); color: inherit; font-size: 13px; font-weight: bold; }
    .cbi-section-table tr:hover { background: rgba(128, 128, 128, 0.05); }

    .full-width-container { display: block; width: 100%; clear: both; margin-bottom: 0px; color: inherit; }

    .pw-panel { display: grid; grid-template-columns: repeat(4, 1fr); gap: 15px; margin-bottom: 15px; background: transparent; padding: 15px; border-radius: 4px; border: 1px solid rgba(128, 128, 128, 0.2); width: 100%; box-sizing: border-box; }
    @media screen and (max-width: 768px) { .pw-panel { grid-template-columns: repeat(2, 1fr); } }
    @media screen and (max-width: 480px) { .pw-panel { grid-template-columns: 1fr; } }

    .pw-box { display: flex; align-items: center; background: rgba(128, 128, 128, 0.05); padding: 15px; border-radius: 4px; border: 1px solid rgba(128, 128, 128, 0.2); transition: 0.2s; }
    .pw-icon { width: 35px; height: 35px; margin-right: 15px; display: flex; align-items: center; justify-content: center; transition: 0.2s; }
    .pw-icon img { width: 100%; height: 100%; object-fit: contain; }
    .pw-info { display: flex; flex-direction: column; }
    .pw-title { font-size: 12px; color: inherit; opacity: 0.7; margin-bottom: 4px; font-weight: bold; }
    .pw-val { font-size: 14px; font-weight: bold; transition: 0.2s; }
    
    .pw-box.clickable { cursor: pointer; }
    .pw-box.clickable .pw-icon { opacity: 0.7; }
    .pw-box.clickable:hover .pw-icon { opacity: 1; transform: scale(1.1); }
    .toolbar-wrapper { display: flex; justify-content: flex-start; align-items: center; margin-bottom: 0px; flex-wrap: wrap; padding-bottom: 0px; gap: 15px; }
    
    /* ===== TAB CONTAINER ===== */
    .cbi-tabmenu { display: flex; color: inherit !important; gap: 3px; }
    .cbi-tabmenu > li { color: inherit !important; margin: 0; padding: 0; position: relative; }
    .cbi-tabmenu > li > a {
        display: block; padding: 8px 16px; line-height: 18px; color: inherit !important; text-decoration: none;
        background: rgba(128,128,128,.06); border: 1px solid rgba(128,128,128,.25); border-bottom-color: rgba(128,128,128,.25);
        border-radius: 4px 4px 0 0; box-shadow: inset 0 1px rgba(255,255,255,.08); transition: all .2s ease;
    }
    .cbi-tabmenu > li:hover > a { background: rgba(128,128,128,.12); }
    .cbi-tabmenu > li.active > a {
        color: #00AEFF !important; background: transparent; border-color: rgba(128,128,128,.25); border-top:2px solid #00AEFF;
        padding-top:7px; margin-bottom: -1px; box-shadow: 0 -1px 3px rgba(0,0,0,.05); font-weight: 600;
    } 

    /* NOTIFIKASI MERAH UPDATE */
    .tab-notif::after {
        content: '';
        position: absolute;
        top: 4px;
        right: 6px;
        width: 8px;
        height: 8px;
        background-color: #ff4c4c;
        border-radius: 50%;
        box-shadow: 0 0 5px rgba(255, 76, 76, 0.8);
    }
   
    .profile-text { font-size: 16px; color: inherit; opacity: 0.8; display: flex; align-items: center; margin-left: auto; }
    .profile-text .p-name { font-weight: bold; color: inherit; margin-right: 5px; opacity: 1; }
    .profile-text .p-status { font-weight: bold; margin-left: 3px; }

    #ip-widget-placeholder { display: flex; align-items: center; justify-content: center; margin-bottom: 15px; width: 100%; }
    
    .status-bar { 
        background: rgba(128, 128, 128, 0.05); border: 1px solid rgba(128, 128, 128, 0.2); border-radius: 4px;
        padding: 10px 15px; color: inherit; display: flex; justify-content: center; align-items: center;
        white-space: nowrap; width: 100%; box-sizing: border-box;
    }

    .inner { display: flex; align-items: center; gap: 12px; }
    .flag { height: 20px; width: 28px; display: flex; align-items: center; justify-content: center; overflow: hidden; } 
    .flag img { height: 100%; width: 100%; object-fit: contain; border-radius: 2px; }

    .ip-info-container { display: flex; align-items: center; gap: 8px; font-size: 14px; font-weight: bold; text-shadow: none; }
    .separator { color: inherit; opacity: 0.5; font-weight: normal; text-shadow: none; }

    .text-offline { color: #ff4c4c !important; }
    .text-online { color: #06BA06 !important; }
    .text-country { color: inherit !important; }
    .text-isp-name { color: #C7AF0C !important; }

    @keyframes spin-globe { 100% { transform: rotate(360deg); } }
    @keyframes wave-flag { 0%, 100% { transform: skewY(-3deg) scale(1); } 50% { transform: skewY(3deg) scale(1.05); } }

    .spin-anim { animation: spin-globe 1.5s linear infinite; height: 20px !important; width: 20px !important; }
    .wave-anim { animation: wave-flag 2.5s ease-in-out infinite; transform-origin: bottom left; }
    
    #log_box {
        background: transparent !important; padding: 10px; font-family: monospace; font-size: 12px;
        white-space: pre-wrap; overflow-y: auto; height: 450px; border-radius: 4px; border: 1px solid rgba(128,128,128,.4);
    }

    /* UPDATE PANEL STYLING */
    .update-card {
        background: rgba(128, 128, 128, 0.05);
        border: 1px solid rgba(128, 128, 128, 0.2);
        border-radius: 6px;
        padding: 20px;
        margin-top: 15px;
        display: flex;
        flex-direction: column;
        gap: 15px;
        max-width: 650px;
    }
    .update-row { display: flex; align-items: center; font-size: 14px; }
    .update-label { width: 180px; font-weight: bold; opacity: 0.85; }
    .update-value { font-weight: bold; }
    .btn-update {
        padding: 7px 18px;
        border: none;
        border-radius: 4px;
        cursor: pointer;
        font-weight: bold;
        font-size: 13px;
        transition: 0.2s;
    }
    .btn-apply { background: #28a745; color: #fff; }
    .btn-apply:hover { background: #218838; }
    .btn-disabled { background: rgba(128,128,128,0.3) !important; color: #999 !important; cursor: not-allowed !important; }

    .hide-main-fields #cbi-passwall-ssh-main-enabled,
    .hide-main-fields #cbi-passwall-ssh-main-selected_profile { display: none !important; }

    .hide-dns-fields #cbi-passwall-ssh-main-dns_proto,
    .hide-dns-fields #cbi-passwall-ssh-main-dns_ip,
    .hide-dns-fields #cbi-passwall-ssh-main-dns_url { display: none !important; }

    /* SlowDNS custom form is shown only while its tab is selected. */
    .hide-slowdns-fields #cbi-passwall-ssh-main-_slowdns_settings { display: none !important; }

    #slowdns-settings-panel .cbi-value { display: flex; align-items: flex-start; }
    #slowdns-settings-panel .cbi-value-title { width: 25%; min-width: 145px; }
    #slowdns-settings-panel .cbi-value-field { flex: 1; min-width: 0; }
    #slowdns-settings-panel input[type="text"],
    #slowdns-settings-panel input[type="password"],
    #slowdns-settings-panel select { width: 100%; max-width: 360px; box-sizing: border-box; }
    .cbi-button-reset { display: none !important; }
    .slowdns-save-apply {
        min-width: 0; min-height: 0; padding: 4px 9px !important;
        font-size: 13px; line-height: 1.35; font-weight: 600;
        border-width: 1px; border-radius: 3px;
    }
    @media screen and (max-width: 600px) {
        #slowdns-settings-panel .cbi-value { display: block; }
        #slowdns-settings-panel .cbi-value-title { width: auto; display: block; margin-bottom: 5px; }
    }

    .slowdns-fields-view #cbi-passwall-ssh-main-enabled,
    .slowdns-fields-view #cbi-passwall-ssh-main-selected_profile { display: none !important; }

    .connection-mode-row {
        display: flex;
        align-items: center;
        justify-content: center;
        gap: 12px;
        margin: 0 0 14px 0;
        padding: 10px 14px;
        border: 1px solid rgba(128,128,128,.22);
        border-radius: 5px;
        background: rgba(128,128,128,.04);
    }
    .connection-mode-title { font-weight: bold; font-size: 13px; }
    .connection-mode-label { min-width: 78px; font-size: 13px; font-weight: bold; }
    .connection-mode-toggle { position: relative; display: inline-block; width: 48px; height: 25px; }
    .connection-mode-toggle input { opacity: 0; width: 0; height: 0; }
    .connection-mode-slider {
        position: absolute; inset: 0; cursor: pointer;
        background: #777; border-radius: 20px; transition: .2s;
    }
    .connection-mode-slider:before {
        position: absolute; content: ""; height: 19px; width: 19px;
        left: 3px; top: 3px; background: #fff; border-radius: 50%;
        transition: .2s;
    }
    .connection-mode-toggle input:checked + .connection-mode-slider { background: #1689d7; }
    .connection-mode-toggle input:checked + .connection-mode-slider:before { transform: translateX(23px); }
    .connection-mode-row.mode-locked { opacity: .62; }
    .connection-mode-toggle input:disabled + .connection-mode-slider {
        cursor: not-allowed;
        opacity: .65;
    }

    .cbi-map { padding-top: 0 !important; }
    .cbi-section, .cbi-map-section { margin-top: -8px !important; padding-top: 0 !important; }
    fieldset.cbi-section legend { margin-bottom: 0 !important; padding-bottom: 0 !important; }
    .cbi-tabmenu { border-bottom: none !important; }
    </style>

    <div class="full-width-container">
        <!-- Status Panel -->
        <div class="pw-panel">
            <div class="pw-box">
                <div class="pw-icon">
                    <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0iIzM4YmRmOCI+PHBhdGggZD0iTTIuMDEgMjFMMjMgMTIgMi4wMSAzIDIgMTBsMTUgMi0xNSAyeiIvPjwvc3ZnPg==">
                </div>
                <div class="pw-info"><span class="pw-title">CORE</span><span class="pw-val" id="status-core" style="color:#ff4c4c;">Check...</span></div>
            </div>

            <div class="pw-box clickable" onclick="touchCheck('https://www.google.com', 'status-google')">
                <div class="pw-icon">
                    <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0iIzQyODVGNCIgZD0iTTIyLjU2IDEyLjI1YzAtLjc4LS4wNy0xLjUzLS4yLTIuMjVIMTJ2NC4yNmg1LjkyYy0uMjYgMS4zNy0xLjA0IDIuNTMtMi4yMSAzLjMxdjIuNzdoMy41N2MyLjA4LTEuOTIgMy4yOC00Ljc0IDMuMjgtOC4wOXoiLz48cGF0aCBmaWxsPSIjMzRBODUzIiBkPSJNMTIgMjNjMi45NyAwIDUuNDYtLjk4IDcuMjgtMi42NmwtMy41Ny0yLjc3Yy0uOTguNjYtMi4yMyAxLjA2LTMuNzEgMS4wNi0yLjg2IDAtNS4yOS0xLjkzLTYuMTYtNC41M0gyLjE4djIuODRDMy45OSAyMC41MyA3LjcwIDIzIDEyIDIzeiIvPjxwYXRoIGZpbGw9IiNGQkJDMDUiIGQ9Ik01Ljg0IDE0LjA5Yy0uMjItLjY2LS4zNS0xLjM2LS4zNS0yLjA5cy4xMy0xLjQzLjM1LTIuMDlWNy4wN0gyLjE4QzEuNDMgOC41NSAxIDEwLjIyIDEgMTJzLjQzIDMuNDUgMS4xOCA0LjkzbDIuODUtMi4yMi44MS0uNjJ6Ii8+PHBhdGggZmlsbD0iI0VBNDMzNSIgZD0iTTEyIDUuMzhjMS42MiAwIDMuMDYuNTYgNC4yMSAxLjY0bDMuMTUtMy4xNUMxNy40NSAyLjA5IDE0Ljk3IDEgMTIgMSA3LjcwIDEgMy45OSAzLjQ3IDIuMTggNy4wN2wzLjY2IDIuODRjLjg3LTIuNjAgMy4zLTQuNTMgNi4xNi00LjUzeiIvPjwvc3ZnPg==">
                </div>
                <div class="pw-info"><span class="pw-title">Google</span><span class="pw-val" id="status-google" style="color:#5bc0de;">Touch to Check</span></div>
            </div>
            <div class="pw-box clickable" onclick="touchCheck('https://www.github.com', 'status-github')">
                <div class="pw-icon">
                    <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0iY3VycmVudENvbG9yIj48cGF0aCBkPSJNMTIgMkM2LjQ3NyAyIDIgNi40NzcgMiAxMmMwIDQuNDIgMi44NjUgOC4xNjYgNi44MzkgOS40ODkuNS4wOTIuNjgyLS4yMTcuNjgyLS40ODIgMC0uMjM3LS4wMDgtLjg2Ni0uMDEzLTEuNy0yLjc4Mi42MDMtMy4zNjktMS4zNC0zLjM2OS0xLjM0LS40NTQtMS4xNTYtMS4xMS0xLjQ2Mi0xLjExLTEuNDYyLS45MDgtLjYyLjA2OS0uNjA4LjA2OS0uNjA4IDEuMDAzLjA3IDEuNTMxIDEuMDMgMS41MzEgMS4wMy44OTIgMS41MjkgMi4zNDEgMS4wODcgMi45MS44MzEuMDkyLS42NDYuMzUtMS4wODYuNjM2LTEuMzM2LTIuMjItLjI1My00LjU1NS0xLjExLTQuNTU1LTQuOTQzIDAtMS4wOTEuMzktMS45ODQgMS4wMjktMi42ODMtLjEwMy0uMjUzLS40NDYtMS4yNy4wOTgtMi42NDcgMCAwIC44NC0uMjY5IDIuNzUgMS4wMjVBOS41NzggOS41NzggMCAwMTEyIDYuODM2Yy44NS4wMDQgMS43MDUuMTE0IDIuNTA0LjMzNiAxLjkwOS0xLjI5NCAyLjc0Ny0xLjAyNSAyLjc0Ny0xLjAyNS41NDYgMS4zNzcuMjAzIDIuMzk0LjEuMjY0Ny42NC42OTkgMS4wMjggMS41OTIgMS4wMjggMi42ODMgMCAzLjg0Mi0yLjMzOSA0LjY4Ny00LjU2NiA0LjkzNS4zNTkuMzA5LjY3OC45MTkuNjc4IDEuODUyIDAgMS4zMzYtLjAxMiAyMC40MTUtLjAxMiAyMC43NDMgMCAuMjY3LjE4LjU3OC42ODguNDhDMTkuMTM4IDIwLjE2MSAyMiAxNi40MTYgMjIgMTJjMC01LjUyMy00LjQ3Ny0xMC0xMC0xMHoiLz48L3N2Zz4=">
                </div>
                <div class="pw-info"><span class="pw-title">Github</span><span class="pw-val" id="status-github" style="color:#5bc0de;">Touch to Check</span></div>
            </div>
            <div class="pw-box clickable" onclick="touchCheck('https://www.youtube.com', 'status-youtube')">
                <div class="pw-icon">
                    <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0iI2ZmMDAwMCI+PHBhdGggZD0iTTIxLjU4IDYuNTVjLS4yMy0uODYtLjkxLTEuNTQtMS43Ny0xLjc3QzE4LjI1IDQuMzMgMTIgNC4zMyAxMiA0LjMzcy02LjI1IDAtNy44MS40NWMtLjg2LjIzLTEuNTQuOTEtMS43NyAxLjc3QzIgOC4xMSAyIDEyIDIgMTJzMCAzLjg5LjQyIDUuNDVjLjIzLjg2LjkxIDEuNTQgMS43NyAxLjc3IDEuNTYuNDUgNy44MS40NSA3LjgxLjQ1czYuMjUgMCA3LjgxLS40NWMuODYtLjIzIDEuNTQtLjkxIDEuNzctMS43Ny40Mi0xLjU2LjQyLTUuNDUuNDItNS40NXMwLTMuODktLjQyLTUuNDV6TTkuOTkgMTUuNXYtN2w2LjUgMy41LTYuNSAzLjV6Ii8+PC9zdmc+">
                </div>
                <div class="pw-info"><span class="pw-title">Youtube</span><span class="pw-val" id="status-youtube" style="color:#5bc0de;">Touch to Check</span></div>
            </div>
        </div>

        <!-- Widget IP -->
        <div id="ip-widget-placeholder">
            <div id="actual-ip-widget" class="status-bar">
                <div class="inner">
                    <div class="flag">
                        <img src="" id="flag-img-element" class="spin-anim">
                    </div>
                    <div class="ip-info-container">
                        <div id="widget-ip-text" class="text-offline">Loading...</div>
                        <div id="widget-separator" class="separator" style="display: none;">|</div>
                        <div id="widget-info-text" class="text-offline" style="display: none;"></div>
                    </div>
                </div>
            </div>
        </div>

        <!-- Widget Stats -->
        <div id="stats-widget-container" class="status-bar" style="justify-content: space-between !important; margin-bottom: 25px; display: flex; width: 100%;">
            <div style="display: flex; flex-direction: column; text-align: left; gap: 3px; flex: 1;">
                <div style="font-size: 13px; font-weight: bold;">
                    <span style="opacity: 1;">Connection Time:</span>
                    <span id="conn-time-val" style="color: #4caf50;">00:00:00</span>
                </div>
                <div style="font-size: 12px; opacity: 0.8;">
                    <span>Last Connection Time :</span>
                    <span id="last-conn-time-val">00:00:00</span>
                </div>
            </div>

            <div class="profile-text" style="margin-left: 0; justify-content: center; flex: 1; display: flex; align-items: center;">
                <span class="p-name" data-ssh-profile="]=] .. slowdns_html_escape(ssh_profile_name) .. [=[">]=] .. slowdns_html_escape(active_profile) .. [=[</span> :
                <span class="p-status" id="profile-status" style="color:#888;">Checking...</span>
            </div>

            <div style="display: flex; flex-direction: column; text-align: right; gap: 3px; flex: 1;">
                <div style="display: flex; justify-content: flex-end; gap: 15px; font-size: 13px; font-weight: bold;">
                    <div><span style="color: #4da6ff;">↓ RX:</span> <span id="rx-val">0 B</span></div>
                    <div><span style="color: #FAAF00;">↑ TX:</span> <span id="tx-val">0 B</span></div>
                </div>
                <div style="display: flex; justify-content: flex-end; gap: 15px; font-size: 12px; opacity: 0.8;">
                    <div>Last RX: <span id="last-rx-val">0 B</span></div>
                    <div>Last TX: <span id="last-tx-val">0 B</span></div>
                </div>
            </div>
        </div>

        <!-- Connection Mode: independent of CBI change tracking -->
        <div class="connection-mode-row">
            <span class="connection-mode-title">Connection Mode</span>
            <label class="connection-mode-toggle" title="SSH HTTP / SlowDNS">
                <input type="checkbox" id="connection-mode-switch" ]=] ..
                    (initial_service_locked and 'disabled="disabled"' or '') .. [=[ />
                <span class="connection-mode-slider"></span>
            </label>
            <span class="connection-mode-label" id="connection-mode-label">SSH HTTP</span>
            <input type="hidden" id="transport-mode-selection"
                name="transport_mode_selection" value="]=] .. initial_mode .. [=[" />
            <input type="hidden" id="active-tab-selection"
                name="active_tab_selection" value="]=] .. (initial_mode == "slowdns" and "slowdns" or "main") .. [=[" />
        </div>

        <!-- TOOLBAR TABS -->
        <div class="toolbar-wrapper">
            <ul class="cbi-tabmenu">
                <li id="tab_main" class="active"><a href="javascript:void(0)" onclick="switchTab('main')">MAIN</a></li>
                <li id="tab_dns"><a href="javascript:void(0)" onclick="switchTab('dns')">DNS</a></li>
                <li id="tab_config"><a href="javascript:void(0)" onclick="switchTab('config')">Profile</a></li>
                <li id="tab_slowdns"><a href="javascript:void(0)" onclick="switchTab('slowdns')">SlowDNS</a></li>
                <li id="tab_update"><a href="javascript:void(0)" onclick="switchTab('update')">App Update</a></li>
                <li id="tab_log"><a href="javascript:void(0)" onclick="switchTab('log')">Log</a></li>
            </ul>
        </div>

        <!-- App Update Container -->
        <div id="update-container" style="display: none;">
            <div class="update-card">
                <div class="update-row">
                    <div class="update-label">Firmware Version :</div>
                    <div class="update-value" id="upd-fw-ver">Detecting...</div>
                </div>
                <div class="update-row">
                    <div class="update-label">Passwall-SSH Version :</div>
                    <div class="update-value" id="upd-cur-ver">Detecting...</div>
                </div>
                
                <div id="update-check-result" style="display: none; font-size: 14px; font-weight: bold; margin-top: 5px;"></div>
                
                <div style="margin-top: 5px;">
                    <button type="button" id="btn-app-update" class="btn-update btn-apply" style="display: none;" onclick="handleAppUpdate()">Click to update</button>
                </div>
            </div>
        </div>

        <!-- Log Container -->
        <div id="log-container" style="display: none;">
            <div style="display: flex; align-items: center; gap: 15px; margin-bottom: 13px;">
                <button type="button" class="cbi-button cbi-button-remove" onclick="clearLog()" style="padding: 2px 10px; font-size: 12px; cursor: pointer; border-radius: 3px;">Clear Logs</button>
                <!-- Tambahan Tombol Copy -->
                <button type="button" id="btn-copy-log" class="cbi-button cbi-button-apply" onclick="copyLog()" style="padding: 2px 10px; font-size: 12px; cursor: pointer; border-radius: 3px;">Copy Logs</button>
            </div>
            <div id="log_box"></div>
        </div>
    </div>

    <script type="text/javascript">
        const loadingGlobeURI = "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMDAgMTAwIiB3aWR0aD0iMjQiIGhlaWdodD0iMjQiPjxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjQwIiBzdHJva2U9IiM4ODgiIHN0cm9rZS13aWR0aD0iOCIgZmlsbD0ibm9uZSIgb3BhY2l0eT0iMC4zIi8+PGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iNDAiIHN0cm9rZT0iIzAwQUVGRiIgc3Ryb2tlLXdpZHRoPSI4IiBmaWxsPSJub25lIiBzdHJva2UtZGFzaGFycmF5PSI3MCAyMDAiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjwvc3ZnPg==";
        const CHECK_IP_URL = ']=] .. luci.dispatcher.build_url("admin", "services", "passwall-ssh", "check_ip") .. [=[';
        const GET_APP_INFO_URL = ']=] .. luci.dispatcher.build_url("admin", "services", "passwall-ssh", "get_app_info") .. [=[';
        const GET_UPDATE_STATUS_URL = ']=] .. luci.dispatcher.build_url("admin", "services", "passwall-ssh", "get_update_status") .. [=[';
        const DO_APP_UPDATE_URL = ']=] .. luci.dispatcher.build_url("admin", "services", "passwall-ssh", "do_app_update") .. [=[';
        
        window.isFetchingIP = false;
        var startTimeEpoch = 0;
        var timerInterval = null;
        var latestDownloadUrl = "";
        var updateReady = false;
        var serviceLocked = ]=] .. (initial_service_locked and "true" or "false") .. [=[;

        function formatBytes(bytes) {
            bytes = parseInt(bytes);
            if (isNaN(bytes) || bytes <= 0) return "0 B";
            var k = 1024;
            var sizes = ["B", "KB", "MB", "GB", "TB"];
            var i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + " " + sizes[i];
        }

        function formatSeconds(sec) {
            sec = parseInt(sec);
            if (isNaN(sec) || sec <= 0) return "00:00:00";
            var hrs = Math.floor(sec / 3600);
            var mins = Math.floor((sec % 3600) / 60);
            var secs = sec % 60;
            var hStr = hrs < 10 ? "0" + hrs : hrs;
            var mStr = mins < 10 ? "0" + mins : mins;
            var sStr = secs < 10 ? "0" + secs : secs;
            return hStr + ":" + mStr + ":" + sStr;
        }

        function startConnTimer() {
            if (timerInterval) clearInterval(timerInterval);
            timerInterval = setInterval(function() {
                var connTimeEl = document.getElementById("conn-time-val");
                if (!connTimeEl) return;
                if (startTimeEpoch > 0) {
                    var now = Math.floor(Date.now() / 1000);
                    var diff = now - startTimeEpoch;
                    if (diff < 0) diff = 0;
                    connTimeEl.innerText = formatSeconds(diff);
                } else {
                    connTimeEl.innerText = "00:00:00";
                }
            }, 1000);
        }

        function write_status(data) {
            const flagImg = document.getElementById("flag-img-element");
            const ipText = document.getElementById("widget-ip-text");
            const infoText = document.getElementById("widget-info-text");
            const sepText = document.getElementById("widget-separator");
            const pStatus = document.getElementById("profile-status");
            
            if (!flagImg || !ipText || !infoText) return;

            if (data.ip === "Offline" || data.ip === "Loading..." || !data.ip) {
                flagImg.src = loadingGlobeURI;
                flagImg.className = "spin-anim";
                ipText.innerHTML = data.ip || "Offline";
                ipText.className = "text-offline";
                if (sepText) sepText.style.display = "none";
                infoText.style.display = "none";
                if(pStatus) {
                    pStatus.innerHTML = (data.ip === "Loading...") ? "Checking..." : "Disconnected";
                    pStatus.style.color = (data.ip === "Loading...") ? "#888" : "#ff4c4c";
                }
            } else {
                let countryCode = data.flag ? data.flag.toLowerCase() : "un"; 
                flagImg.src = 'https://flagcdn.com/w40/' + countryCode + '.png';
                setTimeout(function() { flagImg.className = "wave-anim"; }, 50);

                ipText.innerHTML = data.ip;
                ipText.className = "text-online";
                if (sepText) sepText.style.display = "block";
                infoText.style.display = "block";
                infoText.innerHTML = '<span class="text-country">' + (data.country || "Unknown") + '</span> <span class="separator">|</span> <span class="text-isp-name">' + (data.isp || "Unknown") + '</span>';
                infoText.className = ""; 
                if(pStatus) {
                    pStatus.innerHTML = "Connected";
                    pStatus.style.color = "#06BA06";
                }
            }
        }

        window.forceCheckIP = function() {
            if (window.isFetchingIP) return; 
            window.isFetchingIP = true;
            write_status({ ip: "Loading..." }); 
            fetch(CHECK_IP_URL)
                .then(function(res) { return res.json(); })
                .then(function(data) {
                    write_status(data);
                    window.isFetchingIP = false;
                })
                .catch(function(e) {
                    write_status({ ip: "Offline" });
                    window.isFetchingIP = false; 
                });
        };

        window.setOfflineUI = function() { write_status({ ip: "Offline" }); };

        function findSection(markerId) {
            var el = document.getElementById(markerId);
            while (el && !el.classList.contains('cbi-section') && !el.classList.contains('cbi-map-section') && el.tagName.toLowerCase() !== 'fieldset') {
                el = el.parentElement;
            }
            return el;
        }

        function loadAppInfo() {
            fetch(GET_APP_INFO_URL)
                .then(function(res) { return res.json(); })
                .then(function(data) {
                    var fwVerEl = document.getElementById('upd-fw-ver');
                    var verEl = document.getElementById('upd-cur-ver');
                    
                    if (fwVerEl) fwVerEl.innerText = (data.fw_ver || "Unknown") + " - " + (data.arch || "Unknown");
                    if (verEl) verEl.innerText = data.version || "Unknown";
                });
        }

        function checkUpdateStatus() {
            // Tambahkan anti-cache (URL timestamp & fetch parameter)
            var url = GET_UPDATE_STATUS_URL;
            url += (url.indexOf('?') === -1 ? '?' : '&') + 't=' + new Date().getTime();
            
            fetch(url, { cache: 'no-store' })
                .then(function(r) { return r.json(); })
                .then(function(res) {
                    if (res.has_update) {
                        document.getElementById('tab_update').classList.add('tab-notif');
                        var btn = document.getElementById('btn-app-update');
                        var resBox = document.getElementById('update-check-result');
                        
                        if(btn) btn.style.display = "inline-block";
                        if(resBox) {
                            resBox.style.display = "block";
                            resBox.innerHTML = '<span style="color:#ff4c4c;">Latest Version ' + res.latest_version + ' is available!</span>';
                        }
                        
                        latestDownloadUrl = res.download_url;
                        updateReady = true;
                    }
                })
                .catch(function(e) { console.log("Failed to load update status"); });
        }

        function selectedTransportMode() {
            var modeInput = document.getElementById('transport-mode-selection');
            return modeInput && modeInput.value === 'slowdns' ? 'slowdns' : 'ssh';
        }

        function updateModeLock(state, core) {
            var normalized = String(state || '').toUpperCase();
            var locked = normalized !== ''
                ? normalized !== 'STOPPED'
                : core === '1';
            serviceLocked = !!locked;

            var modeSwitch = document.getElementById('connection-mode-switch');
            var modeRow = document.querySelector('.connection-mode-row');
            if (modeSwitch) {
                modeSwitch.disabled = serviceLocked;
                modeSwitch.title = serviceLocked
                    ? 'Stop Passwall-SSH and wait until STOPPED before changing mode.'
                    : 'Select SSH HTTP or SlowDNS mode.';
                modeSwitch.setAttribute('aria-disabled', serviceLocked ? 'true' : 'false');
            }
            if (modeRow) {
                modeRow.classList.toggle('mode-locked', serviceLocked);
            }
        }

        function switchTab(tabName) {
            var slowDnsMode = selectedTransportMode() === 'slowdns';
            var visibleTabs = slowDnsMode
                ? ['slowdns', 'update', 'log']
                : ['main', 'dns', 'config', 'update', 'log'];

            if (visibleTabs.indexOf(tabName) === -1)
                tabName = slowDnsMode ? 'slowdns' : 'main';

            var activeTabInput = document.getElementById('active-tab-selection');
            if (activeTabInput) activeTabInput.value = tabName;

            var tabHash = '#tab=' + encodeURIComponent(tabName);
            if (window.history && window.history.replaceState) {
                window.history.replaceState(null, document.title,
                    window.location.pathname + window.location.search + tabHash);
            } else {
                window.location.hash = tabHash;
            }

            /* SlowDNS fields are submitted only in SlowDNS mode. Keep them
               enabled while the SlowDNS backend is selected, even on Update/Log. */
            var slowDnsPanel = document.getElementById('slowdns-settings-panel');
            if (slowDnsPanel) {
                var slowDnsInputs = slowDnsPanel.querySelectorAll('input, select');
                Array.prototype.forEach.call(slowDnsInputs, function(input) {
                    input.disabled = !slowDnsMode;
                });
            }

            /* SSH CBI fields must not be submitted in SlowDNS mode.
               Their Lua write/remove hooks below preserve the stored SSH UCI
               values when CBI parses these disabled (missing) form controls. */
            var secMain = findSection('marker-main');
            if (secMain) {
                var mainInputs = secMain.querySelectorAll('input, select');
                Array.prototype.forEach.call(mainInputs, function(input) {
                    if (slowDnsPanel && slowDnsPanel.contains(input)) return;
                    if (input.id === 'connection-mode-switch') return;
                    if (input.id === 'transport-mode-selection') return;
                    if (input.name === 'transport_mode_selection') return;

                    input.disabled = slowDnsMode;
                });
            }

            var profileName = document.querySelector('.p-name');
            if (profileName) {
                profileName.textContent = slowDnsMode
                    ? 'SlowDNS'
                    : (profileName.getAttribute('data-ssh-profile') || 'No Profile');
            }

            ['main', 'dns', 'config', 'slowdns', 'update', 'log'].forEach(function(t) {
                var tab = document.getElementById('tab_' + t);
                if (!tab) return;
                tab.classList.remove('active');
                tab.style.display = visibleTabs.indexOf(t) !== -1 ? '' : 'none';
            });

            var activeTab = document.getElementById('tab_' + tabName);
            if (activeTab) activeTab.classList.add('active');

            var secConfig = findSection('marker-config');
            var secLog = document.getElementById('log-container');
            var secUpdate = document.getElementById('update-container');

            if (secMain) {
                var showMainSection = (tabName === 'main' || tabName === 'dns' || tabName === 'slowdns');
                secMain.style.display = showMainSection ? 'block' : 'none';
                secMain.classList.remove('hide-main-fields', 'hide-dns-fields',
                                         'hide-slowdns-fields', 'slowdns-fields-view');

                if (tabName === 'main') {
                    secMain.classList.add('hide-dns-fields', 'hide-slowdns-fields');
                } else if (tabName === 'dns') {
                    secMain.classList.add('hide-main-fields', 'hide-slowdns-fields');
                } else if (tabName === 'slowdns') {
                    secMain.classList.add('hide-main-fields', 'hide-dns-fields');
                }
            }

            if (secConfig) secConfig.style.display = (tabName === 'config' && !slowDnsMode) ? 'block' : 'none';

            if (secLog) {
                secLog.style.display = (tabName === 'log') ? 'block' : 'none';
                if (tabName === 'log') updateLog();
            }

            if (secUpdate) {
                secUpdate.style.display = (tabName === 'update') ? 'block' : 'none';
                if (tabName === 'update') loadAppInfo();
            }

            var modeLabel = document.getElementById('connection-mode-label');
            if (modeLabel) modeLabel.textContent = slowDnsMode ? 'SlowDNS' : 'SSH HTTP';
        }

        window.switchMode = function(mode) {
            if (mode !== 'ssh' && mode !== 'slowdns') return;

            var modeInput = document.getElementById('transport-mode-selection');
            var modeSwitch = document.getElementById('connection-mode-switch');

            if (serviceLocked) {
                var savedMode = modeInput && modeInput.value === 'slowdns' ? 'slowdns' : 'ssh';
                if (modeSwitch) modeSwitch.checked = (savedMode === 'slowdns');
                switchTab(savedMode === 'slowdns' ? 'slowdns' : 'main');
                return;
            }

            if (modeInput) modeInput.value = mode;
            if (modeSwitch) modeSwitch.checked = (mode === 'slowdns');

            switchTab(mode === 'slowdns' ? 'slowdns' : 'main');
        };

        window.handleAppUpdate = function() {
            if (!updateReady) return;
            var btn = document.getElementById('btn-app-update');
            
            btn.classList.add('btn-disabled');
            btn.disabled = true;

            btn.innerText = "[Downloading]";
            setTimeout(function() {
                if (btn.innerText === "[Downloading]") btn.innerText = "[Unpacking]";
            }, 3000);
            setTimeout(function() {
                if (btn.innerText === "[Unpacking]") btn.innerText = "[Moving]";
            }, 6000);

            var formData = new FormData();
            formData.append("url", latestDownloadUrl);

            fetch(DO_APP_UPDATE_URL, {
                method: "POST",
                body: formData
            })
            .then(function(r) { return r.json(); })
            .then(function(res) {
                if (res.status === "success") {
                    btn.innerText = "[Update Successfull]";
                    btn.style.background = "#28a745";
                    setTimeout(function() {
                        location.reload();
                    }, 2000);
                } else {
                    btn.innerText = "Update Failed!";
                    btn.style.background = "#dc3545";
                    setTimeout(function() {
                        btn.style.background = "";
                        btn.classList.remove('btn-disabled');
                        btn.disabled = false;
                        btn.innerText = "Click to update";
                    }, 3000);
                }
            })
            .catch(function(e) {
                btn.innerText = "Error!";
                btn.style.background = "#dc3545";
                setTimeout(function() {
                    btn.style.background = "";
                    btn.classList.remove('btn-disabled');
                    btn.disabled = false;
                    btn.innerText = "Click to update";
                }, 3000);
            });
        };

        function touchCheck(host, elId) {
            var el = document.getElementById(elId);
            if(!el) return;
            el.innerHTML = "Checking...";
            el.style.color = "#5bc0de"; 
            var xhr = new XMLHttpRequest();
            xhr.open('GET', ']=] .. luci.dispatcher.build_url("admin", "services", "passwall-ssh", "check_conn") .. [=[?host=' + host, true);
            xhr.onreadystatechange = function() {
                if (xhr.readyState === 4 && xhr.status === 200) {
                    var ms = parseInt(xhr.responseText);
                    if (isNaN(ms)) { el.innerHTML = "FAILED"; el.style.color = "#ff4c4c"; } 
                    else { el.innerHTML = ms + " ms"; el.style.color = (ms < 500) ? "#4caf50" : "#ff9800"; }
                }
            };
            xhr.send();
        }

        function updateServiceBadge(id, state) {
            var el = document.getElementById(id);
            if(!el) return;
            if(state === "1") { el.innerHTML = "RUNNING"; el.style.color = "#4caf50"; } 
            else { el.innerHTML = "NOT RUNNING"; el.style.color = "#ff4c4c"; }
        }

        function checkServicesLoop() {
            var xhr = new XMLHttpRequest();
            xhr.open('GET', ']=] .. luci.dispatcher.build_url("admin", "services", "passwall-ssh", "check_services") .. [=[', true);
            xhr.onreadystatechange = function() {
                if (xhr.readyState === 4 && xhr.status === 200) {
                    var raw = xhr.responseText.trim();
                    var parts = raw.split(',');

                    if(parts.length >= 1) {
                        updateServiceBadge('status-core', parts[0]);
                        updateModeLock(parts[10] || '', parts[0]);

                        if (parts[3]) {
                            var pName = document.querySelector('.p-name');
                            var modeInput = document.getElementById('transport-mode-selection');
                            if (pName) {
                                pName.setAttribute('data-ssh-profile', parts[3]);
                                pName.textContent = (modeInput && modeInput.value === 'slowdns')
                                    ? 'SlowDNS' : parts[3];
                            }
                        }

                        var rxVal = (parts.length > 4) ? parseInt(parts[4]) : 0;
                        var txVal = (parts.length > 5) ? parseInt(parts[5]) : 0;
                        var startVal = (parts.length > 6) ? parseInt(parts[6]) : 0;
                        var lastConnVal = (parts.length > 7) ? parseInt(parts[7]) : 0;
                        var lastRxVal = (parts.length > 8) ? parseInt(parts[8]) : 0;
                        var lastTxVal = (parts.length > 9) ? parseInt(parts[9]) : 0;

                        var rxEl = document.getElementById("rx-val");
                        var txEl = document.getElementById("tx-val");
                        var lastConnEl = document.getElementById("last-conn-time-val");
                        var lastRxEl = document.getElementById("last-rx-val");
                        var lastTxEl = document.getElementById("last-tx-val");

                        if (parts[0] === "1") {
                            if (rxEl) rxEl.innerText = formatBytes(rxVal);
                            if (txEl) txEl.innerText = formatBytes(txVal);
                            startTimeEpoch = startVal;
                        } else {
                            if (rxEl) rxEl.innerText = "0 B";
                            if (txEl) txEl.innerText = "0 B";
                            startTimeEpoch = 0;
                            var connTimeEl = document.getElementById("conn-time-val");
                            if (connTimeEl) connTimeEl.innerText = "00:00:00";
                        }

                        if (lastConnEl) lastConnEl.innerText = formatSeconds(lastConnVal);
                        if (lastRxEl) lastRxEl.innerText = formatBytes(lastRxVal);
                        if (lastTxEl) lastTxEl.innerText = formatBytes(lastTxVal);

                        var isRunning = (parts[0] === "1"); 
                        if (isRunning) {
                            var ipText = document.getElementById("widget-ip-text");
                            if (ipText && (ipText.innerText === "Offline" || ipText.innerText === "Loading...")) {
                                if (typeof window.forceCheckIP === "function") window.forceCheckIP();
                            }
                        } else {
                            if (typeof window.setOfflineUI === "function") window.setOfflineUI();
                        }
                    }
                }
            };
            xhr.send();
        }

        function updateLog() {
            if (document.getElementById('log-container').style.display === 'none') return;
            var xhr = new XMLHttpRequest();
            xhr.open('GET', ']=] .. luci.dispatcher.build_url("admin", "services", "passwall-ssh", "get_log") .. [=[', true);
            xhr.onreadystatechange = function () {
                if (xhr.readyState == 4 && xhr.status == 200) {
                    var box = document.getElementById('log_box');
                    if (!box) return;
                    var isScrolledToBottom = (box.scrollHeight - box.clientHeight <= box.scrollTop + 5);
                    
                    var lines = xhr.responseText.split('\n');
                    var formattedLines = [];
                    for (var i = 0; i < lines.length; i++) {
                        if (lines[i].trim() === "") continue;
                        var processedLine = lines[i].replace(
                            /(\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\])/g,
                            '<span style="color: #3C86AB">$1</span>'
                        );
                        formattedLines.push('<span>' + processedLine + '</span>');
                    }
                    box.innerHTML = formattedLines.join('\n');
                    if (isScrolledToBottom) box.scrollTop = box.scrollHeight;
                }
            };
            xhr.send();
        }
        
        window.clearLog = function() {
            var box = document.getElementById('log_box');
            if (box) box.innerHTML = "";
            var xhr = new XMLHttpRequest();
            xhr.open('GET', ']=] .. luci.dispatcher.build_url("admin", "services", "passwall-ssh", "clear_log") .. [=[', true);
            xhr.onreadystatechange = function() {
                if (xhr.readyState === 4 && xhr.status === 200) {
                    if (box) box.innerHTML = "";
                }
            };
            xhr.send();
        };

        window.copyLog = function() {
            var box = document.getElementById('log_box');
            var btn = document.getElementById('btn-copy-log');
            if (!box || !btn) return;
            
            var textToCopy = box.innerText; 
            
            var showSuccess = function() {
                var originalText = btn.innerText;
                btn.innerText = "Copied!";
                btn.style.backgroundColor = "#28a745"; // Warna hijau
                btn.style.color = "#fff";
                setTimeout(function() {
                    btn.innerText = originalText;
                    btn.style.backgroundColor = "";
                    btn.style.color = "";
                }, 2000);
            };

            // Modern Clipboard API (Jika HTTPS)
            if (navigator.clipboard && window.isSecureContext) {
                navigator.clipboard.writeText(textToCopy).then(showSuccess).catch(function(err) {
                    console.error("Gagal menyalin: ", err);
                });
            } else {
                // Fallback (Untuk HTTP LuCI)
                var textArea = document.createElement("textarea");
                textArea.value = textToCopy;
                // Sembunyikan textarea 
                textArea.style.position = "fixed";
                textArea.style.top = "-9999px";
                textArea.style.left = "-9999px";
                document.body.appendChild(textArea);
                
                textArea.focus();
                textArea.select();
                
                try {
                    var successful = document.execCommand('copy');
                    if (successful) showSuccess();
                } catch (err) {
                    console.error('Browser tidak mendukung copy otomatis', err);
                    alert("Gagal menyalin log.");
                }
                
                document.body.removeChild(textArea);
            }
        };
    
        function updateSlowDnsDnsFields() {
            var transportInput = document.getElementById('slowdns_DNS_TRANSPORT');
            var resolverInput = document.getElementById('slowdns_DNS_RESOLVER');
            var resolverHelp = document.getElementById('slowdns-dns-help');
            var qtypeRow = document.getElementById('slowdns-qtype-row');
            var transport = transportInput ? transportInput.value : 'UDP';

            if (qtypeRow) qtypeRow.style.display = (transport === 'UDP') ? '' : 'none';

            if (resolverInput) {
                if (transport === 'DoH') {
                    resolverInput.placeholder = 'https://cloudflare-dns.com/dns-query';
                    if (resolverHelp) resolverHelp.textContent = 'Masukkan URL DoH lengkap (HTTPS), misalnya https://cloudflare-dns.com/dns-query.';
                } else if (transport === 'DoT') {
                    resolverInput.placeholder = '1.1.1.1:853 atau one.one.one.one:853';
                    if (resolverHelp) resolverHelp.textContent = 'Masukkan alamat DoT host:port. Port default jika tidak diisi adalah 853.';
                } else {
                    resolverInput.placeholder = '1.1.1.1';
                    if (resolverHelp) resolverHelp.textContent = 'Masukkan alamat IPv4 resolver UDP.';
                }
            }
        }

        document.addEventListener('DOMContentLoaded', function() {
            var modeInput = document.getElementById('transport-mode-selection');
            var modeSwitch = document.getElementById('connection-mode-switch');
            var initialMode = modeInput && modeInput.value === 'slowdns' ? 'slowdns' : 'ssh';
            var requestedTab = '';
            var tabHashMatch = (window.location.hash || '').match(/^#tab=(main|dns|config|slowdns|update|log)$/);
            if (tabHashMatch) requestedTab = tabHashMatch[1];

            if (modeSwitch) {
                modeSwitch.checked = (initialMode === 'slowdns');
                modeSwitch.addEventListener('change', function() {
                    if (serviceLocked) {
                        window.switchMode(selectedTransportMode());
                        return;
                    }
                    window.switchMode(this.checked ? 'slowdns' : 'ssh');
                });
            }

            window.switchMode(initialMode);
            if (requestedTab) switchTab(requestedTab);
            updateSlowDnsDnsFields();
            var dnsTransportInput = document.getElementById('slowdns_DNS_TRANSPORT');
            if (dnsTransportInput) {
                dnsTransportInput.addEventListener('change', updateSlowDnsDnsFields);
            }
            checkServicesLoop();
            window.forceCheckIP();
            startConnTimer();
            checkUpdateStatus(); // Mengecek secara diam-diam saat load
        });

        setInterval(checkServicesLoop, 3000);
        setInterval(updateLog, 2000); 
    </script>
    ]=]
end

-- ==========================================
-- SECTION MAIN & DNS (TANPA s:tab NATIVE LUCI)
-- ==========================================
s = m:section(NamedSection, "main", "sshtls", "<span id='marker-main'></span>")
s.addremove = false

-- --- OPSI UNTUK TAB MAIN ---
enabled = s:option(Flag, "enabled", translate("Main switch"))
enabled.default = "0"
enabled.rmempty = false

sel = s:option(ListValue, "selected_profile", translate("Profile"))
sel.default = ""
sel:value("", "-- Pilih Profile --")
m.uci:foreach("passwall-ssh", "profile", function(p)
    if p['.name'] then 
        local display_name = p.alias or p['.name']
        sel:value(p['.name'], display_name) 
    end
end)

-- --- OPSI UNTUK TAB DNS ---
dns_proto = s:option(ListValue, "dns_proto", translate("DNS Protocol"))
dns_proto:value("UDP", "UDP")
dns_proto:value("TCP", "TCP")
dns_proto:value("DoT", "DoT (TLS)")
dns_proto:value("DoH", "DoH (HTTPS)")
dns_proto:value("DoQ", "Quic (DoQ)")
dns_proto:value("DoH3", "HTTP3 (DoH3)")
dns_proto.default = "UDP"

dns_ip = s:option(Value, "dns_ip", "DNS Server :", "Pilih dari daftar atau ketik manual")
dns_ip:depends("dns_proto", "UDP")
dns_ip:depends("dns_proto", "TCP")
dns_ip:depends("dns_proto", "DoT")
dns_ip:depends("dns_proto", "DoQ")
dns_ip:value("1.1.1.1", "1.1.1.1 (Cloudflare)")
dns_ip:value("8.8.8.8", "8.8.8.8 (Google)")
dns_ip:value("9.9.9.9", "9.9.9.9 (Quad9)")
dns_ip.default = "1.1.1.1"

dns_url = s:option(Value, "dns_url", "DNS Server :", "Pilih dari daftar atau ketik manual")
dns_url:depends("dns_proto", "DoH")
dns_url:depends("dns_proto", "DoH3")
dns_url:value("cloudflare-dns.com/dns-query", "Cloudflare")
dns_url:value("dns.google/dns-query", "Google")
dns_url:value("dns.quad9.net/dns-query", "Quad")
dns_url.default = "cloudflare-dns.com/dns-query"

-- In SlowDNS mode, SSH CBI inputs are disabled client-side. Since disabled
-- controls are absent from the POST, skip both write() and remove() so CBI
-- cannot delete existing SSH Main Switch/Profile/DNS values. In SSH mode,
-- the normal CBI options remain responsible for saving those settings.
local function write_ssh_option_only(option)
    local original_write = option.write
    local original_remove = option.remove

    option.write = function(self, section, value)
        local submitted_mode = luci.http.formvalue("transport_mode_selection")
        if submitted_mode == "slowdns" then
            return
        end

        -- CBI may submit a control even when its value was not changed.
        -- Skip identical writes to avoid unnecessary UCI deltas.
        local current_value = m.uci:get("passwall-ssh", section, self.option)
        if current_value ~= nil and tostring(current_value) == tostring(value) then
            return
        end

        if original_write then
            return original_write(self, section, value)
        end
    end

    option.remove = function(self, section)
        local submitted_mode = luci.http.formvalue("transport_mode_selection")
        if submitted_mode == "slowdns" then
            return
        end
        if original_remove then
            return original_remove(self, section)
        end
    end
end

write_ssh_option_only(enabled)
write_ssh_option_only(sel)
write_ssh_option_only(dns_proto)
write_ssh_option_only(dns_ip)
write_ssh_option_only(dns_url)

-- ==========================================
-- SLOWDNS SETTINGS (same UCI main section)
-- ==========================================
-- Connection Mode is handled by the custom switch above, not by a CBI option.
-- This prevents a mode toggle from creating a CBI "Unsaved Changes" marker.

-- ==========================================
-- SLOWDNS SETTINGS (separate /etc/config/passwall-ssh-slowdns)
-- ==========================================
slowdns_settings = s:option(DummyValue, "_slowdns_settings")
slowdns_settings.rawhtml = true
slowdns_settings.cfgvalue = function()
    local function sd(option, default)
        local value = slowdns_uci:get("passwall-ssh-slowdns", "SlowDNS", option)
        if value == nil then value = default or "" end
        return slowdns_html_escape(value)
    end

    local enabled_value = slowdns_uci:get("passwall-ssh-slowdns", "SlowDNS", "enabled") or "0"
    local enabled_checked = enabled_value == "1" and ' checked="checked"' or ""
    local selected_qtype = slowdns_uci:get("passwall-ssh-slowdns", "SlowDNS", "Type_DNS") or "NS"
    local selected_dns_transport = slowdns_uci:get("passwall-ssh-slowdns", "SlowDNS", "DNS_TRANSPORT") or "UDP"
    local selected_dns_transport_upper = string.upper(selected_dns_transport)
    if selected_dns_transport_upper == "DOH" then
        selected_dns_transport = "DoH"
    elseif selected_dns_transport_upper == "DOT" then
        selected_dns_transport = "DoT"
    else
        selected_dns_transport = "UDP"
    end
    local selected_dns_resolver = slowdns_uci:get("passwall-ssh-slowdns", "SlowDNS", "DNS_RESOLVER")
    if not selected_dns_resolver or selected_dns_resolver == "" then
        selected_dns_resolver = slowdns_uci:get("passwall-ssh-slowdns", "SlowDNS", "DNS_UDP_IP") or "1.1.1.1"
    end

    local function dns_transport_option(value, label)
        local selected = selected_dns_transport == value and ' selected="selected"' or ""
        return '<option value="' .. value .. '"' .. selected .. '>' .. label .. '</option>'
    end

    local function qtype_option(value, label)
        local selected = selected_qtype == value and ' selected="selected"' or ""
        return '<option value="' .. value .. '"' .. selected .. '>' .. label .. '</option>'
    end

    return [=[
        <div id="slowdns-settings-panel">
            <input type="hidden" name="slowdns_form_submit" value="1" />

            <div class="cbi-value">
                <label class="cbi-value-title" for="slowdns_enabled">Main Switch</label>
                <div class="cbi-value-field">
                    <input type="checkbox" class="cbi-input-checkbox"
                        id="slowdns_enabled" name="slowdns_enabled" value="1"]=] ..
                        enabled_checked .. [=[ />
                </div>
            </div>

            <div class="cbi-value">
                <label class="cbi-value-title" for="slowdns_DNS_TRANSPORT">DNS Transport :</label>
                <div class="cbi-value-field">
                    <select class="cbi-input-select" id="slowdns_DNS_TRANSPORT" name="slowdns_DNS_TRANSPORT">
                        ]=] ..
                        dns_transport_option("UDP", "UDP") ..
                        dns_transport_option("DoH", "DoH (HTTPS)") ..
                        dns_transport_option("DoT", "DoT (TLS)") ..
                        [=[
                    </select>
                </div>
            </div>

            <div class="cbi-value">
                <label class="cbi-value-title" for="slowdns_DNS_RESOLVER">DNS Resolver :</label>
                <div class="cbi-value-field">
                    <input type="text" class="cbi-input-text"
                        id="slowdns_DNS_RESOLVER" name="slowdns_DNS_RESOLVER"
                        value="]=] .. slowdns_html_escape(selected_dns_resolver) .. [=["
                        placeholder="1.1.1.1" />
                    <div class="cbi-value-description" id="slowdns-dns-help">Masukkan alamat IPv4 resolver UDP. DNSTT HTTP Custom menggunakan UDP port 53.</div>
                </div>
            </div>

            <div class="cbi-value" id="slowdns-qtype-row">
                <label class="cbi-value-title" for="slowdns_Type_DNS">HTTP Custom QTYPE :</label>
                <div class="cbi-value-field">
                    <select class="cbi-input-select" id="slowdns_Type_DNS" name="slowdns_Type_DNS">
                        ]=] ..
                        qtype_option("NS", "NS") ..
                        qtype_option("TXT", "TXT") ..
                        qtype_option("MX", "MX") ..
                        qtype_option("CNAME", "CNAME") ..
                        qtype_option("NULL", "NULL") ..
                        qtype_option("SRV", "SRV") ..
                        [=[
                    </select>
                </div>
            </div>

            <div class="cbi-value">
                <label class="cbi-value-title" for="slowdns_DNSTT_DOMAIN">Name Server :</label>
                <div class="cbi-value-field">
                    <input type="text" class="cbi-input-text"
                        id="slowdns_DNSTT_DOMAIN" name="slowdns_DNSTT_DOMAIN"
                        value="]=] .. sd("DNSTT_DOMAIN") .. [=["
                        placeholder="ns-slowdns.example.com" />
                </div>
            </div>

            <div class="cbi-value">
                <label class="cbi-value-title" for="slowdns_DNSTT_SERVER_PUBLIC_KEY">Public Key :</label>
                <div class="cbi-value-field">
                    <input type="text" class="cbi-input-text"
                        id="slowdns_DNSTT_SERVER_PUBLIC_KEY" name="slowdns_DNSTT_SERVER_PUBLIC_KEY"
                        value="]=] .. sd("DNSTT_SERVER_PUBLIC_KEY") .. [=["
                        placeholder="/root/server.pub atau public key hex" />
                </div>
            </div>

            <div class="cbi-value">
                <label class="cbi-value-title" for="slowdns_SSH_USERNAME">Username :</label>
                <div class="cbi-value-field">
                    <input type="text" class="cbi-input-text"
                        id="slowdns_SSH_USERNAME" name="slowdns_SSH_USERNAME"
                        value="]=] .. sd("SSH_USERNAME") .. [=["
                        placeholder="Username SSH" />
                </div>
            </div>

            <div class="cbi-value">
                <label class="cbi-value-title" for="slowdns_SSH_PASSWORD">Password :</label>
                <div class="cbi-value-field">
                    <input type="text" class="cbi-input-text"
                        id="slowdns_SSH_PASSWORD" name="slowdns_SSH_PASSWORD"
                        value="]=] .. sd("SSH_PASSWORD") .. [=["
                        placeholder="Password SSH"
                        autocomplete="off" />
                </div>
            </div>

        </div>
    ]=]
end

-- SECTION CONFIG (Profile List)
-- ==========================================
conf = m:section(TypedSection, "profile", "<span id='marker-config'></span>")
conf.template = "cbi/tblsection" 
conf.addremove = true
conf.anonymous = true

function conf.remove(self, section)
    local active_prof = m.uci:get("passwall-ssh", "main", "selected_profile")
    
    if active_prof == section then
        m.uci:set("passwall-ssh", "main", "selected_profile", "")
        m.uci:set("passwall-ssh", "main", "enabled", "0")
    end
    
    TypedSection.remove(self, section)
end

conf.extedit = luci.dispatcher.build_url("admin", "services", "passwall-ssh", "edit", "%s")

function conf.create(self, section)
    local uuid = sys.exec("cat /proc/sys/kernel/random/uuid 2>/dev/null") or "1a2b3c4d"
    local random_id = "p_" .. string.sub(uuid, 1, 8)
    
    m.uci:section("passwall-ssh", "profile", random_id)
    
    m.uci:set("passwall-ssh", random_id, "alias", "Nama Profil (Bebas Text)")
    
    m.uci:save("passwall-ssh")
    m.uci:commit("passwall-ssh")

    luci.http.redirect(luci.dispatcher.build_url("admin", "services", "passwall-ssh", "edit", random_id))
end

name_list = conf:option(DummyValue, "alias", "Name")
function name_list.cfgvalue(self, section)
    return m.uci:get("passwall-ssh", section, "alias") or section
end

host_list = conf:option(DummyValue, "host", "Address")
host_port_list = conf:option(DummyValue, "host_port", "Port")
username_list = conf:option(DummyValue, "username", "Username")

-- Dedicated page-level Save & Apply button. It submits only the CBI form; the
-- on_after_save hook commits these two packages and restarts this service.
local action_sec = m:section(SimpleSection)
local save_apply = action_sec:option(DummyValue, "_save_apply")
save_apply.rawhtml = true
save_apply.cfgvalue = function()
    return [[
        <div style="display:flex;justify-content:flex-end;width:100%;margin:20px 0 10px 0;">
            <button type="button" class="cbi-button cbi-button-apply slowdns-save-apply"
                onclick="cbi_submit(this, 'custom_save_apply')">Save &amp; Apply</button>
        </div>
    ]]
end

return m
