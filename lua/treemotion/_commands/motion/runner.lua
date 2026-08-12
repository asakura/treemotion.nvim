--- The `motion` implementation, independent of `:TreeMotion`'s command-line parsing.
---
--- `w`/`e`/`b`/`ge` move between individual treesitter leaves.
--- `W`/`E`/`B`/`gE` move between contiguous *runs* of leaves (see
--- `_commands.motion.leaf`'s module docstring). Both families share the same
--- four step shapes below -- `W`/`E`/`B`/`gE` are just `w`/`e`/`b`/`ge` with
--- `leaf.run_start`/`leaf.run_end` used to expand a leaf to its run instead
--- of treating it as a unit of one.

local leaf = require("treemotion._commands.motion.leaf")

local M = {}

--- Identity `run_start`/`run_end`: a "unit" that's just the leaf itself.
---
---@param node TSNode Any leaf.
---@return TSNode # `node`, unchanged.
---
local function _single_leaf(node)
    return node
end

---@return TSNode? # The smallest leaf-or-not node under the cursor, if the buffer has a parser.
local function _current_node()
    local parser = vim.treesitter.get_parser(vim.api.nvim_get_current_buf())

    if not parser then
        return nil
    end

    -- `get_node()` can return a stale/invalid node against an unparsed
    -- tree, so make sure the tree covering the cursor is up to date first.
    parser:parse()

    -- `include_anonymous` matters here: without it, `get_node()` only
    -- returns *named* nodes, so a cursor sitting on punctuation (which is
    -- unnamed in most grammars, see `_commands.motion.leaf`) would resolve
    -- to its named parent instead of the punctuation leaf itself.
    return vim.treesitter.get_node({ include_anonymous = true })
end

---@return integer, integer # The cursor's 0-indexed row and column.
local function _cursor_position()
    local cursor = vim.api.nvim_win_get_cursor(0)

    return cursor[1] - 1, cursor[2]
end

---@param node TSNode The node to move the cursor to the start of.
local function _set_cursor_to_start(node)
    local row, column = node:start()

    vim.api.nvim_win_set_cursor(0, { row + 1, column })
end

---@param node TSNode The node to move the cursor to the (inclusive) end of.
local function _set_cursor_to_end(node)
    local row, column = node:end_()

    vim.api.nvim_win_set_cursor(0, { row + 1, math.max(column - 1, 0) })
end

---@param node TSNode
---@return boolean # `true` if the cursor already sits on `node`'s start.
local function _is_cursor_at_start(node)
    local row, column = node:start()
    local cursor_row, cursor_column = _cursor_position()

    return cursor_row == row and cursor_column == column
end

---@param node TSNode
---@return boolean # `true` if the cursor already sits on `node`'s (inclusive) end.
local function _is_cursor_at_end(node)
    local row, column = node:end_()
    column = math.max(column - 1, 0)
    local cursor_row, cursor_column = _cursor_position()

    return cursor_row == row and cursor_column == column
end

--- `w`/`W`: unconditionally advance to the start of the next unit.
---
---@param count integer How many units to move over.
---@param run_end fun(node: TSNode): TSNode Expand a leaf to the end of its unit.
---@param run_start fun(node: TSNode): TSNode Expand a leaf to the start of its unit.
---
local function _move_forward_to_start(count, run_end, run_start)
    for _ = 1, count do
        local node = _current_node()

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

--- `ge`/`gE`: unconditionally retreat to the end of the previous unit.
---
---@param count integer How many units to move over.
---@param run_start fun(node: TSNode): TSNode Expand a leaf to the start of its unit.
---@param run_end fun(node: TSNode): TSNode Expand a leaf to the end of its unit.
---
local function _move_backward_to_end(count, run_start, run_end)
    for _ = 1, count do
        local node = _current_node()

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

--- `e`/`E`: advance to the end of the current unit, or the next one if already there.
---
---@param count integer How many units to move over.
---@param run_end fun(node: TSNode): TSNode Expand a leaf to the end of its unit.
---
local function _move_forward_to_end(count, run_end)
    for _ = 1, count do
        local node = _current_node()

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

--- `b`/`B`: retreat to the start of the current unit, or the previous one if already there.
---
---@param count integer How many units to move over.
---@param run_start fun(node: TSNode): TSNode Expand a leaf to the start of its unit.
---
local function _move_backward_to_start(count, run_start)
    for _ = 1, count do
        local node = _current_node()

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

--- Move like `w`: to the start of the next treesitter leaf.
---
---@param count number? A 1-or-more value. How many leaves to move over.
---
function M.run_w(count)
    _move_forward_to_start(count or 1, _single_leaf, _single_leaf)
end

--- Move like `ge`: to the end of the previous treesitter leaf.
---
---@param count number? A 1-or-more value. How many leaves to move over.
---
function M.run_ge(count)
    _move_backward_to_end(count or 1, _single_leaf, _single_leaf)
end

--- Move like `e`: to the end of the current or next treesitter leaf.
---
---@param count number? A 1-or-more value. How many leaves to move over.
---
function M.run_e(count)
    _move_forward_to_end(count or 1, _single_leaf)
end

--- Move like `b`: to the start of the current or previous treesitter leaf.
---
---@param count number? A 1-or-more value. How many leaves to move over.
---
function M.run_b(count)
    _move_backward_to_start(count or 1, _single_leaf)
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
