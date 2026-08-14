--- Sub-word-aware unit traversal for `w`/`e`/`b`/`ge`.
---
--- Unlike `W`/`E`/`B`/`gE` (which move by whole treesitter leaves/runs, see
--- `_commands.motion.leaf`), `w`/`e`/`b`/`ge` additionally step through
--- case-convention sub-words *inside* a single leaf (e.g. `fooBar` is two
--- units, `foo` and `Bar`) per `_commands.motion.subword`'s splitting rules.
---
--- This module is the traversal counterpart to `_commands.motion.subword`:
--- `subword.split()` only knows how to slice *one* leaf's text into ranges,
--- it has no notion of "next"/"previous" or of crossing into another leaf --
--- that's what `M.next_unit`/`M.previous_unit` add here, mirroring
--- `_commands.motion.leaf`'s `next_leaf`/`previous_leaf` one level finer.
--- A `treemotion.WordUnit` deliberately stores the *whole* sub-word split of
--- its leaf (`_units`) plus an `_index` into it, rather than just one
--- `treemotion.SubwordUnit` -- that's what lets stepping between sub-words
--- inside the same leaf be a cheap index bump, only falling back to
--- `_commands.motion.leaf` (and re-splitting) once a leaf's units run out.

local logging = require("mega.logging")

local leaf = require("treemotion._commands.motion.leaf")
local subword = require("treemotion._commands.motion.subword")

local _LOGGER = logging.get_logger("treemotion._commands.motion.word")

local M = {}

--- Log `name`'s result at debug level -- shared by `M.current_unit`/
--- `M.next_unit`/`M.previous_unit` below, so a sub-word step's outcome (or
--- lack of one) is reported the same way no matter which of them produced it.
---
---@param name string The wrapped function's name (plus any arguments worth reporting), for the log message.
---@param unit treemotion.WordUnit? The result to report.
---
local function _log_unit_result(name, unit)
    if not unit then
        _LOGGER:fmt_debug("%s -> nil.", name)

        return
    end

    local row, column = unit:start()

    _LOGGER:fmt_debug("%s -> unit %s/%s at %s:%s.", name, unit._index, #unit._units, row, column)
end

--- One sub-word slice of a leaf, plus enough context to step to its neighbors.
---
--- Fields aren't `private` (unlike `treemotion.SubwordUnit`'s) because
--- `M.next_unit`/`M.previous_unit`/`_index_at` read them from outside
--- `_Unit`'s own methods -- they're plain module-level functions, not
--- methods on this class.
---@class treemotion.WordUnit
---@field _leaf TSNode The leaf `_units` was split from.
---@field _units treemotion.SubwordUnit[] Every sub-word slice of `_leaf`, in document order.
---@field _index integer Which of `_units` this `treemotion.WordUnit` currently wraps.
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

--- Build a `treemotion.WordUnit` wrapping `units[index]`.
---
---@param node TSNode The leaf `units` were split from.
---@param units treemotion.SubwordUnit[] `node`'s sub-word units (see `subword.split()`).
---@param index integer Which of `units` this `treemotion.WordUnit` wraps.
---@return treemotion.WordUnit
local function _new_unit(node, units, index)
    return setmetatable({ _leaf = node, _units = units, _index = index }, _Unit)
end

--- Find which of `units` contains (or is the closest unit at-or-after) `row`/`column`.
---
--- Sub-word slices aren't real tree nodes, so there's no `vim.treesitter.get_node()`
--- equivalent to ask "which one is the cursor on" -- this does the same job
--- by hand, scanning in document order for the first unit whose end lands
--- after the cursor. Falling off the end (cursor past every unit) returns
--- the last unit rather than nothing, since the caller always needs a
--- concrete unit to treat as "current."
---
---@param units treemotion.SubwordUnit[] A leaf's sub-word units, in document order.
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

--- Walk from `node` in `step`'s direction until finding a leaf `subword.split()`
--- actually produces units for.
---
--- A leaf entirely consumed by `_commands.motion.subword`'s
--- `_leading_continuation_length` (e.g. tree-sitter-rust's lone `/`
--- `outer_doc_comment_marker` leaf inside a `///` doc comment) splits into
--- zero units -- it has no content of its own, just the tail of the
--- previous leaf's punctuation run -- so it should never be a landing spot.
--- `node` itself is checked first, so passing a leaf straight from
--- `leaf.current_leaf()` (which may or may not already be empty) works the
--- same as passing one already stepped past a known-empty leaf.
---
---@param node TSNode? Where to start looking.
---@param step fun(node: TSNode): TSNode? `leaf.next_leaf` or `leaf.previous_leaf`, matching the caller's direction.
---@return TSNode?, treemotion.SubwordUnit[]? # The first leaf with real
---    units, and its units -- both `nil` if none remain.
local function _first_nonempty_split(node, step)
    while node do
        local units = subword.split(node)

        if #units > 0 then
            return node, units
        end

        node = step(node)
    end

    return nil, nil
end

--- Find the sub-word unit under the cursor.
---
--- Finds the leaf under the cursor (`leaf.current_leaf()`), splits it
--- (`subword.split()`, skipping past any empty leaf via
--- `_first_nonempty_split`), then picks out the right slice with
--- `_index_at`. Everything gets recomputed from scratch here, unlike
--- `next_unit`/`previous_unit`, since there's no previous
--- `treemotion.WordUnit` to step from yet.
---
---@param forward boolean Forwarded to `leaf.current_leaf()`: which nearby
---    leaf to prefer off a leaf (e.g. blank line); also which direction to
---    skip empty leaves in.
---@return treemotion.WordUnit? # The unit under (or nearest) the cursor, if a parser and a leaf exist that way.
function M.current_unit(forward)
    local node, units =
        _first_nonempty_split(leaf.current_leaf(forward), forward and leaf.next_leaf or leaf.previous_leaf)

    if not node then
        _log_unit_result(string.format("current_unit(forward=%s)", forward), nil)

        return nil
    end

    -- `units` is only `nil` when `node` is (see `_first_nonempty_split`),
    -- but the type checker can't correlate two separate return values --
    -- `assert` narrows it back to non-optional for `_new_unit`/`_index_at`.
    units = assert(units)

    local row, column = leaf.cursor_position()

    local unit = _new_unit(node, units, _index_at(units, row, column))

    _log_unit_result(string.format("current_unit(forward=%s)", forward), unit)

    return unit
end

--- Find the sub-word unit directly after `unit`, in document order.
---
--- If `unit`'s leaf still has slices left, this is just an `_index` bump --
--- no treesitter or splitting work at all. Only once `unit` is the last
--- slice of its leaf does this reach for `leaf.next_leaf` and re-split the
--- leaf it finds (skipping any empty ones, see `_first_nonempty_split`),
--- landing on that leaf's *first* slice.
---
---@param unit treemotion.WordUnit
---@return treemotion.WordUnit? # The next sub-word unit, if `unit` isn't the last in the tree.
function M.next_unit(unit)
    local name = string.format("next_unit(unit %s/%s)", unit._index, #unit._units)

    if unit._index < #unit._units then
        local result = _new_unit(unit._leaf, unit._units, unit._index + 1)

        _log_unit_result(name, result)

        return result
    end

    local node, units = _first_nonempty_split(leaf.next_leaf(unit._leaf), leaf.next_leaf)

    if not node then
        _log_unit_result(name, nil)

        return nil
    end

    local result = _new_unit(node, assert(units), 1)

    _log_unit_result(name, result)

    return result
end

--- Find the sub-word unit directly before `unit`, in document order.
---
--- Mirror image of `next_unit`: decrements `_index` while slices remain,
--- otherwise reaches for `leaf.previous_leaf`, re-splits it (skipping any
--- empty ones), and lands on that leaf's *last* slice.
---
---@param unit treemotion.WordUnit
---@return treemotion.WordUnit? # The previous sub-word unit, if `unit` isn't the first in the tree.
function M.previous_unit(unit)
    local name = string.format("previous_unit(unit %s/%s)", unit._index, #unit._units)

    if unit._index > 1 then
        local result = _new_unit(unit._leaf, unit._units, unit._index - 1)

        _log_unit_result(name, result)

        return result
    end

    local node, units = _first_nonempty_split(leaf.previous_leaf(unit._leaf), leaf.previous_leaf)

    if not node then
        _log_unit_result(name, nil)

        return nil
    end

    units = assert(units)

    local result = _new_unit(node, units, #units)

    _log_unit_result(name, result)

    return result
end

return M
