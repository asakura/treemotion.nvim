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
--- untouched. The rules only look at motion units, leaves, brackets and
--- blank characters in the buffer, never at node types, so they work the
--- same for any grammar.
---
--- Visual mode is never used, so the `'<`/`'>` marks (`gv`) stay the
--- user's. A forward inclusive range is turned into the exclusive range
--- ending one character later. When that's the end of a line, the cursor
--- is put there with `'virtualedit'` briefly set to `"onemore"`. A backward
--- inclusive range (`dge`) must include the character under the cursor the
--- operator started from, which no cursor position can do, so the `<Plug>`
--- mappings force the motion with `v` instead (see
--- `_commands.motion.runner.operator_keys`).

local codepoint = require("treemotion._commands.motion.codepoint")
local constant = require("treemotion._commands.motion.constant")
local position = require("treemotion._commands.motion.position")
local shape = require("treemotion._commands.motion.shape")

local M = {}

--- How a motion runs under an operator: `M.forward_to_start` or `M.inclusive`.
---
--- `step` is the motion's own `_commands.motion.shape` step.
---
-- luacheck: push ignore 631
---@alias treemotion._OperatorMove fun(units: treemotion._UnitSource, count: integer, pending: treemotion.OperatorSettings, step: treemotion._Step)
-- luacheck: pop

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

--- Check whether the current buffer has a treesitter parser.
---
--- Without one there are no units anywhere, which is different from being
--- past the last unit.
---
---@return boolean
local function _has_parser()
    return vim.treesitter.get_parser(0, nil, { error = false }) ~= nil
end

--- Check whether `row`/`column` sits on a non-blank character.
---
---@param row integer
---@param column integer
---@return boolean
local function _is_non_blank(row, column)
    local character = codepoint.line(row):sub(column + 1, column + 1)

    return character ~= "" and not character:match("%s")
end

--- Where the token from `row`/`column` ends (exclusive), never before `row`/`column`.
---
--- A token runs to `span_row`/`span_column`, the end of its leaf (or `W`
--- run), but stops at the first of:
---
--- - the end of `row`'s line, since some grammars end a leaf at the next
---   row's column 0 (a trailing newline);
--- - the first blank from `row`/`column`. Prose splits a whole sentence out
---   of one leaf, so its span alone would take the `` ` `` in "and `code`"
---   along with "and ";
--- - `next_unit`'s start, if given and not before `row`/`column`.
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

--- Where the skipped text at `row`/`column` ends (exclusive).
---
--- Used when the position sits on non-blank text that no unit covers: an
--- insignificant leaf such as Nix's `=`, or a `"skip"` delimiter such as
--- the `_` in `foo_bar`. That text is what the operator is aimed at, so it
--- is the token there (see `_token_end`): at least its first character, up
--- to the end of the leaf (or `W` run) there, cut at the next unit.
---
---@param units treemotion._UnitSource
---@param row integer
---@param column integer
---@param next_unit treemotion.MotionUnit? `units.unit_at(row, column, true)`.
---@param start_leaf TSNode? The leaf that same call started from.
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

--- Each opening bracket's closing bracket.
---
---@type table<string, string>
local _CLOSING_BRACKET = { ["("] = ")", ["["] = "]", ["{"] = "}" }

---@type table<string, true>
local _CLOSING_BRACKETS = { [")"] = true, ["]"] = true, ["}"] = true }

--- Check whether the bracket at `row`/`column` is part of the code's structure.
---
--- Grammars parse real brackets as unnamed tokens (`(`, `[[`, ...). A
--- bracket inside a named leaf (a string's content, a comment) is just text
--- in it, so it only counts while the whole range stays inside that leaf,
--- as when `dw` runs over prose in one comment. A range that runs out of
--- the leaf treats it as one opaque token: `dW` on the `"` of `")" .. x`
--- mustn't stop at the `)`.
---
--- Without a parser every bracket counts.
---
--- The node is looked up with `descendant_for_range()` rather than
--- `vim.treesitter.get_node()`, whose `include_anonymous` option only exists
--- on Neovim 0.11+: without it every bracket would resolve to its named
--- parent and look like text in a leaf.
---
---@param parser vim.treesitter.LanguageTree? The buffer's parser, if any.
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

--- Where a range from `start` to `finish` (exclusive) ends without taking a
--- closing bracket it didn't open.
---
--- `dw` on the `c` of `(config.lib)` should leave the `)` behind, while `dw`
--- on the `(` takes the whole `(config.lib)`. Closing brackets at the very
--- start of the range are the ones the cursor is on, so they stay in.
--- Brackets are matched by kind, so the `]` in `(a]` closes nothing, and
--- only structural ones count (see `_is_structural_bracket`).
---
---@param start_row integer
---@param start_column integer
---@param finish_row integer
---@param finish_column integer
---@return integer, integer # `finish`, or the first unopened closing bracket after `start`.
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

--- Put the cursor at `row`/`column`, which may be just past a line's last character.
---
--- Outside Visual and Insert mode the cursor can't normally go there, so
--- `'virtualedit'` is set to `"onemore"` for the move. The pending operator
--- still uses that position after the option is restored. Only the
--- window-local value is touched, and an unset one (`""`, following the
--- global value) is put back unset.
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

--- `range`, ending before the first closing bracket it didn't open.
---
--- See `_before_unopened_bracket`. Only for ranges that run forward from
--- the cursor. The last step for every forward range, after any trimming.
---
---@param range treemotion.OperatorRange
---@return treemotion.OperatorRange
function M.balance_brackets(range)
    local finish_row, finish_column = range.finish_row, range.finish_column

    local finish_line = codepoint.line(finish_row)

    -- An empty line has no character to step past: the range ends there,
    -- as with `M.stop_at_line_end`'s range on one.
    if range.inclusive and #finish_line > 0 then
        finish_column = math.min(#finish_line, finish_column + codepoint.char_width(finish_line, finish_column + 1))
    end

    local row, column = _before_unopened_bracket(range.start_row, range.start_column, finish_row, finish_column)

    if row == finish_row and column == finish_column then
        return range
    end

    if not range.inclusive then
        return _range(range.start_row, range.start_column, row, column, false)
    end

    if column == 0 then
        -- The bracket starts a line: end on the last character before it,
        -- keeping the line breaks in between. Empty lines have no last
        -- character, and ending on one would take its line break (see
        -- `M.apply`), so they're stepped over, back to the start's line.
        row = row - 1

        while row > range.start_row and #codepoint.line(row) == 0 do
            row = row - 1
        end

        column = #codepoint.line(row)
    end

    column = codepoint.last_character_column(row, column)

    return _range(range.start_row, range.start_column, row, column, true)
end

--- `cw`/`cW`: change to the end of the current unit, like `ce`/`cE`.
---
--- Only used while `settings.change_to_end` is set (see
--- `treemotion.OperatorSettings`).
---
--- On skipped text (see `_skipped_text_end`) that text counts as the
--- current unit. Further counts step like `e`/`E` (`shape.next_end`).
---
---@param units treemotion._UnitSource
---@param start_row integer
---@param start_column integer
---@param unit treemotion.MotionUnit? `units.unit_at(start_row, start_column, true)`, `nil` past the last unit.
---@param start_leaf TSNode? The leaf that same call started from.
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

    local finish_row, finish_column = position.clamp(end_row, codepoint.last_character_column(end_row, end_column))

    if count > 1 then
        finish_row, finish_column = shape.next_end(units, finish_row, finish_column, count - 1)
    end

    return M.balance_brackets(_range(start_row, start_column, finish_row, finish_column, true))
end

--- The `w`/`W` motion an operator runs, before any trimming.
---
--- `start` is where the operator starts and `target` where the motion
--- lands. `tail` is where the last unit moved over ends (or the skipped
--- text the final step started on, see `_skipped_text_end`), the point the
--- trimming steps measure from. `token_end` is `tail` pushed out to the end
--- of that unit's leaf (or `W` run), for `"keep_between_tokens"`.
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

--- The untrimmed `w`/`W` motion from `start_row`/`start_column`.
---
--- Past the buffer's last unit (its last word, trailing blanks, or skipped
--- text such as a final `=`) the motion has nowhere to go, so it lands at
--- the end of the line, like Vim's `dw` at the end of the buffer.
---
---@param units treemotion._UnitSource
---@param start_row integer
---@param start_column integer
---@param unit treemotion.MotionUnit? `units.unit_at(start_row, start_column, true)`.
---@param start_leaf TSNode? The leaf that same call started from.
---@param count integer
---@param step treemotion._Step `shape.next_start`.
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

--- `motion`'s range, as an exclusive one ending at `motion`'s target.
---
---@param motion treemotion.OperatorMotion
---@return treemotion.OperatorRange
local function _motion_range(motion)
    return _range(motion.start_row, motion.start_column, motion.target_row, motion.target_column, false)
end

--- `motion`'s range ending at `row`/`column` instead.
---
--- A trimming step never empties a range: if `row`/`column` isn't past the
--- start, it's the untrimmed motion's range.
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

--- `motion`'s range, without the skipped text after its last unit.
---
--- - `"keep"` ends the range at the first non-blank character after
---   `motion`'s tail, so skipped text is never included.
--- - `"keep_between_tokens"` measures from the token's end instead, so
---   skipped delimiters inside the same token (the `_` in `foo_bar`) are
---   still included.
--- - `"delete"` doesn't trim.
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

--- `range`, ending at the end of `motion`'s tail line rather than on a later line.
---
--- Like Vim's `dw` on a line's last word (`:help word`'s "Another special
--- case"), which takes any trailing blanks with it, and so does `dw` on
--- those trailing blanks. On an empty line the range is the line break
--- itself, as with Vim's `dw` there, or nothing at all for `change`.
---
---@param motion treemotion.OperatorMotion
---@param range treemotion.OperatorRange `motion`'s range, from `M.trim_skipped_text`.
---@param change boolean Whether the operator is `c`.
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
        return _range(motion.start_row, motion.start_column, motion.start_row, motion.start_column, not change)
    end

    return _trimmed(motion, motion.tail_row, length)
end

--- The range `dw`/`cw`/`yW`/... should act on: the `w`/`W` motion's, trimmed per `settings`.
---
--- The motion is measured once (see `treemotion.OperatorMotion`), then
--- passed through one step per setting:
---
--- - `skipped_text`: `M.trim_skipped_text`.
--- - `stop_at_line_end`: `M.stop_at_line_end`.
--- - always: `M.balance_brackets`.
---
--- `change_to_end` replaces all of that with `ce`'s range. Without a
--- parser it's the plain motion's range.
---
--- Measured purely from `start_row`/`start_column`: the cursor is neither
--- read nor moved (see `M.apply`).
---
---@param units treemotion._UnitSource
---@param start_row integer Where the operator starts (the cursor, before the motion).
---@param start_column integer
---@param count integer
---@param settings treemotion.OperatorSettings
---@param step treemotion._Step `shape.next_start`.
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

--- The range `de`/`dge`/... should act on: the motion's, including both ends.
---
--- The plain (exclusive) range when `settings.inclusive` is off. A motion
--- that didn't move gives an empty range, rather than the character under
--- the cursor.
---
--- A backward range (`dge`) is exclusive too: an inclusive one would have
--- to include the character the operator started from, which only a forced
--- `v` can do (see `_commands.motion.runner.operator_keys`). The `<Plug>` mappings
--- add that `v`, and the motion then runs as a plain one.
---
--- Measured purely from `start_row`/`start_column`, like `M.forward_range`.
---
---@param units treemotion._UnitSource
---@param start_row integer Where the operator starts (the cursor, before the motion).
---@param start_column integer
---@param count integer
---@param settings treemotion.OperatorSettings
---@param step treemotion._Step The `e`/`E`/`ge`/`gE`-shape step.
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

    return M.balance_brackets(_range(start_row, start_column, target_row, target_column, true))
end

--- Make the pending operator act on `range`.
---
--- An exclusive range just needs the cursor at its `finish`, as for a plain
--- motion, even at the end of a line (see `_set_cursor_onemore`). An
--- inclusive range (always a forward one, see `M.inclusive_range`) becomes
--- the exclusive range ending after its last character, so an empty line's
--- `finish` takes its line break: the cursor goes to the next line's start,
--- and Vim makes that linewise when the range starts the line (`:help
--- exclusive-linewise`), as with its own `dw` on an empty line. On the
--- buffer's last line there's no line break to take.
---
--- Never starts Visual mode, so `'<`/`'>` are left alone.
---
---@param range treemotion.OperatorRange
---
function M.apply(range)
    local row, column = range.finish_row, range.finish_column

    if range.inclusive then
        local line = codepoint.line(row)

        if #line > 0 then
            column = column + codepoint.char_width(line, column + 1)
        elseif row + 1 < vim.api.nvim_buf_line_count(0) then
            row, column = row + 1, 0
        end
    end

    _set_cursor_onemore(row, column)
end

--- `dw`/`cw`/`yW`/...: act on `M.forward_range`, from the cursor.
---
---@param units treemotion._UnitSource
---@param count integer
---@param settings treemotion.OperatorSettings
---@param step treemotion._Step `shape.next_start`.
---
function M.forward_to_start(units, count, settings, step)
    local row, column = position.cursor_position()

    M.apply(M.forward_range(units, row, column, count, settings, step))
end

--- `de`/`dge`/...: act on `M.inclusive_range`, from the cursor.
---
---@param units treemotion._UnitSource
---@param count integer
---@param settings treemotion.OperatorSettings
---@param step treemotion._Step The `e`/`E`/`ge`/`gE`-shape step.
---
function M.inclusive(units, count, settings, step)
    local row, column = position.cursor_position()

    M.apply(M.inclusive_range(units, row, column, count, settings, step))
end

return M
