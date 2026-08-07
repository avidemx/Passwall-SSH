local fs = require "nixio.fs"
local sys = require "luci.sys"

m = Map("passwall-ssh", "PASSWALL-SSH")

-- ==========================================
-- HOOK TRIGGER SAVE & APPLY 
-- ==========================================
m.on_after_commit = function(self)
    self.uci:commit("passwall-ssh")
    sys.call("/etc/init.d/passwall-ssh enable")
    sys.call("/etc/init.d/passwall-ssh restart >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "services", "passwall-ssh"))
end

local active_profile = m.uci:get("passwall-ssh", "main", "selected_profile")
if not active_profile or active_profile == "" then
    active_profile = "No Profile"
end

-- ==========================================
-- TOP STATUS PANEL & CUSTOM TABS 
-- ==========================================
local top_sec = m:section(SimpleSection)
local header_ui = top_sec:option(DummyValue, "_header")
header_ui.rawhtml = true
header_ui.cfgvalue = function()
    return [=[
    <style>
    /* Styling Standar Passwall */
    .cbi-section-table { width: 100%; border-collapse: collapse; margin-top: 10px; background: #2b2b2b; border-radius: 4px; overflow: hidden; }
    .cbi-section-table th, .cbi-section-table td { padding: 12px; text-align: left; border-bottom: 1px solid #333; color: #ccc; }
    .cbi-section-table th { background: #333; color: #fff; font-size: 13px; }
    .cbi-section-table tr:hover { background: #353535; }

    .full-width-container { display: block; width: 100%; clear: both; margin-bottom: 20px; }

    .pw-panel { display: grid; grid-template-columns: repeat(3, 1fr); gap: 15px; margin-bottom: 15px; background: #2b2b2b; padding: 15px; border-radius: 4px; border: 1px solid #1a1a1a; width: 100%; box-sizing: border-box; }
    @media screen and (max-width: 768px) { .pw-panel { grid-template-columns: repeat(2, 1fr); } }
    @media screen and (max-width: 480px) { .pw-panel { grid-template-columns: 1fr; } }

    .pw-box { display: flex; align-items: center; background: #1f1f1f; padding: 15px; border-radius: 4px; border: 1px solid #111; transition: 0.2s; }
    .pw-icon { width: 30px; height: 30px; margin-right: 15px; color: #ccc; display: flex; align-items: center; justify-content: center; }
    .pw-info { display: flex; flex-direction: column; }
    .pw-title { font-size: 12px; color: #a1a1a1; margin-bottom: 4px; font-weight: bold; }
    .pw-val { font-size: 14px; font-weight: bold; transition: 0.2s; }
    
    .pw-box.clickable { cursor: pointer; }
    .pw-box.clickable:hover { background: #2a2a2a; border-color: #333; }
    .pw-box.clickable .pw-icon { color: #5bc0de; }

    .toolbar-wrapper { display: flex; justify-content: flex-start; align-items: center; border-bottom: 1px solid #555; margin-bottom: 15px; flex-wrap: wrap; padding-bottom: 10px; gap: 15px; }
    
    .cbi-tabmenu { list-style: none; padding: 0; margin: 0; display: flex; border-bottom: none; }
    .cbi-tabmenu li { margin-right: 2px; }
    .cbi-tabmenu li a { display: block; padding: 6px 15px; text-decoration: none; color: #888; border: 1px solid transparent; border-bottom: none; font-size: 13px; }
    .cbi-tabmenu li.active a { color: #5bc0de; border-color: #555; border-bottom: 1px solid #1f1f1f; margin-bottom: -1px; background: transparent; }
    
    .profile-text { font-size: 16px; color: #ccc; display: flex; align-items: center; margin-left: auto; }
    .profile-text .p-name { font-weight: bold; color: #fff; margin-right: 5px; }
    .profile-text .p-status { font-weight: bold; margin-left: 3px; }

    /* STYLING WIDGET IP & ANIMASI */
    #ip-widget-placeholder { display: flex; align-items: center; justify-content: center; margin-bottom: 25px; width: 100%; }
    
    .status-bar { 
        background: #1f1f1f; 
        border: 1px solid #333; 
        border-radius: 4px;            
        padding: 10px 15px; 
        color: white;
        display: flex; 
        justify-content: center; 
        align-items: center;
        white-space: nowrap;
        width: 100%;
        box-sizing: border-box;
    }

    .inner { display: flex; align-items: center; gap: 12px; }
    .flag { height: 20px; width: 28px; display: flex; align-items: center; justify-content: center; overflow: hidden; } 
    .flag img { height: 100%; width: 100%; object-fit: contain; border-radius: 2px; }

    .ip-info-container { display: flex; align-items: center; gap: 8px; font-size: 14px; font-weight: bold; }
    .separator { color: #666; font-weight: normal; }

    .text-offline { color: #ff4c4c !important; }
    .text-online { color: #4caf50 !important; }
    .text-isp { color: #ffeb3b !important; }

    @keyframes spin-globe { 100% { transform: rotate(360deg); } }
    @keyframes wave-flag { 
        0%, 100% { transform: skewY(-3deg) scale(1); }
        50% { transform: skewY(3deg) scale(1.05); }
    }

    .spin-anim { animation: spin-globe 1.5s linear infinite; height: 20px !important; width: 20px !important; }
    .wave-anim { animation: wave-flag 2.5s ease-in-out infinite; transform-origin: bottom left; }
    
    /* FIX HIDE FIELDS MANAGEMENT (DENGAN ID LUA YANG BENAR) */
    .hide-main-fields #cbi-passwall-ssh-main-enabled,
    .hide-main-fields #cbi-passwall-ssh-main-selected_profile {
        display: none !important;
    }

    .hide-dns-fields #cbi-passwall-ssh-main-dns_proto,
    .hide-dns-fields #cbi-passwall-ssh-main-dns_ip,
    .hide-dns-fields #cbi-passwall-ssh-main-dns_url {
        display: none !important;
    }
    </style>

    <div class="full-width-container">
        <!-- Status Panel -->
        <div class="pw-panel">
            <div class="pw-box">
                <div class="pw-icon"><svg width="24" height="24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg></div>
                <div class="pw-info"><span class="pw-title">TCP Core</span><span class="pw-val" id="status-tcp" style="color:#ff4c4c;">Check...</span></div>
            </div>
            <div class="pw-box">
                <div class="pw-icon"><svg width="24" height="24" fill="none" stroke="currentColor" stroke-width="2"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg></div>
                <div class="pw-info"><span class="pw-title">UDP Core</span><span class="pw-val" id="status-udp" style="color:#ff4c4c;">Check...</span></div>
            </div>
            <div class="pw-box">
                <div class="pw-icon"><svg width="24" height="24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="2" width="20" height="8" rx="2" ry="2"/><rect x="2" y="14" width="20" height="8" rx="2" ry="2"/><line x1="6" y1="6" x2="6.01" y2="6"/><line x1="6" y1="18" x2="6.01" y2="18"/></svg></div>
                <div class="pw-info"><span class="pw-title">DNS Resolver</span><span class="pw-val" id="status-dns" style="color:#ff4c4c;">Check...</span></div>
            </div>

            <div class="pw-box clickable" onclick="touchCheck('www.google.com', 'status-google')">
                <div class="pw-icon"><svg width="24" height="24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg></div>
                <div class="pw-info"><span class="pw-title">Google</span><span class="pw-val" id="status-google" style="color:#5bc0de;">Touch to Check</span></div>
            </div>
            <div class="pw-box clickable" onclick="touchCheck('www.github.com', 'status-github')">
                <div class="pw-icon"><svg width="24" height="24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 19c-5 1.5-5-2.5-7-3m14 6v-3.87a3.37 3.37 0 0 0-.94-2.61c3.14-.35 6.44-1.54 6.44-7A5.44 5.44 0 0 0 20 4.77 5.07 5.07 0 0 0 19.91 1S18.73.65 16 2.48a13.38 13.38 0 0 0-7 0C6.27.65 5.09 1 5.09 1A5.07 5.07 0 0 0 5 4.77a5.44 5.44 0 0 0-1.5 3.78c0 5.42 3.3 6.61 6.44 7A3.37 3.37 0 0 0 9 18.13V22"/></svg></div>
                <div class="pw-info"><span class="pw-title">Github</span><span class="pw-val" id="status-github" style="color:#5bc0de;">Touch to Check</span></div>
            </div>
            <div class="pw-box clickable" onclick="touchCheck('www.youtube.com', 'status-youtube')">
                <div class="pw-icon"><svg width="24" height="24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22.54 6.42a2.78 2.78 0 0 0-1.94-2C18.88 4 12 4 12 4s-6.88 0-8.6.46a2.78 2.78 0 0 0-1.94 2A29 29 0 0 0 1 11.75a29 29 0 0 0 .46 5.33 2.78 2.78 0 0 0 1.94 2c1.72.46 8.6.46 8.6.46s6.88 0 8.6-.46a2.78 2.78 0 0 0 1.94-2 29 29 0 0 0 .46-5.33 29 29 0 0 0-.46-5.33z"/><polygon points="9.75 15.02 15.5 11.75 9.75 8.48 9.75 15.02"/></svg></div>
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
                        <div class="separator">|</div>
                        <div id="widget-info-text" class="text-offline">Menunggu data...</div>
                    </div>
                </div>
            </div>
        </div>

        <!-- TOOLBAR TABS -->
        <div class="toolbar-wrapper">
            <ul class="cbi-tabmenu">
                <li id="tab_main" class="active"><a href="javascript:void(0)" onclick="switchTab('main')">Main</a></li>
                <li id="tab_dns"><a href="javascript:void(0)" onclick="switchTab('dns')">DNS</a></li>
                <li id="tab_config"><a href="javascript:void(0)" onclick="switchTab('config')">Profile</a></li>
                <li id="tab_log"><a href="javascript:void(0)" onclick="switchTab('log')">Log</a></li>
            </ul>

            <div class="profile-text">
                <span class="p-name">]=] .. active_profile .. [=[</span> :
                <span class="p-status" id="profile-status" style="color:#888;">Checking...</span>
            </div>
        </div>

        <!-- Log Container -->
        <div id="log-container" style="display: none;">
            <div style="font-weight: bold; margin-bottom: 5px; color: #888;">LOG (Auto Clean) :</div>
            <div id="log_box" style="background-color:#141414; color:#ccc; padding:10px; font-family:monospace; height:450px; overflow-y:scroll; border-radius:3px; white-space:pre-wrap; font-size:12px; border: 1px solid #333;">Loading...</div>
        </div>
    </div>

    <script type="text/javascript">
        const loadingGlobeURI = "data:image/svg+xml;base64,PHN2ZyB4bWxucz0naHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmcnIHZpZXdCb3g9JzAgMCAyNCAyNCcgd2lkdGg9JzI0JyBoZWlnaHQ9JzI0JyBzdHJva2U9JyNmZmZmZmYnIHN0cm9rZS13aWR0aD0nMicgZmlsbD0nbm9uZScgc3Ryb2tlLWxpbmVjYXA9J3JvdW5kJyBzdHJva2UtbGluZWpvaW49J3JvdW5kJz48Y2lyY2xlIGN4PScxMicgY3k9JzEyJyByPScxMCcvPjxwYXRoIGQ9J00xMiAyYTE1LjMgMTUuMyAwIDAgMSA0IDEwIDE1LjMgMTUuMyAwIDAgMS00IDEwIDE1LjMgMTUuMyAwIDAgMS00LTEwIDE1LjMgMTUuMyAwIDAgMSA0LTEweicvPjxwYXRoIGQ9J00yIDEyaDIwJy8+PC9zdmc+";
        const CHECK_IP_URL = ']=] .. luci.dispatcher.build_url("admin", "services", "passwall-ssh", "check_ip") .. [=[';
        
        window.isFetchingIP = false;

        function write_status(data) {
            const flagImg = document.getElementById("flag-img-element");
            const ipText = document.getElementById("widget-ip-text");
            const infoText = document.getElementById("widget-info-text");
            const pStatus = document.getElementById("profile-status");
            
            if (!flagImg || !ipText || !infoText) return;

            if (data.ip === "Offline" || !data.ip) {
                flagImg.src = loadingGlobeURI;
                flagImg.className = "spin-anim";
                
                ipText.innerHTML = "Offline";
                ipText.className = "text-offline";
                
                infoText.innerHTML = "Offline";
                infoText.className = "text-offline";
                
                if(pStatus) {
                    pStatus.innerHTML = "Disconnected";
                    pStatus.style.color = "#ff4c4c";
                }
            } else {
                let countryCode = data.flag ? data.flag.toLowerCase() : "un"; 
                
                flagImg.src = 'https://flagcdn.com/w40/' + countryCode + '.png';
                
                setTimeout(function() { 
                    flagImg.className = "wave-anim"; 
                }, 50);

                ipText.innerHTML = data.ip;
                ipText.className = "text-online";
                
                infoText.innerHTML = (data.country || "Unknown") + ' <span class="separator">|</span> ' + (data.isp || "Unknown");
                infoText.className = "text-isp";
                
                if(pStatus) {
                    pStatus.innerHTML = "Connected";
                    pStatus.style.color = "#4caf50";
                }
            }
        }

        window.forceCheckIP = function() {
            if (window.isFetchingIP) return; 
            window.isFetchingIP = true;
            
            write_status({ ip: "Offline" }); 

            fetch(CHECK_IP_URL)
                .then(function(res) { return res.json(); })
                .then(function(data) {
                    write_status(data);
                    window.isFetchingIP = false;
                })
                .catch(function(e) {
                    console.log("IP Check Error", e);
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

        function switchTab(tabName) {
            sessionStorage.setItem('passwall_active_tab', tabName);
            ['main', 'dns', 'config', 'log'].forEach(function(t) {
                var tab = document.getElementById('tab_' + t);
                if (tab) tab.classList.remove('active');
            });
            var activeTab = document.getElementById('tab_' + tabName);
            if (activeTab) activeTab.classList.add('active');

            var secMain = findSection('marker-main');
            var secConfig = findSection('marker-config');
            var secLog = document.getElementById('log-container');

            if (secMain) {
                secMain.style.display = (tabName === 'main' || tabName === 'dns') ? 'block' : 'none';
                
                if (tabName === 'main') {
                    secMain.classList.remove('hide-main-fields');
                    secMain.classList.add('hide-dns-fields');
                } else if (tabName === 'dns') {
                    secMain.classList.remove('hide-dns-fields');
                    secMain.classList.add('hide-main-fields');
                }
            }

            if (secConfig) secConfig.style.display = (tabName === 'config') ? 'block' : 'none';
            if (secLog) secLog.style.display = (tabName === 'log') ? 'block' : 'none';
        }

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
                    var parts = xhr.responseText.trim().split(',');
                    if(parts.length >= 3) {
                        updateServiceBadge('status-tcp', parts[0]);
                        updateServiceBadge('status-udp', parts[1]);
                        updateServiceBadge('status-dns', parts[2]);

                        if (parts[3]) {
                            var pName = document.querySelector('.p-name');
                            if (pName) pName.innerHTML = parts[3];
                        }

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
                        var color = "#d4d4d4"; 
                        if (lines[i].indexOf("GAGAL") >= 0 || lines[i].indexOf("ERROR") >= 0 || lines[i].indexOf("STOPPED") >= 0) color = "#ff4c4c"; 
                        else if (lines[i].indexOf("sukses") >= 0 || lines[i].indexOf("OK") >= 0 || lines[i].indexOf("RUNNING") >= 0) color = "#4caf50";
                        var processedLine = lines[i].replace(/(\[[0-9]{2}:[0-9]{2}:[0-9]{2}\])/g, '<span style="color: #888;">$1</span>');
                        formattedLines.push('<span style="color: ' + color + ';">' + processedLine + '</span>');
                    }
                    box.innerHTML = formattedLines.join('<br>');
                    if (isScrolledToBottom) box.scrollTop = box.scrollHeight;
                }
            };
            xhr.send();
        }
            
        document.addEventListener('DOMContentLoaded', function() {
            switchTab(sessionStorage.getItem('passwall_active_tab') || 'main');
            window.forceCheckIP();
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
enabled = s:option(Flag, "enabled", translate("Enable"))
enabled.default = "0"
enabled.rmempty = false

sel = s:option(ListValue, "selected_profile", translate("Main Profile"))
sel.default = ""
sel:value("", "-- Pilih Profile --")
m.uci:foreach("passwall-ssh", "profile", function(p)
    if p['.name'] then sel:value(p['.name'], p['.name']) end
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

dns_ip = s:option(Value, "dns_ip", "DNS Server :", "Pilih dari daftar atau KETIK LANGSUNG MANUAL")
dns_ip:depends("dns_proto", "UDP")
dns_ip:depends("dns_proto", "TCP")
dns_ip:depends("dns_proto", "DoT")
dns_ip:depends("dns_proto", "DoQ")
dns_ip:value("1.1.1.1", "1.1.1.1 (Cloudflare)")
dns_ip:value("8.8.8.8", "8.8.8.8 (Google)")
dns_ip:value("9.9.9.9", "9.9.9.9 (Quad9)")
dns_ip.default = "1.1.1.1"

dns_url = s:option(Value, "dns_url", "DNS Server :", "Pilih dari daftar atau KETIK LANGSUNG MANUAL")
dns_url:depends("dns_proto", "DoH")
dns_url:depends("dns_proto", "DoH3")
dns_url:value("cloudflare-dns.com/dns-query", "Cloudflare")
dns_url:value("dns.google/dns-query", "Google")
dns_url:value("dns.quad9.net/dns-query", "Quad")
dns_url.default = "cloudflare-dns.com/dns-query"

-- ==========================================
-- SECTION CONFIG (Profile List)
-- ==========================================
conf = m:section(TypedSection, "profile", "<span id='marker-config'></span>" .. translate("Profile List"))
conf.template = "cbi/tblsection" 
conf.addremove = true
conf.anonymous = false

conf.extedit = luci.dispatcher.build_url("admin", "services", "passwall-ssh", "edit", "%s")

function conf.create(self, section)
    local created = TypedSection.create(self, section)
    if created then
        m.uci:save("passwall-ssh")
        m.uci:commit("passwall-ssh")
        local target_name = type(created) == "string" and created or section
        luci.http.redirect(luci.dispatcher.build_url("admin", "services", "passwall-ssh", "edit", target_name))
    end
    return created
end

local os_release = sys.exec("cat /etc/os-release 2>/dev/null") or ""

local is_old_openwrt = os_release:match('VERSION_ID="24') or os_release:match('VERSION_ID="23') or os_release:match('VERSION_ID="22') or os_release:match('VERSION_ID="21')

if not is_old_openwrt then
    name_list = conf:option(DummyValue, "_name", "Name")
    function name_list.cfgvalue(self, section)
        return section
    end
end

host_list = conf:option(DummyValue, "host", "Address")
host_port_list = conf:option(DummyValue, "host_port", "Port")
username_list = conf:option(DummyValue, "username", "Username")

return m