--- Cursor-position and position-comparison helpers shared by the motion modules.
---
--- A position is a 0-indexed row and a 0-indexed byte column, the
--- convention `TSNode:start()`/`:end_()` use.

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
