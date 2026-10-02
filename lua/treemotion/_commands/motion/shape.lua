--- The four shapes of Vim's word motions, shared by every motion family.
---
--- Real Vim's word motions come in four *shapes*, not just "forward" and
--- "backward": `w`/`W` unconditionally advance to the start of the next
--- word; `ge`/`gE` unconditionally retreat to the end of the previous word;
--- `e`/`E` advance to the end of the current word, or the next one if the
--- cursor is already there; `b`/`B` retreat to the start of the current
--- word, or the previous one if the cursor is already there. Each public
--- function here implements exactly one of those four shapes.
---
--- Each shape works over two different notions of "word":
--- `w`/`e`/`b`/`ge` move between sub-word units -- individual treesitter
--- leaves, optionally split further by naming convention (camelCase,
--- kebab-case, ...) per `commands.motion.small`, via
--- `_commands.motion.word`. `W`/`E`/`B`/`gE` move between contiguous *runs*
--- of whole leaves (see `_commands.motion.run`),
--- optionally split the same way per `commands.motion.big` (only once
--- `.enabled = true`; by default a run ignores case entirely, the same way
--- real Vim's `W` ignores punctuation inside a WORD), via
--- `_commands.motion.bigword`. The two families are symmetric, one level
--- apart, and expose the same `current_unit`/`next_unit`/`previous_unit`
--- API, so each shape takes the family to step through as its `units`
--- argument.
---
--- Each shape is a pure *step* (`M.next_start`, `M.previous_end`,
--- `M.next_end`, `M.previous_start`): given a position, it returns where
--- the motion lands, without reading or moving the cursor. The
--- cursor-moving motions (`M.forward_to_start`, ...) are thin wrappers
--- around those steps.
---
--- `_commands.motion.runner` picks a shape per motion name, and
--- `_commands.motion.operator` measures ranges with the same steps.

local codepoint = require("treemotion._commands.motion.codepoint")
local position = require("treemotion._commands.motion.position")

local M = {}

--- `node`'s first character.
---
---@param node TSNode|treemotion.MotionUnit Anything with a `:start()` -- a leaf or unit.
---@return integer, integer
local function _start_of(node)
    return position.clamp(node:start())
end

--- `node`'s last character.
---
--- `node:end_()` is the column *after* the last character (exclusive), so
--- this steps back to the character itself via `codepoint.last_character_column`,
--- landing on its lead byte even when it's multi-byte UTF-8.
---
---@param node TSNode|treemotion.MotionUnit Anything with an `:end_()` -- a leaf or unit.
---@return integer, integer
local function _end_of(node)
    local row, column = node:end_()

    return position.clamp(row, codepoint.last_character_column(row, column))
end

--- Check if `row`/`column` already sits on `node`'s first character.
---
--- `b`/`B` use this to decide whether to retreat to the *previous* unit, or
--- just snap to the start of the current one -- mirroring how real Vim's
--- `b` only skips the current word if the cursor is already at its start.
---
---@param node TSNode|treemotion.MotionUnit
---@param row integer
---@param column integer
---@return boolean # `true` if `row`/`column` already sits on `node`'s start.
local function _is_at_start(node, row, column)
    local start_row, start_column = node:start()

    return row == start_row and column == start_column
end

--- Check if `row`/`column` already sits on `node`'s last character.
---
--- `e`/`E` use this to decide whether to advance to the *next* unit, or
--- just snap to the end of the current one -- mirroring how real Vim's `e`
--- only skips the current word if the cursor is already at its end.
---
---@param node TSNode|treemotion.MotionUnit
---@param row integer
---@param column integer
---@return boolean # `true` if `row`/`column` already sits on `node`'s (inclusive) end.
local function _is_at_end(node, row, column)
    local end_row, end_column = node:end_()

    return row == end_row and column == codepoint.last_character_column(end_row, end_column)
end

--- The unit-stepping API `_commands.motion.word` and `_commands.motion.bigword` share.
---
--- Every shape below takes a source built by one of those two modules'
--- `new_source` as its `units` argument, so each of the four
--- shapes is implemented once and serves both `w`/`e`/`b`/`ge` and
--- `W`/`E`/`B`/`gE`. Both modules build theirs with
--- `_commands.motion.unit.new_source`.
---
---@class treemotion._UnitSource
---@field unit_at fun(row: integer, column: integer, forward: boolean): treemotion.MotionUnit?, TSNode?
---    The unit at (or nearest) a position, and the leaf at (or nearest) it.
---@field next_unit fun(unit: treemotion.MotionUnit): treemotion.MotionUnit?
---@field previous_unit fun(unit: treemotion.MotionUnit): treemotion.MotionUnit?
---@field span_end fun(node: TSNode): integer, integer Where the span containing the leaf `node` ends.

--- Any one of the steps below: where the motion lands from a position.
---
--- Returns the position it started from when there's nowhere to go.
---
-- luacheck: push ignore 631
---@alias treemotion._Step fun(units: treemotion._UnitSource, row: integer, column: integer, count: integer): integer, integer
-- luacheck: pop

--- Any one of the cursor-moving motions below.
---
---@alias treemotion._Move fun(units: treemotion._UnitSource, count: integer): any

--- `w`/`W`-shape step: unconditionally advance to the start of the next unit.
---
--- Over `_commands.motion.word` units, a single leaf like `fooBar` counts
--- as more than one stop. Over `_commands.motion.bigword` units, a single
--- run counts as more than one stop once `commands.motion.big.enabled` is
--- `true` (it's exactly one stop by default, see
--- `bigword.new_source`/`subword.split_run`).
---
--- `units.unit_at` substitutes the nearest unit ahead when the position
--- sits in a gap no unit covers (e.g. a blank line). That unit is already
--- the next one, so stepping past it would overshoot by one: a position
--- outside the unit it gets lands on that unit instead.
---
---@param units treemotion._UnitSource From `word.new_source` or `bigword.new_source`.
---@param row integer 0-indexed row to start from.
---@param column integer 0-indexed column to start from.
---@param count integer How many units to move over.
---@return integer, integer # Where the step lands.
---
function M.next_start(units, row, column, count)
    for _ = 1, count do
        local unit = units.unit_at(row, column, true)

        if not unit then
            break
        end

        if position.contains(unit, row, column) then
            unit = units.next_unit(unit)

            if not unit then
                break
            end
        end

        row, column = _start_of(unit)
    end

    return row, column
end

--- `ge`/`gE`-shape step: unconditionally retreat to the end of the previous unit.
---
--- Same gap substitution rule as `M.next_start`, mirrored.
---
---@param units treemotion._UnitSource From `word.new_source` or `bigword.new_source`.
---@param row integer 0-indexed row to start from.
---@param column integer 0-indexed column to start from.
---@param count integer How many units to move over.
---@return integer, integer # Where the step lands.
---
function M.previous_end(units, row, column, count)
    for _ = 1, count do
        local unit = units.unit_at(row, column, false)

        if not unit then
            break
        end

        if position.contains(unit, row, column) then
            unit = units.previous_unit(unit)

            if not unit then
                break
            end
        end

        row, column = _end_of(unit)
    end

    return row, column
end

--- `e`/`E`-shape step: advance to the end of the current unit, or the next one if already there.
---
---@param units treemotion._UnitSource From `word.new_source` or `bigword.new_source`.
---@param row integer 0-indexed row to start from.
---@param column integer 0-indexed column to start from.
---@param count integer How many units to move over.
---@return integer, integer # Where the step lands.
---
function M.next_end(units, row, column, count)
    for _ = 1, count do
        local unit = units.unit_at(row, column, true)

        if not unit then
            break
        end

        if _is_at_end(unit, row, column) then
            unit = units.next_unit(unit)

            if not unit then
                break
            end
        end

        row, column = _end_of(unit)
    end

    return row, column
end

--- `b`/`B`-shape step: retreat to the start of the current unit, or the previous one if already there.
---
---@param units treemotion._UnitSource From `word.new_source` or `bigword.new_source`.
---@param row integer 0-indexed row to start from.
---@param column integer 0-indexed column to start from.
---@param count integer How many units to move over.
---@return integer, integer # Where the step lands.
---
function M.previous_start(units, row, column, count)
    for _ = 1, count do
        local unit = units.unit_at(row, column, false)

        if not unit then
            break
        end

        if _is_at_start(unit, row, column) then
            unit = units.previous_unit(unit)

            if not unit then
                break
            end
        end

        row, column = _start_of(unit)
    end

    return row, column
end

--- Turn `step` into a motion that moves the cursor.
---
--- The cursor is left alone when the step goes nowhere, so a motion that
--- can't move doesn't reset the column `j`/`k` aim for.
---
---@param step treemotion._Step
---@return treemotion._Move
local function _moving(step)
    return function(units, count)
        local row, column = position.cursor_position()
        local target_row, target_column = step(units, row, column, count)

        if target_row ~= row or target_column ~= column then
            vim.api.nvim_win_set_cursor(0, { target_row + 1, target_column })
        end
    end
end

--- `w`/`W`: move the cursor by `M.next_start`.
---
---@type fun(units: treemotion._UnitSource, count: integer)
M.forward_to_start = _moving(M.next_start)

--- `ge`/`gE`: move the cursor by `M.previous_end`.
---
---@type fun(units: treemotion._UnitSource, count: integer)
M.backward_to_end = _moving(M.previous_end)

--- `e`/`E`: move the cursor by `M.next_end`.
---
---@type fun(units: treemotion._UnitSource, count: integer)
M.forward_to_end = _moving(M.next_end)

--- `b`/`B`: move the cursor by `M.previous_start`.
---
---@type fun(units: treemotion._UnitSource, count: integer)
M.backward_to_start = _moving(M.previous_start)

return M
