--- Encoding-aware primitives for stepping across UTF-8 codepoints in buffer text.
---
--- Neovim's own APIs (`TSNode:start()`/`:end_()`, `nvim_win_set_cursor`, ...)
--- all measure columns in *bytes*, not characters -- correct and cheap for
--- pure-ASCII text (one byte is one character there), but naive `column - 1`/
--- `text:sub(i, i)` byte arithmetic lands mid-character the moment a unit
--- touches a multi-byte UTF-8 character (e.g. an em dash `—`, 3 bytes). This
--- module is the one place in the plugin that steps across a codepoint
--- boundary -- `_commands.motion.shape`'s "what column is a unit's own last
--- character at" and `_commands.motion.subword`'s "what character sits
--- immediately before this leaf" both reduce to the same question (see
--- `M.last_character_column`'s docstring), so both funnel through here
--- instead of each re-deriving their own byte math.
---
--- `vim.str_utf_start`/`vim.str_utf_end` (`:help vim.str_utf_start()`) do the
--- real work; this module only adds the buffer-row/column plumbing around
--- them.

local M = {}

--- `M.class` results for characters above U+00FF.
---@type table<string, integer>
local _CLASSES = {}

--- The Latin-1 value (U+0080 to U+00FF) of a non-ASCII `character`, if it has one.
---
--- A 2-byte character led by 0xC2/0xC3 is U+0080 to U+00FF. An invalid
--- lone byte is read as the Latin-1 character with its value, as Vim does.
---
---@param character string One non-ASCII character (see `M.characters`).
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

--- `_case` results for non-ASCII characters.
---@type table<string, "upper"|"lower"|"none">
local _CASES = {}

--- The current buffer's text on `row`.
---
---@param row integer 0-indexed row.
---@return string # The row's text, or `""` past the buffer's end.
---
function M.line(row)
    return vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1] or ""
end

--- How many bytes the UTF-8 codepoint starting at `text`'s `byte_index`
--- (1-indexed) occupies.
---
--- `vim.str_utf_end(text, byte_index)` returns the distance *to* the
--- codepoint's last byte (`0` for a 1-byte/ASCII character); this is that
--- distance plus one, so callers can step a whole character at a time
--- (`text:sub(i, i + width - 1)`, then `i = i + width`) instead of assuming
--- every character is exactly 1 byte. `byte_index` must already be a
--- codepoint's first byte (a lead byte or an ASCII byte) -- both call sites
--- in this plugin only reach this after establishing that (either they're
--- scanning character-by-character from `text`'s own start, or they got
--- `byte_index` from `M.last_character_column`, which already lands on a
--- lead byte).
---
---@param text string
---@param byte_index integer 1-indexed byte offset of a codepoint's first byte.
---@return integer # Always >= 1.
---
function M.char_width(text, byte_index)
    return vim.str_utf_end(text, byte_index) + 1
end

--- Find the column of the last full character ending at `end_column`
--- (0-indexed, exclusive), on `row`, in the current buffer.
---
--- Two unrelated-looking questions both reduce to this: `_commands.motion.shape`
--- asks "what column is a unit's own *last* character at" (`end_column` is
--- the unit's exclusive `:end_()`); `_commands.motion.subword` asks "what
--- character sits immediately *before* this leaf" (`end_column` is the
--- leaf's own start column) -- both are "step back one character from an
--- exclusive boundary," which is exactly what `vim.str_utf_start` computes
--- given the byte immediately before that boundary. A raw `end_column - 1`
--- lands mid-character the moment that boundary follows a multi-byte
--- character; this walks the byte back to its own lead byte instead.
---
--- Confirmed safe on out-of-range rows (`M.line` returns `""`,
--- so this falls through to the raw byte, matching `end_column - 1`'s old
--- behavior for a line that doesn't exist) and on malformed UTF-8
--- (`vim.str_utf_start` never errors, treats each stray byte as its own lead
--- byte) -- no `pcall` needed.
---
---@param row integer 0-indexed row.
---@param end_column integer 0-indexed column, one past the last character (exclusive).
---@return integer # The 0-indexed column of that last character's lead byte.
---
function M.last_character_column(row, end_column)
    local last_byte = math.max(end_column - 1, 0)
    local line = M.line(row)

    if last_byte >= #line then
        return last_byte
    end

    return last_byte + vim.str_utf_start(line, last_byte + 1)
end

--- `M.class`'s result for blanks (`:help charclass()`).
M.BLANK = 0

--- `M.class`'s result for punctuation (`:help charclass()`).
M.PUNCTUATION = 1

--- `M.class`'s result for keyword characters (`:help charclass()`).
M.WORD = 2

--- Whether `text` is pure ASCII, so every byte is one character.
---
--- Callers use this for a byte-at-a-time fast path.
---
---@param text string
---@return boolean
---
function M.is_ascii(text)
    return not text:find("[\128-\255]")
end

--- Split `text` into characters, keeping composing characters with the one before them.
---
--- A character here is what the cursor steps over: `é` spelled as `e` plus
--- U+0301 is one character, as `:help mbyte-composing` describes. An
--- invalid UTF-8 byte is a character of its own. Uses `split()` with
--- `\zs` (`:help /\zs`), which splits the same way.
---
---@param text string
---@return {text: string, offset: integer}[] # Each character and its 1-indexed byte offset in `text`.
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

--- The character class Vim's word motions use for `character` (`:help charclass()`).
---
--- `:help word`: a word is a run of keyword characters, or of other
--- non-blank characters, and above 255 a word ends wherever this class
--- changes. `M.BLANK`, `M.PUNCTUATION` and `M.WORD` are the three classes
--- ASCII uses; emoji are 3, and other Unicode blocks (CJK, subscripts,
--- ...) get a class of their own.
---
--- ASCII and Latin-1 are classified here, as Vim does with the default
--- `'iskeyword'` (`@,48-57,_,192-255`): letters, digits, `_` and U+00C0 to
--- U+00FF are keyword characters, U+00A0 (no-break space) is blank. So the
--- plugin's splitting doesn't change with a buffer's `'iskeyword'`. An
--- invalid byte counts as the Latin-1 character with that value, like
--- Vim's. Everything above U+00FF goes through `vim.fn.charclass()`, cached.
---
---@param character string One character (see `M.characters`).
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
        class = vim.fn.charclass(character)
        _CLASSES[character] = class
    end

    return class
end

--- Whether `character` is a letter or digit, in any script.
---
--- Like Lua's `%w` for ASCII (so `_` doesn't count). Above that, any
--- keyword, emoji or other Unicode-class character (see `M.class`) counts:
--- `é`, `日` or `😀` are content, not punctuation.
---
---@param character string One character (see `M.characters`).
---@return boolean
---
function M.is_alphanumeric(character)
    if character:byte(1) < 128 then
        return character:match("^%w") ~= nil
    end

    return M.class(character) >= M.WORD
end

--- Whether `text` has any letter or digit in it (see `M.is_alphanumeric`).
---
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

--- Whether `character` is a lone byte that isn't valid UTF-8.
---
---@param character string One character (see `M.characters`).
---@return boolean
local function _is_invalid_byte(character)
    return #character == 1 and character:byte(1) >= 128
end

--- The case of a non-ASCII `character`: `"upper"`, `"lower"` or `"none"`, cached.
---
---@param character string One character (see `M.characters`).
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

--- Whether `character` is an uppercase letter, in any script.
---
--- A letter is uppercase when lowercasing changes it (`:help tolower()`).
--- An invalid byte has no case, although `tolower()` reads it as Latin-1.
---
---@param character string One character (see `M.characters`).
---@return boolean
---
function M.is_upper(character)
    if character:byte(1) < 128 then
        return character:match("^%u") ~= nil
    end

    return _case(character) == "upper"
end

--- Whether `character` is a lowercase letter, in any script.
---
--- A letter is lowercase when uppercasing changes it (`:help toupper()`).
--- An invalid byte has no case (see `M.is_upper`).
---
---@param character string One character (see `M.characters`).
---@return boolean
---
function M.is_lower(character)
    if character:byte(1) < 128 then
        return character:match("^%l") ~= nil
    end

    return _case(character) == "lower"
end

return M
