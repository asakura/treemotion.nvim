--- Make sure `_commands.motion.operator.apply` sets up the range it's given.
---
--- `apply` only moves the cursor: to an exclusive range's end, or just past
--- an inclusive range's last character, which can be past a line's last
--- character. It never starts Visual mode, so `'<`/`'>` (`gv`) stay put.
--- These call it outside operator-pending mode and check the mode, the
--- cursor, the Visual marks and `'virtualedit'`, so they need no parser.
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

--- Apply `range` in a buffer holding `lines`, with the cursor at the range's start.
---
--- `'<`/`'>` are set to the first character beforehand and must be left there.
---
---@param lines string[]
---@param range treemotion.OperatorRange
---@return integer[] # The cursor afterwards, 0-indexed.
local function _apply(lines, range)
    _BUFFER = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(_BUFFER, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(_BUFFER)
    vim.api.nvim_buf_set_mark(_BUFFER, "<", 1, 0, {})
    vim.api.nvim_buf_set_mark(_BUFFER, ">", 1, 0, {})
    grammar_helpers.set_cursor(range.start_row, range.start_column)

    local virtualedit = vim.wo.virtualedit

    operator.apply(range)

    assert.equal("n", vim.fn.mode())
    assert.same({ 1, 0 }, vim.api.nvim_buf_get_mark(_BUFFER, "<"))
    assert.same({ 1, 0 }, vim.api.nvim_buf_get_mark(_BUFFER, ">"))
    assert.equal(virtualedit, vim.wo.virtualedit)

    return { grammar_helpers.get_cursor() }
end

describe("operator.apply", function()
    after_each(function()
        grammar_helpers.remove_buffer(_BUFFER)
        _BUFFER = nil
    end)

    describe("exclusive", function()
        it("moves the cursor to a finish inside the line", function()
            assert.same({ 0, 4 }, _apply({ "foo bar" }, _range(0, 0, 0, 4, false)))
        end)

        it("moves the cursor to a finish at the next line's start", function()
            assert.same({ 1, 0 }, _apply({ "foo", "bar" }, _range(0, 0, 1, 0, false)))
        end)

        it("moves the cursor onto an empty line", function()
            assert.same({ 0, 0 }, _apply({ "", "bar" }, _range(0, 0, 0, 0, false)))
        end)

        it("moves the cursor past the last character for a finish at the line's end", function()
            assert.same({ 0, 7 }, _apply({ "foo bar" }, _range(0, 4, 0, 7, false)))
        end)

        it("moves the cursor past a multibyte last character", function()
            assert.same({ 0, 7 }, _apply({ "foo —" }, _range(0, 0, 0, 7, false)))
        end)

        it("moves the cursor backward", function()
            assert.same({ 0, 2 }, _apply({ "foo bar" }, _range(0, 5, 0, 2, false)))
        end)
    end)

    describe("inclusive", function()
        it("moves the cursor past the finish", function()
            assert.same({ 0, 5 }, _apply({ "foo bar" }, _range(0, 1, 0, 4, true)))
        end)

        it("moves the cursor past the finish across lines", function()
            assert.same({ 1, 2 }, _apply({ "foo", "bar" }, _range(0, 2, 1, 1, true)))
        end)

        it("moves the cursor past a finish on the line's last character", function()
            assert.same({ 0, 7 }, _apply({ "foo bar" }, _range(0, 4, 0, 6, true)))
        end)

        it("moves the cursor past a multibyte finish", function()
            assert.same({ 0, 7 }, _apply({ "foo —" }, _range(0, 0, 0, 4, true)))
        end)

        it("takes an empty line's line break", function()
            assert.same({ 1, 0 }, _apply({ "", "bar" }, _range(0, 0, 0, 0, true)))
        end)

        it("has no line break to take on an empty last line", function()
            assert.same({ 1, 0 }, _apply({ "foo", "" }, _range(1, 0, 1, 0, true)))
        end)
    end)
end)
