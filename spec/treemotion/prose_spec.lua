--- Direct unit tests for `_commands.motion.prose`'s word splitting --
--- `M.split_words`, `M.words` -- isolated from the motion machinery that
--- consumes them. See `treemotion_spec.lua` for the end-to-end prose and
--- backtick-identifier motion tests.

local prose = require("treemotion._commands.motion.prose")

--- Where Neovim's own `w` starts each word of `text`, as 1-indexed byte offsets.
---
--- Runs `normal! w` in a plain buffer (no parser, default `'iskeyword'`),
--- so this is the reference `prose.split_words` should agree with. A
--- sentinel word after `text` gives the last real word a word to move to.
---
---@param text string Text without `-`, `:` or `/`, which the plugin deliberately keeps inside words.
---@return integer[]
local function _neovim_word_starts(text)
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buffer)
    vim.bo[buffer].iskeyword = "@,48-57,_,192-255"
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { text .. " sentinel" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local starts = {}

    if not text:sub(1, 1):match("%s") and vim.fn.charclass(vim.fn.strcharpart(text, 0, 1)) ~= 0 then
        table.insert(starts, 1)
    end

    while true do
        vim.cmd("normal! w")

        local column = vim.api.nvim_win_get_cursor(0)[2]

        if column >= #text then
            break
        end

        table.insert(starts, column + 1)
    end

    vim.api.nvim_buf_delete(buffer, { force = true })

    return starts
end

---@param text string
---@return integer[] # Where each of `prose.split_words`'s words starts.
local function _word_starts(text)
    return vim.tbl_map(function(word)
        return word.offset
    end, prose.split_words(text))
end

describe("prose.split_words", function()
    it("splits on blanks and drops them", function()
        assert.same(
            { { text = "hello", offset = 1 }, { text = "world", offset = 8 } },
            prose.split_words("hello  world")
        )
    end)

    it("groups a run of punctuation into one word", function()
        assert.same({ { text = "wait", offset = 1 }, { text = "?!", offset = 5 } }, prose.split_words("wait?!"))
    end)

    it("keeps -, :, / and _ inside a word for the delimiter pass to decide", function()
        assert.same({ { text = "github:NixOS/nix-pkgs_x", offset = 1 } }, prose.split_words("github:NixOS/nix-pkgs_x"))
    end)

    it("returns nothing for all-blank text", function()
        assert.same({}, prose.split_words("   "))
    end)

    it("keeps an accented word whole", function()
        assert.same(
            { { text = "café", offset = 1 }, { text = "au", offset = 7 }, { text = "lait", offset = 10 } },
            prose.split_words("café au lait")
        )
    end)

    it("keeps a combining accent with its letter", function()
        assert.same({ { text = "cafe\204\129", offset = 1 } }, prose.split_words("cafe\204\129"))
    end)

    it("puts non-ASCII punctuation in the same class as ASCII punctuation", function()
        assert.same({ { text = "foo", offset = 1 }, { text = "?—!", offset = 4 } }, prose.split_words("foo?—!"))
    end)

    it("treats non-ASCII blanks as blanks", function()
        assert.same(
            { { text = "a", offset = 1 }, { text = "b", offset = 4 }, { text = "c", offset = 8 } },
            prose.split_words("a\194\160b\227\128\128c") -- no-break space, ideographic space
        )
    end)

    it("ends a word where the Unicode class changes", function()
        assert.same({
            { text = "abc", offset = 1 },
            { text = "日本", offset = 4 },
            { text = "テキスト", offset = 10 },
            { text = "😀😀", offset = 22 },
        }, prose.split_words("abc日本テキスト😀😀"))
    end)

    describe("matches Neovim's own w", function()
        for _, text in ipairs({
            "café au lait",
            "naïve…end",
            "cafe\204\129 au lait",
            "foo—bar — baz",
            "«quote» and „this“",
            "a\194\160b a\226\128\131b a\227\128\128b",
            "日本語テキスト한국어",
            "abc日本def",
            "hi😀😀there 🇳🇱 flag",
            "family 👨\226\128\141👩\226\128\141👧 emoji",
            "x₂y and x²",
            "Ωmega фу бар ٣٤ عربى",
            "?—! ... ¿qué? ¡sí!",
            "straße ÆØÅ æøå ÿ",
            "× ÷ ± §",
            "bad\255byte \192 lone",
            "tab\tseparated\tvalues",
            "",
            "   ",
        }) do
            it(string.format("for %q", text), function()
                assert.same(_neovim_word_starts(text), _word_starts(text))
            end)
        end
    end)
end)

describe("prose.words", function()
    it("flags a single-word backtick span as an identifier and drops the backticks", function()
        assert.same({
            { text = "see", offset = 1 },
            { text = "fooBar", offset = 6, is_identifier = true },
            { text = "here", offset = 14 },
        }, prose.words("see `fooBar` here", true, 16))
    end)

    it("leaves a multi-word backtick span as ordinary prose", function()
        assert.same({
            { text = "`", offset = 1 },
            { text = "foo", offset = 2 },
            { text = "bar", offset = 6 },
            { text = "`", offset = 9 },
        }, prose.words("`foo bar`", true, 16))
    end)

    it("treats backticks as ordinary punctuation when backtick_identifiers is off", function()
        assert.same({
            { text = "`", offset = 1 },
            { text = "fooBar", offset = 2 },
            { text = "`", offset = 8 },
        }, prose.words("`fooBar`", false, 16))
    end)

    it("merges base64 padding back into the hash before it", function()
        assert.same(
            { { text = "see", offset = 1 }, { text = "A8YgPkQ3xZ7rT2mN9sLwVbE1=", offset = 5 } },
            prose.words("see A8YgPkQ3xZ7rT2mN9sLwVbE1=", true, 16)
        )
    end)

    it("keeps a trailing = separate when the word before it isn't hash-shaped", function()
        assert.same({ { text = "x", offset = 1 }, { text = "=", offset = 2 } }, prose.words("x=", true, 16))
    end)
end)
