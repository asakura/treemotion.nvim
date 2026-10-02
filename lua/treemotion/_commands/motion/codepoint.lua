--- UTF-8 helpers. Buffer columns are bytes; these step whole characters.

local M = {}

---@type table<string, integer> `M.class` cache above U+00FF.
local _CLASSES = {}

--- The U+0080..U+00FF value of `character`, if any. A lone invalid byte
--- reads as Latin-1, as in Vim.
---
---@param character string
---@return integer?
local function _latin1_value(character)
    local byte = character:byte(1)

    if #character == 1 then
        return byte
    elseif byte == 0xC2 or byte == 0xC3 then
        return (byte - 0xC0) * 64 + (character:byte(2) - 0x80)
    end

    return nil
end

---@type table<string, "upper"|"lower"|"none"> `_case` cache.
local _CASES = {}

---@param row integer
---@return string # `""` past the buffer's end.
---
function M.line(row)
    return vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1] or ""
end

--- Bytes in the character starting at `byte_index` (a lead byte).
---
---@param text string
---@param byte_index integer 1-indexed.
---@return integer
---
function M.char_width(text, byte_index)
    return vim.str_utf_end(text, byte_index) + 1
end

--- The column of the character ending at the exclusive `end_column`.
---
---@param row integer
---@param end_column integer
---@return integer
---
function M.last_character_column(row, end_column)
    local last_byte = math.max(end_column - 1, 0)
    local line = M.line(row)

    if last_byte >= #line then
        return last_byte
    end

    return last_byte + vim.str_utf_start(line, last_byte + 1)
end

--- `:help charclass()` values.
M.BLANK = 0

M.PUNCTUATION = 1

M.WORD = 2

---@param text string
---@return boolean
---
function M.is_ascii(text)
    return not text:find("[\128-\255]")
end

--- Split `text` into characters, keeping composing characters with their
--- base (`:help mbyte-composing`).
---
---@param text string
---@return {text: string, offset: integer}[] # Characters and their 1-indexed byte offsets.
---
function M.characters(text)
    local result = {}

    if M.is_ascii(text) then
        for index = 1, #text do
            result[index] = { text = text:sub(index, index), offset = index }
        end

        return result
    end

    if not text:find("[\204-\255]") then
        -- Nothing from U+0300 up, so no composing characters: step by codepoint.
        local offset = 1

        while offset <= #text do
            local width = M.char_width(text, offset)

            table.insert(result, { text = text:sub(offset, offset + width - 1), offset = offset })
            offset = offset + width
        end

        return result
    end

    local offset = 1

    for _, character in ipairs(vim.fn.split(text, "\\zs")) do
        table.insert(result, { text = character, offset = offset })
        offset = offset + #character
    end

    return result
end

--- Vim's word class for `character` (`:help charclass()`). ASCII and
--- Latin-1 use the default `'iskeyword'`, so a buffer's own setting has no
--- effect.
---
---@param character string
---@return integer
---
function M.class(character)
    local byte = character:byte(1)

    if byte < 128 then
        if character:match("^%s") then
            return M.BLANK
        elseif character:match("^[%w_]") then
            return M.WORD
        end

        return M.PUNCTUATION
    end

    local latin1 = _latin1_value(character)

    if latin1 then
        if latin1 == 0xA0 then
            return M.BLANK
        elseif latin1 >= 0xC0 then
            return M.WORD
        end

        return M.PUNCTUATION
    end

    local class = _CLASSES[character]

    if not class then
        -- Typed `0|1|2|3|'other'`, but `'other'` stands for a class number.
        class = vim.fn.charclass(character) --[[@as integer]]
        _CLASSES[character] = class
    end

    return class
end

--- Whether `character` is a letter or digit in any script (`_` is not).
---
---@param character string
---@return boolean
---
function M.is_alphanumeric(character)
    if character:byte(1) < 128 then
        return character:match("^%w") ~= nil
    end

    return M.class(character) >= M.WORD
end

---@param text string
---@return boolean
---
function M.has_alphanumeric(text)
    if text:find("%w") then
        return true
    end

    if M.is_ascii(text) then
        return false
    end

    for _, character in ipairs(M.characters(text)) do
        if M.is_alphanumeric(character.text) then
            return true
        end
    end

    return false
end

---@param character string
---@return boolean
local function _is_invalid_byte(character)
    return #character == 1 and character:byte(1) >= 128
end

---@param character string Non-ASCII.
---@return "upper"|"lower"|"none"
local function _case(character)
    local result = _CASES[character]

    if result then
        return result
    end

    if _is_invalid_byte(character) then
        result = "none"
    elseif vim.fn.tolower(character) ~= character then
        result = "upper"
    elseif vim.fn.toupper(character) ~= character then
        result = "lower"
    else
        result = "none"
    end

    _CASES[character] = result

    return result
end

--- Uppercase means `tolower()` changes it. Invalid bytes have no case.
---
---@param character string
---@return boolean
---
function M.is_upper(character)
    if character:byte(1) < 128 then
        return character:match("^%u") ~= nil
    end

    return _case(character) == "upper"
end

--- Lowercase means `toupper()` changes it. Invalid bytes have no case.
---
---@param character string
---@return boolean
---
function M.is_lower(character)
    if character:byte(1) < 128 then
        return character:match("^%l") ~= nil
    end

    return _case(character) == "lower"
end

return M
