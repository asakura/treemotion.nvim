--- Shared sub-word unit traversal behind `_commands.motion.word` and `_commands.motion.bigword`.
---
--- Both modules step through `treemotion.SubwordUnit` slices of some
--- *span* of treesitter leaves -- a single leaf for `w`/`e`/`b`/`ge`, a
--- whole run of contiguous leaves for `W`/`E`/`B`/`gE` -- and the stepping
--- itself is identical: pick the slice under the cursor, bump an index
--- while the span still has slices left, and only once it runs out reach
--- for the neighboring span. The only thing that differs is how a span is
--- found and split, and how to get past one, so `M.new_source` takes
--- exactly those as callbacks and builds the `current_unit`/`next_unit`/
--- `previous_unit` API (see `treemotion._UnitSource` in
--- `_commands.motion.runner`) on top of them.
---
--- A `treemotion.MotionUnit` deliberately stores the *whole* sub-word
--- split of its span (`_units`) plus an `_index` into it, rather than just
--- one `treemotion.SubwordUnit` -- that's what lets stepping between
--- sub-words inside the same span be a cheap index bump, only falling back
--- to `_commands.motion.leaf` (and re-splitting) once a span's units run out.

local logging = require("mega.logging")

local leaf = require("treemotion._commands.motion.leaf")
local position = require("treemotion._commands.motion.position")

local M = {}

--- One sub-word slice of a span, plus enough context to step to its neighbors.
---
--- Fields aren't `private` (unlike `treemotion.SubwordUnit`'s) because
--- `next_unit`/`previous_unit`/`_index_at` read them from outside
--- `_Unit`'s own methods -- they're plain functions, not methods on this class.
---@class treemotion.MotionUnit
---@field _leaf TSNode The span's first leaf, which `_units` was split from.
---@field _units treemotion.SubwordUnit[] Every sub-word slice of the span, in document order.
---@field _index integer Which of `_units` this `treemotion.MotionUnit` currently wraps.
local _Unit = {}
_Unit.__index = _Unit

--- This unit's first character (delegates to the wrapped `treemotion.SubwordUnit`).
---@return integer, integer
function _Unit:start()
    return self._units[self._index]:start()
end

--- This unit's last character, exclusive (delegates to the wrapped `treemotion.SubwordUnit`).
---@return integer, integer
function _Unit:end_()
    return self._units[self._index]:end_()
end

--- Build a `treemotion.MotionUnit` wrapping `units[index]`.
---
---@param node TSNode The span's first leaf `units` were split from.
---@param units treemotion.SubwordUnit[] The span's sub-word units.
---@param index integer Which of `units` this `treemotion.MotionUnit` wraps.
---@return treemotion.MotionUnit
local function _new_unit(node, units, index)
    return setmetatable({ _leaf = node, _units = units, _index = index }, _Unit)
end

--- Find which of `units` contains (or is the closest unit in `forward`'s
--- direction to) `row`/`column`.
---
--- Sub-word slices aren't real tree nodes, so there's no `vim.treesitter.get_node()`
--- equivalent to ask "which one is the cursor on" -- this does the same job
--- by hand, scanning in document order for the first unit whose end lands
--- after the cursor. When the cursor sits genuinely inside a unit, that unit
--- wins regardless of direction; when it sits in a *gap* between two units
--- (e.g. the blank column between two words, once `w`/`ge`'s "already
--- inside" check falls through to here), `forward` decides which side of
--- the gap to prefer -- the unit after it (matching the old, direction-blind
--- behavior) or the one before it, so `b`/`ge` retreat instead of
--- overshooting forward. Falling off the end (cursor past every unit)
--- returns the last unit rather than nothing, since the caller always needs
--- a concrete unit to treat as "current."
---
---@param units treemotion.SubwordUnit[] A span's sub-word units, in document order.
---@param row integer 0-indexed cursor row.
---@param column integer 0-indexed cursor column.
---@param forward boolean Which side of a gap between two units to prefer.
---@return integer # The 1-indexed unit to treat as "under the cursor".
---
local function _index_at(units, row, column, forward)
    for index, unit in ipairs(units) do
        local start_row, start_column = unit:start()
        local end_row, end_column = unit:end_()

        local before_end = end_row > row or (end_row == row and end_column > column)

        if before_end then
            local after_start = start_row < row or (start_row == row and start_column <= column)

            if after_start then
                return index -- cursor is genuinely inside this unit
            end

            if forward or index == 1 then
                return index -- gap before this unit: prefer it (forward), or it's all there is
            end

            return index - 1 -- gap before this unit: prefer the one before the gap
        end
    end

    return #units
end

--- How `M.new_source` finds and steps past spans.
---
---@class treemotion._UnitSpans
---@field logger string The `mega.logging` logger name to report results under.
---@field first_nonempty fun(node: TSNode?, forward: boolean): TSNode?, treemotion.SubwordUnit[]?
---    Starting at `node`'s span, search in `forward`'s direction for the first
---    span with any units. Returns that span's first leaf and its units --
---    both `nil` if none remain.
---@field after fun(node: TSNode): TSNode? Given a span's first leaf, the leaf right after the span.
---@field span_end fun(node: TSNode): integer, integer Where the span containing the leaf `node`
---    ends (exclusive): `node`'s own end for a one-leaf span, its run's end for a run.

--- Build a `treemotion._UnitSource` stepping through the spans `spans` describes.
---
---@param spans treemotion._UnitSpans
---@return treemotion._UnitSource
---
function M.new_source(spans)
    local logger = logging.get_logger(spans.logger)

    --- Log `name`'s result at debug level, so a step's outcome (or lack of
    --- one) is reported the same way no matter which function produced it.
    ---
    ---@param name string The function's name (plus any arguments worth reporting), for the log message.
    ---@param unit treemotion.MotionUnit? The result to report.
    ---@return treemotion.MotionUnit? # `unit`, unchanged.
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

    --- Find the sub-word unit under the cursor.
    ---
    --- Finds the leaf under the cursor (`leaf.current_leaf()`), finds the
    --- first nonempty span from there (`spans.first_nonempty`), then picks
    --- out the right slice with `_index_at`. Everything gets recomputed from
    --- scratch here, unlike `next_unit`/`previous_unit`, since there's no
    --- previous unit to step from yet.
    ---
    ---@param forward boolean Forwarded to `leaf.current_leaf()`: which nearby
    ---    leaf to prefer off a leaf (e.g. blank line); also which direction to
    ---    skip empty spans in.
    ---@return treemotion.MotionUnit? # The unit under (or nearest) the cursor, if a parser and a leaf exist that way.
    function source.current_unit(forward)
        local name = string.format("current_unit(forward=%s)", forward)
        local node, units = spans.first_nonempty(leaf.current_leaf(forward), forward)

        if not node then
            return _log(name, nil)
        end

        -- `units` is only `nil` when `node` is (see `spans.first_nonempty`),
        -- but the type checker can't correlate two separate return values --
        -- `assert` narrows it back to non-optional for `_new_unit`/`_index_at`.
        units = assert(units)

        local row, column = position.cursor_position()

        return _log(name, _new_unit(node, units, _index_at(units, row, column, forward)))
    end

    --- Find the sub-word unit directly after `unit`, in document order.
    ---
    --- If `unit`'s span still has slices left, this is just an `_index` bump
    --- -- no treesitter or splitting work at all. Only once `unit` is the
    --- last slice of its span does this step past it (`spans.after`) and
    --- re-split whatever span it finds there, landing on its *first* slice.
    ---
    ---@param unit treemotion.MotionUnit
    ---@return treemotion.MotionUnit? # The next sub-word unit, if `unit` isn't the last in the tree.
    function source.next_unit(unit)
        local name = string.format("next_unit(unit %s/%s)", unit._index, #unit._units)

        if unit._index < #unit._units then
            return _log(name, _new_unit(unit._leaf, unit._units, unit._index + 1))
        end

        local node, units = spans.first_nonempty(spans.after(unit._leaf), true)

        if not node then
            return _log(name, nil)
        end

        return _log(name, _new_unit(node, assert(units), 1))
    end

    --- Find the sub-word unit directly before `unit`, in document order.
    ---
    --- Mirror image of `next_unit`: decrements `_index` while slices remain,
    --- otherwise reaches for `leaf.previous_leaf(unit._leaf)` -- `unit._leaf`
    --- is already the span's first leaf, so that's the leaf right before the
    --- span -- re-splits whatever span it finds there, and lands on its
    --- *last* slice.
    ---
    ---@param unit treemotion.MotionUnit
    ---@return treemotion.MotionUnit? # The previous sub-word unit, if `unit` isn't the first in the tree.
    function source.previous_unit(unit)
        local name = string.format("previous_unit(unit %s/%s)", unit._index, #unit._units)

        if unit._index > 1 then
            return _log(name, _new_unit(unit._leaf, unit._units, unit._index - 1))
        end

        local node, units = spans.first_nonempty(leaf.previous_leaf(unit._leaf), false)

        if not node then
            return _log(name, nil)
        end

        units = assert(units)

        return _log(name, _new_unit(node, units, #units))
    end

    --- Where the span containing the leaf `node` ends (exclusive).
    ---
    --- Operator-pending motions use this to tell text inside the current
    --- token from text between tokens (see `_commands.motion.operator`).
    ---
    ---@param node TSNode Any leaf, e.g. a `treemotion.MotionUnit`'s `_leaf`.
    ---@return integer, integer
    function source.span_end(node)
        return spans.span_end(node)
    end

    return source
end

return M
