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
    -- rows) is still one single `leaf.lua`-level leaf, not split at the row
    -- boundary -- but that's no longer the same thing as one single `w`/`b`
    -- *stop*: both fixtures below are `@string`/`@spell`-tagged (see
    -- `subword.lua`'s `_is_prose_capture`), i.e. prose by this plugin's own
    -- classification, and `subword.split()` already divides a *single-row*
    -- prose leaf word-by-word -- multi-row prose used to be the one place
    -- that stopped short, collapsing into one giant unit purely because it
    -- happened to span more than one row (see
    -- `motion_markdown_paragraph_spec.lua` for the real-world case that
    -- bug came from: a hard/soft-wrapped markdown paragraph). Now it's
    -- split the same way single-row prose already was, consistently
    -- crossing the row boundary instead of stopping at it.

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
            -- `;`(0,9) then one `comment` leaf spanning (0,11) - (1,6),
            -- `@spell`-tagged, then `int`(1,7). `/`/`*` each land as their
            -- own bare punctuation stop either side of the comment's real
            -- words -- see `motion_gap_spec.lua`'s `*text*` case (and
            -- `_char_class`'s docstring) for why `/` and `*` fall into
            -- different classes and so never merge into one run together.
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
            -- their own at all. `string_content` is also `@string`-tagged
            -- (see `subword.lua`'s `_is_prose_capture`), so `subword` splits
            -- its text like prose: `foo`(11-14, word-class), `\`(14-15,
            -- its own "other"-class run), `nbar`(15-19, `n` and `bar` are
            -- both word-class with nothing between them, so they're one
            -- run) -- proving the escape sequence's uncovered text on
            -- *both* sides survives as real, reachable content, not a
            -- silent gap, regardless of where `subword` itself then splits.
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
