--- The motions walk into and out of language injections leaf by leaf.
---
--- Uses `vim.cmd([[...]])`, which Neovim's bundled Lua queries inject as
--- Vimscript, so no extra grammars are needed.

local grammar = require("treemotion.grammar_helpers")
local treemotion = require("treemotion")

--- See `grammar_helpers.lua`'s `M.wrap` docstring for why this thin
--- `it(...)` call has to live here instead of in the shared module.
---
---@param description string
---@param body fun(buffer: integer)
local function _it(description, body)
    it(description, grammar.wrap(pending, { filetype = "lua", lines = { "vim.cmd([[set number]])" } }, body))
end

describe("motion API - crossing language injections", function()
    -- Leaves: `vim`(0-3) `.`(3-4) `cmd`(4-7) `(`(7-8) `[[`(8-10), then
    -- Vimscript `set`(10-13) `number`(14-20), then `]]`(20-22) `)`(22-23).
    -- Both injection boundaries touch with no gap.

    _it("#w steps leaf-by-leaf through the injected Vimscript, then resumes in the host", function()
        grammar.set_cursor(0, 0)

        for _, column in ipairs({ 3, 4, 7, 8, 10, 14, 20, 22 }) do
            treemotion.run_motion_w()
            local _, actual = grammar.get_cursor()
            assert.same(column, actual)
        end
    end)

    _it("#b mirrors #w backward, re-entering the injection from the host side", function()
        grammar.set_cursor(0, 23)

        for _, column in ipairs({ 20, 14, 10, 8, 7, 4, 3, 0 }) do
            treemotion.run_motion_b()
            local _, actual = grammar.get_cursor()
            assert.same(column, actual)
        end
    end)

    _it("#e/#ge mirror #w/#b, landing on each leaf's end instead of its start", function()
        grammar.set_cursor(0, 0)

        for _, column in ipairs({ 2, 3, 6, 7, 9, 12, 19, 21 }) do
            treemotion.run_motion_e()
            local _, actual = grammar.get_cursor()
            assert.same(column, actual)
        end

        grammar.set_cursor(0, 23)

        for _, column in ipairs({ 21, 19, 12, 9, 7, 6, 3, 2 }) do
            treemotion.run_motion_ge()
            local _, actual = grammar.get_cursor()
            assert.same(column, actual)
        end
    end)

    _it("#W/#B treat the injection boundary as contiguous, not a run break", function()
        -- `vim.cmd([[set` is one run: only whitespace breaks a run.
        grammar.set_cursor(0, 0)
        treemotion.run_motion_W()

        local _, after_w = grammar.get_cursor()
        assert.same(14, after_w)

        grammar.set_cursor(0, 23)
        treemotion.run_motion_B()

        local _, after_b = grammar.get_cursor()
        assert.same(14, after_b)
    end)
end)

describe("motion API - crossing an injection nested inside another injection", function()
    -- The same line inside a ```lua``` Markdown fence: three stacked trees
    -- (markdown, lua, vim). Columns match the flat case; this checks that
    -- `set`/`number` are reached rather than Lua's `string_content`.
    local function _nested_it(description, body)
        it(
            description,
            grammar.wrap(pending, {
                filetype = "markdown",
                lines = { "```lua", "vim.cmd([[set number]])", "```" },
            }, body)
        )
    end

    _nested_it("#w reaches into the doubly-injected Vimscript, not just the singly-injected Lua", function()
        grammar.set_cursor(1, 0)

        for _, column in ipairs({ 3, 4, 7, 8, 10, 14, 20, 22 }) do
            treemotion.run_motion_w()
            local _, actual = grammar.get_cursor()
            assert.same(column, actual)
        end
    end)

    _nested_it("#b mirrors #w backward, back out through both injection boundaries", function()
        grammar.set_cursor(1, 23)

        for _, column in ipairs({ 20, 14, 10, 8, 7, 4, 3, 0 }) do
            treemotion.run_motion_b()
            local _, actual = grammar.get_cursor()
            assert.same(column, actual)
        end
    end)

    _nested_it("#e/#ge mirror #w/#b, landing on each leaf's end instead of its start", function()
        grammar.set_cursor(1, 0)

        for _, column in ipairs({ 2, 3, 6, 7, 9, 12, 19, 21 }) do
            treemotion.run_motion_e()
            local _, actual = grammar.get_cursor()
            assert.same(column, actual)
        end

        grammar.set_cursor(1, 23)

        for _, column in ipairs({ 21, 19, 12, 9, 7, 6, 3, 2 }) do
            treemotion.run_motion_ge()
            local _, actual = grammar.get_cursor()
            assert.same(column, actual)
        end
    end)

    -- `LanguageTree:parse()` skips an injected region given a zero-width
    -- range at its exact start. A cursor on an injection's first character
    -- must still resolve to the injected leaf.
    _nested_it("#w resolves the injected leaf when the cursor starts exactly at its region's first column", function()
        grammar.set_cursor(1, 0)
        treemotion.run_motion_w()

        local row, column = grammar.get_cursor()
        assert.same({ 1, 3 }, { row, column })
    end)
end)

describe("motion API - a fenced code block's content reported as several regions", function()
    -- tree-sitter-markdown reports a two-line fence as two one-line regions
    -- while the host node spans both. The regions must be merged for the
    -- fence to be entered at all.
    local function _multiline_it(description, body)
        it(
            description,
            grammar.wrap(pending, {
                filetype = "markdown",
                lines = { "```lua", "local x = 1", "local y = 2", "```" },
            }, body)
        )
    end

    _multiline_it(
        "#w steps across the fence's two-line region boundary instead of jumping to the closing delimiter",
        function()
            grammar.set_cursor(1, 0)

            for _, position in ipairs({
                { 1, 6 },
                { 1, 8 },
                { 1, 10 },
                { 2, 0 },
                { 2, 6 },
                { 2, 8 },
                { 2, 10 },
                { 3, 0 },
            }) do
                treemotion.run_motion_w()
                local row, column = grammar.get_cursor()
                assert.same(position, { row, column })
            end
        end
    )
end)
