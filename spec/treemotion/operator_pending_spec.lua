--- Make sure `commands.motion.operator_pending` gives operators (`dw`, `cw`,
--- `de`, ...) Vim's own ranges, and changes nothing while it's disabled.
---
--- Keys go through the real `<Plug>` mappings with `nvim_feedkeys`, since
--- the feature depends on operator-pending mode. Most fixtures are Lua (a
--- bundled parser) with `insignificant_characters` configured, because the
--- rules only look at units, leaves and blanks. The Nix fixtures exercise a
--- grammar whose defaults skip punctuation, and are pending where the Nix
--- parser isn't installed.
---
--- Expected results for `dw` at a line's end, on an empty line, and for
--- `cw` on whitespace or a word's last character were taken from Neovim's
--- built-in `dw`/`cw` on the same text.
---
--- These are end-to-end checks of the mappings. The range rules themselves
--- are tested directly in `operator_range_spec.lua`.

local configuration = require("treemotion._core.configuration")
local grammar_helpers = require("treemotion.grammar_helpers")
local treemotion = require("treemotion")

--- Apply `operator_pending` and `insignificant_characters` on top of the
--- defaults (every test starts from them, see `after_each` below).
---
---@param operator_pending table? Overrides for `commands.motion.operator_pending`.
---@param insignificant_characters table? `commands.motion.insignificant_characters`.
local function _configure(operator_pending, insignificant_characters)
    treemotion.setup({
        commands = {
            motion = {
                operator_pending = operator_pending or {},
                insignificant_characters = insignificant_characters or {},
            },
        },
    })
end

--- Map every motion in `buffer`, the way the README suggests.
---
---@param buffer integer
local function _map_motions(buffer)
    for _, name in ipairs({ "w", "e", "b", "ge", "W", "E", "B", "gE" }) do
        vim.keymap.set({ "n", "x", "o" }, name, string.format("<Plug>(TreeMotion%s)", name), {
            buffer = buffer,
            remap = true,
        })
    end
end

--- Type `keys` at `row`/`column` in a `filetype` buffer holding `lines`.
---
---@param filetype string
---@param lines string[]
---@param row integer 0-indexed row.
---@param column integer 0-indexed column.
---@param keys string Keys to type, in `:help keycodes` notation.
---@return string[] # The buffer's lines afterwards.
local function _type(filetype, lines, row, column, keys)
    local buffer = grammar_helpers.new_buffer(filetype, lines)

    _map_motions(buffer)
    grammar_helpers.set_cursor(row, column)
    vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
    vim.cmd("stopinsert")

    local result = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)

    grammar_helpers.remove_buffer(buffer)

    return result
end

--- Type `keys` at `row`/`column` with Neovim's built-in motions: no mappings, no parser.
---
---@param lines string[]
---@param row integer 0-indexed row.
---@param column integer 0-indexed column.
---@param keys string Keys to type, in `:help keycodes` notation.
---@return string[] # The buffer's lines afterwards.
local function _type_builtin(lines, row, column, keys)
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(buffer)
    grammar_helpers.set_cursor(row, column)
    vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
    vim.cmd("stopinsert")

    local result = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)

    grammar_helpers.remove_buffer(buffer)

    return result
end

--- Mark the running test pending.
---
--- Inside a test busted's `pending` takes just a message, but its type stubs
--- only describe the `pending(name, block)` form used outside one. Busted
--- swaps in the in-test `pending` while a test runs, so it's looked up on
--- each call rather than kept in a local.
---
---@param message string
local function _skip(message)
    local skip = pending --[[@as fun(message: string)]]

    skip(message)
end

---@param filetype string
---@return boolean # Whether `filetype` has a treesitter parser here.
local function _has_parser(filetype)
    local ok, added = pcall(vim.treesitter.language.add, filetype)

    return ok and added == true
end

describe("operator-pending motions", function()
    ---@type treemotion.ResolvedConfiguration
    local original

    before_each(function()
        original = configuration.resolve_data()
    end)

    after_each(function()
        -- `setup()` deep-merges, so it can't remove the `lua` entries these
        -- tests add to `insignificant_characters`. Restore the snapshot
        -- instead, as `configuration_spec.lua` does: every change replaces
        -- `configuration.DATA` rather than editing it, so the saved table is
        -- still the original.
        configuration.DATA = original
    end)

    describe("disabled (the default)", function()
        it("is off by default", function()
            assert.is_false(configuration.resolve_data().commands.motion.operator_pending.enabled)
        end)

        it("leaves #dw deleting everything up to the next stop", function()
            _configure({}, { lua = { "=" } })

            assert.same({ "local bar" }, _type("lua", { "local foo = bar" }, 0, 6, "dw"))
        end)

        it("leaves #de exclusive", function()
            assert.same({ "local oBar = 1" }, _type("lua", { "local fooBar = 1" }, 0, 6, "de"))
        end)
    end)

    describe("skipped text", function()
        it("#dw keeps an insignificant leaf the motion skips", function()
            _configure({ enabled = true }, { lua = { "=" } })

            assert.same({ "local = bar" }, _type("lua", { "local foo = bar" }, 0, 6, "dw"))
        end)

        it("#dw on an insignificant leaf deletes that leaf and the blanks after it", function()
            _configure({ enabled = true }, { lua = { "=" } })

            assert.same({ "local foo bar" }, _type("lua", { "local foo = bar" }, 0, 10, "dw"))
        end)

        it("#dW keeps an isolated insignificant run", function()
            _configure({ enabled = true }, { lua = { "=" } })

            assert.same({ "local = bar" }, _type("lua", { "local foo = bar" }, 0, 6, "dW"))
        end)

        it("still includes skipped delimiters inside the token with keep_between_tokens", function()
            _configure({ enabled = true })

            assert.same({ "local bar = 1" }, _type("lua", { "local foo_bar = 1" }, 0, 6, "dw"))
        end)

        it("keeps skipped delimiters inside the token too with keep", function()
            _configure({ enabled = true, skipped_text = "keep" })

            assert.same({ "local _bar = 1" }, _type("lua", { "local foo_bar = 1" }, 0, 6, "dw"))
        end)

        it("includes skipped text with delete", function()
            _configure({ enabled = true, skipped_text = "delete" }, { lua = { "=" } })

            assert.same({ "local bar" }, _type("lua", { "local foo = bar" }, 0, 6, "dw"))
        end)

        it("#d2w only trims after the last unit", function()
            _configure({ enabled = true }, { lua = { "=", "," } })

            assert.same({ "local , c = 1" }, _type("lua", { "local a, b, c = 1" }, 0, 6, "d2w"))
        end)

        it("#dw on the buffer's last unit deletes the rest of it", function()
            _configure({ enabled = true })

            assert.same({ "local x = " }, _type("lua", { "local x = foo" }, 0, 10, "dw"))
        end)

        it("#d5w running out of units still deletes the last one, like Vim's", function()
            _configure({ enabled = true })

            assert.same({ "local x " }, _type("lua", { "local x = foo" }, 0, 8, "d5w"))
        end)
    end)

    describe("line ends", function()
        it("#dw on a line's last word stops at the end of the line", function()
            _configure({ enabled = true })

            assert.same(
                { "local x = ", "  local y = 2" },
                _type("lua", { "local x = foo  ", "  local y = 2" }, 0, 10, "dw")
            )
        end)

        it("#dw on trailing blanks deletes only those", function()
            _configure({ enabled = true })

            assert.same(
                { "local x = foo", "  local y = 2" },
                _type("lua", { "local x = foo  ", "  local y = 2" }, 0, 13, "dw")
            )
        end)

        it("#dw on an empty line deletes the line break", function()
            _configure({ enabled = true })

            assert.same(
                { "local x = foo", "  local y = 2" },
                _type("lua", { "local x = foo", "", "  local y = 2" }, 1, 0, "dw")
            )
        end)

        it("#cw on an empty line just starts inserting", function()
            _configure({ enabled = true })

            assert.same(
                { "local x = foo", "X", "  local y = 2" },
                _type("lua", { "local x = foo", "", "  local y = 2" }, 1, 0, "cwX<Esc>")
            )
        end)

        it("joins lines again with #stop_at_line_end = false", function()
            _configure({ enabled = true, stop_at_line_end = false })

            assert.same({ "local x = local y = 2" }, _type("lua", { "local x = foo", "  local y = 2" }, 0, 10, "dw"))
        end)
    end)

    describe("end of the buffer, like the built-in", function()
        ---@type {description: string, lines: string[], row: integer, column: integer, keys: string}[]
        local cases = {
            {
                description = "#dw on the last word takes the blanks after it",
                lines = { "x = foo  " },
                row = 0,
                column = 4,
                keys = "dw",
            },
            {
                description = "#dw on trailing blanks",
                lines = { "local x = foo  " },
                row = 0,
                column = 13,
                keys = "dw",
            },
            {
                description = "#dw on trailing blanks in a comment",
                lines = { "-- c  " },
                row = 0,
                column = 5,
                keys = "dw",
            },
            {
                description = "#dw on trailing blanks on a later line",
                lines = { "local x = foo =  ", "  " },
                row = 1,
                column = 1,
                keys = "dw",
            },
            { description = "#dw on a final =", lines = { "local x = foo =  " }, row = 0, column = 14, keys = "dw" },
            {
                description = "#dw on an empty last line",
                lines = { "local x = foo", "" },
                row = 1,
                column = 0,
                keys = "dw",
            },
            { description = "#d3w past the last word", lines = { "x = foo  bar" }, row = 0, column = 4, keys = "d3w" },
            {
                description = "#cw on a final =",
                lines = { "local x = foo =  " },
                row = 0,
                column = 14,
                keys = "cwX<Esc>",
            },
            {
                description = "#cw on a final ==",
                lines = { "local x = foo ==  " },
                row = 0,
                column = 14,
                keys = "cwX<Esc>",
            },
            {
                description = "#cw on trailing blanks",
                lines = { "local x = foo  ", "  " },
                row = 0,
                column = 13,
                keys = "cwX<Esc>",
            },
        }

        for _, case in ipairs(cases) do
            it(case.description, function()
                _configure({ enabled = true }, { lua = { "=", "==" } })

                assert.same(
                    _type_builtin(case.lines, case.row, case.column, case.keys),
                    _type("lua", case.lines, case.row, case.column, case.keys)
                )
            end)
        end
    end)

    describe("change", function()
        it("#cw changes to the end of the current unit", function()
            _configure({ enabled = true })

            assert.same({ "local XBar = 1" }, _type("lua", { "local fooBar = 1" }, 0, 6, "cwX<Esc>"))
        end)

        it("#cw on a unit's last character changes just that character", function()
            _configure({ enabled = true })

            assert.same({ "local x = foX" }, _type("lua", { "local x = foo" }, 0, 12, "cwX<Esc>"))
        end)

        it("#cw on blanks changes the blanks", function()
            _configure({ enabled = true })

            assert.same({ "local x = fooXbar" }, _type("lua", { "local x = foo  bar" }, 0, 13, "cwX<Esc>"))
        end)

        it("#cW changes to the end of the WORD", function()
            _configure({ enabled = true })

            assert.same({ "local X = 1" }, _type("lua", { "local foo.bar = 1" }, 0, 6, "cWX<Esc>"))
        end)

        it("#c2w changes to the end of the second unit", function()
            _configure({ enabled = true })

            assert.same({ "local XBaz = 1" }, _type("lua", { "local fooBarBaz = 1" }, 0, 6, "c2wX<Esc>"))
        end)

        it("follows 'cpoptions' without _, like Vim's own cw", function()
            _configure({ enabled = true }, { lua = { "=" } })
            local cpoptions = vim.o.cpoptions
            vim.o.cpoptions = cpoptions:gsub("_", "")

            local ok, result = pcall(_type, "lua", { "local foo = bar" }, 0, 6, "cwX<Esc>")
            vim.o.cpoptions = cpoptions

            if not ok then
                error(result, 0)
            end

            assert.same({ "local X= bar" }, result)
        end)

        it("#cw behaves like #dw with #change_to_end = false", function()
            _configure({ enabled = true, change_to_end = false }, { lua = { "=" } })

            assert.same({ "local X= bar" }, _type("lua", { "local foo = bar" }, 0, 6, "cwX<Esc>"))
        end)
    end)

    describe("inclusive motions", function()
        it("#de deletes the whole unit", function()
            _configure({ enabled = true })

            assert.same({ "local Bar = 1" }, _type("lua", { "local fooBar = 1" }, 0, 6, "de"))
        end)

        it("#dge includes the character under the cursor", function()
            _configure({ enabled = true })

            assert.same({ "local fo = 1" }, _type("lua", { "local fooBar = 1" }, 0, 11, "dge"))
        end)

        it("#dE deletes the whole WORD", function()
            _configure({ enabled = true })

            assert.same({ "local  = 1" }, _type("lua", { "local foo.bar = 1" }, 0, 6, "dE"))
        end)

        it("respects 'selection' = exclusive", function()
            _configure({ enabled = true })
            local selection = vim.o.selection
            vim.o.selection = "exclusive"

            local ok, result = pcall(_type, "lua", { "local fooBar = 1" }, 0, 6, "de")
            vim.o.selection = selection

            if not ok then
                error(result, 0)
            end

            assert.same({ "local Bar = 1" }, result)
        end)

        it("stays exclusive with #inclusive = false", function()
            _configure({ enabled = true, inclusive = false })

            assert.same({ "local oBar = 1" }, _type("lua", { "local fooBar = 1" }, 0, 6, "de"))
        end)
    end)

    describe("unchanged", function()
        it("leaves a forced motion (#dvw) alone", function()
            _configure({ enabled = true })

            assert.same({ "local ar = 1" }, _type("lua", { "local fooBar = 1" }, 0, 6, "dvw"))
        end)

        it("leaves #db alone", function()
            _configure({ enabled = true }, { lua = { "=" } })

            assert.same({ "local bar" }, _type("lua", { "local foo = bar" }, 0, 12, "db"))
        end)

        it("leaves Visual mode alone", function()
            _configure({ enabled = true }, { lua = { "=" } })

            assert.same({ "local ar" }, _type("lua", { "local foo = bar" }, 0, 6, "vwd"))
        end)

        it("repeats with #.", function()
            _configure({ enabled = true })

            assert.same(
                { "local , b = 1", "local , d = 2" },
                _type("lua", { "local a, b = 1", "local c, d = 2" }, 0, 6, "dwj0w.")
            )
        end)
    end)

    describe("nix", function()
        local lines = { "{", '  "origin" = {', '    source = "rule";', "  };", "}" }

        it("#dw keeps the quotes and the rest of the binding", function()
            if not _has_parser("nix") then
                _skip('no "nix" treesitter parser installed')

                return
            end

            _configure({ enabled = true })

            assert.same({ "{", '  "" = {', '    source = "rule";', "  };", "}" }, _type("nix", lines, 1, 3, "dw"))
        end)

        it("#cw changes only the attribute name", function()
            if not _has_parser("nix") then
                _skip('no "nix" treesitter parser installed')

                return
            end

            _configure({ enabled = true })

            assert.same(
                { "{", '  "X" = {', '    source = "rule";', "  };", "}" },
                _type("nix", lines, 1, 3, "cwX<Esc>")
            )
        end)
    end)
end)
