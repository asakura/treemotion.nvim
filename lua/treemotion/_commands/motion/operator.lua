--- Operator-pending behavior for the motions (`dw`, `cw`, `de`, `yW`, ...).
---
--- A `<Plug>` mapping in operator-pending mode only moves the cursor, so
--- the operator acts on exactly the text between the old and new cursor,
--- as an exclusive characterwise motion. That's wrong in two ways Vim's
--- built-in motions avoid:
---
--- - `w`/`W` land past text the motion skips (insignificant leaves,
---   `"skip"` delimiters, comment markers) and past line breaks, so `dw`
---   deletes that text too. Vim's `dw` never crosses into another word
---   and ends at a line's last word (`:help word`), and `cw` works like
---   `ce` (`:help cw`, `:help cpo-_`).
--- - `e`/`E`/`ge`/`gE` are inclusive in Vim (`:help inclusive`), but a
---   mapping that just moves the cursor is exclusive, so `de` leaves the
---   word's last character behind.
---
--- Everything here runs only when `commands.motion.operator_pending.enabled`
--- is `true` and the operator isn't forced (`dvw` etc. are left alone), so
--- plain cursor movement, Visual mode and the disabled default are
--- untouched. The rules only look at motion units, leaves and blank
--- characters in the buffer, never at node types, so they work the same for
--- any grammar.
---
--- An inclusive range is made by starting Visual mode from the callback
--- (`normal! v`) and moving the cursor to the range's last character: the
--- pending operator then acts on that selection, the same technique
--- textobject plugins use.

local codepoint = require("treemotion._commands.motion.codepoint")
local constant = require("treemotion._commands.motion.constant")
local leaf = require("treemotion._commands.motion.leaf")
local position = require("treemotion._commands.motion.position")
local shape = require("treemotion._commands.motion.shape")

local M = {}

--- How a motion runs under an operator: `M.forward_to_start` or `M.inclusive`.
---
--- `move` is the motion's own `_commands.motion.shape` shape.
---
-- luacheck: push ignore 631
---@alias treemotion._OperatorMove fun(units: treemotion._UnitSource, count: integer, pending: treemotion.OperatorSettings, move: treemotion._Move)
-- luacheck: pop

--- Check whether `row_a`/`column_a` comes before `row_b`/`column_b`.
---
---@param row_a integer
---@param column_a integer
---@param row_b integer
---@param column_b integer
---@return boolean
---
local function _is_before(row_a, column_a, row_b, column_b)
    return row_a < row_b or (row_a == row_b and column_a < column_b)
end

--- The later of two positions.
---
---@param row_a integer
---@param column_a integer
---@param row_b integer
---@param column_b integer
---@return integer, integer
---
local function _max(row_a, column_a, row_b, column_b)
    if _is_before(row_a, column_a, row_b, column_b) then
        return row_b, column_b
    end

    return row_a, column_a
end

--- The earlier of two positions.
---
---@param row_a integer
---@param column_a integer
---@param row_b integer
---@param column_b integer
---@return integer, integer
---
local function _min(row_a, column_a, row_b, column_b)
    if _is_before(row_a, column_a, row_b, column_b) then
        return row_a, column_a
    end

    return row_b, column_b
end

---@param row integer 0-indexed row.
---@return string # The row's text, or `""` past the buffer's end.
local function _line(row)
    return vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1] or ""
end

--- Find the first non-blank character in `[from, to)`.
---
---@param from_row integer
---@param from_column integer
---@param to_row integer
---@param to_column integer
---@return integer?, integer? # Its position, or `nil` if the range is all blank.
---
local function _first_non_blank(from_row, from_column, to_row, to_column)
    local row, column = from_row, from_column

    while _is_before(row, column, to_row, to_column) do
        local found = _line(row):find("%S", column + 1)

        if found and _is_before(row, found - 1, to_row, to_column) then
            return row, found - 1
        end

        if found or row >= to_row then
            return nil, nil
        end

        row, column = row + 1, 0
    end

    return nil, nil
end

--- Check whether the cursor sits on a non-blank character.
---
---@return boolean
local function _is_cursor_on_non_blank()
    local row, column = position.cursor_position()
    local character = _line(row):sub(column + 1, column + 1)

    return character ~= "" and not character:match("%s")
end

--- Check whether `row`/`column` falls within `node`'s range.
---
---@param node TSNode|treemotion.MotionUnit
---@param row integer
---@param column integer
---@return boolean
---
local function _contains(node, row, column)
    local start_row, start_column = node:start()
    local end_row, end_column = node:end_()

    return not _is_before(row, column, start_row, start_column) and _is_before(row, column, end_row, end_column)
end

--- Where the skipped text under the cursor ends (exclusive).
---
--- Used when the cursor sits on non-blank text that no unit covers: an
--- insignificant leaf such as Nix's `=`, or a `"skip"` delimiter such as
--- the `_` in `foo_bar`. That text is what the operator is aimed at, so it
--- runs until the first of: the end of the leaf (or `W` run) under the
--- cursor, the next unit, or a blank character.
---
---@param units treemotion._UnitSource
---@param next_unit treemotion.MotionUnit? `units.current_unit(true)` at the cursor.
---@return integer, integer
---
local function _skipped_text_end(units, next_unit)
    local row, column = position.cursor_position()
    local line = _line(row)
    local end_row, end_column = row, column + codepoint.char_width(line, column + 1)
    local node = leaf.current_leaf(true)

    if node and _contains(node, row, column) then
        end_row, end_column = _max(end_row, end_column, units.span_end(node))
    end

    if next_unit then
        local unit_row, unit_column = next_unit:start()

        if _is_before(row, column, unit_row, unit_column) then
            end_row, end_column = _min(end_row, end_column, unit_row, unit_column)
        end
    end

    local blank = line:find("%s", column + 1)

    if blank then
        end_row, end_column = _min(end_row, end_column, row, blank - 1)
    end

    return end_row, end_column
end

--- Select from `start` to `finish`, both inclusive, for the pending operator.
---
--- With `'selection'` set to `"exclusive"` the Visual area leaves out its
--- last character, so the cursor goes one character further.
---
---@param start_row integer
---@param start_column integer
---@param finish_row integer
---@param finish_column integer
---
local function _select(start_row, start_column, finish_row, finish_column)
    vim.api.nvim_win_set_cursor(0, { start_row + 1, start_column })
    vim.cmd("normal! v")

    if vim.o.selection == "exclusive" then
        finish_column = finish_column + codepoint.char_width(_line(finish_row), finish_column + 1)
    end

    vim.api.nvim_win_set_cursor(0, { finish_row + 1, finish_column })
end

--- The text an operator should act on.
---
--- `start` is where the cursor was before the motion. `finish` is where the
--- range ends: the character after it for an exclusive range (as with a
--- plain motion), its last character for an inclusive one.
---
---@class treemotion.OperatorRange
---@field start_row integer
---@field start_column integer
---@field finish_row integer
---@field finish_column integer
---@field inclusive boolean

---@param start_row integer
---@param start_column integer
---@param finish_row integer
---@param finish_column integer
---@param inclusive boolean
---@return treemotion.OperatorRange
local function _range(start_row, start_column, finish_row, finish_column, inclusive)
    return {
        start_row = start_row,
        start_column = start_column,
        finish_row = finish_row,
        finish_column = finish_column,
        inclusive = inclusive,
    }
end

--- The plain motion's range: from `start` to wherever the cursor is now.
---
---@param start_row integer
---@param start_column integer
---@return treemotion.OperatorRange
local function _range_to_cursor(start_row, start_column)
    local row, column = position.cursor_position()

    return _range(start_row, start_column, row, column, false)
end

--- `cw`/`cW`: change to the end of the current unit, like `ce`/`cE`.
---
--- Only used while `settings.change_to_end` is set (see
--- `treemotion.OperatorSettings`).
---
--- On skipped text (see `_skipped_text_end`) that text counts as the
--- current unit. Further counts step like `e`/`E`.
---
---@param units treemotion._UnitSource
---@param unit treemotion.MotionUnit `units.current_unit(true)` at the cursor.
---@param count integer
---@return treemotion.OperatorRange
---
local function _change_to_end_range(units, unit, count)
    local start_row, start_column = position.cursor_position()
    local end_row, end_column

    if _contains(unit, start_row, start_column) then
        end_row, end_column = unit:end_()
    else
        end_row, end_column = _skipped_text_end(units, unit)
    end

    vim.api.nvim_win_set_cursor(0, { end_row + 1, codepoint.last_character_column(end_row, end_column) })

    if count > 1 then
        shape.forward_to_end(units, count - 1)
    end

    local finish_row, finish_column = position.cursor_position()

    return _range(start_row, start_column, finish_row, finish_column, true)
end

--- The range `dw`/`cw`/`yW`/... should act on: the `w`/`W` motion's, trimmed per `settings`.
---
--- The range starts at the cursor and would end where the motion lands.
--- Its tail is trimmed from the end of the last unit moved over:
---
--- - `skipped_text`: `"keep"` ends the range at the first non-blank
---   character after that unit, so skipped text is never included.
---   `"keep_between_tokens"` measures from the end of the unit's leaf (or
---   `W` run) instead, so skipped delimiters inside the same token (the
---   `_` in `foo_bar`) are still included. `"delete"` doesn't trim.
--- - `stop_at_line_end`: a range that would continue onto a later line ends
---   at the end of the current line instead, like Vim's `dw` on a line's
---   last word (`:help word`'s "Another special case"). On an empty line
---   the range is the line break itself, as with Vim's `dw` there.
---
--- A range the trimming would empty, and a motion that found nowhere to go
--- from outside every unit, keep the plain motion's range.
---
--- Moves the cursor while measuring, since `units` works from the cursor;
--- `M.apply` puts it where the range needs it.
---
---@param units treemotion._UnitSource
---@param count integer
---@param settings treemotion.OperatorSettings
---@param move treemotion._Move `shape.forward_to_start`.
---@return treemotion.OperatorRange
---
function M.forward_range(units, count, settings, move)
    local start_row, start_column = position.cursor_position()
    local unit = units.current_unit(true)

    if not unit then
        -- No parser, or nothing left to move to: same as the plain motion.
        move(units, count)

        return _range_to_cursor(start_row, start_column)
    end

    if settings.change_to_end and _is_cursor_on_non_blank() then
        return _change_to_end_range(units, unit, count)
    end

    if count > 1 then
        -- Only the final step is trimmed, so take the others as they are.
        move(units, count - 1)
        unit = units.current_unit(true)

        if not unit then
            return _range_to_cursor(start_row, start_column)
        end
    end

    local step_row, step_column = position.cursor_position()
    local tail_row, tail_column = step_row, step_column
    ---@type treemotion.MotionUnit?
    local departed

    if _contains(unit, step_row, step_column) then
        departed = unit
        tail_row, tail_column = unit:end_()

        if settings.skipped_text == constant.SkippedText.keep_between_tokens then
            -- Clamped to the unit's own line, since some grammars end a
            -- leaf at the next row's column 0 (a trailing newline).
            local span_row, span_column = _min(tail_row, #_line(tail_row), units.span_end(unit._leaf))

            tail_row, tail_column = _max(tail_row, tail_column, span_row, span_column)
        end
    elseif _is_cursor_on_non_blank() then
        tail_row, tail_column = _skipped_text_end(units, unit)
    end

    move(units, 1)

    local target_row, target_column = position.cursor_position()

    if not _is_before(step_row, step_column, target_row, target_column) then
        if not departed then
            return _range_to_cursor(start_row, start_column)
        end

        -- The final step found nowhere to go (the buffer's last unit): the
        -- range still covers the rest of the unit.
        target_row, target_column = tail_row, tail_column
    end

    local end_row, end_column = target_row, target_column

    if settings.skipped_text ~= constant.SkippedText.delete then
        local kept_row, kept_column = _first_non_blank(tail_row, tail_column, target_row, target_column)

        if kept_row then
            ---@cast kept_column integer
            end_row, end_column = kept_row, kept_column
        end
    end

    if settings.stop_at_line_end and end_row > tail_row then
        local length = #_line(tail_row)

        if length == 0 then
            -- An empty line is a word of its own (`:help word`): Vim's `dw`
            -- there acts on the line break, while `cw` just starts
            -- inserting.
            return _range(start_row, start_column, start_row, start_column, not settings.change)
        end

        -- Vim's `dw` on a line's last word stops at the end of the line
        -- (`:help word`, "Another special case"), taking any trailing
        -- blanks with it, and so does `dw` on those trailing blanks.
        end_row, end_column = tail_row, length
    end

    if not _is_before(start_row, start_column, end_row, end_column) then
        return _range(start_row, start_column, target_row, target_column, false)
    end

    return _range(start_row, start_column, end_row, end_column, false)
end

--- The range `de`/`dge`/... should act on: the motion's, including both ends.
---
--- The plain (exclusive) range when `settings.inclusive` is off. A motion
--- that didn't move gives an empty range, rather than the character under
--- the cursor.
---
--- Moves the cursor, like `M.forward_range`.
---
---@param units treemotion._UnitSource
---@param count integer
---@param settings treemotion.OperatorSettings
---@param move treemotion._Move The `e`/`E`/`ge`/`gE`-shape move.
---@return treemotion.OperatorRange
---
function M.inclusive_range(units, count, settings, move)
    local start_row, start_column = position.cursor_position()

    move(units, count)

    local target_row, target_column = position.cursor_position()
    local moved = target_row ~= start_row or target_column ~= start_column

    if not settings.inclusive or not moved then
        return _range(start_row, start_column, target_row, target_column, false)
    end

    local first_row, first_column = _min(start_row, start_column, target_row, target_column)
    local last_row, last_column = _max(start_row, start_column, target_row, target_column)

    return _range(first_row, first_column, last_row, last_column, true)
end

--- Make the pending operator act on `range`.
---
--- An exclusive range just needs the cursor at its `finish`, as for a plain
--- motion. A `finish` at the end of a non-empty line can't hold the cursor
--- outside Visual/Insert mode, so that case selects up to the line's last
--- character instead. An inclusive range is always selected.
---
---@param range treemotion.OperatorRange
---
function M.apply(range)
    if range.inclusive then
        _select(range.start_row, range.start_column, range.finish_row, range.finish_column)

        return
    end

    local length = #_line(range.finish_row)

    if range.finish_column == 0 or range.finish_column < length then
        vim.api.nvim_win_set_cursor(0, { range.finish_row + 1, range.finish_column })

        return
    end

    local last_column = codepoint.last_character_column(range.finish_row, length)

    _select(range.start_row, range.start_column, range.finish_row, last_column)
end

--- `dw`/`cw`/`yW`/...: act on `M.forward_range`.
---
---@param units treemotion._UnitSource
---@param count integer
---@param settings treemotion.OperatorSettings
---@param move treemotion._Move `shape.forward_to_start`.
---
function M.forward_to_start(units, count, settings, move)
    M.apply(M.forward_range(units, count, settings, move))
end

--- `de`/`dge`/...: act on `M.inclusive_range`.
---
---@param units treemotion._UnitSource
---@param count integer
---@param settings treemotion.OperatorSettings
---@param move treemotion._Move The `e`/`E`/`ge`/`gE`-shape move.
---
function M.inclusive(units, count, settings, move)
    M.apply(M.inclusive_range(units, count, settings, move))
end

return M
