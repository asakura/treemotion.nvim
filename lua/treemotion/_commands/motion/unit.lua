--- Step through the sub-word units of spans: one leaf for `w`, one run of
--- contiguous leaves for `W`.
---
--- A unit keeps its span's whole split plus an index, so stepping inside a
--- span is an index bump and only crossing spans touches the tree.

local classify = require("treemotion._commands.motion.classify")
local leaf = require("treemotion._commands.motion.leaf")
local subword = require("treemotion._commands.motion.subword")

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

            if after_start or forward or index == 1 then
                return index
            end

            return index - 1
        end
    end

    return #units
end

---@class treemotion._UnitSource
---@field unit_at fun(row: integer, column: integer, forward: boolean): treemotion.MotionUnit?, TSNode?
---    The unit at or nearest a position, and the leaf the search started
---    from, which may have no units.
---@field next_unit fun(unit: treemotion.MotionUnit): treemotion.MotionUnit?
---@field previous_unit fun(unit: treemotion.MotionUnit): treemotion.MotionUnit?
---@field span_end fun(node: TSNode): integer, integer Where the span containing the leaf `node` ends.

---@class treemotion._UnitSpans
---@field first_nonempty fun(node: TSNode?, forward: boolean): TSNode?, treemotion.SubwordUnit[]?
---    From `node`'s span, the first span in `forward`'s direction with units:
---    its first leaf and its units.
---@field after fun(node: TSNode): TSNode? The leaf after the span starting at `node`.
---@field span_end fun(node: TSNode): integer, integer Where the span containing `node` ends.

---@param spans treemotion._UnitSpans
---@return treemotion._UnitSource
---
local function _new_source(spans)
    local source = {}

    function source.unit_at(row, column, forward)
        local start_leaf = leaf.leaf_at(row, column, forward)
        local node, units = spans.first_nonempty(start_leaf, forward)

        if not node then
            return nil, start_leaf
        end

        units = assert(units)

        return _new_unit(node, units, _index_at(units, row, column, forward), spans.span_end), start_leaf
    end

    function source.next_unit(unit)
        if unit._index < #unit._units then
            return _new_unit(unit._leaf, unit._units, unit._index + 1, spans.span_end)
        end

        local node, units = spans.first_nonempty(spans.after(unit._leaf), true)

        if not node then
            return nil
        end

        return _new_unit(node, assert(units), 1, spans.span_end)
    end

    function source.previous_unit(unit)
        if unit._index > 1 then
            return _new_unit(unit._leaf, unit._units, unit._index - 1, spans.span_end)
        end

        local node, units = spans.first_nonempty(leaf.previous_leaf(unit._leaf), false)

        if not node then
            return nil
        end

        units = assert(units)

        return _new_unit(node, units, #units, spans.span_end)
    end

    source.span_end = spans.span_end

    return source
end

---@param node TSNode
---@return integer, integer
local function _leaf_end(node)
    local row, column = node:end_()

    return row, column
end

--- `w`/`e`/`b`/`ge` units: the sub-words of each leaf.
---
---@param settings treemotion.SplitSettings
---@return treemotion._UnitSource
---
function M.word(settings)
    return _new_source({
        first_nonempty = function(node, forward)
            local step = forward and leaf.next_leaf or leaf.previous_leaf

            while node do
                local units = subword.split(node, settings)

                if #units > 0 then
                    return node, units
                end

                node = step(node)
            end

            return nil, nil
        end,
        after = leaf.next_leaf,
        span_end = _leaf_end,
    })
end

---@param first TSNode
---@param second TSNode
---@return boolean
local function _is_contiguous(first, second)
    local end_row, end_column = first:end_()
    local start_row, start_column = second:start()

    return end_row == start_row and end_column == start_column
end

---@param node TSNode
---@return TSNode # The first leaf of `node`'s run.
local function _run_start(node)
    while true do
        local previous = leaf.previous_leaf(node)

        if not previous or not _is_contiguous(previous, node) then
            return node
        end

        node = previous
    end
end

---@param node TSNode
---@return TSNode # The last leaf of `node`'s run.
local function _run_end(node)
    while true do
        local next_ = leaf.next_leaf(node)

        if not next_ or not _is_contiguous(node, next_) then
            return node
        end

        node = next_
    end
end

---@param run_start TSNode
---@param run_end TSNode
---@param characters string[]?
---@return boolean
local function _run_is_insignificant(run_start, run_end, characters)
    local node = run_start

    while true do
        if not classify.is_insignificant(node, characters) then
            return false
        end

        if node:equal(run_end) then
            return true
        end

        node = assert(leaf.next_leaf(node))
    end
end

--- `W`/`E`/`B`/`gE` units: the sub-words of each run of contiguous leaves,
--- skipping runs that are entirely insignificant.
---
---@param settings treemotion.SplitSettings
---@return treemotion._UnitSource
---
function M.bigword(settings)
    return _new_source({
        first_nonempty = function(node, forward)
            while node do
                local run_start = _run_start(node)
                local run_end = _run_end(node)

                if not _run_is_insignificant(run_start, run_end, settings.insignificant_characters) then
                    local units = subword.split_run(run_start, run_end, settings)

                    if #units > 0 then
                        return run_start, units
                    end
                end

                node = forward and leaf.next_leaf(run_end) or leaf.previous_leaf(run_start)
            end

            return nil, nil
        end,
        after = function(run_start)
            return leaf.next_leaf(_run_end(run_start))
        end,
        span_end = function(node)
            return _leaf_end(_run_end(node))
        end,
    })
end

return M
