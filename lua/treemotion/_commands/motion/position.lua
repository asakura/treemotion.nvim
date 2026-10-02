--- Positions are a 0-indexed row and byte column, as in `TSNode:start()`.

local codepoint = require("treemotion._commands.motion.codepoint")

local M = {}

---@return integer, integer
function M.cursor_position()
    local cursor = vim.api.nvim_win_get_cursor(0)

    return cursor[1] - 1, cursor[2]
end

--- Pull a position past a line's last character back onto it, as
--- `nvim_win_set_cursor` does outside Insert and Visual mode.
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

---@param row_a integer
---@param column_a integer
---@param row_b integer
---@param column_b integer
---@return boolean
---
function M.is_before(row_a, column_a, row_b, column_b)
    return row_a < row_b or (row_a == row_b and column_a < column_b)
end

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

--- Whether `row`/`column` is inside `node`'s range (end exclusive).
---
---@param node TSNode|treemotion.MotionUnit
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
