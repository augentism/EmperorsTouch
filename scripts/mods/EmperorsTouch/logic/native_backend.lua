--[[
    native_backend.lua — FFI glue for et_native.dll (the in-process
    buttplug.io client; see et-native/ for the Rust side).

    Follows the ImguiPatch runtime/native.lua pattern: the library handle
    lives in a persistent table so mod hot-reloads re-use it (the DLL can
    never be unloaded from the process), the cdef is guarded against
    re-definition, and a missing DLL degrades to (nil, error) instead of
    breaking mod load.

    All calls are non-blocking: the DLL queues work for its own background
    thread and never calls back into Lua.
--]]

local mod = get_mod("EmperorsTouch")
local ffi = Mods.lua.ffi

local native = {}

local DLL_PATH = "../mods/EmperorsTouch/bin/et_native.dll"
local DEFAULT_WS_URL = "ws://127.0.0.1:12345"

-- Status codes (BP_Status)
native.ST_DISCONNECTED = 0
native.ST_CONNECTING   = 1
native.ST_CONNECTED    = 2
native.ST_FAILED       = 3

local instances = mod:persistent_table("instances")
instances.et_native = instances.et_native or {}
local state = instances.et_native

if not pcall(ffi.typeof, "EmperorsTouch_CDEF") then
    ffi.cdef([[
        typedef struct { int unused; } EmperorsTouch_CDEF;

        int  BP_Connect(const char* url);
        void BP_Disconnect(void);
        int  BP_Status(void);
        int  BP_Command(const char* json);
        int  BP_GetDevices(char* buffer, int buffer_size);
        int  BP_LastError(char* buffer, int buffer_size);
    ]])
end

local buffer_size = 16384
local buffer = ffi.new("char[?]", buffer_size)

local function load_dll()
    if state.dll then
        return state.dll
    end
    local ok, dll_or_error = pcall(ffi.load, DLL_PATH)
    if not ok then
        return nil, "et_native.dll not loaded: " .. tostring(dll_or_error)
    end
    state.dll = dll_or_error
    return state.dll
end

local function last_error(dll)
    local n = dll.BP_LastError(buffer, buffer_size)
    if n > 0 then
        return ffi.string(buffer, n)
    end
    return "unknown native backend error"
end

function native.ws_url()
    return mod:get("native_ws_url") or DEFAULT_WS_URL
end

-- Idempotent: (re)targets the DLL at the configured Intiface URL. The DLL
-- keeps the connection alive (5s retry) from its own thread.
function native.ensure_connected()
    local dll, err = load_dll()
    if not dll then
        return false, err
    end
    if dll.BP_Connect(native.ws_url()) == 0 then
        return false, last_error(dll)
    end
    return true
end

function native.disconnect()
    if state.dll then
        state.dll.BP_Disconnect()
    end
end

-- nil when the DLL is unavailable, else a ST_* code.
function native.status()
    if not state.dll then
        return nil
    end
    return state.dll.BP_Status()
end

-- Sends one make_toy_command-shaped table. Returns ok, err.
function native.command(command_table)
    local dll, err = load_dll()
    if not dll then
        return false, err
    end
    native.ensure_connected()

    local json_str, encode_err = mod.json.encode(command_table)
    if not json_str then
        return false, "encode failed: " .. tostring(encode_err)
    end
    if dll.BP_Command(json_str) == 0 then
        return false, last_error(dll)
    end
    return true
end

-- GetToys equivalent: returns a body table shaped exactly like the
-- Lovense HTTP response (code 200 + double-encoded toys string, or 402
-- when no devices), so mod:get_toys parses it unchanged. Returns nil, err
-- only when the DLL itself is unavailable.
function native.get_toys_body()
    local dll, err = load_dll()
    if not dll then
        return nil, err
    end
    native.ensure_connected()

    local n = dll.BP_GetDevices(buffer, buffer_size)
    if n < 0 then
        -- Buffer too small: grow to the size the DLL asked for and retry
        -- (the snapshot is re-readable, nothing was lost).
        buffer_size = -n
        buffer = ffi.new("char[?]", buffer_size)
        n = dll.BP_GetDevices(buffer, buffer_size)
    end
    if n < 0 then
        return nil, "device snapshot exceeds buffer"
    end

    local toys_str = ffi.string(buffer, n)
    if toys_str == "{}" then
        -- Same "reachable but no toys" code desktop Lovense Remote uses;
        -- get_toys maps it to an empty list.
        return { code = 402, type = "OK" }
    end
    return {
        code = 200,
        type = "OK",
        data = { toys = toys_str, platform = "native", appType = "remote" },
    }
end

return native
