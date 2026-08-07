#!/usr/bin/env lua

local socket = require("socket")

-- ==========================================
-- 1. LOGGER UTILITIES
-- ==========================================
local LOG = "/tmp/passwall-ssh.log"

local function log(msg)
    local f = io.open(LOG, "a")
    if f then
        f:write(string.format("[%s] %s\n", os.date("%H:%M:%S"), msg))
        f:close()
    end
end

local function log_payload(title, payload)
    if not payload or payload == "" then return end
    log(title)
    for line in payload:gmatch("([^\r\n]+)") do
        log(line)
    end
end

-- ==========================================
-- 2. ENVIRONMENT & ROUTING
-- ==========================================
local ENV_FILE = "/usr/share/passwall-ssh/passwall-ssh.env"
local function load_env(path)
    local f = io.open(path, "r")
    if not f then return {} end
    local env = {}
    for line in f:lines() do
        if line ~= "" and not line:match("^#") then
            local key, value = line:match("^([%w_]+)%s*=%s*['\"]?(.-)['\"]?$")
            if key then env[key] = value end
        end
    end
    f:close()
    return env
end
local ENV = load_env(ENV_FILE)

local PAYLOAD_FILE = "/usr/share/passwall-ssh/passwall-ssh.payload"
local LISTEN_HOST = "127.0.0.1"
local LISTEN_PORT = tonumber(ENV.LISTEN_PORT) or 8080
local REMOTE_HOST, REMOTE_PORT

if ENV.TRANSPORT == "TLS" then
    REMOTE_HOST = "127.0.0.1"
    REMOTE_PORT = tonumber(ENV.STUNNEL_PORT) or 4444
    log("Mode: TLS/SNI via Stunnel")
else
    if ENV.PROXY and ENV.PROXY ~= "" then
        REMOTE_HOST = ENV.PROXY
        REMOTE_PORT = tonumber(ENV.PROXY_PORT) or 80
        log("Mode: TCP via HTTP Proxy -> " .. tostring(REMOTE_HOST) .. ":" .. tostring(REMOTE_PORT))
    else
        REMOTE_HOST = ENV.HOST
        REMOTE_PORT = tonumber(ENV.HOST_PORT) or 80
        log("Mode: Direct TCP Injector -> " .. tostring(REMOTE_HOST) .. ":" .. tostring(REMOTE_PORT))
    end
end

if not REMOTE_HOST or REMOTE_HOST == "" then
    REMOTE_HOST = "127.0.0.1"
end

-- ==========================================
-- 3. SAFE ENHANCED PAYLOAD TRANSLATOR
-- ==========================================
local f, err = io.open(PAYLOAD_FILE, "rb")
local RAW_PAYLOAD = ""
if f then 
    RAW_PAYLOAD = f:read("*a") or ""
    f:close()
end

local USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

-- Inisialisasi seed acak sekali di awal (Aman untuk CPU 32-bit OpenWrt)
local t_sec = os.time()
local t_ms = math.floor((socket.gettime() % 1) * 1000)
math.randomseed(t_sec + t_ms)

local function generate_ws_key()
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local key = {}
    for i = 1, 22 do
        local rand = math.random(1, #chars)
        table.insert(key, chars:sub(rand, rand))
    end
    table.insert(key, "==")
    return table.concat(key)
end

-- Helper: Pengganti string aman Lua (mencegah crash % capture index)
local function safe_sub(str, pattern, repl)
    if not str then return "" end
    return (str:gsub(pattern, function() return tostring(repl or "") end))
end

-- 1. Penanganan Pengulangan Token [token*N] (misal: [crlf*2])
local function expand_multipliers(payload)
    if not payload then return "" end
    return payload:gsub("%[([%w_%-]+)%*(%d+)%]", function(token, count)
        local n = tonumber(count) or 1
        return string.rep("[" .. token .. "]", n)
    end)
end

local RAW_EXPANDED = expand_multipliers(RAW_PAYLOAD)

-- 2. Static Pre-parsing
local STATIC_PAYLOAD = RAW_EXPANDED
STATIC_PAYLOAD = safe_sub(STATIC_PAYLOAD, "%[crlf%]", "\r\n")
STATIC_PAYLOAD = safe_sub(STATIC_PAYLOAD, "%[lf%]", "\n")
STATIC_PAYLOAD = safe_sub(STATIC_PAYLOAD, "%[cr%]", "\r")
STATIC_PAYLOAD = safe_sub(STATIC_PAYLOAD, "%[protocol%]", "HTTP/1.1")
STATIC_PAYLOAD = safe_sub(STATIC_PAYLOAD, "%[ua%]", USER_AGENT)
STATIC_PAYLOAD = safe_sub(STATIC_PAYLOAD, "%[proxy%]", ENV.PROXY or "")
STATIC_PAYLOAD = safe_sub(STATIC_PAYLOAD, "%[proxy_host%]", ENV.PROXY or "")
STATIC_PAYLOAD = safe_sub(STATIC_PAYLOAD, "%[proxy_port%]", ENV.PROXY_PORT or "")
STATIC_PAYLOAD = safe_sub(STATIC_PAYLOAD, "%[sni%]", ENV.SNI or "")
STATIC_PAYLOAD = safe_sub(STATIC_PAYLOAD, "%[sni_host%]", ENV.SNI or "")
STATIC_PAYLOAD = safe_sub(STATIC_PAYLOAD, "%[sni_port%]", "443")

local rotate_index = 0

-- 3. Dynamic Token Parsing (Aman & Stabil)
local function parse_tags_dynamic(payload, host, port, client_raw_request)
    if not payload then return "" end
    
    local SSH_HOST = ENV.HOST or host or ""
    local SSH_PORT = tostring(ENV.HOST_PORT or port or 80)
    local SSH_HOST_PORT = SSH_HOST .. ":" .. SSH_PORT

    -- Deteksi Method HTTP Valid (Abaikan banner SSH-2.0)
    local method = "GET"
    if client_raw_request and client_raw_request ~= "" then
        local m = client_raw_request:match("^([A-Z]+)%s+")
        if m and m ~= "SSH" then 
            method = m 
        elseif client_raw_request:find("^CONNECT") then
            method = "CONNECT"
        end
    end

    local res = payload
    -- Server & SSH Alias
    res = safe_sub(res, "%[host%]", SSH_HOST)
    res = safe_sub(res, "%[server%]", SSH_HOST)
    res = safe_sub(res, "%[ssh%]", SSH_HOST)
    res = safe_sub(res, "%[ssh_host%]", SSH_HOST)
    res = safe_sub(res, "%[ip%]", SSH_HOST)
    res = safe_sub(res, "%[host_no_port%]", SSH_HOST)
    
    res = safe_sub(res, "%[port%]", SSH_PORT)
    res = safe_sub(res, "%[ssh_port%]", SSH_PORT)
    
    res = safe_sub(res, "%[host_port%]", SSH_HOST_PORT)
    res = safe_sub(res, "%[ip_port%]", SSH_HOST_PORT)
    
    -- WebSocket & Request Tokens
    res = (res:gsub("%[ws_key%]", generate_ws_key))
    res = (res:gsub("%[ws%-key%]", generate_ws_key))
    res = safe_sub(res, "%[method%]", method)
    res = safe_sub(res, "%[raw%]", client_raw_request or "")
    res = safe_sub(res, "%[real_raw%]", client_raw_request or "")
    res = safe_sub(res, "%[realData%]", client_raw_request or "")
    res = safe_sub(res, "%[netData%]", client_raw_request or "")

    -- Evaluator Rotate & Random
    res = res:gsub("%[rotate=([^%]]+)%]", function(list)
        local items = {}
        for item in list:gmatch("[^;]+") do table.insert(items, item) end
        if #items > 0 then
            rotate_index = (rotate_index % #items) + 1
            return items[rotate_index]
        end
        return ""
    end)

    res = res:gsub("%[random=([^%]]+)%]", function(list)
        local items = {}
        for item in list:gmatch("[^;]+") do table.insert(items, item) end
        if #items > 0 then
            return items[math.random(1, #items)]
        end
        return ""
    end)

    return res
end

-- INI ADALAH FUNGSI YANG SEBELUMNYA TERHAPUS
local function generate_steps(payload, is_connect)
    local steps = {}
    local pos_ds = payload:find("%[delay_split%]", 1, true)
    local pos_s = payload:find("%[split%]", 1, true)
    
    if pos_ds then
        table.insert(steps, { action = "SEND", data = payload:sub(1, pos_ds - 1) })
        table.insert(steps, { action = "SEND_BANNER" })
        table.insert(steps, { action = "DELAY", ms = tonumber(ENV.DELAY) or 1000 })
        table.insert(steps, { action = "SEND", data = payload:sub(pos_ds + 13) })
    elseif pos_s then
        table.insert(steps, { action = "SEND", data = payload:sub(1, pos_s - 1) })
        table.insert(steps, { action = "SEND_BANNER" })
        table.insert(steps, { action = "WAIT_INCOMING_HTTP" })
        table.insert(steps, { action = "SEND", data = payload:sub(pos_s + 7) })
    else
        table.insert(steps, { action = "SEND", data = payload })
        table.insert(steps, { action = "SEND_BANNER" })
    end
    
    return steps
end

-- ==========================================
-- 4. GLOBAL EVENT LOOP ENGINE (ASYNC WRITE + SHORT TIMEOUT CONNECT)
-- ==========================================

local server, bind_err = socket.bind(LISTEN_HOST, LISTEN_PORT)
if not server then
    log("FATAL BIND ERROR: " .. tostring(bind_err))
    os.exit(1)
end
server:settimeout(0)

local read_sockets = { server }
local write_sockets = {}      
local session_pairs = {} 
local write_buffers = {}      

local function set_wants_write(sock, wants)
    local idx = nil
    for i, s in ipairs(write_sockets) do
        if s == sock then idx = i; break end
    end
    if wants and not idx then
        table.insert(write_sockets, sock)
    elseif not wants and idx then
        table.remove(write_sockets, idx)
    end
end

local function cleanup(sess)
    if not sess or sess.closed then return end
    sess.closed = true
    for _, s in ipairs({sess.client, sess.remote}) do
        if s then
            pcall(function() s:close() end)
            session_pairs[s] = nil
            write_buffers[s] = nil
            for i = #read_sockets, 1, -1 do
                if read_sockets[i] == s then table.remove(read_sockets, i); break end
            end
            set_wants_write(s, false)
        end
    end
end

local function queue_send(sock, data)
    if not sock or not data or data == "" then return end
    if not write_buffers[sock] then write_buffers[sock] = "" end
    write_buffers[sock] = write_buffers[sock] .. data
    set_wants_write(sock, true)
end

local function execute_sequence(sess)
    if sess.closed then return end
    while sess.out_index <= #sess.out_steps do
        local step = sess.out_steps[sess.out_index]
        
        if step.action == "SEND" then
            if step.data and #step.data > 0 then
                log_payload("Queued Payload Part", step.data)
                queue_send(sess.remote, step.data)
            end
            sess.out_index = sess.out_index + 1
            
        elseif step.action == "SEND_BANNER" then
            if sess.banner and #sess.banner > 0 then
                queue_send(sess.remote, sess.banner)
                sess.banner = "" 
            end
            sess.out_index = sess.out_index + 1
            
        elseif step.action == "DELAY" then
            sess.out_state = "WAIT_DELAY"
            sess.delay_until = socket.gettime() + (step.ms / 1000)
            return
            
        elseif step.action == "WAIT_INCOMING_HTTP" then
            sess.out_state = "WAIT_INCOMING_HTTP"
            return
        end
    end
    sess.out_state = "DONE"
end

while true do
    local now = socket.gettime()
    local min_timeout = 1.0

    -- Evaluasi Timers (Idle & Payload Delays)
    for sock, sess in pairs(session_pairs) do
        if sock == sess.client and not sess.closed then 
            if now - sess.last_active > 300 then
                log("Idle Timeout - Terminating Zombie Session")
                cleanup(sess)
            elseif sess.out_state == "WAIT_DELAY" then
                local time_left = sess.delay_until - now
                if time_left <= 0 then
                    sess.out_state = "RUNNING"
                    sess.out_index = sess.out_index + 1
                    execute_sequence(sess)
                else
                    if time_left < min_timeout then min_timeout = time_left end
                end
            end
        end
    end

    local readable, writable, _ = socket.select(read_sockets, write_sockets, min_timeout)

    -- PROCESS WRITABLE (Hanya untuk Asynchronous Write Buffer)
    if writable then
        for _, sock in ipairs(writable) do
            local sess = session_pairs[sock]
            
            if sess and not sess.closed and write_buffers[sock] and #write_buffers[sock] > 0 then
                local sent, err_send, last = sock:send(write_buffers[sock])
                if sent then
                    write_buffers[sock] = write_buffers[sock]:sub(sent + 1)
                elseif err_send == "timeout" then
                    if last and last > 0 then
                        write_buffers[sock] = write_buffers[sock]:sub(last + 1)
                    end
                else
                    cleanup(sess)
                end
            end
            
            if sess and not sess.closed then
                if not write_buffers[sock] or write_buffers[sock] == "" then
                    set_wants_write(sock, false)
                end
            end
        end
    end

    -- PROCESS READABLE
    if readable then
        for _, sock in ipairs(readable) do
            if sock == server then
                local client = server:accept()
                if client then
                    client:settimeout(0)
                    client:setoption("tcp-nodelay", true)
                    table.insert(read_sockets, client)
                    session_pairs[client] = {
                        client = client,
                        remote = nil,
                        last_active = now,
                        in_need_200 = false,
                        out_state = "INIT",
                        out_steps = {},
                        out_index = 1,
                        banner = "",
                        closed = false
                    }
                end
            else
                local sess = session_pairs[sock]
                if sess and not sess.closed then
                    sess.last_active = now
                    
                    if sock == sess.client then
                        if sess.out_state == "INIT" then
                            local data, err_recv, partial = sock:receive(8192)
                            local chunk = data or partial or ""

                            if #chunk > 0 then
                                local host, port = REMOTE_HOST, REMOTE_PORT
                                
                                if chunk:match("^CONNECT") then
                                    sess.in_need_200 = true
                                    local hp = chunk:match("^CONNECT%s+([^%s]+)")
                                    if hp then
                                        local h, p = hp:match("^([^:]+):(%d+)$")
                                        if h then host = h; port = tonumber(p) end
                                    end
                                    local end_header = chunk:find("\r\n\r\n")
                                    if end_header then chunk = chunk:sub(end_header + 4) else chunk = "" end
                                end
                                
                                sess.banner = chunk 
                                
                                -- KONEKSI AMAN: Menggunakan short-timeout blocking connect (2.5 detik)
                                local remote = socket.tcp()
                                remote:settimeout(2.5) 
                                
                                local res, conn_err = remote:connect(REMOTE_HOST, REMOTE_PORT)
                                
                                if not res then
                                    log("Upstream Connect Failed: " .. tostring(conn_err))
                                    cleanup(sess)
                                else
                                    -- Sukses connect, langsung ubah ke mode non-blocking untuk performa penuh
                                    remote:settimeout(0)
                                    remote:setoption("tcp-nodelay", true)
                                    sess.remote = remote
                                    session_pairs[remote] = sess
                                    table.insert(read_sockets, remote)
                                    
                                    local translated_payload = parse_tags_dynamic(STATIC_PAYLOAD, host, port,chunk)
                                    sess.out_steps = generate_steps(translated_payload, sess.in_need_200)
                                    sess.out_state = "RUNNING"
                                    execute_sequence(sess)
                                end
                            else
                                if err_recv == "closed" then cleanup(sess) end
                            end
                        else
                            local data, err_recv, partial = sock:receive(8192)
                            local chunk = data or partial or ""
                            if #chunk > 0 then
                                queue_send(sess.remote, chunk)
                            end
                            if err_recv == "closed" then cleanup(sess) end
                        end

                    elseif sock == sess.remote then
                        local data, err_recv, partial = sock:receive(8192)
                        local chunk = data or partial or ""
                        
                        if #chunk > 0 then
                            if sess.in_need_200 or sess.out_state == "WAIT_INCOMING_HTTP" then
                                if chunk:find("^HTTP/1%.") then
                                    if sess.in_need_200 then
                                        log("> Injecting HTTP 200 OK (Buffered)")
                                        queue_send(sess.client, "HTTP/1.0 200 Connection established\r\n\r\n")
                                        sess.in_need_200 = false
                                        local end_header = chunk:find("\r\n\r\n")
                                        if end_header then chunk = chunk:sub(end_header + 4) else chunk = "" end
                                    end
                                    
                                    if sess.out_state == "WAIT_INCOMING_HTTP" then
                                        sess.out_state = "RUNNING"
                                        sess.out_index = sess.out_index + 1
                                        execute_sequence(sess)
                                    end
                                end
                            end
                            
                            if #chunk > 0 then
                                queue_send(sess.client, chunk)
                            end
                        end
                        
                        if err_recv == "closed" then 
                            log("Upstream Closed Connection")
                            cleanup(sess) 
                        end
                    end
                end
            end
        end
    end
end
