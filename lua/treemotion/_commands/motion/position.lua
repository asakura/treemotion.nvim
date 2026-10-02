--- Cursor-position and position-comparison helpers shared by the motion modules.
---
--- A position is a 0-indexed row and a 0-indexed byte column, the
--- convention `TSNode:start()`/`:end_()` use.

local codepoint = require("treemotion._commands.motion.codepoint")

local M = {}

--- Read the cursor's position, converted to `TSNode`'s 0-indexed row convention.
---
--- `nvim_win_get_cursor` returns a 1-indexed row (matching `:` command-line
--- line numbers), but every `TSNode:start()`/`:end_()` row is 0-indexed --
--- this is the single place that conversion happens, so callers can compare
--- cursor positions against node positions directly.
---
---@return integer, integer # The cursor's 0-indexed row and column.
function M.cursor_position()
    local cursor = vim.api.nvim_win_get_cursor(0)

    return cursor[1] - 1, cursor[2]
end

--- Where the cursor ends up if put at `row`/`column`.
---
--- `nvim_win_set_cursor` keeps the cursor on a line's last character
--- outside Insert and Visual mode, so a position past it (an empty line's
--- column 0 aside) is pulled back the same way. Code that measures from
--- positions instead of moving the cursor uses this to see the same
--- position a cursor move would have read back.
---
---@param row integer
---@param column integer
---@return integer, integer
function M.clamp(row, column)
    local line = codepoint.line(row)

    if column < #line then
        return row, column
    end

    if #line == 0 then
        return row, 0
    end

    return row, codepoint.last_character_column(row, #line)
end

--- Check whether `row_a`/`column_a` comes before `row_b`/`column_b`.
---
---@param row_a integer
---@param column_a integer
---@param row_b integer
---@param column_b integer
---@return boolean
---
function M.is_before(row_a, column_a, row_b, column_b)
    return row_a < row_b or (row_a == row_b and column_a < column_b)
end

--- The earlier of two positions.
---
---@param row_a integer
---@param column_a integer
---@param row_b integer
---@param column_b integer
---@return integer, integer
---
function M.min(row_a, column_a, row_b, column_b)
    if M.is_before(row_a, column_a, row_b, column_b) then
        return row_a, column_a
    end

    return row_b, column_b
end

--- The later of two positions.
---
---@param row_a integer
---@param column_a integer
---@param row_b integer
---@param column_b integer
---@return integer, integer
---
function M.max(row_a, column_a, row_b, column_b)
    if M.is_before(row_a, column_a, row_b, column_b) then
        return row_b, column_b
    end

    return row_a, column_a
end

--- Check whether `row`/`column` falls within `node`'s range (its end is exclusive).
---
---@param node TSNode|treemotion.MotionUnit Anything with `:start()`/`:end_()`.
---@param row integer
---@param column integer
---@return boolean
---
function M.contains(node, row, column)
    local start_row, start_column = node:start()
    local end_row, end_column = node:end_()

    return not M.is_before(row, column, start_row, start_column) and M.is_before(row, column, end_row, end_column)
end

return M
