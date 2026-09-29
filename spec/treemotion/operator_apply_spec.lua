--- Make sure `_commands.motion.operator.apply` sets up the range it's given.
---
--- `apply` either moves the cursor (an exclusive range the cursor can reach)
--- or starts Visual mode (an inclusive range, or one ending past a line's
--- last character). These call it outside operator-pending mode and check
--- the mode, the Visual start and the cursor, so they need no parser.
--- `operator_pending_spec.lua` checks the text operators then act on.

local grammar_helpers = require("treemotion.grammar_helpers")
local operator = require("treemotion._commands.motion.operator")

---@type integer?
local _BUFFER

--- Build a `treemotion.OperatorRange`.
---
---@param start_row integer
---@param start_column integer
---@param finish_row integer
---@param finish_column integer
---@param inclusive boolean
---@return treemotion.OperatorRange
local function _range(start_row, start_column, finish_row, finish_column, inclusive)
    return {
        start_row = start_row,
        start_column = start_column,
        finish_row = finish_row,
        finish_column = finish_column,
        inclusive = inclusive,
    }
end

--- Apply `range` in a buffer holding `lines`, with `'selection'` set to `selection`.
---
---@param lines string[]
---@param range treemotion.OperatorRange
---@param selection string? `'selection'`, `"inclusive"` if not given.
---@return table # `{ mode, visual_start, cursor }`. `visual_start` is `nil` outside Visual mode.
local function _apply(lines, range, selection)
    _BUFFER = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(_BUFFER, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(_BUFFER)
    grammar_helpers.set_cursor(0, 0)

    local original = vim.o.selection
    vim.o.selection = selection or "inclusive"

    local ok, message = pcall(operator.apply, range)

    local mode = vim.fn.mode()
    local visual = vim.fn.getpos("v")
    local cursor = { grammar_helpers.get_cursor() }

    vim.cmd('execute "normal! \\<Esc>"')
    vim.o.selection = original

    assert.is_true(ok, message)

    return {
        mode,
        mode == "v" and { visual[2] - 1, visual[3] - 1 } or nil,
        cursor,
    }
end

describe("operator.apply", function()
    after_each(function()
        grammar_helpers.remove_buffer(_BUFFER)
        _BUFFER = nil
    end)

    describe("exclusive", function()
        it("moves the cursor to a finish inside the line", function()
            assert.same({ "n", nil, { 0, 4 } }, _apply({ "foo bar" }, _range(0, 0, 0, 4, false)))
        end)

        it("moves the cursor to a finish at the next line's start", function()
            assert.same({ "n", nil, { 1, 0 } }, _apply({ "foo", "bar" }, _range(0, 0, 1, 0, false)))
        end)

        it("moves the cursor onto an empty line", function()
            assert.same({ "n", nil, { 0, 0 } }, _apply({ "", "bar" }, _range(0, 0, 0, 0, false)))
        end)

        it("selects to the last character for a finish at the line's end", function()
            assert.same({ "v", { 0, 4 }, { 0, 6 } }, _apply({ "foo bar" }, _range(0, 4, 0, 7, false)))
        end)

        it("selects to a multibyte last character's first byte", function()
            assert.same({ "v", { 0, 0 }, { 0, 4 } }, _apply({ "foo —" }, _range(0, 0, 0, 7, false)))
        end)

        it("selects past the last character with 'selection' = exclusive", function()
            assert.same({ "v", { 0, 0 }, { 0, 7 } }, _apply({ "foo —" }, _range(0, 0, 0, 7, false), "exclusive"))
        end)
    end)

    describe("inclusive", function()
        it("selects from start to finish", function()
            assert.same({ "v", { 0, 1 }, { 0, 4 } }, _apply({ "foo bar" }, _range(0, 1, 0, 4, true)))
        end)

        it("selects across lines", function()
            assert.same({ "v", { 0, 2 }, { 1, 1 } }, _apply({ "foo", "bar" }, _range(0, 2, 1, 1, true)))
        end)

        it("selects an empty line's line break", function()
            assert.same({ "v", { 0, 0 }, { 0, 0 } }, _apply({ "", "bar" }, _range(0, 0, 0, 0, true)))
        end)

        it("steps past a multibyte finish with 'selection' = exclusive", function()
            assert.same({ "v", { 0, 0 }, { 0, 7 } }, _apply({ "foo —" }, _range(0, 0, 0, 4, true), "exclusive"))
        end)
    end)
end)
