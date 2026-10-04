--- `commands.motion.operator_pending` gives operators Vim's ranges, end to
--- end through the `<Plug>` mappings, and changes nothing while disabled.
--- The range rules themselves are tested in `operator_range_spec.lua`.
---
--- Expected results for `dw` at a line's end, on an empty line, and `cw` on
--- blanks or a word's last character match Neovim's built-in `dw`/`cw`.

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

--- Type `keys` like `_type`, after making a blockwise selection on the last line.
---
--- The selection is `<C-v>l` from `lines`' first line's column 6, so `keys`
--- must leave that line, and the number of lines before it, alone.
---
---@param lines string[]
---@param row integer 0-indexed row.
---@param column integer 0-indexed column.
---@param keys string Keys to type, in `:help keycodes` notation.
---@return table # `{ '<, '>, visualmode() }` afterwards, as `nvim_buf_get_mark` gives them.
local function _visual_marks_after(lines, row, column, keys)
    local buffer = grammar_helpers.new_buffer("lua", lines)

    _map_motions(buffer)
    grammar_helpers.set_cursor(0, 6)
    vim.api.nvim_feedkeys(vim.keycode("<C-v>l<Esc>"), "xt", false)
    grammar_helpers.set_cursor(row, column)
    vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
    vim.cmd("stopinsert")

    local result = {
        vim.api.nvim_buf_get_mark(buffer, "<"),
        vim.api.nvim_buf_get_mark(buffer, ">"),
        vim.fn.visualmode(),
    }

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
        -- `setup()` deep-merges and can't remove entries, so restore the
        -- snapshot (writers replace `DATA` rather than edit it).
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

        it("#dw deletes a whole acronym with a one-letter suffix", function()
            _configure({ enabled = true }, { lua = { "=" } })

            assert.same({ "local = bar" }, _type("lua", { "local CIDRv4 = bar" }, 0, 6, "dw"))
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

    describe("prose", function()
        it("#dw in markdown keeps the punctuation after the blanks", function()
            _configure({ enabled = true })

            local lines = { "- and `comment`. It always counts." }

            assert.same({ "- `comment`. It always counts." }, _type("markdown", lines, 0, 2, "dw"))
            assert.same(_type_builtin(lines, 0, 2, "dw"), _type("markdown", lines, 0, 2, "dw"))
        end)

        it("#dw in a comment keeps the punctuation after the blanks", function()
            _configure({ enabled = true })

            assert.same(
                { "-- `comment`. It always counts." },
                _type("lua", { "-- and `comment`. It always counts." }, 0, 3, "dw")
            )
        end)
    end)

    describe("brackets", function()
        it("#dW keeps a closing ( the range didn't open", function()
            _configure({ enabled = true })

            assert.same({ "local x = f()" }, _type("lua", { "local x = f(config.a.b)" }, 0, 12, "dW"))
        end)

        it("#dW keeps a closing [ the range didn't open", function()
            _configure({ enabled = true })

            assert.same({ "local x = t[]" }, _type("lua", { "local x = t[config.a]" }, 0, 12, "dW"))
        end)

        it("#dW keeps a closing { the range didn't open", function()
            _configure({ enabled = true })

            assert.same({ "local x = {}" }, _type("lua", { "local x = {config.a}" }, 0, 11, "dW"))
        end)

        it("#dW on an opening bracket deletes through its closing one", function()
            _configure({ enabled = true })

            assert.same({ "local x = f" }, _type("lua", { "local x = f(config.a.b)" }, 0, 11, "dW"))
            assert.same({ "local x = t" }, _type("lua", { "local x = t[config.a]" }, 0, 11, "dW"))
            assert.same({ "local x = " }, _type("lua", { "local x = {config.a}" }, 0, 10, "dW"))
        end)

        it("#dW keeps nested brackets that close inside the range", function()
            _configure({ enabled = true })

            assert.same({ "local x = f()" }, _type("lua", { "local x = f(g(a).b)" }, 0, 12, "dW"))
        end)

        it("#cW keeps a closing bracket the range didn't open", function()
            _configure({ enabled = true })

            assert.same({ "local x = f(X)" }, _type("lua", { "local x = f(config.a.b)" }, 0, 12, "cWX<Esc>"))
        end)

        it("#dE keeps a closing bracket the range didn't open", function()
            _configure({ enabled = true })

            assert.same({ "local x = f()" }, _type("lua", { "local x = f(config.a.b)" }, 0, 12, "dE"))
        end)

        it("#de keeps the empty lines before a closing bracket that starts a line", function()
            _configure({ enabled = true })

            assert.same({ "foo(", "", ")" }, _type("lua", { "foo(x", "", ")" }, 0, 4, "de"))
        end)

        it("#de keeps the indent and empty lines before a closing bracket that starts a line", function()
            _configure({ enabled = true })

            assert.same({ "foo(", "    ", "", ")" }, _type("lua", { "foo(", "    x", "", ")" }, 1, 4, "de"))
        end)

        it("#dW on a closing bracket still deletes it", function()
            _configure({ enabled = true })

            assert.same({ "local x = f(a" }, _type("lua", { "local x = f(a))" }, 0, 13, "dW"))
        end)

        it("#dW ignores a closing bracket inside a string", function()
            _configure({ enabled = true })

            assert.same({ "print(.. x)" }, _type("lua", { 'print(")" .. x)' }, 0, 6, "dW"))
        end)

        it("#dE ignores a closing bracket inside a string", function()
            _configure({ enabled = true })

            assert.same({ "f( y)" }, _type("lua", { 'f(")", y)' }, 0, 2, "dE"))
        end)

        it("#dW ignores an opening bracket inside a string", function()
            _configure({ enabled = true })

            assert.same({ "local x = f()" }, _type("lua", { 'local x = f("("..a)' }, 0, 12, "dW"))
        end)

        it("#dW matches brackets by kind", function()
            _configure({ enabled = true })

            assert.same({ "local x = t[]" }, _type("lua", { "local x = t[f(a.b]" }, 0, 12, "dW"))
        end)

        it("#dw in a comment keeps a closing bracket it didn't open", function()
            _configure({ enabled = true })

            assert.same({ "-- (foo )" }, _type("lua", { "-- (foo bar)" }, 0, 8, "dw"))
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

        it("#cw changes a whole acronym with a one-letter suffix", function()
            _configure({ enabled = true })

            assert.same({ "local X = 1" }, _type("lua", { "local CIDRv4 = 1" }, 0, 6, "cwX<Esc>"))
            assert.same({ "local x = getXFor()" }, _type("lua", { "local x = getURLsFor()" }, 0, 13, "cwX<Esc>"))
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

    describe("backward inclusive motions", function()
        it("#dge counts like #ge", function()
            _configure({ enabled = true })

            assert.same({ "local fo 1" }, _type("lua", { "local fooBar = 1" }, 0, 13, "d2ge"))
        end)

        it("#dge across lines includes the character under the cursor", function()
            _configure({ enabled = true })

            assert.same({ "local foal bar" }, _type("lua", { "local foo", "local bar" }, 1, 2, "dge"))
        end)

        it("#dge that can't move deletes nothing", function()
            _configure({ enabled = true })

            assert.same({ "local fooBar = 1" }, _type("lua", { "local fooBar = 1" }, 0, 2, "dge"))
        end)

        it("repeats #dge with .", function()
            _configure({ enabled = true })

            assert.same({ "local fz = 1" }, _type("lua", { "local fooBar baz = 1" }, 0, 11, "dge$5h."))
        end)

        it("repeats #dge with . where #ge can't move without deleting anything", function()
            _configure({ enabled = true })
            vim.v.errmsg = ""

            assert.same({ "local fo = 1" }, _type("lua", { "local fooBar = 1" }, 0, 11, "dge0."))
            assert.equal("", vim.v.errmsg)
        end)

        it("#gUge includes the character under the cursor", function()
            _configure({ enabled = true })

            assert.same({ "local foOBAR = 1" }, _type("lua", { "local fooBar = 1" }, 0, 11, "gUge"))
        end)

        it("#dgE includes the character under the cursor", function()
            _configure({ enabled = true })

            assert.same({ "local x.y " }, _type("lua", { "local x.y = a.b" }, 0, 14, "dgE"))
        end)

        it("#dge stays exclusive with #inclusive = false", function()
            _configure({ enabled = true, inclusive = false })

            assert.same({ "local for = 1" }, _type("lua", { "local fooBar = 1" }, 0, 11, "dge"))
        end)
    end)

    describe("Visual marks", function()
        local lines = { "local x = 2", "local fooBar = 1", "", "local y = 3" }

        ---@type {description: string, row: integer, column: integer, keys: string}[]
        local cases = {
            { description = "#de", row = 1, column = 6, keys = "de" },
            { description = "#dE", row = 1, column = 6, keys = "dE" },
            { description = "#dge", row = 1, column = 11, keys = "dge" },
            { description = "#dgE", row = 1, column = 15, keys = "dgE" },
            { description = "#dw at a line's end", row = 1, column = 15, keys = "dw" },
            { description = "#dw on an empty line", row = 2, column = 0, keys = "dw" },
            { description = "#cw", row = 1, column = 6, keys = "cwx<Esc>" },
            { description = "#ye", row = 1, column = 6, keys = "ye" },
        }

        for _, case in ipairs(cases) do
            it(string.format("%s leaves '< and '> alone (gv)", case.description), function()
                _configure({ enabled = true })

                assert.same(
                    { { 1, 6 }, { 1, 7 }, vim.keycode("<C-v>") },
                    _visual_marks_after(lines, case.row, case.column, case.keys)
                )
            end)
        end

        it("#de then gv selects the earlier selection, like the built-in", function()
            _configure({ enabled = true })

            local keys = "wviw<Esc>0degvd"

            assert.same(
                _type_builtin({ "aaa bbb ccc ddd" }, 0, 0, keys),
                _type("lua", { "aaa bbb ccc ddd" }, 0, 0, keys)
            )
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

        it("#cw changes a whole acronym with a one-letter suffix", function()
            if not _has_parser("nix") then
                _skip('no "nix" treesitter parser installed')

                return
            end

            _configure({ enabled = true })

            local acronym = { "{", "  CIDRv4 = {", "    address = 1;", "  };", "}" }

            assert.same({ "{", "  X = {", "    address = 1;", "  };", "}" }, _type("nix", acronym, 1, 2, "cwX<Esc>"))
        end)

        describe("inherit", function()
            local inherit = {
                "{",
                "  inherit (config.fleet.lib.firewall.statements.analysis)",
                "    foo",
                "    ;",
                "}",
            }

            ---@param line string The second line.
            ---@return string[] # `inherit` with `line` as its second line.
            local function _with_line(line)
                local result = vim.deepcopy(inherit)
                result[2] = line

                return result
            end

            it("#dW keeps the closing )", function()
                if not _has_parser("nix") then
                    _skip('no "nix" treesitter parser installed')

                    return
                end

                _configure({ enabled = true })

                assert.same(_with_line("  inherit ()"), _type("nix", inherit, 1, 11, "dW"))
            end)

            it("#dW on ( deletes the whole parenthesized expression", function()
                if not _has_parser("nix") then
                    _skip('no "nix" treesitter parser installed')

                    return
                end

                _configure({ enabled = true })

                assert.same(_with_line("  inherit "), _type("nix", inherit, 1, 10, "dW"))
            end)

            it("#dw on the path's last attribute keeps the closing )", function()
                if not _has_parser("nix") then
                    _skip('no "nix" treesitter parser installed')

                    return
                end

                _configure({ enabled = true })

                assert.same(
                    _with_line("  inherit (config.fleet.lib.firewall.statements.)"),
                    _type("nix", inherit, 1, 48, "dw")
                )
            end)
        end)
    end)
end)
