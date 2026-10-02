--- Sub-word ranges with the same `:start()`/`:end_()` shape as `TSNode`.

local M = {}

--- One sub-word slice of a leaf's text.
---@class treemotion.SubwordUnit
---@field private _start_row integer
---@field private _start_col integer
---@field private _end_row integer
---@field private _end_col integer
local _Span = {}
_Span.__index = _Span

---@return integer, integer
function _Span:start()
    return self._start_row, self._start_col
end

--- Exclusive, like `TSNode:end_()`.
---@return integer, integer
function _Span:end_()
    return self._end_row, self._end_col
end

---@param start_row integer
---@param start_col integer
---@param end_row integer
---@param end_col integer
---@return treemotion.SubwordUnit
---
function M.new(start_row, start_col, end_row, end_col)
    return setmetatable(
        { _start_row = start_row, _start_col = start_col, _end_row = end_row, _end_col = end_col },
        _Span
    )
end

--- The position one past `text`'s end, when `text` starts at `start_row`/`start_col`.
---
---@param start_row integer
---@param start_col integer
---@param text string
---@return integer, integer
---
function M.end_position(start_row, start_col, text)
    local last_newline = text:match(".*()\n")

    if not last_newline then
        return start_row, start_col + #text
    end

    local _, newlines = text:gsub("\n", "")

    return start_row + newlines, #text - last_newline
end

--- Map a 1-indexed offset into `text` (up to `#text + 1`) to a buffer position,
--- when `text` starts at `start_row`/`start_col`. Multi-line `text` is
--- binary-searched by line start; single-line `text` allocates nothing.
---
---@param start_row integer
---@param start_col integer
---@param text string
---@return fun(offset: integer): integer, integer
---
function M.position_mapper(start_row, start_col, text)
    if not text:find("\n") then
        return function(offset)
            return start_row, start_col + offset - 1
        end
    end

    ---@type integer[] 1-indexed offset of each line's first character.
    local line_starts = { 1 }

    for newline in text:gmatch("()\n") do
        table.insert(line_starts, newline + 1)
    end

    return function(offset)
        local low, high = 1, #line_starts

        while low < high do
            local middle = math.floor((low + high + 1) / 2)

            if line_starts[middle] <= offset then
                low = middle
            else
                high = middle - 1
            end
        end

        if low == 1 then
            return start_row, start_col + offset - 1
        end

        return start_row + low - 1, offset - line_starts[low]
    end
end

return M
