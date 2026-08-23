local dsp = require "luci.dispatcher"
local http = require "luci.http"
local sys = require "luci.sys"

local config_name = arg[1] or ""

m = Map("passwall-ssh", "EDIT PROFILE", "Detail Konfigurasi untuk Profil: <b>" .. config_name .. "</b>")
m.redirect = dsp.build_url("admin", "services", "passwall-ssh")

s = m:section(NamedSection, config_name, "profile", "")
s.addremove = false
s.anonymous = false

-- ==========================================
-- VIRTUAL FIELD: Nama Profile
-- ==========================================
name = s:option(Value, "_name", "Nama Profile :")
name.rmempty = false
name.datatype = "uciname"
function name.cfgvalue(self, section)
    return section
end
function name.write(self, section, value)
end

-- ==========================================
-- FIELD KONEKSI UTAMA
-- ==========================================
host = s:option(Value, "host", "SSH Host / IP :")
host_port = s:option(Value, "host_port", "SSH Port :")
user = s:option(Value, "username", "Username :")

pass = s:option(Value, "password", "Password :")
pass.password = true

-- ==========================================
-- LOGIKA NETMOD: PROXY & TLS TYPE
-- ==========================================

proxy_type = s:option(ListValue, "proxy_type", "Proxy Type :")
proxy_type:value("None", "None (Direct)")
proxy_type:value("HTTP", "HTTP Proxy")
proxy_type.default = "None"

proxy = s:option(Value, "proxy", "Remote Proxy :")
proxy:depends("proxy_type", "HTTP")

proxy_port = s:option(Value, "proxy_port", "Port Proxy :")
proxy_port.default = "80"
proxy_port.datatype = "port"
proxy_port:depends("proxy_type", "HTTP")

proxy_port.description = [[
<script>
setInterval(function() {
    var pRow = document.querySelector('.cbi-value[id$="-proxy"]');
    var ptRow = document.querySelector('.cbi-value[id$="-proxy_port"]');
    
    if (pRow && ptRow && !ptRow.dataset.moved && pRow.style.display !== 'none') {
        var pField = pRow.querySelector('.cbi-value-field');
        var pInput = pField ? pField.querySelector('input') : null;
        var ptInput = ptRow.querySelector('input');
        
        if (pField && pInput && ptInput) {
            var container = document.createElement('div');
            container.style.display = 'flex';
            container.style.alignItems = 'center';
            container.style.gap = '25px'; 
            
            var pWrap = document.createElement('div');
            pWrap.style.width = '210px'; 
            pInput.style.width = '100%';
            pWrap.appendChild(pInput);
            
            var ptWrap = document.createElement('div');
            ptWrap.style.display = 'flex';
            ptWrap.style.alignItems = 'center';
            ptWrap.style.gap = '10px'; 
            
            var lbl = document.createElement('span');
            lbl.innerText = 'Port Proxy :';
            lbl.style.fontWeight = 'bold';
            lbl.style.whiteSpace = 'nowrap';
            
            var ptInputWrap = document.createElement('div');
            ptInputWrap.style.width = '60px'; 
            ptInput.style.width = '100%';
            ptInputWrap.appendChild(ptInput);
            
            ptWrap.appendChild(lbl);
            ptWrap.appendChild(ptInputWrap);
            
            container.appendChild(pWrap);
            container.appendChild(ptWrap);
            
            pField.insertBefore(container, pField.firstChild);
            
            ptRow.style.display = 'none';
            ptRow.dataset.moved = 'true';
        }
    }
}, 500);
</script>
]]

tls_type = s:option(ListValue, "tls_type", "TLS Type :")
tls_type:value("None", "None (TCP)")
tls_type:value("TLS", "TLS (SSL/SNI)")
tls_type.default = "None"

sni = s:option(Value, "sni", "SNI :")
sni:depends("tls_type", "TLS")

-- ==========================================
-- ADVANCED & PAYLOAD
-- ==========================================
udpgw_port = s:option(Value, "udpgw_port", "UDPGW Port :")
udpgw_port.default = "7500"
udpgw_port.datatype = "port"

payload = s:option(TextValue, "payload", "Payload :")
payload.rows = 5

-- ==========================================
-- HOOK: Proses Commit Config & Redirect
-- ==========================================
function m.on_after_commit(self)
    self.uci:commit("passwall-ssh")
    local new_name = name:formvalue(config_name)
    
    if new_name and new_name ~= "" and new_name ~= config_name then
        sys.call("uci rename passwall-ssh." .. config_name .. "=" .. new_name)
        local current_selected = sys.exec("uci -q get passwall-ssh.main.selected_profile"):gsub("\n", "")
        if current_selected == config_name then
            sys.call("uci set passwall-ssh.main.selected_profile='" .. new_name .. "'")
        end
        sys.call("uci commit passwall-ssh")
    end
    
    http.redirect(dsp.build_url("admin", "services", "passwall-ssh"))
end

return m
