--- Blank-line gaps, multi-row leaves and partially covered nodes behave the
--- same across grammars.

local grammar = require("treemotion.grammar_helpers")
local treemotion = require("treemotion")

--- See `grammar_helpers.lua`'s `M.wrap` docstring for why this thin
--- `it(...)` call has to live here instead of in the shared module.
---
---@param fixture {filetype: string, lines: string[], comment_node: string?}
---@param description string
---@param body fun(buffer: integer)
local function _it_per_grammar(fixture, description, body)
    it(string.format("[%s] %s", fixture.filetype, description), grammar.wrap(pending, fixture, body))
end

describe("motion API - blank line gaps, across grammars", function()
    -- A blank line has no node, so the motion must climb to a real leaf.

    _it_per_grammar(
        { filetype = "lua", lines = { "local a = 1", "", "local b = 2" } },
        "#w/#W/#e/#b/#ge all cross a blank line to the nearest real leaf",
        function()
            -- Leaf columns, both lines: `local`=0, `a`/`b`=6, `=`=8, `1`/`2`=10.
            grammar.set_cursor(1, 0)
            treemotion.run_motion_w()
            assert.same({ 2, 0 }, { grammar.get_cursor() }) -- `local`, not `a`

            grammar.set_cursor(1, 0)
            treemotion.run_motion_W()
            assert.same({ 2, 0 }, { grammar.get_cursor() })

            grammar.set_cursor(1, 0)
            treemotion.run_motion_e()
            assert.same({ 2, 4 }, { grammar.get_cursor() }) -- end of `local`

            grammar.set_cursor(1, 0)
            treemotion.run_motion_b()
            assert.same({ 0, 10 }, { grammar.get_cursor() }) -- start of `1`

            grammar.set_cursor(1, 0)
            treemotion.run_motion_ge()
            assert.same({ 0, 10 }, { grammar.get_cursor() }) -- end of `1`, not `=`
        end
    )

    _it_per_grammar(
        { filetype = "c", lines = { "int x = 1;", "", "int y = 2;" } },
        "#w/#W/#e/#b/#ge all cross a blank line to the nearest real leaf",
        function()
            -- Leaf columns, both lines: `int`=0, `x`/`y`=4, `=`=6, `1`/`2`=8, `;`=9.
            grammar.set_cursor(1, 0)
            treemotion.run_motion_w()
            assert.same({ 2, 0 }, { grammar.get_cursor() })

            grammar.set_cursor(1, 0)
            treemotion.run_motion_W()
            assert.same({ 2, 0 }, { grammar.get_cursor() })

            grammar.set_cursor(1, 0)
            treemotion.run_motion_e()
            assert.same({ 2, 2 }, { grammar.get_cursor() }) -- end of `int`

            grammar.set_cursor(1, 0)
            treemotion.run_motion_b()
            assert.same({ 0, 9 }, { grammar.get_cursor() }) -- start of `;`

            grammar.set_cursor(1, 0)
            treemotion.run_motion_ge()
            assert.same({ 0, 9 }, { grammar.get_cursor() }) -- end of `;`
        end
    )

    _it_per_grammar(
        { filetype = "vim", lines = { "let a = 1", "", "let b = 2" } },
        "#w and #b cross a blank line to the nearest real leaf",
        function()
            grammar.set_cursor(1, 0)
            treemotion.run_motion_w()
            assert.same({ 2, 0 }, { grammar.get_cursor() })

            grammar.set_cursor(1, 0)
            treemotion.run_motion_b()
            assert.same({ 0, 8 }, { grammar.get_cursor() }) -- start of `1`
        end
    )

    _it_per_grammar(
        { filetype = "query", lines = { "(foo)", "", "(bar)" } },
        "#w and #b cross a blank line to the nearest real leaf",
        function()
            grammar.set_cursor(1, 0)
            treemotion.run_motion_w()
            assert.same({ 2, 0 }, { grammar.get_cursor() })

            grammar.set_cursor(1, 0)
            treemotion.run_motion_b()
            assert.same({ 0, 4 }, { grammar.get_cursor() }) -- start of `)`
        end
    )

    _it_per_grammar(
        { filetype = "vimdoc", lines = { "foo bar", "", "baz qux" } },
        "#w and #b cross a blank line to the nearest real leaf",
        function()
            grammar.set_cursor(1, 0)
            treemotion.run_motion_w()
            assert.same({ 2, 0 }, { grammar.get_cursor() }) -- `baz`

            grammar.set_cursor(1, 0)
            treemotion.run_motion_b()
            assert.same({ 0, 4 }, { grammar.get_cursor() }) -- start of `bar`
        end
    )
end)

describe("motion API - genuinely multi-row leaves, across grammars", function()
    -- A multi-row prose leaf is one leaf but is still split word by word
    -- across its rows.

    _it_per_grammar(
        { filetype = "lua", lines = { "local x = [[foo", "bar]]" } },
        "#w/#b split a multi-row long string word-by-word, the same as a single-row one would",
        function()
            -- `local`(0,0) `x`(0,6) `=`(0,8) `[[`(0,10)
            -- `string_content`(0,12 - 1,3, text `foo\nbar`, `@string`-tagged) `]]`(1,3).
            grammar.set_cursor(0, 10) -- start of `[[`

            local w_expected = { { 0, 12 }, { 1, 0 }, { 1, 3 } } -- `foo`, `bar`, `]]`
            for _, position in ipairs(w_expected) do
                treemotion.run_motion_w()
                assert.same(position, { grammar.get_cursor() })
            end

            grammar.set_cursor(1, 3) -- start of `]]`

            local b_expected = { { 1, 0 }, { 0, 12 }, { 0, 10 } } -- `bar`, `foo`, `[[`
            for _, position in ipairs(b_expected) do
                treemotion.run_motion_b()
                assert.same(position, { grammar.get_cursor() })
            end
        end
    )

    _it_per_grammar(
        { filetype = "c", lines = { "int x = 1; /* foo", "bar */ int y = 2;" } },
        "#w/#b split a multi-row block comment word-by-word, the same as a single-row one would",
        function()
            -- `;`(0,9), a `comment` (0,11)-(1,6), then `int`(1,7). `/` and `*`
            -- are separate punctuation stops.
            grammar.set_cursor(0, 9) -- start of `;`

            local w_expected = { { 0, 11 }, { 0, 12 }, { 0, 14 }, { 1, 0 }, { 1, 4 }, { 1, 5 }, { 1, 7 } }
            -- `/`, `*`, `foo`, `bar`, `*`, `/`, `int`
            for _, position in ipairs(w_expected) do
                treemotion.run_motion_w()
                assert.same(position, { grammar.get_cursor() })
            end

            grammar.set_cursor(1, 7) -- start of `int`

            local b_expected = { { 1, 5 }, { 1, 4 }, { 1, 0 }, { 0, 14 }, { 0, 12 }, { 0, 11 } }
            -- `/`, `*`, `bar`, `foo`, `*`, `/`
            for _, position in ipairs(b_expected) do
                treemotion.run_motion_b()
                assert.same(position, { grammar.get_cursor() })
            end
        end
    )
end)

describe("motion API - leaves with a partial-coverage child, across grammars", function()
    -- Text no child covers must stay reachable, not become a gap.

    _it_per_grammar(
        { filetype = "lua", lines = { [[local x = "foo\nbar"]] } },
        "#w/#e/#b treat string_content as one whole leaf around its embedded escape_sequence",
        function()
            -- `string_content` (11-19) has one child, `escape_sequence`
            -- (14-16). As prose it splits into `foo`(11-14), `\`(14-15) and
            -- `nbar`(15-19), so the text on both sides is reachable.
            grammar.set_cursor(0, 11) -- start of `foo`, uncovered by `escape_sequence`

            local w_expected = { 14, 15, 19 } -- `\`, `nbar`, straight to the closing `"`
            for _, column in ipairs(w_expected) do
                treemotion.run_motion_w()
                local _, actual = grammar.get_cursor()
                assert.same(column, actual)
            end

            grammar.set_cursor(0, 11)

            local e_expected = { 13, 14, 18 } -- end of `foo`, `\`, `nbar` (`string_content`'s own last character)
            for _, column in ipairs(e_expected) do
                treemotion.run_motion_e()
                local _, actual = grammar.get_cursor()
                assert.same(column, actual)
            end

            grammar.set_cursor(0, 18) -- last character of `nbar`

            local b_expected = { 15, 14, 11 } -- start of `nbar`, `\`, `foo`
            for _, column in ipairs(b_expected) do
                treemotion.run_motion_b()
                local _, actual = grammar.get_cursor()
                assert.same(column, actual)
            end
        end
    )

    _it_per_grammar(
        { filetype = "markdown", lines = { "some *text* here" } },
        "#w/#e/#b treat inline markup text as real content around its `*` marker children",
        function()
            -- `some *text* here` is one `inline` node (0-16) whose only
            -- children are the two `*` (5-6, 10-11). Each `*` is a stop.
            grammar.set_cursor(0, 0)
            local w_expected = { 5, 6, 10, 12 } -- `some`, `*`, `text`, `*`->`here`
            for _, column in ipairs(w_expected) do
                treemotion.run_motion_w()
                local _, actual = grammar.get_cursor()
                assert.same(column, actual)
            end

            grammar.set_cursor(0, 0)
            local e_expected = { 3, 5, 9, 10 } -- end of `some`, `*`, `text`, `*`
            for _, column in ipairs(e_expected) do
                treemotion.run_motion_e()
                local _, actual = grammar.get_cursor()
                assert.same(column, actual)
            end

            grammar.set_cursor(0, 12) -- start of `here`
            local b_expected = { 10, 6, 5, 0 } -- `*`, `text`, `*`, `some`
            for _, column in ipairs(b_expected) do
                treemotion.run_motion_b()
                local _, actual = grammar.get_cursor()
                assert.same(column, actual)
            end
        end
    )
end)
