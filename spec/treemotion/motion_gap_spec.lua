--- Make sure the three "not an ordinary leaf" node shapes `leaf.lua` has to
--- special-case -- a blank-line gap, a leaf that genuinely spans multiple
--- rows, and a leaf with a partial-coverage child -- are handled the same
--- way regardless of grammar. Each gets at least a second, structurally
--- different grammar beyond the Lua case that originally motivated the fix,
--- to prove the fix generalizes rather than just happening to work for the
--- one shape it was written against. See `grammar_helpers.lua` for the
--- shared plumbing.

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
    -- A blank line has no treesitter node of its own, so `get_node()` there
    -- lands on the smallest node that still covers it (the whole buffer, if
    -- there's nothing more specific) -- which has no useful next/previous
    -- sibling. Every motion below exercises the fallback that climbs to a
    -- real leaf instead of getting stuck.

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
    -- A leaf that itself spans more than one row (not just a gap between
    -- rows) must land as one single stop, not split at the row boundary.

    _it_per_grammar(
        { filetype = "lua", lines = { "local x = [[foo", "bar]]" } },
        "#w/#b treat a multi-row long string as a single stop",
        function()
            -- `local`(0,0) `x`(0,6) `=`(0,8) `[[`(0,10)
            -- `string_content`(0,12 - 1,3, text `foo\nbar`) `]]`(1,3).
            grammar.set_cursor(0, 10) -- start of `[[`
            treemotion.run_motion_w()
            assert.same({ 0, 12 }, { grammar.get_cursor() }) -- `string_content`'s start
            treemotion.run_motion_w()
            assert.same({ 1, 3 }, { grammar.get_cursor() }) -- straight to `]]`

            grammar.set_cursor(1, 3) -- start of `]]`
            treemotion.run_motion_b()
            assert.same({ 0, 12 }, { grammar.get_cursor() })
        end
    )

    _it_per_grammar(
        { filetype = "c", lines = { "int x = 1; /* foo", "bar */ int y = 2;" } },
        "#w/#b treat a multi-row block comment as a single stop",
        function()
            -- `;`(0,9) then one `comment` leaf spanning (0,11) - (1,6), then `int`(1,7).
            grammar.set_cursor(0, 9) -- start of `;`
            treemotion.run_motion_w()
            assert.same({ 0, 11 }, { grammar.get_cursor() }) -- comment's start, not split at the row break
            treemotion.run_motion_w()
            assert.same({ 1, 7 }, { grammar.get_cursor() }) -- straight to `int`, skipping the comment's body

            grammar.set_cursor(1, 7) -- start of `int`
            treemotion.run_motion_b()
            assert.same({ 0, 11 }, { grammar.get_cursor() }) -- back to the comment's start
        end
    )
end)

describe("motion API - leaves with a partial-coverage child, across grammars", function()
    -- A node can have children that don't cover its whole span, leaving
    -- real (non-blank) text with no node of its own -- `_has_uncovered_text`
    -- must settle such a node as one whole leaf rather than treating that
    -- uncovered text as an invisible gap. See `leaf.lua`'s docstring.

    _it_per_grammar(
        { filetype = "lua", lines = { [[local x = "foo\nbar"]] } },
        "#w/#e/#b treat string_content as one whole leaf around its embedded escape_sequence",
        function()
            -- `"foo\nbar"` (a literal backslash-n) parses as `string_content`
            -- (11-19) with exactly one child, `escape_sequence` (14-16, the
            -- `\n`) -- `"foo"` (11-14) and `"bar"` (16-19) have no node of
            -- their own at all.
            grammar.set_cursor(0, 11) -- start of `foo`, uncovered by `escape_sequence`
            treemotion.run_motion_w()
            assert.same({ 0, 19 }, { grammar.get_cursor() }) -- straight to the closing `"`

            grammar.set_cursor(0, 11)
            treemotion.run_motion_e()
            assert.same({ 0, 18 }, { grammar.get_cursor() }) -- `string_content`'s own last character

            grammar.set_cursor(0, 18) -- last character of `bar`
            treemotion.run_motion_b()
            assert.same({ 0, 11 }, { grammar.get_cursor() }) -- back to `foo`'s start
        end
    )

    _it_per_grammar(
        { filetype = "markdown", lines = { "some *text* here" } },
        "#w/#e/#b treat inline markup text as real content around its `*` marker children",
        function()
            -- `some *text* here` parses as one `inline` node (0-16) whose
            -- only two children are the anonymous `*` markers (5-6 and
            -- 10-11) -- "some "(0-5), "text"(6-10) and " here"(11-16) have
            -- no node of their own, the same partial-coverage shape as the
            -- Lua case above, just arising from markdown's emphasis syntax
            -- instead of an escape sequence. `(inline) @spell` makes this
            -- leaf prose, so `subword` further splits it on whitespace and
            -- bare punctuation (each `*` is its own bare, non-alnum run, so
            -- `comment_marker_case`'s default "stop" makes it a landing
            -- stop too -- see `_split_delimiters`).
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
