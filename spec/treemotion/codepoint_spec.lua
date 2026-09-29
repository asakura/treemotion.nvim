--- Direct unit tests for `_commands.motion.codepoint`'s encoding-aware
--- primitives -- `M.char_width`, `M.last_character_column`, and the
--- character classification helpers -- isolated from
--- the motion machinery that consumes them. See
--- `treemotion_spec.lua`'s "multi-byte (UTF-8) characters" block for an
--- end-to-end `#e` regression covering the same fix through
--- `_commands.motion.runner`.

local codepoint = require("treemotion._commands.motion.codepoint")

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

--- `fn`'s result for each of `characters`, keyed by the character, so a failure shows which one.
---
---@generic T
---@param characters string[]
---@param fn fun(character: string): T
---@return table<string, T>
local function _map(characters, fn)
    local result = {}

    for _, character in ipairs(characters) do
        result[character] = fn(character)
    end

    return result
end

--- `"upper"`, `"lower"`, `"both"` or `"none"`, from `codepoint.is_upper`/`codepoint.is_lower`.
---
---@param character string
---@return string
local function _case(character)
    local upper, lower = codepoint.is_upper(character), codepoint.is_lower(character)

    if upper and lower then
        return "both"
    end

    return upper and "upper" or lower and "lower" or "none"
end

describe("codepoint.characters", function()
    it("splits ASCII into bytes", function()
        assert.same({ { text = "a", offset = 1 }, { text = "b", offset = 2 } }, codepoint.characters("ab"))
    end)

    it("keeps a multibyte character whole", function()
        assert.same({ { text = "é", offset = 1 }, { text = "x", offset = 3 } }, codepoint.characters("éx"))
    end)

    it("keeps a combining accent with the letter before it", function()
        assert.same(
            { { text = "e\204\129", offset = 1 }, { text = "x", offset = 4 } },
            codepoint.characters("e\204\129x")
        )
    end)

    it("gives an invalid byte its own character", function()
        assert.same(
            { { text = "a", offset = 1 }, { text = "\255", offset = 2 }, { text = "b", offset = 3 } },
            codepoint.characters("a\255b")
        )
    end)

    it("returns nothing for empty text", function()
        assert.same({}, codepoint.characters(""))
    end)
end)

describe("codepoint.class", function()
    it("classifies ASCII and Latin-1 like the default 'iskeyword', whatever the buffer's", function()
        local iskeyword = vim.bo.iskeyword
        vim.bo.iskeyword = "a-z"

        local classes = vim.tbl_map(codepoint.class, { " ", "A", "_", "-", "é", "\194\160", "«", "\255" })
        vim.bo.iskeyword = iskeyword

        assert.same({
            codepoint.BLANK,
            codepoint.WORD,
            codepoint.WORD,
            codepoint.PUNCTUATION,
            codepoint.WORD,
            codepoint.BLANK,
            codepoint.PUNCTUATION,
            codepoint.WORD,
        }, classes)
    end)

    it("follows charclass() with the default 'iskeyword'", function()
        for _, character in ipairs({ "é", "e\204\129", "—", "…", "\194\160", "\227\128\128", "日", "😀", "₂" }) do
            assert.same(vim.fn.charclass(character), codepoint.class(character), character)
        end
    end)

    it("puts accented letters, punctuation and spaces in Vim's classes", function()
        assert.same(codepoint.WORD, codepoint.class("é"))
        assert.same(codepoint.PUNCTUATION, codepoint.class("—"))
        assert.same(codepoint.BLANK, codepoint.class("\194\160")) -- no-break space
    end)
end)

describe("codepoint.is_alphanumeric", function()
    it("counts ASCII letters and digits, but not _", function()
        assert.is_true(codepoint.is_alphanumeric("a"))
        assert.is_true(codepoint.is_alphanumeric("7"))
        assert.is_false(codepoint.is_alphanumeric("_"))
        assert.is_false(codepoint.is_alphanumeric("-"))
    end)

    it("counts letters, emoji and CJK in any script, but not punctuation or blanks", function()
        assert.same(
            { ["é"] = true, ["Ω"] = true, ["ж"] = true, ["日"] = true, ["😀"] = true },
            _map({ "é", "Ω", "ж", "日", "😀" }, codepoint.is_alphanumeric)
        )
        assert.same(
            { ["—"] = false, ["…"] = false, ["«"] = false, ["\194\160"] = false },
            _map({ "—", "…", "«", "\194\160" }, codepoint.is_alphanumeric)
        )
    end)
end)

describe("codepoint.has_alphanumeric", function()
    it("finds a letter in any script", function()
        assert.is_true(codepoint.has_alphanumeric("--é"))
        assert.is_true(codepoint.has_alphanumeric("_a_"))
    end)

    it("is false for punctuation and blanks only", function()
        assert.is_false(codepoint.has_alphanumeric("---"))
        assert.is_false(codepoint.has_alphanumeric("—…\194\160"))
        assert.is_false(codepoint.has_alphanumeric(""))
    end)
end)

describe("codepoint.is_upper / codepoint.is_lower", function()
    it("knows the case of accented and non-Latin letters", function()
        assert.same(
            { A = "upper", ["É"] = "upper", ["Ω"] = "upper", ["Ж"] = "upper" },
            _map({ "A", "É", "Ω", "Ж" }, _case)
        )
        assert.same(
            { a = "lower", ["é"] = "lower", ["ω"] = "lower", ["ж"] = "lower" },
            _map({ "a", "é", "ω", "ж" }, _case)
        )
    end)

    it("treats caseless characters as neither", function()
        assert.same(
            { ["1"] = "none", _ = "none", ["日"] = "none", ["😀"] = "none", ["—"] = "none", ["\255"] = "none" },
            _map({ "1", "_", "日", "😀", "—", "\255" }, _case)
        )
    end)
end)
