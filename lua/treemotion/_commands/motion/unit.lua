--- Step through the sub-word units of spans: one leaf for `w`, one run for `W`.
---
--- A unit keeps its span's whole split plus an index, so stepping inside a
--- span is an index bump and only crossing spans touches the tree.

local logging = require("mega.logging")

local leaf = require("treemotion._commands.motion.leaf")

local M = {}

---@class treemotion.MotionUnit
---@field _leaf TSNode The span's first leaf.
---@field _units treemotion.SubwordUnit[] The span's units, in document order.
---@field _index integer Which of `_units` this is.
---@field _span_end fun(node: TSNode): integer, integer
local _Unit = {}
_Unit.__index = _Unit

---@return integer, integer
function _Unit:start()
    return self._units[self._index]:start()
end

--- Exclusive.
---@return integer, integer
function _Unit:end_()
    return self._units[self._index]:end_()
end

--- Where this unit's span ends, exclusive.
---@return integer, integer
function _Unit:span_end()
    return self._span_end(self._leaf)
end

---@param node TSNode
---@param units treemotion.SubwordUnit[]
---@param index integer
---@param span_end fun(node: TSNode): integer, integer
---@return treemotion.MotionUnit
local function _new_unit(node, units, index, span_end)
    return setmetatable({ _leaf = node, _units = units, _index = index, _span_end = span_end }, _Unit)
end

--- The index of the unit containing `row`/`column`. In a gap between units,
--- prefer the next one when `forward`, else the previous one. Past every
--- unit, the last one.
---
---@param units treemotion.SubwordUnit[]
---@param row integer
---@param column integer
---@param forward boolean
---@return integer
---
local function _index_at(units, row, column, forward)
    for index, unit in ipairs(units) do
        local start_row, start_column = unit:start()
        local end_row, end_column = unit:end_()

        local before_end = end_row > row or (end_row == row and end_column > column)

        if before_end then
            local after_start = start_row < row or (start_row == row and start_column <= column)

            if after_start then
                return index
            end

            if forward or index == 1 then
                return index
            end

            return index - 1
        end
    end

    return #units
end

---@class treemotion._UnitSpans
---@field logger string
---@field first_nonempty fun(node: TSNode?, forward: boolean): TSNode?, treemotion.SubwordUnit[]?
---    From `node`'s span, the first span in `forward`'s direction with units:
---    its first leaf and its units.
---@field after fun(node: TSNode): TSNode? The leaf after the span starting at `node`.
---@field span_end fun(node: TSNode): integer, integer Where the span containing `node` ends.

---@param spans treemotion._UnitSpans
---@return treemotion._UnitSource
---
function M.new_source(spans)
    local logger = logging.get_logger(spans.logger)

    ---@param name string
    ---@param unit treemotion.MotionUnit?
    ---@return treemotion.MotionUnit?
    ---
    local function _log(name, unit)
        if not unit then
            logger:fmt_debug("%s -> nil.", name)

            return nil
        end

        local row, column = unit:start()

        logger:fmt_debug("%s -> unit %s/%s at %s:%s.", name, unit._index, #unit._units, row, column)

        return unit
    end

    local source = {}

    ---@param row integer
    ---@param column integer
    ---@param forward boolean Which way to look from a position with no leaf.
    ---@return treemotion.MotionUnit? # The unit at or nearest the position.
    ---@return TSNode? # The leaf the search started from, which may have no units.
    function source.unit_at(row, column, forward)
        local name = string.format("unit_at(%s:%s, forward=%s)", row, column, forward)
        local start_leaf = leaf.leaf_at(row, column, forward)
        local node, units = spans.first_nonempty(start_leaf, forward)

        if not node then
            return _log(name, nil), start_leaf
        end

        units = assert(units)

        return _log(name, _new_unit(node, units, _index_at(units, row, column, forward), spans.span_end)), start_leaf
    end

    ---@param unit treemotion.MotionUnit
    ---@return treemotion.MotionUnit?
    function source.next_unit(unit)
        local name = string.format("next_unit(unit %s/%s)", unit._index, #unit._units)

        if unit._index < #unit._units then
            return _log(name, _new_unit(unit._leaf, unit._units, unit._index + 1, spans.span_end))
        end

        local node, units = spans.first_nonempty(spans.after(unit._leaf), true)

        if not node then
            return _log(name, nil)
        end

        return _log(name, _new_unit(node, assert(units), 1, spans.span_end))
    end

    ---@param unit treemotion.MotionUnit
    ---@return treemotion.MotionUnit?
    function source.previous_unit(unit)
        local name = string.format("previous_unit(unit %s/%s)", unit._index, #unit._units)

        if unit._index > 1 then
            return _log(name, _new_unit(unit._leaf, unit._units, unit._index - 1, spans.span_end))
        end

        local node, units = spans.first_nonempty(leaf.previous_leaf(unit._leaf), false)

        if not node then
            return _log(name, nil)
        end

        units = assert(units)

        return _log(name, _new_unit(node, units, #units, spans.span_end))
    end

    --- Where the span containing the leaf `node` ends, exclusive.
    ---
    ---@param node TSNode
    ---@return integer, integer
    function source.span_end(node)
        return spans.span_end(node)
    end

    return source
end

return M
