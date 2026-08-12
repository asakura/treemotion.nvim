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
--- Each shape is implemented twice, over two different notions of "word":
--- `w`/`e`/`b`/`ge` move between sub-word units -- individual treesitter
--- leaves, optionally split further by naming convention (camelCase,
--- kebab-case, ...) per `_commands.motion.subword`, via
--- `_commands.motion.word`. `W`/`E`/`B`/`gE` move between contiguous *runs*
--- of whole leaves (see `_commands.motion.leaf`'s module docstring) and
--- ignore case entirely, the same way real Vim's `W` ignores punctuation
--- inside a WORD. The `W`-family functions are written generically, taking
--- `run_start`/`run_end` as parameters, so `_commands.motion.leaf`'s
--- leaf/run logic can be plugged straight in; the `w`-family functions call
--- `_commands.motion.word` directly instead, since sub-word splitting needs
--- more than just "expand this leaf to its run".

local leaf = require("treemotion._commands.motion.leaf")
local word = require("treemotion._commands.motion.word")

local M = {}

--- Move the cursor to `node`'s first character.
---
--- Converts `TSNode`/`treemotion.WordUnit`'s 0-indexed row to
--- `nvim_win_set_cursor`'s 1-indexed row; the column needs no conversion,
--- since both are already 0-indexed.
---
---@param node TSNode|treemotion.WordUnit Anything with a `:start()` -- a leaf or a sub-word unit.
local function _set_cursor_to_start(node)
    local row, column = node:start()

    vim.api.nvim_win_set_cursor(0, { row + 1, column })
end

--- Move the cursor to `node`'s last character.
---
--- `node:end_()` is the column *after* the last character (exclusive), so
--- this subtracts 1 to land on the character itself -- clamped at 0 so an
--- empty node can't push the column negative.
---
---@param node TSNode|treemotion.WordUnit Anything with an `:end_()` -- a leaf or a sub-word unit.
local function _set_cursor_to_end(node)
    local row, column = node:end_()

    vim.api.nvim_win_set_cursor(0, { row + 1, math.max(column - 1, 0) })
end

--- Check if the cursor already sits on `node`'s first character.
---
--- `b`/`B` use this to decide whether to retreat to the *previous* unit, or
--- just snap to the start of the current one -- mirroring how real Vim's
--- `b` only skips the current word if the cursor is already at its start.
---
---@param node TSNode|treemotion.WordUnit
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
---@param node TSNode|treemotion.WordUnit
---@return boolean # `true` if the cursor already sits on `node`'s (inclusive) end.
local function _is_cursor_at_end(node)
    local row, column = node:end_()
    column = math.max(column - 1, 0)
    local cursor_row, cursor_column = leaf.cursor_position()

    return cursor_row == row and cursor_column == column
end

--- Generic `w`/`W`-shape move: unconditionally advance to the start of the next unit.
---
--- Only `M.run_W` calls this -- `w` has its own sub-word-aware
--- `_move_word_forward_to_start` below. To find the next run: expand the
--- current leaf out to the *end* of its own run (so leaves already known to
--- belong to it are skipped over), take the leaf right after that, then
--- expand forward from there to the *start* of the next run.
---
---@param count integer How many runs to move over.
---@param run_end fun(node: TSNode): TSNode Expand a leaf to the end of its run.
---@param run_start fun(node: TSNode): TSNode Expand a leaf to the start of its run.
---
local function _move_forward_to_start(count, run_end, run_start)
    for _ = 1, count do
        local node = leaf.current_leaf()

        if not node then
            return
        end

        local next_ = leaf.next_leaf(run_end(node))

        if not next_ then
            return
        end

        _set_cursor_to_start(run_start(next_))
    end
end

--- Generic `ge`/`gE`-shape move: unconditionally retreat to the end of the previous unit.
---
--- Only `M.run_gE` calls this -- `ge` has its own sub-word-aware
--- `_move_word_backward_to_end` below. Mirror image of
--- `_move_forward_to_start`: expand backward to the start of the current
--- run, step to the leaf before that, then expand backward from there to
--- the end of the previous run.
---
---@param count integer How many runs to move over.
---@param run_start fun(node: TSNode): TSNode Expand a leaf to the start of its run.
---@param run_end fun(node: TSNode): TSNode Expand a leaf to the end of its run.
---
local function _move_backward_to_end(count, run_start, run_end)
    for _ = 1, count do
        local node = leaf.current_leaf()

        if not node then
            return
        end

        local previous = leaf.previous_leaf(run_start(node))

        if not previous then
            return
        end

        _set_cursor_to_end(run_end(previous))
    end
end

--- Generic `e`/`E`-shape move: advance to the end of the current run, or the next one if already there.
---
--- Only `M.run_E` calls this -- `e` has its own sub-word-aware
--- `_move_word_forward_to_end` below. The `_is_cursor_at_end` check is what
--- distinguishes this from `_move_forward_to_start`: pressing `E`
--- repeatedly from the middle of a run lands on that run's own end before
--- ever advancing to the next one.
---
---@param count integer How many runs to move over.
---@param run_end fun(node: TSNode): TSNode Expand a leaf to the end of its run.
---
local function _move_forward_to_end(count, run_end)
    for _ = 1, count do
        local node = leaf.current_leaf()

        if not node then
            return
        end

        local edge = run_end(node)

        if _is_cursor_at_end(edge) then
            local next_ = leaf.next_leaf(edge)

            if not next_ then
                return
            end

            edge = run_end(next_)
        end

        _set_cursor_to_end(edge)
    end
end

--- Generic `b`/`B`-shape move: retreat to the start of the current run, or the previous one if already there.
---
--- Only `M.run_B` calls this -- `b` has its own sub-word-aware
--- `_move_word_backward_to_start` below. Mirror image of
--- `_move_forward_to_end`.
---
---@param count integer How many runs to move over.
---@param run_start fun(node: TSNode): TSNode Expand a leaf to the start of its run.
---
local function _move_backward_to_start(count, run_start)
    for _ = 1, count do
        local node = leaf.current_leaf()

        if not node then
            return
        end

        local edge = run_start(node)

        if _is_cursor_at_start(edge) then
            local previous = leaf.previous_leaf(edge)

            if not previous then
                return
            end

            edge = run_start(previous)
        end

        _set_cursor_to_start(edge)
    end
end

--- `w`-shape move: unconditionally advance to the start of the next sub-word unit.
---
--- Same shape as `_move_forward_to_start`, but stepping through
--- `_commands.motion.word` units instead of whole leaves/runs, so a single
--- leaf like `fooBar` counts as more than one stop.
---
---@param count integer How many units to move over.
---
local function _move_word_forward_to_start(count)
    for _ = 1, count do
        local unit = word.current_unit()

        if not unit then
            return
        end

        local next_ = word.next_unit(unit)

        if not next_ then
            return
        end

        _set_cursor_to_start(next_)
    end
end

--- `ge`-shape move: unconditionally retreat to the end of the previous sub-word unit.
---
--- Same shape as `_move_backward_to_end`, but over `_commands.motion.word` units.
---
---@param count integer How many units to move over.
---
local function _move_word_backward_to_end(count)
    for _ = 1, count do
        local unit = word.current_unit()

        if not unit then
            return
        end

        local previous = word.previous_unit(unit)

        if not previous then
            return
        end

        _set_cursor_to_end(previous)
    end
end

--- `e`-shape move: advance to the end of the current sub-word unit, or the next one if already there.
---
--- Same shape as `_move_forward_to_end`, but over `_commands.motion.word` units.
---
---@param count integer How many units to move over.
---
local function _move_word_forward_to_end(count)
    for _ = 1, count do
        local unit = word.current_unit()

        if not unit then
            return
        end

        if _is_cursor_at_end(unit) then
            unit = word.next_unit(unit)

            if not unit then
                return
            end
        end

        _set_cursor_to_end(unit)
    end
end

--- `b`-shape move: retreat to the start of the current sub-word unit, or the previous one if already there.
---
--- Same shape as `_move_backward_to_start`, but over `_commands.motion.word` units.
---
---@param count integer How many units to move over.
---
local function _move_word_backward_to_start(count)
    for _ = 1, count do
        local unit = word.current_unit()

        if not unit then
            return
        end

        if _is_cursor_at_start(unit) then
            unit = word.previous_unit(unit)

            if not unit then
                return
            end
        end

        _set_cursor_to_start(unit)
    end
end

--- Move like `w`: to the start of the next sub-word unit.
---
---@param count number? A 1-or-more value. How many units to move over.
---
function M.run_w(count)
    _move_word_forward_to_start(count or 1)
end

--- Move like `ge`: to the end of the previous sub-word unit.
---
---@param count number? A 1-or-more value. How many units to move over.
---
function M.run_ge(count)
    _move_word_backward_to_end(count or 1)
end

--- Move like `e`: to the end of the current or next sub-word unit.
---
---@param count number? A 1-or-more value. How many units to move over.
---
function M.run_e(count)
    _move_word_forward_to_end(count or 1)
end

--- Move like `b`: to the start of the current or previous sub-word unit.
---
---@param count number? A 1-or-more value. How many units to move over.
---
function M.run_b(count)
    _move_word_backward_to_start(count or 1)
end

--- Move like `W`: to the start of the next run of contiguous treesitter leaves.
---
---@param count number? A 1-or-more value. How many runs to move over.
---
function M.run_W(count)
    _move_forward_to_start(count or 1, leaf.run_end, leaf.run_start)
end

--- Move like `gE`: to the end of the previous run of contiguous treesitter leaves.
---
---@param count number? A 1-or-more value. How many runs to move over.
---
function M.run_gE(count)
    _move_backward_to_end(count or 1, leaf.run_start, leaf.run_end)
end

--- Move like `E`: to the end of the current or next run of contiguous treesitter leaves.
---
---@param count number? A 1-or-more value. How many runs to move over.
---
function M.run_E(count)
    _move_forward_to_end(count or 1, leaf.run_end)
end

--- Move like `B`: to the start of the current or previous run of contiguous treesitter leaves.
---
---@param count number? A 1-or-more value. How many runs to move over.
---
function M.run_B(count)
    _move_backward_to_start(count or 1, leaf.run_start)
end

return M
