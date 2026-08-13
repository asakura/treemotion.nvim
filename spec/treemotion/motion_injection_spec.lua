--- Prove `w`/`e`/`b`/`ge`/`W`/`E`/`B`/`gE` cross `:help
--- treesitter-language-injections` boundaries instead of treating injected
--- content as one opaque leaf -- see `_commands.motion.leaf`'s module
--- docstring for the full design (descending into a piece of injected
--- content, walking it leaf-by-leaf, then climbing back out to the host
--- node's own neighbors once the piece runs out).
---
--- Uses `vim.cmd([[...]])`, which Neovim's own bundled
--- `queries/lua/injections.scm` injects as Vimscript -- so this runs
--- hermetically against just the `lua`/`vim` grammars Neovim bundles,
--- unlike e.g. a Nix `# bash` string, which needs `treesitterAllGrammars`
--- (see `grammar_helpers.lua`'s module docstring) and so can't run in every
--- environment this suite does.

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
    -- Leaves: `vim`(0-3) `.`(3-4) `cmd`(4-7) `(`(7-8) `[[`(8-10) -- then
    -- Vimscript takes over inside the string -- `set`(10-13) `number`(14-20)
    -- -- then back to Lua's own `]]`(20-22) `)`(22-23). `[[`'s end (0,10)
    -- touches `set`'s start (0,10) exactly, and `number`'s end (0,20)
    -- touches `]]`'s start (0,20) exactly -- both injection boundaries are
    -- immediately adjacent in the buffer, not separated by a gap.

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
        -- `vim.cmd([[set` is one run even though it crosses into injected
        -- content, since nothing but real buffer whitespace (the space
        -- before `number`) ever counts as a run break -- see
        -- `_commands.motion.leaf`'s `is_contiguous`.
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
    -- Same `vim.cmd([[set number]])` text as above, but this time inside a
    -- Markdown fence tagged ```lua``` -- Neovim's own bundled
    -- `queries/markdown/injections.scm` injects fenced code as whatever
    -- language its info string names, so this buffer has *three*
    -- `LanguageTree`s stacked on top of each other: `markdown` (the fence
    -- itself), `lua` (the fence's content, injected by markdown), and `vim`
    -- (the `vim.cmd([[...]])` string, injected by lua's own
    -- `queries/lua/injections.scm` -- the same query the flat case above
    -- uses, just now running one injection boundary deeper). All three
    -- grammars are bundled with Neovim, so -- like the flat case -- this
    -- needs no `treesitterAllGrammars`.
    --
    -- The buffer text on row 1 is identical to the flat case's single line,
    -- so every column below matches that spec exactly; what this proves
    -- instead is that `w`/`b`/`e`/`ge` reach `set`/`number` as their own
    -- leaves at all, rather than stopping one level short at the Lua
    -- grammar's own (childless, from Lua's point of view) `string_content`
    -- node -- see `_leaf_at`'s docstring in `_commands.motion.leaf` for why
    -- that stopping-one-level-short shape was a real bug, not a hypothetical.
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
end)
