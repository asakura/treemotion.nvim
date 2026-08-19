--- Regression test for `w`/`e`/`b`/`ge` swallowing an entire wrapped
--- markdown paragraph in one motion, instead of stepping word by word.
---
--- Neovim's bundled `markdown_inline` grammar doesn't tokenize plain prose
--- into per-word nodes: a paragraph parses as one `inline` node whose only
--- children are markup delimiters (`*`, `` ` ``, ...) -- the prose text
--- itself has no node of its own, which is exactly the "leaf with
--- uncovered text" shape `_has_uncovered_text` exists to handle (see
--- `motion_gap_spec.lua`'s "leaves with a partial-coverage child" tests,
--- which cover this correctly for a *single-line* paragraph: `is_prose`
--- (via `@spell`) makes `subword.split()` divide that leaf's text
--- word-by-word).
---
--- That word-splitting used to never run at all once the paragraph wrapped
--- across more than one line, though: `subword.lua`'s `_split()` checked
--- `start_row ~= end_row` before ever consulting `is_prose`, and -- since
--- `_single_row_span` can't collapse a leaf whose extra rows hold real
--- content, not just trailing blanks -- fell back to treating the *entire*
--- multi-row node as a single unit. That fallback is still correct for a
--- genuinely atomic multi-row leaf (a Lua long string, a C block comment --
--- see `motion_gap_spec.lua`'s "genuinely multi-row leaves" tests), but a
--- hard/soft-wrapped markdown paragraph was exactly the case where it
--- wasn't: wrapping prose across lines is the normal, common shape for real
--- markdown, not an edge case.
---
--- Fixed by making `_split`/`_split_run_segment` fall through to
--- `_split_text` for genuinely multi-row *prose* instead of taking the
--- single-unit fallback, and making `_split_text` itself row/column-aware
--- (`_multirow_positions`/`_make_unit`) so a unit's start/end can land past
--- a line break instead of assuming flat `start_col + offset` arithmetic.
--- This fixture is confirmed directly against Neovim's own bundled
--- `markdown`/`markdown_inline` grammars (reproduced on unmodified `main`
--- via this exact buffer: a single `#w` from `(0, 0)` used to land straight
--- on `(4, 0)`, the next paragraph, skipping every word in between).

local grammar = require("treemotion.grammar_helpers")
local treemotion = require("treemotion")

local function _it(description, body)
    it(
        description,
        grammar.wrap(pending, {
            filetype = "markdown",
            lines = {
                "This is a plain paragraph that wraps across",
                "several lines in the markdown source file",
                "because prose is usually hard-wrapped like this.",
                "",
                "Second paragraph here.",
            },
        }, body)
    )
end

describe("motion API - markdown paragraph wrapped across multiple lines", function()
    -- Every word boundary across all three lines, in document order --
    -- `-` (from `hard-wrapped`) is its own landing stop too, the same as
    -- `motion_gap_spec.lua`'s `*text*` case: a bare punctuation run gets
    -- `comment_marker_case`'s default `"stop"` treatment. Reaching `(4, 0)`
    -- (`Second`) only as the *last* step, after every real word, is what
    -- proves the paragraph is no longer swallowed whole.
    local positions = {
        { 0, 5 }, -- is
        { 0, 8 }, -- a
        { 0, 10 }, -- plain
        { 0, 16 }, -- paragraph
        { 0, 26 }, -- that
        { 0, 31 }, -- wraps
        { 0, 37 }, -- across
        { 1, 0 }, -- several -- crosses the first line wrap
        { 1, 8 }, -- lines
        { 1, 14 }, -- in
        { 1, 17 }, -- the
        { 1, 21 }, -- markdown
        { 1, 30 }, -- source
        { 1, 37 }, -- file
        { 2, 0 }, -- because -- crosses the second line wrap
        { 2, 8 }, -- prose
        { 2, 14 }, -- is
        { 2, 17 }, -- usually
        { 2, 25 }, -- hard
        { 2, 29 }, -- -
        { 2, 30 }, -- wrapped
        { 2, 38 }, -- like
        { 2, 43 }, -- this
        { 2, 47 }, -- .
        { 4, 0 }, -- Second -- next paragraph, only after every word above
    }

    _it(
        "#w steps word-by-word across every line, reaching the next paragraph only once the whole thing is consumed",
        function()
            grammar.set_cursor(0, 0) -- start of `This`

            for _, position in ipairs(positions) do
                treemotion.run_motion_w()
                assert.same(position, { grammar.get_cursor() })
            end
        end
    )

    _it("#b mirrors #w backward, re-entering the wrapped paragraph from its last word", function()
        grammar.set_cursor(4, 0) -- start of `Second`

        for index = #positions - 1, 1, -1 do
            treemotion.run_motion_b()
            assert.same(positions[index], { grammar.get_cursor() })
        end

        treemotion.run_motion_b()
        assert.same({ 0, 0 }, { grammar.get_cursor() }) -- `This`
    end)

    _it("#e/#ge land on each word's end across a line wrap too, not just its start", function()
        grammar.set_cursor(0, 31) -- start of `wraps`

        local e_expected = {
            { 0, 35 }, -- end of `wraps`
            { 0, 42 }, -- end of `across`
            { 1, 6 }, -- end of `several` -- crosses the line wrap
            { 1, 12 }, -- end of `lines`
        }

        for _, position in ipairs(e_expected) do
            treemotion.run_motion_e()
            assert.same(position, { grammar.get_cursor() })
        end

        grammar.set_cursor(1, 8) -- start of `lines`

        local ge_expected = {
            { 1, 6 }, -- end of `several`
            { 0, 42 }, -- end of `across` -- crosses the line wrap backward
            { 0, 35 }, -- end of `wraps`
        }

        for _, position in ipairs(ge_expected) do
            treemotion.run_motion_ge()
            assert.same(position, { grammar.get_cursor() })
        end
    end)
end)
