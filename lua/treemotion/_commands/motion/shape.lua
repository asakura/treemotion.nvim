--- The four shapes of Vim's word motions, shared by `w` and `W` families.
---
--- `w` advances to the next start, `ge` retreats to the previous end, `e`
--- advances to the current or next end, and `b` retreats to the current or
--- previous start. Each step is pure (position in, position out); the
--- `forward_to_*`/`backward_to_*` motions move the cursor.

local codepoint = require("treemotion._commands.motion.codepoint")
local position = require("treemotion._commands.motion.position")

local M = {}

---@param node TSNode|treemotion.MotionUnit
---@return integer, integer
local function _start_of(node)
    return position.clamp(node:start())
end

--- The position of `node`'s last character.
---
---@param node TSNode|treemotion.MotionUnit
---@return integer, integer
local function _end_of(node)
    local row, column = node:end_()

    return position.clamp(row, codepoint.last_character_column(row, column))
end

---@param node TSNode|treemotion.MotionUnit
---@param row integer
---@param column integer
---@return boolean
local function _is_at_start(node, row, column)
    local start_row, start_column = node:start()

    return row == start_row and column == start_column
end

--- Whether `row`/`column` is on `node`'s last character.
---
---@param node TSNode|treemotion.MotionUnit
---@param row integer
---@param column integer
---@return boolean
local function _is_at_end(node, row, column)
    local end_row, end_column = node:end_()

    return row == end_row and column == codepoint.last_character_column(end_row, end_column)
end

--- Built by `word.new_source` or `bigword.new_source`.
---
---@class treemotion._UnitSource
---@field unit_at fun(row: integer, column: integer, forward: boolean): treemotion.MotionUnit?, TSNode?
---    The unit at (or nearest) a position, and the leaf at (or nearest) it.
---@field next_unit fun(unit: treemotion.MotionUnit): treemotion.MotionUnit?
---@field previous_unit fun(unit: treemotion.MotionUnit): treemotion.MotionUnit?
---@field span_end fun(node: TSNode): integer, integer Where the span containing the leaf `node` ends.

--- Where a motion lands from a position; the start position if nowhere.
---
-- luacheck: push ignore 631
---@alias treemotion._Step fun(units: treemotion._UnitSource, row: integer, column: integer, count: integer): integer, integer
-- luacheck: pop

---@alias treemotion._Move fun(units: treemotion._UnitSource, count: integer): any

--- `w`/`W`: the start of the next unit.
---
--- In a gap (a blank line), `unit_at` already returns the next unit, so the
--- step lands on it instead of stepping past it.
---
---@param units treemotion._UnitSource
---@param row integer
---@param column integer
---@param count integer
---@return integer, integer
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

--- `ge`/`gE`: the end of the previous unit. Gaps as in `M.next_start`.
---
---@param units treemotion._UnitSource
---@param row integer
---@param column integer
---@param count integer
---@return integer, integer
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

--- `e`/`E`: the end of this unit, or of the next one if already there.
---
---@param units treemotion._UnitSource
---@param row integer
---@param column integer
---@param count integer
---@return integer, integer
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

--- `b`/`B`: the start of this unit, or of the previous one if already there.
---
---@param units treemotion._UnitSource
---@param row integer
---@param column integer
---@param count integer
---@return integer, integer
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

--- Turn `step` into a cursor motion. A step that goes nowhere leaves the
--- cursor alone, so `j`/`k` keep their target column.
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

---@type fun(units: treemotion._UnitSource, count: integer)
M.forward_to_start = _moving(M.next_start)

---@type fun(units: treemotion._UnitSource, count: integer)
M.backward_to_end = _moving(M.previous_end)

---@type fun(units: treemotion._UnitSource, count: integer)
M.forward_to_end = _moving(M.next_end)

---@type fun(units: treemotion._UnitSource, count: integer)
M.backward_to_start = _moving(M.previous_start)

return M
