--- Operator-pending ranges for `dw`, `cw`, `de`, `yW`, ...
---
--- A `<Plug>` motion only moves the cursor, so the operator would act on an
--- exclusive range to wherever it lands. Vim's own motions differ: `dw`
--- stays within a line and doesn't take skipped text, `cw` acts like `ce`,
--- and `e`/`ge` are inclusive. This module computes those ranges from motion
--- units, leaves, brackets and blanks only, so it works for any grammar.
---
--- Ranges are always exclusive. An end past a line's last character is
--- reached with `'virtualedit'` briefly set to `"onemore"`, so Visual mode
--- and the `'<`/`'>` marks are never touched.

local codepoint = require("treemotion._commands.motion.codepoint")
local constant = require("treemotion._commands.motion.constant")
local position = require("treemotion._commands.motion.position")
local shape = require("treemotion._commands.motion.shape")

local M = {}

--- `M.forward_to_start` or `M.inclusive`.
-- luacheck: push ignore 631
---@alias treemotion._OperatorMove fun(units: treemotion._UnitSource, count: integer, pending: treemotion.OperatorSettings, step: treemotion._Step)
-- luacheck: pop

---@param from_row integer
---@param from_column integer
---@param to_row integer
---@param to_column integer
---@return integer?, integer? # The first non-blank in `[from, to)`.
---
local function _first_non_blank(from_row, from_column, to_row, to_column)
    local row, column = from_row, from_column

    while position.is_before(row, column, to_row, to_column) do
        local found = codepoint.line(row):find("%S", column + 1)

        if found and position.is_before(row, found - 1, to_row, to_column) then
            return row, found - 1
        end

        if found or row >= to_row then
            return nil, nil
        end

        row, column = row + 1, 0
    end

    return nil, nil
end

---@return boolean
local function _has_parser()
    return vim.treesitter.get_parser(0, nil, { error = false }) ~= nil
end

---@param row integer
---@param column integer
---@return boolean
local function _is_non_blank(row, column)
    local character = codepoint.line(row):sub(column + 1, column + 1)

    return character ~= "" and not character:match("%s")
end

--- Where the token at `row`/`column` ends (exclusive): the leaf or `W` run's
--- end at `span_row`/`span_column`, but no later than the line's end, the
--- next blank (prose leaves hold whole sentences) or `next_unit`'s start.
---
---@param row integer
---@param column integer
---@param span_row integer
---@param span_column integer
---@param next_unit treemotion.MotionUnit?
---@return integer, integer
---
local function _token_end(row, column, span_row, span_column, next_unit)
    local line = codepoint.line(row)
    local end_row, end_column = position.min(row, #line, span_row, span_column)
    local blank = line:find("%s", column + 1)

    if blank then
        end_row, end_column = position.min(end_row, end_column, row, blank - 1)
    end

    if next_unit then
        local unit_row, unit_column = next_unit:start()

        if not position.is_before(unit_row, unit_column, row, column) then
            end_row, end_column = position.min(end_row, end_column, unit_row, unit_column)
        end
    end

    return position.max(row, column, end_row, end_column)
end

--- Where non-blank text that no unit covers (Nix's `=`, a skipped `_`)
--- ends: at least one character, at most its leaf, cut at the next unit.
---
---@param units treemotion._UnitSource
---@param row integer
---@param column integer
---@param next_unit treemotion.MotionUnit?
---@param start_leaf TSNode?
---@return integer, integer
---
local function _skipped_text_end(units, row, column, next_unit, start_leaf)
    local end_column = column + codepoint.char_width(codepoint.line(row), column + 1)
    local span_row, span_column = row, end_column

    if start_leaf and position.contains(start_leaf, row, column) then
        span_row, span_column = units.span_end(start_leaf)
    end

    return _token_end(row, end_column, span_row, span_column, next_unit)
end

---@type table<string, string>
local _CLOSING_BRACKET = { ["("] = ")", ["["] = "]", ["{"] = "}" }

---@type table<string, true>
local _CLOSING_BRACKETS = { [")"] = true, ["]"] = true, ["}"] = true }

--- Whether the bracket at `row`/`column` is code rather than text.
---
--- A bracket inside a named leaf (a string, a comment) only counts while
--- the whole range stays inside that leaf. Without a parser every bracket
--- counts. `descendant_for_range()` finds anonymous nodes on all supported
--- Neovim versions.
---
---@param parser vim.treesitter.LanguageTree?
---@param row integer
---@param column integer
---@param start_row integer
---@param start_column integer
---@param finish_row integer
---@param finish_column integer
---@return boolean
---
local function _is_structural_bracket(parser, row, column, start_row, start_column, finish_row, finish_column)
    if not parser then
        return true
    end

    local tree = parser:tree_for_range({ row, column, row, column + 1 }, { ignore_injections = false })
    local node = tree and tree:root():descendant_for_range(row, column, row, column + 1)

    if not node or not node:named() then
        return true
    end

    local node_start_row, node_start_column, node_end_row, node_end_column = node:range()

    return not position.is_before(start_row, start_column, node_start_row, node_start_column)
        and not position.is_before(node_end_row, node_end_column, finish_row, finish_column)
end

--- Where the range ends before a closing bracket it didn't open, so `dw` on
--- the `c` of `(config.lib)` leaves the `)`. Closing brackets at the very
--- start of the range are under the cursor and stay in.
---
---@param start_row integer
---@param start_column integer
---@param finish_row integer
---@param finish_column integer
---@return integer, integer
---
local function _before_unopened_bracket(start_row, start_column, finish_row, finish_column)
    local lines = vim.api.nvim_buf_get_text(0, start_row, start_column, finish_row, finish_column, {})
    ---@type string[]
    local expected = {}
    local leading = true
    local parser = vim.treesitter.get_parser(0, nil, { error = false })

    for index, line in ipairs(lines) do
        local row = start_row + index - 1
        local offset = index == 1 and start_column or 0

        if index > 1 then
            leading = false
        end

        for byte = 1, #line do
            local character = line:sub(byte, byte)
            local column = offset + byte - 1
            local is_bracket = (_CLOSING_BRACKETS[character] or _CLOSING_BRACKET[character]) ~= nil
                and _is_structural_bracket(parser, row, column, start_row, start_column, finish_row, finish_column)

            if is_bracket and _CLOSING_BRACKETS[character] then
                if expected[#expected] == character then
                    expected[#expected] = nil
                elseif #expected > 0 or not leading then
                    return row, column
                end
            else
                leading = false

                if is_bracket then
                    table.insert(expected, _CLOSING_BRACKET[character])
                end
            end
        end
    end

    return finish_row, finish_column
end

--- Put the cursor at `row`/`column`, which may be past the line's end.
--- Only the window-local `'virtualedit'` is touched, and restored after.
---
---@param row integer
---@param column integer
---
local function _set_cursor_onemore(row, column)
    local scope = { scope = "local", win = 0 }
    local original = vim.api.nvim_get_option_value("virtualedit", scope)

    vim.api.nvim_set_option_value("virtualedit", "onemore", scope)

    local ok, message = pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, column })

    vim.api.nvim_set_option_value("virtualedit", original, scope)

    if not ok then
        error(message, 0)
    end
end

--- An operator's range. `finish` is exclusive. `inclusive` is how the
--- operator sees it (`:help inclusive`).
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

--- The exclusive end after the character at `row`/`column`. An empty
--- line's character is its line break, except on the last line.
---
---@param row integer
---@param column integer
---@return integer, integer
local function _after_character(row, column)
    local line = codepoint.line(row)

    if #line > 0 then
        return row, column + codepoint.char_width(line, column + 1)
    end

    if row + 1 < vim.api.nvim_buf_line_count(0) then
        return row + 1, 0
    end

    return row, column
end

--- `range`, ending before its first unopened closing bracket.
---
---@param range treemotion.OperatorRange
---@return treemotion.OperatorRange
function M.balance_brackets(range)
    local row, column =
        _before_unopened_bracket(range.start_row, range.start_column, range.finish_row, range.finish_column)

    if row == range.finish_row and column == range.finish_column then
        return range
    end

    if range.inclusive and column == 0 and row > range.start_row then
        -- The bracket starts a line: end after the last character before
        -- it, keeping the line breaks in between. Ending at its line's
        -- start would let Vim pull an exclusive end back onto the previous
        -- line (`:help exclusive`), so empty lines are stepped over too,
        -- back to the start's line, whose own line break is then taken if
        -- it's empty (see `_after_character`).
        row = row - 1

        while row > range.start_row and #codepoint.line(row) == 0 do
            row = row - 1
        end

        row, column = _after_character(row, codepoint.last_character_column(row, #codepoint.line(row)))
    end

    return _range(range.start_row, range.start_column, row, column, range.inclusive)
end

--- `cw` as `ce`: to the end of the current unit, or of skipped text.
---
---@param units treemotion._UnitSource
---@param start_row integer
---@param start_column integer
---@param unit treemotion.MotionUnit?
---@param start_leaf TSNode?
---@param count integer
---@return treemotion.OperatorRange
---
local function _change_to_end_range(units, start_row, start_column, unit, start_leaf, count)
    local end_row, end_column

    if unit and position.contains(unit, start_row, start_column) then
        end_row, end_column = unit:end_()
    else
        end_row, end_column = _skipped_text_end(units, start_row, start_column, unit, start_leaf)
    end

    local last_row, last_column = position.clamp(end_row, codepoint.last_character_column(end_row, end_column))

    if count > 1 then
        last_row, last_column = shape.next_end(units, last_row, last_column, count - 1)
    end

    local finish_row, finish_column = _after_character(last_row, last_column)

    return M.balance_brackets(_range(start_row, start_column, finish_row, finish_column, true))
end

--- An untrimmed `w` motion. `tail` is where the last unit (or skipped text)
--- ends; `token_end` is `tail` pushed to the end of its leaf or run.
---
---@class treemotion.OperatorMotion
---@field start_row integer
---@field start_column integer
---@field tail_row integer
---@field tail_column integer
---@field token_end_row integer
---@field token_end_column integer
---@field target_row integer
---@field target_column integer

--- Measure the untrimmed `w`/`W` motion. Past the last unit it lands at
--- the end of the line, like Vim's `dw` at the end of the buffer.
---
---@param units treemotion._UnitSource
---@param start_row integer
---@param start_column integer
---@param unit treemotion.MotionUnit?
---@param start_leaf TSNode?
---@param count integer
---@param step treemotion._Step
---@return treemotion.OperatorMotion
---
local function _forward_motion(units, start_row, start_column, unit, start_leaf, count, step)
    local step_row, step_column = start_row, start_column

    if unit and count > 1 then
        -- Only the final step is trimmed, so take the others as they are.
        step_row, step_column = step(units, start_row, start_column, count - 1)
        unit, start_leaf = units.unit_at(step_row, step_column, true)
    end

    local tail_row, tail_column = step_row, step_column
    local token_end_row, token_end_column = step_row, step_column

    if unit and position.contains(unit, step_row, step_column) then
        tail_row, tail_column = unit:end_()
        token_end_row, token_end_column = _token_end(tail_row, tail_column, unit:span_end())
    elseif _is_non_blank(step_row, step_column) then
        tail_row, tail_column = _skipped_text_end(units, step_row, step_column, unit, start_leaf)
        token_end_row, token_end_column = tail_row, tail_column
    end

    local target_row, target_column = step(units, step_row, step_column, 1)

    if not position.is_before(step_row, step_column, target_row, target_column) then
        target_row, target_column = tail_row, #codepoint.line(tail_row)
    end

    return {
        start_row = start_row,
        start_column = start_column,
        tail_row = tail_row,
        tail_column = tail_column,
        token_end_row = token_end_row,
        token_end_column = token_end_column,
        target_row = target_row,
        target_column = target_column,
    }
end

---@param motion treemotion.OperatorMotion
---@return treemotion.OperatorRange
local function _motion_range(motion)
    return _range(motion.start_row, motion.start_column, motion.target_row, motion.target_column, false)
end

--- `motion`'s range ending at `row`/`column`, unless that would empty it.
---
---@param motion treemotion.OperatorMotion
---@param row integer
---@param column integer
---@return treemotion.OperatorRange
local function _trimmed(motion, row, column)
    if not position.is_before(motion.start_row, motion.start_column, row, column) then
        return _motion_range(motion)
    end

    return _range(motion.start_row, motion.start_column, row, column, false)
end

--- `motion`'s range without the skipped text after its last unit.
--- `"keep_between_tokens"` measures from the token end, so `foo_bar` keeps its `_`.
---
---@param motion treemotion.OperatorMotion
---@param skipped_text treemotion.SkippedTextMode
---@return treemotion.OperatorRange
---
function M.trim_skipped_text(motion, skipped_text)
    if skipped_text == constant.SkippedText.delete then
        return _motion_range(motion)
    end

    local from_row, from_column = motion.tail_row, motion.tail_column

    if skipped_text == constant.SkippedText.keep_between_tokens then
        from_row, from_column = motion.token_end_row, motion.token_end_column
    end

    local kept_row, kept_column = _first_non_blank(from_row, from_column, motion.target_row, motion.target_column)

    if not kept_row then
        return _motion_range(motion)
    end

    ---@cast kept_column integer
    return _trimmed(motion, kept_row, kept_column)
end

--- `range`, cut at the end of `motion`'s tail line (`:help word`'s special
--- case for `dw`). On an empty line, the line break, or nothing for `cw`.
---
---@param motion treemotion.OperatorMotion
---@param range treemotion.OperatorRange
---@param change boolean
---@return treemotion.OperatorRange
---
function M.stop_at_line_end(motion, range, change)
    if range.finish_row <= motion.tail_row then
        return range
    end

    local length = #codepoint.line(motion.tail_row)

    if length == 0 then
        -- An empty line is a word of its own (`:help word`): Vim's `dw`
        -- there acts on the line break, while `cw` just starts inserting.
        if change then
            return _range(motion.start_row, motion.start_column, motion.start_row, motion.start_column, false)
        end

        local finish_row, finish_column = _after_character(motion.start_row, motion.start_column)

        return _range(motion.start_row, motion.start_column, finish_row, finish_column, true)
    end

    return _trimmed(motion, motion.tail_row, length)
end

--- The range for `dw`/`cw`/`yW`/...: the `w` motion, trimmed per `settings`.
--- Doesn't read or move the cursor.
---
---@param units treemotion._UnitSource
---@param start_row integer
---@param start_column integer
---@param count integer
---@param settings treemotion.OperatorSettings
---@param step treemotion._Step
---@return treemotion.OperatorRange
---
function M.forward_range(units, start_row, start_column, count, settings, step)
    local unit, start_leaf = units.unit_at(start_row, start_column, true)

    if not unit and not _has_parser() then
        local row, column = step(units, start_row, start_column, count)

        return _range(start_row, start_column, row, column, false)
    end

    if settings.change_to_end and _is_non_blank(start_row, start_column) then
        return _change_to_end_range(units, start_row, start_column, unit, start_leaf, count)
    end

    local motion = _forward_motion(units, start_row, start_column, unit, start_leaf, count, step)
    local range = M.trim_skipped_text(motion, settings.skipped_text)

    if settings.stop_at_line_end then
        range = M.stop_at_line_end(motion, range, settings.change)
    end

    return M.balance_brackets(range)
end

--- The range for `de`/`dge`/...: inclusive when `settings.inclusive` is on
--- and the motion moved forward. Backward inclusion uses a forced `v`
--- instead (see `runner.operator_keys`).
---
---@param units treemotion._UnitSource
---@param start_row integer
---@param start_column integer
---@param count integer
---@param settings treemotion.OperatorSettings
---@param step treemotion._Step
---@return treemotion.OperatorRange
---
function M.inclusive_range(units, start_row, start_column, count, settings, step)
    local target_row, target_column = step(units, start_row, start_column, count)
    local moved = target_row ~= start_row or target_column ~= start_column

    if
        not settings.inclusive
        or not moved
        or position.is_before(target_row, target_column, start_row, start_column)
    then
        return _range(start_row, start_column, target_row, target_column, false)
    end

    local finish_row, finish_column = _after_character(target_row, target_column)

    return M.balance_brackets(_range(start_row, start_column, finish_row, finish_column, true))
end

---@param range treemotion.OperatorRange
---
function M.apply(range)
    _set_cursor_onemore(range.finish_row, range.finish_column)
end

---@param units treemotion._UnitSource
---@param count integer
---@param settings treemotion.OperatorSettings
---@param step treemotion._Step
---
function M.forward_to_start(units, count, settings, step)
    local row, column = position.cursor_position()

    M.apply(M.forward_range(units, row, column, count, settings, step))
end

---@param units treemotion._UnitSource
---@param count integer
---@param settings treemotion.OperatorSettings
---@param step treemotion._Step
---
function M.inclusive(units, count, settings, step)
    local row, column = position.cursor_position()

    M.apply(M.inclusive_range(units, row, column, count, settings, step))
end

return M
