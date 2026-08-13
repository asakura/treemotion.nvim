--- Make sure `w`/`e`/`b`/`ge` (leaf) and `W`/`E`/`B`/`gE` (contiguous-run)
--- motions work the same way regardless of which treesitter grammar parsed
--- the buffer -- the motion logic only ever looks at generic node shape and
--- leaf text, never a language's specific node type names, so the same
--- assertions run once per fixture filetype below instead of being
--- hand-duplicated per grammar. See `grammar_helpers.lua` for the shared
--- plumbing and why a missing parser becomes a pending test rather than a
--- failure.
---
--- Every fixture is one line of punctuation-separated tokens, chosen per
--- grammar so its leaf sequence is unambiguous from a `nvim --headless`
--- treesitter dump; expected columns were captured from the plugin's own
--- output (not hand-derived), since grammars disagree in surprising ways --
--- e.g. `query`'s `(` is a single-character leaf, so `e`'s first press from
--- column 0 skips straight to the *second* leaf's end, matching real Vim's
--- "already on the last character of this word" rule.

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

---@class treemotion.spec.LeafFixture
---@field filetype string
---@field lines string[]
---@field w_start integer
---@field w integer[]
---@field b_start integer
---@field b integer[]
---@field e_start integer
---@field e integer[]
---@field ge_start integer
---@field ge integer[]

---@type treemotion.spec.LeafFixture[]
local _LEAF_FIXTURES = {
    {
        -- Leaves: foo(0-3) .(3-4) bar(4-7) ((7-8) 1(8-9) ,(9-10) 2(11-12) )(12-13)
        filetype = "lua",
        lines = { "foo.bar(1, 2)" },
        w_start = 0,
        w = { 3, 4, 7, 8, 9, 11, 12, 12 },
        b_start = 12,
        b = { 11, 9, 8, 7, 4, 3, 0, 0 },
        e_start = 0,
        e = { 2, 3, 6, 7, 8, 9, 11, 12 },
        ge_start = 12,
        ge = { 11, 9, 8, 7, 6, 3, 2, 2 },
    },
    {
        -- Leaves: foo(0-3) ((3-4) bar(4-7) ,(7-8) 1(9-10) ,(10-11) 2(12-13) )(13-14) ;(14-15)
        filetype = "c",
        lines = { "foo(bar, 1, 2);" },
        w_start = 0,
        w = { 3, 4, 7, 9, 10, 12, 13, 14, 14 },
        b_start = 14,
        b = { 13, 12, 10, 9, 7, 4, 3, 0, 0 },
        e_start = 0,
        e = { 2, 3, 6, 7, 9, 10, 12, 13, 14 },
        ge_start = 14,
        ge = { 13, 12, 10, 9, 7, 6, 3, 2, 2 },
    },
    {
        -- Leaves: call(0-4) foo(5-8) ((8-9) bar(9-12) ,(12-13) 1(14-15) ,(15-16) 2(17-18) )(18-19)
        filetype = "vim",
        lines = { "call foo(bar, 1, 2)" },
        w_start = 0,
        w = { 5, 8, 9, 12, 14, 15, 17, 18, 18 },
        b_start = 18,
        b = { 17, 15, 14, 12, 9, 8, 5, 0, 0 },
        e_start = 0,
        e = { 3, 7, 8, 11, 12, 14, 15, 17, 18 },
        ge_start = 18,
        ge = { 17, 15, 14, 12, 11, 8, 7, 3, 3 },
    },
    {
        -- Leaves: ((0-1) foo(1-4) ((5-6) bar(6-9) )(9-10) @(11-12) baz(12-15) )(15-16)
        -- `(` is a single-character leaf, unlike the other 3 fixtures' first
        -- leaf -- see the module docstring's note on `e`'s first-press quirk.
        filetype = "query",
        lines = { "(foo (bar) @baz)" },
        w_start = 0,
        w = { 1, 5, 6, 9, 11, 12, 15, 15 },
        b_start = 15,
        b = { 12, 11, 9, 6, 5, 1, 0, 0 },
        e_start = 0,
        e = { 3, 5, 8, 9, 11, 14, 15, 15 },
        ge_start = 15,
        ge = { 14, 11, 9, 8, 5, 3, 0, 0 },
    },
    {
        -- Unlike the other fixtures, `vimdoc`'s own grammar barely tokenizes
        -- at all: it has only 3 whitespace-delimited `word` leaves here
        -- (`foo-bar_baz`(0-11), `qux`(12-15), `quux`(16-20)). Every extra
        -- stop below comes entirely from `subword.lua` splitting `-`/`_`
        -- *inside* that first leaf's text -- proving the motions work even
        -- when a grammar's own leaf granularity is this coarse.
        filetype = "vimdoc",
        lines = { "foo-bar_baz qux quux" },
        w_start = 0,
        w = { 4, 8, 12, 16, 16, 16, 16, 16 },
        b_start = 20,
        b = { 16, 12, 8, 4, 0, 0, 0, 0 },
        e_start = 0,
        e = { 2, 6, 10, 14, 19, 19, 19, 19 },
        ge_start = 20,
        ge = { 14, 10, 6, 2, 2, 2, 2, 2 },
    },
}

---@class treemotion.spec.WordFixture
---@field filetype string
---@field lines string[]
---@field W_start integer
---@field W integer[]
---@field B_start integer
---@field B integer[]
---@field E_start integer
---@field E integer[]
---@field gE_start integer
---@field gE integer[]

---@type treemotion.spec.WordFixture[]
local _WORD_FIXTURES = {
    {
        -- Runs: `foo.bar(1,`(0-10) `2)`(11-13)
        filetype = "lua",
        lines = { "foo.bar(1, 2)" },
        W_start = 0,
        W = { 11, 11 },
        B_start = 12,
        B = { 11, 0 },
        E_start = 0,
        E = { 9, 12 },
        gE_start = 12,
        gE = { 9, 9 },
    },
    {
        -- Runs: `foo(bar,`(0-8) `1,`(9-11) `2);`(12-15)
        filetype = "c",
        lines = { "foo(bar, 1, 2);" },
        W_start = 0,
        W = { 9, 12, 12 },
        B_start = 14,
        B = { 12, 9, 0 },
        E_start = 0,
        E = { 7, 10, 14 },
        gE_start = 14,
        gE = { 10, 7, 7 },
    },
    {
        -- Runs: `call`(0-4) `foo(bar,`(5-13) `1,`(14-16) `2)`(17-19)
        filetype = "vim",
        lines = { "call foo(bar, 1, 2)" },
        W_start = 0,
        W = { 5, 14, 17 },
        B_start = 18,
        B = { 17, 14, 5 },
        E_start = 0,
        E = { 3, 12, 15 },
        gE_start = 18,
        gE = { 15, 12, 3 },
    },
    {
        -- Runs: `(foo`(0-4) `(bar)`(5-10) `@baz)`(11-16)
        filetype = "query",
        lines = { "(foo (bar) @baz)" },
        W_start = 0,
        W = { 5, 11, 11 },
        B_start = 15,
        B = { 11, 5, 0 },
        E_start = 0,
        E = { 3, 9, 15 },
        gE_start = 15,
        gE = { 9, 3, 3 },
    },
    {
        -- Runs: `foo-bar_baz`(0-11) `qux`(12-15) `quux`(16-20) -- here `W`/`E`/`B`/`gE`
        -- match the grammar's own `word` leaves exactly, since they never look inside
        -- a leaf's text the way `w`/`e`/`b`/`ge`'s subword splitting does.
        filetype = "vimdoc",
        lines = { "foo-bar_baz qux quux" },
        W_start = 0,
        W = { 12, 16, 16, 16 },
        B_start = 20,
        B = { 16, 12, 0, 0 },
        E_start = 0,
        E = { 10, 14, 19, 19 },
        gE_start = 20,
        gE = { 14, 10, 10, 10 },
    },
}

describe("motion API - word (leaf) motions, across grammars", function()
    for _, fixture in ipairs(_LEAF_FIXTURES) do
        _it_per_grammar(fixture, "#w moves to the start of each next leaf", function()
            grammar.set_cursor(0, fixture.w_start)

            for _, column in ipairs(fixture.w) do
                treemotion.run_motion_w()
                local _, actual = grammar.get_cursor()
                assert.same(column, actual)
            end
        end)

        _it_per_grammar(fixture, "#b moves to the start of each previous leaf", function()
            grammar.set_cursor(0, fixture.b_start)

            for _, column in ipairs(fixture.b) do
                treemotion.run_motion_b()
                local _, actual = grammar.get_cursor()
                assert.same(column, actual)
            end
        end)

        _it_per_grammar(fixture, "#e moves to the end of the current, then each next, leaf", function()
            grammar.set_cursor(0, fixture.e_start)

            for _, column in ipairs(fixture.e) do
                treemotion.run_motion_e()
                local _, actual = grammar.get_cursor()
                assert.same(column, actual)
            end
        end)

        _it_per_grammar(fixture, "#ge moves to the end of each previous leaf", function()
            grammar.set_cursor(0, fixture.ge_start)

            for _, column in ipairs(fixture.ge) do
                treemotion.run_motion_ge()
                local _, actual = grammar.get_cursor()
                assert.same(column, actual)
            end
        end)
    end
end)

describe("motion API - WORD (contiguous run) motions, across grammars", function()
    for _, fixture in ipairs(_WORD_FIXTURES) do
        _it_per_grammar(fixture, "#W jumps over an entire run, not leaf-by-leaf", function()
            grammar.set_cursor(0, fixture.W_start)

            for _, column in ipairs(fixture.W) do
                treemotion.run_motion_W()
                local _, actual = grammar.get_cursor()
                assert.same(column, actual)
            end
        end)

        _it_per_grammar(fixture, "#B moves run-by-run, backward", function()
            grammar.set_cursor(0, fixture.B_start)

            for _, column in ipairs(fixture.B) do
                treemotion.run_motion_B()
                local _, actual = grammar.get_cursor()
                assert.same(column, actual)
            end
        end)

        _it_per_grammar(fixture, "#E jumps to the end of the current, then next, run", function()
            grammar.set_cursor(0, fixture.E_start)

            for _, column in ipairs(fixture.E) do
                treemotion.run_motion_E()
                local _, actual = grammar.get_cursor()
                assert.same(column, actual)
            end
        end)

        _it_per_grammar(fixture, "#gE jumps to the end of the previous run", function()
            grammar.set_cursor(0, fixture.gE_start)

            for _, column in ipairs(fixture.gE) do
                treemotion.run_motion_gE()
                local _, actual = grammar.get_cursor()
                assert.same(column, actual)
            end
        end)
    end
end)
