--- A wrapped Markdown paragraph is one `inline` node spanning several rows.
--- `w`/`e`/`b`/`ge` must step through its words instead of jumping over it.

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
    -- Every word boundary on all three lines, `-` included. `Second` (4, 0)
    -- comes only last.
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
