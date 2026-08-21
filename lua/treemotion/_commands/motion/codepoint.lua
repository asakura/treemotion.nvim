--- Encoding-aware primitives for stepping across UTF-8 codepoints in buffer text.
---
--- Neovim's own APIs (`TSNode:start()`/`:end_()`, `nvim_win_set_cursor`, ...)
--- all measure columns in *bytes*, not characters -- correct and cheap for
--- pure-ASCII text (one byte is one character there), but naive `column - 1`/
--- `text:sub(i, i)` byte arithmetic lands mid-character the moment a unit
--- touches a multi-byte UTF-8 character (e.g. an em dash `—`, 3 bytes). This
--- module is the one place in the plugin that steps across a codepoint
--- boundary -- `_commands.motion.runner`'s "what column is a unit's own last
--- character at" and `_commands.motion.subword`'s "what character sits
--- immediately before this leaf" both reduce to the same question (see
--- `M.last_character_column`'s docstring), so both funnel through here
--- instead of each re-deriving their own byte math.
---
--- `vim.str_utf_start`/`vim.str_utf_end` (`:help vim.str_utf_start()`) do the
--- real work; this module only adds the buffer-row/column plumbing around
--- them, plus `M.classify`, which names *why* a given leaf needs this at all.

local M = {}

--- How a run of text is encoded, byte-wise.
---
--- Purely descriptive: nothing downstream branches on it (`M.char_width`/
--- `M.last_character_column` are already correct, and just as cheap, for
--- pure `"ascii"` text, where every codepoint is 1 byte wide already) -- it
--- exists so a caller can name *why* a particular leaf needed codepoint-aware
--- handling (a comment containing an em dash is `"mixed"`; an emoji-only
--- reaction leaf would be `"multibyte"`; an ordinary identifier is
--- `"ascii"`), without every caller re-deriving that classification itself.
---@alias treemotion.EncodingKind "ascii"|"multibyte"|"mixed"

--- Classify `text`'s byte content: every byte < 128 (`"ascii"`, the common
--- case for identifiers/delimiters), every byte >= 128 (`"multibyte"`), or
--- some of each (`"mixed"` -- ordinary prose containing an em dash, an
--- accented letter, ...).
---
---@param text string
---@return treemotion.EncodingKind
---
function M.classify(text)
    local saw_ascii = false
    local saw_multibyte = false

    for index = 1, #text do
        if text:byte(index) < 128 then
            saw_ascii = true
        else
            saw_multibyte = true
        end

        if saw_ascii and saw_multibyte then
            return "mixed"
        end
    end

    if saw_multibyte then
        return "multibyte"
    end

    return "ascii"
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
--- Two unrelated-looking questions both reduce to this: `_commands.motion.runner`
--- asks "what column is a unit's own *last* character at" (`end_column` is
--- the unit's exclusive `:end_()`); `_commands.motion.subword` asks "what
--- character sits immediately *before* this leaf" (`end_column` is the
--- leaf's own start column) -- both are "step back one character from an
--- exclusive boundary," which is exactly what `vim.str_utf_start` computes
--- given the byte immediately before that boundary. A raw `end_column - 1`
--- lands mid-character the moment that boundary follows a multi-byte
--- character; this walks the byte back to its own lead byte instead.
---
--- Confirmed safe on out-of-range rows (`nvim_buf_get_lines` returns `{}`,
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
    local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1]

    if not line or last_byte >= #line then
        return last_byte
    end

    return last_byte + vim.str_utf_start(line, last_byte + 1)
end

return M
