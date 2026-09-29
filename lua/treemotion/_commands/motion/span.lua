--- Coordinate ranges for sub-word slices, and the offset -> buffer-position
--- arithmetic `_commands.motion.subword` needs to build them.
---
--- A `treemotion.SubwordUnit` is deliberately dumber than a `TSNode`: just
--- the four numbers that bound it, no parent/child/sibling links -- a
--- sub-word slice isn't a real tree node, it's a range `subword.split`
--- invents on top of one. Exposing the same `:start()`/`:end_()` shape a
--- `TSNode` has is what lets `_commands.motion.shape` treat this and a
--- `TSNode` interchangeably (see its `TSNode|treemotion.MotionUnit` params,
--- and `_commands.motion.unit`, which wraps these).

local M = {}

--- A coordinate range identifying one sub-word slice of a leaf's text.
---@class treemotion.SubwordUnit
---@field private _start_row integer
---@field private _start_col integer
---@field private _end_row integer
---@field private _end_col integer
local _Span = {}
_Span.__index = _Span

--- This unit's first character.
---@return integer, integer
function _Span:start()
    return self._start_row, self._start_col
end

--- This unit's last character, exclusive (one column past the end, matching `TSNode:end_()`).
---@return integer, integer
function _Span:end_()
    return self._end_row, self._end_col
end

--- Build a `treemotion.SubwordUnit` from raw coordinates.
---
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

--- The buffer row/column one past `text`'s last character, given `text`'s
--- own first character sits at `start_row`/`start_col`.
---
--- Counts `text`'s newlines and the bytes after its last one, rather than
--- walking it offset by offset.
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

--- Build a function mapping a 1-indexed offset into `text` (up to and
--- including `#text + 1`, one past its last character) to the buffer
--- row/column it corresponds to, given `text`'s own first character sits at
--- `start_row`/`start_col`.
---
--- Flat column arithmetic (`start_col + offset - 1`) is only valid for
--- single-row `text` -- a `\n` anywhere in `text` resets the real buffer
--- column back to `0`. This is what lets a multi-row *prose* leaf (a
--- hard/soft-wrapped markdown paragraph, confirmed against Neovim's own
--- bundled `markdown_inline` grammar: a whole paragraph parses as one leaf
--- with no per-word node of its own) still get split word-by-word across
--- every line it spans.
---
--- Single-row `text` -- the overwhelming majority: every code leaf, and
--- every prose leaf/run that doesn't wrap -- gets the plain arithmetic and
--- allocates nothing. Multi-row `text` records where each of its lines
--- starts (one entry per `\n`, not per byte) and binary-searches it.
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

    ---@type integer[] 1-indexed offset of each line's first character; `line_starts[1]` is `text`'s start row.
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
