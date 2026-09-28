--- The `motion` implementation, independent of `:TreeMotion`'s command-line parsing.
---
--- Real Vim's word motions come in four *shapes*, not just "forward" and
--- "backward": `w`/`W` unconditionally advance to the start of the next
--- word; `ge`/`gE` unconditionally retreat to the end of the previous word;
--- `e`/`E` advance to the end of the current word, or the next one if the
--- cursor is already there; `b`/`B` retreat to the start of the current
--- word, or the previous one if the cursor is already there. Every
--- `_move_*` function below implements exactly one of those four shapes.
---
--- Each shape works over two different notions of "word":
--- `w`/`e`/`b`/`ge` move between sub-word units -- individual treesitter
--- leaves, optionally split further by naming convention (camelCase,
--- kebab-case, ...) per `commands.motion.small`, via
--- `_commands.motion.word`. `W`/`E`/`B`/`gE` move between contiguous *runs*
--- of whole leaves (see `_commands.motion.leaf`'s module docstring),
--- optionally split the same way per `commands.motion.big` (only once
--- `.enabled = true`; by default a run ignores case entirely, the same way
--- real Vim's `W` ignores punctuation inside a WORD), via
--- `_commands.motion.bigword`. The two families are symmetric, one level
--- apart, and expose the same `current_unit`/`next_unit`/`previous_unit`
--- API, so each `_move_*` function takes the family to step through as its
--- `units` argument.

local logging = require("mega.logging")

local codepoint = require("treemotion._commands.motion.codepoint")
local leaf = require("treemotion._commands.motion.leaf")
local bigword = require("treemotion._commands.motion.bigword")
local word = require("treemotion._commands.motion.word")

local _LOGGER = logging.get_logger("treemotion._commands.motion.runner")

local M = {}

--- Move the cursor to `node`'s first character.
---
--- Converts `TSNode`/`treemotion.MotionUnit`'s 0-indexed row to
--- `nvim_win_set_cursor`'s 1-indexed row; the column needs no conversion,
--- since both are already 0-indexed.
---
---@param node TSNode|treemotion.MotionUnit Anything with a `:start()` -- a leaf or unit.
local function _set_cursor_to_start(node)
    local row, column = node:start()

    vim.api.nvim_win_set_cursor(0, { row + 1, column })
end

--- Move the cursor to `node`'s last character.
---
--- `node:end_()` is the column *after* the last character (exclusive), so
--- this steps back to the character itself via `codepoint.last_character_column`,
--- landing on its lead byte even when it's multi-byte UTF-8.
---
---@param node TSNode|treemotion.MotionUnit Anything with an `:end_()` -- a leaf or unit.
local function _set_cursor_to_end(node)
    local row, column = node:end_()

    vim.api.nvim_win_set_cursor(0, { row + 1, codepoint.last_character_column(row, column) })
end

--- Check if the cursor already sits on `node`'s first character.
---
--- `b`/`B` use this to decide whether to retreat to the *previous* unit, or
--- just snap to the start of the current one -- mirroring how real Vim's
--- `b` only skips the current word if the cursor is already at its start.
---
---@param node TSNode|treemotion.MotionUnit
---@return boolean # `true` if the cursor already sits on `node`'s start.
local function _is_cursor_at_start(node)
    local row, column = node:start()
    local cursor_row, cursor_column = leaf.cursor_position()

    return cursor_row == row and cursor_column == column
end

--- Check if the cursor already sits on `node`'s last character.
---
--- `e`/`E` use this to decide whether to advance to the *next* unit, or
--- just snap to the end of the current one -- mirroring how real Vim's `e`
--- only skips the current word if the cursor is already at its end.
---
---@param node TSNode|treemotion.MotionUnit
---@return boolean # `true` if the cursor already sits on `node`'s (inclusive) end.
local function _is_cursor_at_end(node)
    local row, column = node:end_()
    column = codepoint.last_character_column(row, column)
    local cursor_row, cursor_column = leaf.cursor_position()

    return cursor_row == row and cursor_column == column
end

--- Check if the cursor sits anywhere within `node`'s range.
---
--- `w`/`ge` (and their `W`/`gE` counterparts) use this to tell a *real*
--- current unit -- the cursor genuinely sitting inside it -- apart from one
--- `leaf.current_leaf()`/`word.current_unit()` had to substitute because the
--- cursor was in a gap no unit covers (e.g. a blank line): in that case
--- `node` is already the nearest unit in the direction they're moving, so
--- unconditionally stepping to the *next*/*previous* one from there would
--- overshoot by one. See `_move_forward_to_start`/`_move_backward_to_end`.
---
---@param node TSNode|treemotion.MotionUnit
---@return boolean # `true` if the cursor is inside `node`'s range, `false` for a gap `node` substitutes for.
local function _is_cursor_inside(node)
    local start_row, start_column = node:start()
    local end_row, end_column = node:end_()
    local cursor_row, cursor_column = leaf.cursor_position()

    if cursor_row < start_row or (cursor_row == start_row and cursor_column < start_column) then
        return false
    end

    if cursor_row > end_row or (cursor_row == end_row and cursor_column >= end_column) then
        return false
    end

    return true
end

--- The unit-stepping API `_commands.motion.word` and `_commands.motion.bigword` share.
---
--- Every `_move_*` function below takes one of those two modules as its
--- `units` argument, so each of the four shapes is implemented once and
--- serves both `w`/`e`/`b`/`ge` and `W`/`E`/`B`/`gE`. Both modules build
--- theirs with `_commands.motion.unit.new_source`.
---
---@class treemotion._UnitSource
---@field current_unit fun(forward: boolean): treemotion.MotionUnit?
---@field next_unit fun(unit: treemotion.MotionUnit): treemotion.MotionUnit?
---@field previous_unit fun(unit: treemotion.MotionUnit): treemotion.MotionUnit?

--- `w`/`W`-shape move: unconditionally advance to the start of the next unit.
---
--- Over `_commands.motion.word` units, a single leaf like `fooBar` counts
--- as more than one stop. Over `_commands.motion.bigword` units, a single
--- run counts as more than one stop once `commands.motion.big.enabled` is
--- `true` (it's exactly one stop by default, see
--- `bigword.current_unit`/`subword.split_run`). Either way, the gap
--- substitution rule applies -- see `_is_cursor_inside`.
---
---@param units treemotion._UnitSource `_commands.motion.word` or `_commands.motion.bigword`.
---@param count integer How many units to move over.
---
local function _move_forward_to_start(units, count)
    for _ = 1, count do
        local unit = units.current_unit(true)

        if not unit then
            return
        end

        if not _is_cursor_inside(unit) then
            _set_cursor_to_start(unit)
        else
            local next_ = units.next_unit(unit)

            if not next_ then
                return
            end

            _set_cursor_to_start(next_)
        end
    end
end

--- `ge`/`gE`-shape move: unconditionally retreat to the end of the previous unit.
---
--- Same gap substitution rule as `_move_forward_to_start` -- see `_is_cursor_inside`.
---
---@param units treemotion._UnitSource `_commands.motion.word` or `_commands.motion.bigword`.
---@param count integer How many units to move over.
---
local function _move_backward_to_end(units, count)
    for _ = 1, count do
        local unit = units.current_unit(false)

        if not unit then
            return
        end

        if not _is_cursor_inside(unit) then
            _set_cursor_to_end(unit)
        else
            local previous = units.previous_unit(unit)

            if not previous then
                return
            end

            _set_cursor_to_end(previous)
        end
    end
end

--- `e`/`E`-shape move: advance to the end of the current unit, or the next one if already there.
---
---@param units treemotion._UnitSource `_commands.motion.word` or `_commands.motion.bigword`.
---@param count integer How many units to move over.
---
local function _move_forward_to_end(units, count)
    for _ = 1, count do
        local unit = units.current_unit(true)

        if not unit then
            return
        end

        if _is_cursor_at_end(unit) then
            unit = units.next_unit(unit)

            if not unit then
                return
            end
        end

        _set_cursor_to_end(unit)
    end
end

--- `b`/`B`-shape move: retreat to the start of the current unit, or the previous one if already there.
---
---@param units treemotion._UnitSource `_commands.motion.word` or `_commands.motion.bigword`.
---@param count integer How many units to move over.
---
local function _move_backward_to_start(units, count)
    for _ = 1, count do
        local unit = units.current_unit(false)

        if not unit then
            return
        end

        if _is_cursor_at_start(unit) then
            unit = units.previous_unit(unit)

            if not unit then
                return
            end
        end

        _set_cursor_to_start(unit)
    end
end

--- Run `move`, logging the cursor's position before and after.
---
--- Every `M.run_*` entry point goes through this, since it's where a
--- keymap/`:TreeMotion motion` invocation actually starts -- logging here
--- (rather than inside each `_move_*` helper) covers all eight motions with
--- one implementation, and reports exactly what a user would want to
--- reproduce a "cursor didn't land where I expected" report: which motion
--- ran, with what `count`, from where, to where.
---
---@param name string The motion's Vim-facing name (`"w"`, `"gE"`, ...), for the log message.
---@param move fun(units: treemotion._UnitSource, count: integer): nil One of the `_move_*` helpers above.
---@param units treemotion._UnitSource `_commands.motion.word` or `_commands.motion.bigword`.
---@param count integer How many units to move over.
---
local function _run(name, move, units, count)
    local start_row, start_column = leaf.cursor_position()

    _LOGGER:fmt_debug('Running treemotion motion "%s" (count=%s) from %s:%s.', name, count, start_row, start_column)

    move(units, count)

    local end_row, end_column = leaf.cursor_position()

    _LOGGER:fmt_debug('Finished treemotion motion "%s" at %s:%s.', name, end_row, end_column)
end

--- Move like `w`: to the start of the next sub-word unit.
---
---@param count number? A 1-or-more value. How many units to move over.
---
function M.run_w(count)
    _run("w", _move_forward_to_start, word, count or 1)
end

--- Move like `ge`: to the end of the previous sub-word unit.
---
---@param count number? A 1-or-more value. How many units to move over.
---
function M.run_ge(count)
    _run("ge", _move_backward_to_end, word, count or 1)
end

--- Move like `e`: to the end of the current or next sub-word unit.
---
---@param count number? A 1-or-more value. How many units to move over.
---
function M.run_e(count)
    _run("e", _move_forward_to_end, word, count or 1)
end

--- Move like `b`: to the start of the current or previous sub-word unit.
---
---@param count number? A 1-or-more value. How many units to move over.
---
function M.run_b(count)
    _run("b", _move_backward_to_start, word, count or 1)
end

--- Move like `W`: to the start of the next run of contiguous treesitter leaves
--- (or its next sub-word unit, once `commands.motion.big.enabled = true`).
---
---@param count number? A 1-or-more value. How many units to move over.
---
function M.run_W(count)
    _run("W", _move_forward_to_start, bigword, count or 1)
end

--- Move like `gE`: to the end of the previous run of contiguous treesitter leaves
--- (or its previous sub-word unit, once `commands.motion.big.enabled = true`).
---
---@param count number? A 1-or-more value. How many units to move over.
---
function M.run_gE(count)
    _run("gE", _move_backward_to_end, bigword, count or 1)
end

--- Move like `E`: to the end of the current or next run of contiguous treesitter leaves
--- (or its current/next sub-word unit, once `commands.motion.big.enabled = true`).
---
---@param count number? A 1-or-more value. How many units to move over.
---
function M.run_E(count)
    _run("E", _move_forward_to_end, bigword, count or 1)
end

--- Move like `B`: to the start of the current or previous run of contiguous treesitter leaves
--- (or its current/previous sub-word unit, once `commands.motion.big.enabled = true`).
---
---@param count number? A 1-or-more value. How many units to move over.
---
function M.run_B(count)
    _run("B", _move_backward_to_start, bigword, count or 1)
end

return M
