local fs = require "nixio.fs"
local sys = require "luci.sys"

m = Map("passwall-ssh")

-- HOOK TRIGGER SAVE & APPLY 
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
    .cbi-tabmenu > li { color: inherit !important; margin: 0; padding: 0; }
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
    .btn-check { background: #00AEFF; color: #fff; }
    .btn-check:hover { background: #008ecc; }
    .btn-apply { background: #28a745; color: #fff; }
    .btn-apply:hover { background: #218838; }
    .btn-disabled { background: rgba(128,128,128,0.3) !important; color: #999 !important; cursor: not-allowed !important; }

    .hide-main-fields #cbi-passwall-ssh-main-enabled,
    .hide-main-fields #cbi-passwall-ssh-main-selected_profile { display: none !important; }

    .hide-dns-fields #cbi-passwall-ssh-main-dns_proto,
    .hide-dns-fields #cbi-passwall-ssh-main-dns_ip,
    .hide-dns-fields #cbi-passwall-ssh-main-dns_url { display: none !important; }

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
                    <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0iY3VycmVudENvbG9yIj48cGF0aCBkPSJNMTIgMkM2LjQ3NyAyIDIgNi40NzcgMiAxMmMwIDQuNDIgMi44NjUgOC4xNjYgNi44MzkgOS40ODkuNS4wOTIuNjgyLS4yMTcuNjgyLS40ODIgMC0uMjM3LS4wMDgtLjg2Ni0uMDEzLTEuNy0yLjc4Mi42MDMtMy4zNjktMS4zNC0zLjM2OS0xLjM0LS40NTQtMS4xNTYtMS4xMS0xLjQ2Mi0xLjExLTEuNDYyLS45MDgtLjYyLjA2OS0uNjA4LjA2OS0uNjA4IDEuMDAzLjA3IDEuNTMxIDEuMDMgMS41MzEgMS4wMy44OTIgMS41MjkgMi4zNDEgMS4wODcgMi45MS44MzEuMDkyLS42NDYuMzUtMS4wODYuNjM2LTEuMzM2LTIuMjItLjI1My00LjU1NS0xLjExLTQuNTU1LTQuOTQzIDAtMS4wOTEuMzktMS45ODQgMS4wMjktMi42ODMtLjEwMy0uMjUzLS40NDYtMS4yNy4wOTgtMi42NDcgMCAwIC44NC0uMjY5IDIuNzUgMS4wMjVBOS41NzggOS41NzggMCAwMTEyIDYuODM2Yy44NS4wMDQgMS43MDUuMTE0IDIuNTA0LjMzNiAxLjkwOS0xLjI5NCAyLjc0Ny0xLjAyNSAyLjc0Ny0xLjAyNS41NDYgMS4zNzcuMjAzIDIuMzk0LjEgMi42NDcuNjQuNjk5IDEuMDI4IDEuNTkyIDEuMDI4IDIuNjgzIDAgMy44NDItMi4zMzkgNC42ODctNC41NjYgNC45MzUuMzU5LjMwOS42NzguOTE5LjY3OCAxLjg1MiAwIDEuMzM2LS4wMTIgMjAuNDE1LS4wMTIgMjAuNzQzIDAgLjI2Ny4xOC41NzguNjg4LjQ4QzE5LjEzOCAyMC4xNjEgMjIgMTYuNDE2IDIyIDEyYzAtNS41MjMtNC40NzctMTAtMTAtMTB6Ii8+PC9zdmc+">
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
                <span class="p-name">]=] .. active_profile .. [=[</span> :
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

        <!-- TOOLBAR TABS -->
        <div class="toolbar-wrapper">
            <ul class="cbi-tabmenu">
                <li id="tab_main" class="active"><a href="javascript:void(0)" onclick="switchTab('main')">Main</a></li>
                <li id="tab_dns"><a href="javascript:void(0)" onclick="switchTab('dns')">DNS</a></li>
                <li id="tab_config"><a href="javascript:void(0)" onclick="switchTab('config')">Profile</a></li>
                <li id="tab_update"><a href="javascript:void(0)" onclick="switchTab('update')">App Update</a></li>
                <li id="tab_log"><a href="javascript:void(0)" onclick="switchTab('log')">Log</a></li>
            </ul>
        </div>

        <!-- App Update Container -->
        <div id="update-container" style="display: none;">
            <div class="update-card">
                <div class="update-row">
                    <div class="update-label">Architecture :</div>
                    <div class="update-value" id="upd-arch">Detecting...</div>
                </div>
                <div class="update-row">
                    <div class="update-label">Passwall-SSH Version :</div>
                    <div class="update-value" id="upd-cur-ver">Detecting...</div>
                </div>
                <div style="margin-top: 5px;">
                    <button type="button" id="btn-check-update" class="btn-update btn-check" onclick="checkAppUpdate()">Check Update</button>
                </div>
                
                <div id="update-check-result" style="display: none; font-size: 14px; font-weight: bold; margin-top: 5px;"></div>
                
                <div id="update-action-box" style="display: none;">
                    <button type="button" id="btn-do-update" class="btn-update btn-apply" onclick="executeAppUpdate()">Click To Update</button>
                </div>
            </div>
        </div>

        <!-- Log Container -->
        <div id="log-container" style="display: none;">
            <div style="display: flex; align-items: center; gap: 15px; margin-bottom: 13px;">
                <button type="button" class="cbi-button cbi-button-remove" onclick="clearLog()" style="padding: 2px 10px; font-size: 12px; cursor: pointer; border-radius: 3px;">Clear Logs</button>
            </div>
            <div id="log_box"></div>
        </div>
    </div>

    <script type="text/javascript">
        const loadingGlobeURI = "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMDAgMTAwIiB3aWR0aD0iMjQiIGhlaWdodD0iMjQiPjxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjQwIiBzdHJva2U9IiM4ODgiIHN0cm9rZS13aWR0aD0iOCIgZmlsbD0ibm9uZSIgb3BhY2l0eT0iMC4zIi8+PGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iNDAiIHN0cm9rZT0iIzAwQUVGRiIgc3Ryb2tlLXdpZHRoPSI4IiBmaWxsPSJub25lIiBzdHJva2UtZGFzaGFycmF5PSI3MCAyMDAiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjwvc3ZnPg==";
        const CHECK_IP_URL = ']=] .. luci.dispatcher.build_url("admin", "services", "passwall-ssh", "check_ip") .. [=[';
        const GET_APP_INFO_URL = ']=] .. luci.dispatcher.build_url("admin", "services", "passwall-ssh", "get_app_info") .. [=[';
        const CHECK_APP_UPDATE_URL = ']=] .. luci.dispatcher.build_url("admin", "services", "passwall-ssh", "check_app_update") .. [=[';
        const DO_APP_UPDATE_URL = ']=] .. luci.dispatcher.build_url("admin", "services", "passwall-ssh", "do_app_update") .. [=[';
        
        window.isFetchingIP = false;
        var startTimeEpoch = 0;
        var timerInterval = null;
        var latestDownloadUrl = "";

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
                    var archEl = document.getElementById('upd-arch');
                    var verEl = document.getElementById('upd-cur-ver');
                    if (archEl) archEl.innerText = data.arch || "Unknown";
                    if (verEl) verEl.innerText = data.version || "Unknown";
                });
        }

        function switchTab(tabName) {
            sessionStorage.setItem('passwall_active_tab', tabName);
            ['main', 'dns', 'config', 'update', 'log'].forEach(function(t) {
                var tab = document.getElementById('tab_' + t);
                if (tab) tab.classList.remove('active');
            });
            var activeTab = document.getElementById('tab_' + tabName);
            if (activeTab) activeTab.classList.add('active');

            var secMain = findSection('marker-main');
            var secConfig = findSection('marker-config');
            var secLog = document.getElementById('log-container');
            var secUpdate = document.getElementById('update-container');

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
            if (secLog) {
                secLog.style.display = (tabName === 'log') ? 'block' : 'none';
                if (tabName === 'log') updateLog(); 
            }
            if (secUpdate) {
                secUpdate.style.display = (tabName === 'update') ? 'block' : 'none';
                if (tabName === 'update') loadAppInfo();
            }
        }

        window.checkAppUpdate = function() {
            var btn = document.getElementById('btn-check-update');
            var resBox = document.getElementById('update-check-result');
            var actBox = document.getElementById('update-action-box');
            
            btn.classList.add('btn-disabled');
            btn.disabled = true;
            btn.innerText = "Checking...";
            resBox.style.display = "none";
            actBox.style.display = "none";

            fetch(CHECK_APP_UPDATE_URL)
                .then(function(r) { return r.json(); })
                .then(function(res) {
                    btn.classList.remove('btn-disabled');
                    btn.disabled = false;
                    btn.innerText = "Check Update";
                    resBox.style.display = "block";

                    if (!res.success) {
                        resBox.innerHTML = '<span style="color:#ff4c4c;">Failed to check update.</span>';
                        return;
                    }

                    if (res.has_update) {
                        latestDownloadUrl = res.download_url;
                        resBox.innerHTML = '<span style="color:#ff4c4c;">Latest Version ' + res.latest_version + '</span>';
                        actBox.style.display = "block";
                    } else {
                        resBox.innerHTML = '<span style="color:#06BA06;">Latest Version ' + res.latest_version + ', your app up to date.</span>';
                        actBox.style.display = "none";
                    }
                })
                .catch(function() {
                    btn.classList.remove('btn-disabled');
                    btn.disabled = false;
                    btn.innerText = "Check Update";
                    resBox.style.display = "block";
                    resBox.innerHTML = '<span style="color:#ff4c4c;">Connection error during update check.</span>';
                });
        };

        window.executeAppUpdate = function() {
            var btn = document.getElementById('btn-do-update');
            var chkBtn = document.getElementById('btn-check-update');
            btn.classList.add('btn-disabled');
            btn.disabled = true;
            chkBtn.classList.add('btn-disabled');
            chkBtn.disabled = true;

            // Animasi transisi status
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
                    alert("Update failed: " + (res.message || "Unknown error"));
                    btn.classList.remove('btn-disabled');
                    btn.disabled = false;
                }
            })
            .catch(function(e) {
                btn.innerText = "Error!";
                btn.style.background = "#dc3545";
                alert("Network error while updating");
                btn.classList.remove('btn-disabled');
                btn.disabled = false;
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

                        if (parts[3]) {
                            var pName = document.querySelector('.p-name');
                            if (pName) pName.innerHTML = parts[3];
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
    
        document.addEventListener('DOMContentLoaded', function() {
            switchTab(sessionStorage.getItem('passwall_active_tab') || 'main');
            window.forceCheckIP();
            startConnTimer();
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

-- ==========================================
-- SECTION CONFIG (Profile List)
-- ==========================================
conf = m:section(TypedSection, "profile", "<span id='marker-config'></span>")
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
