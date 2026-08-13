--- Make sure `commands.motion.subword.prose.comment_marker_case` behaves the
--- same way regardless of what a grammar's comment-opener punctuation looks
--- like, or whether that punctuation is its own leaf (Lua's `--`, split from
--- `comment_content`) or embedded in one larger leaf's text alongside the
--- comment body (C/Vim/query, whose `comment` node is a single leaf with no
--- children at all). This is the fix that motivated cross-grammar testing
--- in the first place: `M.split`'s old "no units -> fall back to the whole
--- leaf" rule silently re-added a stop that `comment_marker_case = "skip"`
--- was supposed to remove, but only for grammars/shapes where the marker
--- was its own leaf -- see `subword.lua`'s `M.split` docstring. See
--- `grammar_helpers.lua` for the shared plumbing.

local grammar = require("treemotion.grammar_helpers")
local treemotion = require("treemotion")

--- See `grammar_helpers.lua`'s `M.wrap` docstring for why this thin
--- `it(...)` call has to live here instead of in the shared module.
---
---@param fixture {filetype: string, lines: string[]}
---@param description string
---@param body fun(buffer: integer)
local function _it_per_grammar(fixture, description, body)
    it(string.format("[%s] %s", fixture.filetype, description), grammar.wrap(fixture, body))
end

---@type {filetype: string, marker: string, lines: string[]}[]
local _FIXTURES = {
    { filetype = "lua", marker = "--", lines = { "-- foo", "-- bar" } },
    { filetype = "c", marker = "//", lines = { "// foo", "// bar" } },
    { filetype = "vim", marker = '"', lines = { '" foo', '" bar' } },
    { filetype = "query", marker = ";", lines = { "; foo", "; bar" } },
}

describe("motion API - comment_marker_case, across grammars", function()
    after_each(function()
        treemotion.setup({
            commands = { motion = { subword = { prose = { comment_marker_case = "stop" } } } },
        })
    end)

    for _, fixture in ipairs(_FIXTURES) do
        -- `foo`'s column, on either line: right after the marker and the
        -- space following it. Varies by marker width (1 char for vim's `"`
        -- and query's `;`, 2 for lua's `--` and c's `//`), unlike the
        -- marker's own start (always 0) and the next line's marker (always
        -- row+1, column 0).
        local foo_column = #fixture.marker + 1

        _it_per_grammar(
            fixture,
            string.format('lands on `%s` as its own stop by default ("stop")', fixture.marker),
            function()
                grammar.set_cursor(0, 0)

                local expected = { { 0, foo_column }, { 1, 0 }, { 1, foo_column } }
                for _, position in ipairs(expected) do
                    treemotion.run_motion_w()
                    assert.same(position, { grammar.get_cursor() })
                end
            end
        )

        _it_per_grammar(
            fixture,
            string.format('jumps straight past `%s` on every line when "skip"', fixture.marker),
            function()
                treemotion.setup({
                    commands = { motion = { subword = { prose = { comment_marker_case = "skip" } } } },
                })

                -- From `foo`, straight to `bar` on the next line -- never
                -- stopping on line 2's marker, matching the regression this
                -- whole file exists to generalize (see the module docstring).
                grammar.set_cursor(0, foo_column)
                treemotion.run_motion_w()
                assert.same({ 1, foo_column }, { grammar.get_cursor() })

                treemotion.run_motion_b()
                assert.same({ 0, foo_column }, { grammar.get_cursor() })
            end
        )
    end
end)
