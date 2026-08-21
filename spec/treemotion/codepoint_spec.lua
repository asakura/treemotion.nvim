--- Direct unit tests for `_commands.motion.codepoint`'s encoding-aware
--- primitives -- `M.classify`, `M.char_width`, `M.last_character_column` --
--- isolated from the motion machinery that consumes them. See
--- `motion_spec.lua`'s "multi-byte (UTF-8) characters" block for an
--- end-to-end `#e` regression covering the same fix through
--- `_commands.motion.runner`.

local codepoint = require("treemotion._commands.motion.codepoint")

describe("codepoint.classify", function()
    it('classifies pure ASCII text as "ascii"', function()
        assert.same("ascii", codepoint.classify("hello world"))
    end)

    it('classifies empty text as "ascii"', function()
        assert.same("ascii", codepoint.classify(""))
    end)

    it('classifies text made entirely of multi-byte characters as "multibyte"', function()
        assert.same("multibyte", codepoint.classify("\226\128\148\226\128\148")) -- "——"
    end)

    it('classifies text mixing ASCII and multi-byte characters as "mixed"', function()
        assert.same("mixed", codepoint.classify("hello \226\128\148 world"))
    end)
end)

describe("codepoint.char_width", function()
    it("returns 1 for an ASCII character", function()
        assert.same(1, codepoint.char_width("hello", 1))
    end)

    it("returns 3 for a 3-byte UTF-8 character (em dash)", function()
        assert.same(3, codepoint.char_width("\226\128\148", 1))
    end)

    it("returns 2 for a 2-byte UTF-8 character", function()
        assert.same(2, codepoint.char_width("\195\166", 1)) -- "æ"
    end)

    it("measures the character starting at a non-1 byte_index, not just the string's start", function()
        assert.same(3, codepoint.char_width("x\226\128\148y", 2)) -- "x—y", em dash starts at byte 2
    end)
end)

describe("codepoint.last_character_column", function()
    ---@type integer?
    local _BUFFER

    before_each(function()
        _BUFFER = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(_BUFFER)
    end)

    after_each(function()
        if _BUFFER and vim.api.nvim_buf_is_valid(_BUFFER) then
            vim.api.nvim_buf_delete(_BUFFER, { force = true })
        end
        _BUFFER = nil
    end)

    it("steps back one byte for an ASCII trailing character", function()
        vim.api.nvim_buf_set_lines(assert(_BUFFER), 0, -1, false, { "hello" })
        assert.same(4, codepoint.last_character_column(0, 5)) -- end_column 5 (exclusive) -> "o" at 4
    end)

    it("lands on the lead byte of a multi-byte trailing character, not a continuation byte", function()
        -- "x—y": x=0, em dash=1-3 (3 bytes), y=4. end_column 4 (exclusive) is
        -- one past the em dash's own last byte (3) -- naive `column - 1`
        -- would land on byte 3, a continuation byte, not the dash's lead
        -- byte (1).
        vim.api.nvim_buf_set_lines(assert(_BUFFER), 0, -1, false, { "x\226\128\148y" })
        assert.same(1, codepoint.last_character_column(0, 4))
    end)

    it("clamps at 0 for end_column 0", function()
        vim.api.nvim_buf_set_lines(assert(_BUFFER), 0, -1, false, { "hello" })
        assert.same(0, codepoint.last_character_column(0, 0))
    end)

    it("falls back to a raw byte decrement for an out-of-range row", function()
        vim.api.nvim_buf_set_lines(assert(_BUFFER), 0, -1, false, { "hello" })
        -- `nvim_buf_get_lines` returns `{}` for a row past the buffer's end,
        -- so this can't consult the (nonexistent) line's bytes -- same
        -- fallback the old, unfixed `column - 1` arithmetic always used.
        assert.same(4, codepoint.last_character_column(5, 5))
    end)

    it("never errors on malformed UTF-8, treating a stray continuation byte as its own lead byte", function()
        vim.api.nvim_buf_set_lines(assert(_BUFFER), 0, -1, false, { "x\128y" }) -- a stray 0x80 byte
        assert.same(1, codepoint.last_character_column(0, 2))
    end)
end)
