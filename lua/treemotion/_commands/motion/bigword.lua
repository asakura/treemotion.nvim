--- Sub-word-aware unit traversal for `W`/`E`/`B`/`gE`.
---
--- Mirrors `_commands.motion.word` one level coarser: where `word.lua` steps
--- through case-convention sub-words *inside* a single treesitter leaf,
--- this steps through them inside a whole *run* of contiguous leaves (see
--- `_commands.motion.leaf`'s module docstring for what a "run" is). By
--- default (`commands.motion.big.enabled = false`) a run is always exactly
--- one stop, ignoring case/delimiters entirely -- the same way real Vim's
--- `W` ignores punctuation inside a WORD; `subword.split_run()` is what
--- decides that, this module only adds the "next"/"previous" traversal on
--- top of whatever it returns.
---
--- A `treemotion.BigWordUnit` deliberately stores the *whole* sub-word split
--- of its run (`_units`) plus an `_index` into it, rather than just one
--- `treemotion.SubwordUnit` -- exactly like `treemotion.WordUnit` does for a
--- single leaf -- so stepping between sub-words inside the same run is a
--- cheap index bump, only falling back to `_commands.motion.leaf` (and
--- re-deriving/re-splitting the next run) once a run's units run out.
--- `_leaf` holds the run's *start* leaf specifically (not just any leaf in
--- it), since that's what `leaf.run_end`/`leaf.previous_leaf` need to
--- re-derive the run's bounds when stepping past it.

local logging = require("mega.logging")

local leaf = require("treemotion._commands.motion.leaf")
local subword = require("treemotion._commands.motion.subword")

local _LOGGER = logging.get_logger("treemotion._commands.motion.bigword")

local M = {}

--- Log `name`'s result at debug level -- shared by `M.current_unit`/
--- `M.next_unit`/`M.previous_unit` below, mirroring `_commands.motion.word`'s
--- identical helper one level coarser.
---
---@param name string The wrapped function's name (plus any arguments worth reporting), for the log message.
---@param unit treemotion.BigWordUnit? The result to report.
---
local function _log_unit_result(name, unit)
    if not unit then
        _LOGGER:fmt_debug("%s -> nil.", name)

        return
    end

    local row, column = unit:start()

    _LOGGER:fmt_debug("%s -> unit %s/%s at %s:%s.", name, unit._index, #unit._units, row, column)
end

--- One sub-word slice of a run, plus enough context to step to its neighbors.
---
--- Fields aren't `private` (unlike `treemotion.SubwordUnit`'s), same reason
--- as `treemotion.WordUnit`'s -- `M.next_unit`/`M.previous_unit`/`_index_at`
--- read them from outside `_Unit`'s own methods.
---@class treemotion.BigWordUnit
---@field _leaf TSNode The run's start leaf (`leaf.run_start(...)`) `_units` was split from.
---@field _units treemotion.SubwordUnit[] Every sub-word slice of the run, in document order.
---@field _index integer Which of `_units` this `treemotion.BigWordUnit` currently wraps.
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

--- Build a `treemotion.BigWordUnit` wrapping `units[index]`.
---
---@param run_start TSNode The run's start leaf `units` were split from.
---@param units treemotion.SubwordUnit[] The run's sub-word units (see `subword.split_run()`).
---@param index integer Which of `units` this `treemotion.BigWordUnit` wraps.
---@return treemotion.BigWordUnit
local function _new_unit(run_start, units, index)
    return setmetatable({ _leaf = run_start, _units = units, _index = index }, _Unit)
end

--- Find which of `units` contains (or is the closest unit at-or-after) `row`/`column`.
---
--- Identical in shape to `word.lua`'s own `_index_at` -- see its docstring.
---
---@param units treemotion.SubwordUnit[] A run's sub-word units, in document order.
---@param row integer 0-indexed cursor row.
---@param column integer 0-indexed cursor column.
---@return integer # The 1-indexed unit to treat as "under the cursor".
---
local function _index_at(units, row, column)
    for index, unit in ipairs(units) do
        local end_row, end_column = unit:end_()

        if end_row > row or (end_row == row and end_column > column) then
            return index
        end
    end

    return #units
end

--- Walk from `node` in `forward`'s direction until finding a leaf whose
--- *run* `subword.split_run()` actually produces units for.
---
--- Steps a whole run at a time, not one leaf at a time (unlike `word.lua`'s
--- `_first_nonempty_split`): once a run turns out empty (an
--- `commands.motion.big.enabled = true` run that's entirely a dropped
--- `"skip"` delimiter run, see `subword.split_run`'s docstring), the next
--- candidate is the leaf right after (or before) that *whole* run --
--- `leaf.next_leaf(run_end)`/`leaf.previous_leaf(run_start)` -- not just the
--- next leaf inside it, since every leaf inside the same run would
--- re-derive the exact same (empty) run again.
---
---@param node TSNode? Where to start looking.
---@param forward boolean Search after `node` (`leaf.next_leaf` off each empty run's end) or
---    before it (`leaf.previous_leaf` off each empty run's start).
---@return TSNode?, treemotion.SubwordUnit[]? # The first nonempty run's
---    *start* leaf, and its units -- both `nil` if none remain.
---
local function _first_nonempty_split(node, forward)
    while node do
        local run_start = leaf.run_start(node)
        local run_end = leaf.run_end(node)
        local units = subword.split_run(run_start, run_end)

        if #units > 0 then
            return run_start, units
        end

        node = forward and leaf.next_leaf(run_end) or leaf.previous_leaf(run_start)
    end

    return nil, nil
end

--- Find the sub-word unit under the cursor.
---
--- Finds the leaf under the cursor (`leaf.current_leaf()`), derives its run
--- and splits it (`subword.split_run()`, skipping past any empty run via
--- `_first_nonempty_split`), then picks out the right slice with
--- `_index_at`. Everything gets recomputed from scratch here, unlike
--- `next_unit`/`previous_unit`, since there's no previous
--- `treemotion.BigWordUnit` to step from yet.
---
---@param forward boolean Forwarded to `leaf.current_leaf()`: which nearby
---    leaf to prefer off a leaf (e.g. blank line); also which direction to
---    skip empty runs in.
---@return treemotion.BigWordUnit? # The unit under (or nearest) the cursor, if a parser and a leaf exist that way.
function M.current_unit(forward)
    local run_start, units = _first_nonempty_split(leaf.current_leaf(forward), forward)

    if not run_start then
        _log_unit_result(string.format("current_unit(forward=%s)", forward), nil)

        return nil
    end

    -- `units` is only `nil` when `run_start` is (see `_first_nonempty_split`),
    -- but the type checker can't correlate two separate return values --
    -- `assert` narrows it back to non-optional for `_new_unit`/`_index_at`.
    units = assert(units)

    local row, column = leaf.cursor_position()

    local unit = _new_unit(run_start, units, _index_at(units, row, column))

    _log_unit_result(string.format("current_unit(forward=%s)", forward), unit)

    return unit
end

--- Find the sub-word unit directly after `unit`, in document order.
---
--- If `unit`'s run still has slices left, this is just an `_index` bump --
--- no treesitter or splitting work at all. Only once `unit` is the last
--- slice of its run does this reach past the run's own end
--- (`leaf.run_end(unit._leaf)`, then `leaf.next_leaf`) and re-derive/re-split
--- whatever run it finds there (skipping any empty ones, see
--- `_first_nonempty_split`), landing on that run's *first* slice.
---
---@param unit treemotion.BigWordUnit
---@return treemotion.BigWordUnit? # The next sub-word unit, if `unit` isn't the last in the tree.
function M.next_unit(unit)
    local name = string.format("next_unit(unit %s/%s)", unit._index, #unit._units)

    if unit._index < #unit._units then
        local result = _new_unit(unit._leaf, unit._units, unit._index + 1)

        _log_unit_result(name, result)

        return result
    end

    local run_start, units = _first_nonempty_split(leaf.next_leaf(leaf.run_end(unit._leaf)), true)

    if not run_start then
        _log_unit_result(name, nil)

        return nil
    end

    local result = _new_unit(run_start, assert(units), 1)

    _log_unit_result(name, result)

    return result
end

--- Find the sub-word unit directly before `unit`, in document order.
---
--- Mirror image of `next_unit`: decrements `_index` while slices remain,
--- otherwise reaches for `leaf.previous_leaf(unit._leaf)` -- `unit._leaf` is
--- already the run's *start* leaf, so no `leaf.run_start` call is needed
--- first, unlike `next_unit`'s `leaf.run_end` -- re-derives/re-splits
--- whatever run it finds there (skipping any empty ones), and lands on that
--- run's *last* slice.
---
---@param unit treemotion.BigWordUnit
---@return treemotion.BigWordUnit? # The previous sub-word unit, if `unit` isn't the first in the tree.
function M.previous_unit(unit)
    local name = string.format("previous_unit(unit %s/%s)", unit._index, #unit._units)

    if unit._index > 1 then
        local result = _new_unit(unit._leaf, unit._units, unit._index - 1)

        _log_unit_result(name, result)

        return result
    end

    local run_start, units = _first_nonempty_split(leaf.previous_leaf(unit._leaf), false)

    if not run_start then
        _log_unit_result(name, nil)

        return nil
    end

    units = assert(units)

    local result = _new_unit(run_start, units, #units)

    _log_unit_result(name, result)

    return result
end

return M
