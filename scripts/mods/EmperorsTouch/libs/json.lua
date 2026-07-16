--[[
    Minimal JSON decoder + encoder.
    decode: parses the double-encoded "toys" string from the Lovense API.
    encode: serializes command tables for the native (FFI) backend.
--]]

local mod = get_mod("EmperorsTouch")

local json = {}

local function skip_ws(s, i)
    return (s:find("[^ \t\r\n]", i)) or (#s + 1)
end

local decode_value

local function decode_string(s, i)
    -- i points at opening quote
    local out = {}
    i = i + 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(out), i + 1
        elseif c == "\\" then
            local e = s:sub(i + 1, i + 1)
            if e == "n" then out[#out + 1] = "\n"
            elseif e == "t" then out[#out + 1] = "\t"
            elseif e == "r" then out[#out + 1] = "\r"
            elseif e == "b" then out[#out + 1] = "\b"
            elseif e == "f" then out[#out + 1] = "\f"
            elseif e == "u" then
                local hex = s:sub(i + 2, i + 5)
                local code = tonumber(hex, 16) or 63
                if code < 128 then
                    out[#out + 1] = string.char(code)
                elseif code < 2048 then
                    out[#out + 1] = string.char(192 + math.floor(code / 64), 128 + code % 64)
                else
                    out[#out + 1] = string.char(
                        224 + math.floor(code / 4096),
                        128 + math.floor(code / 64) % 64,
                        128 + code % 64
                    )
                end
                i = i + 4
            else
                out[#out + 1] = e
            end
            i = i + 2
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    error("unterminated string in JSON")
end

local function decode_number(s, i)
    local num_str = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
    return tonumber(num_str), i + #num_str
end

local function decode_object(s, i)
    local obj = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
        if s:sub(i, i) ~= '"' then error("expected key string in JSON object") end
        local key
        key, i = decode_string(s, i)
        i = skip_ws(s, i)
        if s:sub(i, i) ~= ":" then error("expected ':' in JSON object") end
        local val
        val, i = decode_value(s, skip_ws(s, i + 1))
        obj[key] = val
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == "}" then return obj, i + 1 end
        if c ~= "," then error("expected ',' or '}' in JSON object") end
        i = skip_ws(s, i + 1)
    end
end

local function decode_array(s, i)
    local arr = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
        local val
        val, i = decode_value(s, i)
        arr[#arr + 1] = val
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == "]" then return arr, i + 1 end
        if c ~= "," then error("expected ',' or ']' in JSON array") end
        i = skip_ws(s, i + 1)
    end
end

decode_value = function(s, i)
    local c = s:sub(i, i)
    if c == "{" then return decode_object(s, i) end
    if c == "[" then return decode_array(s, i) end
    if c == '"' then return decode_string(s, i) end
    if c == "t" and s:sub(i, i + 3) == "true"  then return true,  i + 4 end
    if c == "f" and s:sub(i, i + 4) == "false" then return false, i + 5 end
    if c == "n" and s:sub(i, i + 3) == "null"  then return nil,   i + 4 end
    return decode_number(s, i)
end

-- Returns decoded value, or nil + error message
json.decode = function(s)
    if type(s) ~= "string" then return nil, "not a string" end
    local ok, result = pcall(function()
        local v = decode_value(s, skip_ws(s, 1))
        return v
    end)
    if ok then return result end
    return nil, result
end

local encode_value

local ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n",
    ["\r"] = "\\r", ["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f",
}

local function encode_string(s)
    return '"' .. s:gsub('[%z\1-\31"\\]', function(c)
        return ESCAPES[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

encode_value = function(v)
    local t = type(v)
    if t == "string" then return encode_string(v) end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            error("cannot encode non-finite number")
        end
        -- %.14g round-trips integers cleanly and avoids float noise
        return string.format("%.14g", v)
    end
    if t == "boolean" then return tostring(v) end
    if t == "table" then
        -- Array if [1] is set (command tables never mix array/hash parts)
        if v[1] ~= nil then
            local parts = {}
            for i = 1, #v do parts[i] = encode_value(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for key, val in pairs(v) do
            if type(key) ~= "string" then error("object keys must be strings") end
            parts[#parts + 1] = encode_string(key) .. ":" .. encode_value(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("cannot encode type " .. t)
end

-- Returns JSON string, or nil + error message
json.encode = function(value)
    local ok, result = pcall(encode_value, value)
    if ok then return result end
    return nil, result
end

mod.json = json

return json
