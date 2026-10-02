--- Walk treesitter leaves in document order, across language injections.
---
--- Inside an injected tree every step is checked against the piece the walk
--- started in, because an `injection.combined` tree stitches unrelated
--- stretches of source together.

local logging = require("mega.logging")

local injection = require("treemotion._commands.motion.injection")
local leaf_shape = require("treemotion._commands.motion.leaf_shape")

local _LOGGER = logging.get_logger("treemotion._commands.motion.leaf")

local M = {}

--- The leaf on the `forward` side of a gap between `gap_parent`'s children
--- (e.g. a blank line), staying in the gap's injected piece.
---
---@param gap_parent TSNode The smallest node containing the position.
---@param row integer
---@param column integer
---@param forward boolean
---@return TSNode?
---
local function _nearest_leaf_in_gap(gap_parent, row, column, forward)
    ---@type TSNode?, TSNode?
    local before, after

    for index = 0, gap_parent:child_count() - 1 do
        local child = assert(gap_parent:child(index))
        local start_row, start_column = child:start()

        if start_row > row or (start_row == row and start_column > column) then
            after = child

            break
        end

        before = child
    end

    local piece = injection.enclosing_piece(gap_parent, row, column)

    if forward then
        if after and (not piece or injection.within_piece(after, piece)) then
            return M.first_leaf(after)
        end

        return M.next_leaf(gap_parent)
    end

    if before and (not piece or injection.within_piece(before, piece)) then
        return M.last_leaf(before)
    end

    return M.previous_leaf(gap_parent)
end

--- The leaf at or nearest `row`/`column` in `ltree`, recursing into nested
--- injections. Uses `descendant_for_range` so punctuation resolves to itself.
---
---@param ltree vim.treesitter.LanguageTree
---@param row integer
---@param column integer
---@param forward boolean
---@return TSNode?
local function _leaf_at(ltree, row, column, forward)
    local node = ltree:node_for_range({ row, column, row, column }, { ignore_injections = true })

    if not node then
        return nil
    end

    node = leaf_shape.settle(node)

    local child_ltree, piece = injection.injected_content(node)

    if child_ltree then
        piece = assert(piece)
        local entry = _leaf_at(child_ltree, row, column, forward)

        if entry and injection.within_piece(entry, piece) then
            return entry
        end
    end

    if leaf_shape.is_leaf(node) then
        return node
    end

    return _nearest_leaf_in_gap(node, row, column, forward)
end

---@param name string
---@param node TSNode?
---
local function _log_leaf_result(name, node)
    if not node then
        _LOGGER:fmt_trace("%s -> nil.", name)

        return
    end

    local row, column = node:start()

    _LOGGER:fmt_trace("%s -> %s at %s:%s.", name, node:type(), row, column)
end

---@param node TSNode
---@return string # e.g. `"identifier at 3:4"`.
---
function M.describe_node(node)
    return string.format("%s at %s:%s", node:type(), node:start())
end

--- Wrap `fn` to trace-log its result.
---
---@generic F: function
---@param name string
---@param fn F
---@param describe_args fun(...: any): string
---@return F
---
function M.logged(name, fn, describe_args)
    return function(...)
        local result = fn(...)

        _log_leaf_result(string.format("%s(%s)", name, describe_args(...)), result)

        return result
    end
end

--- The leaf at `row`/`column`, or the nearest one in `forward`'s direction.
---
--- Resolves in the host grammar first and then asks whether that node is
--- injected content, so highlight-only injections (a C comment injected as
--- `comment`) don't break a node into marker tokens.
---
---@param row integer
---@param column integer
---@param forward boolean
---@return TSNode?
---
M.leaf_at = M.logged("leaf_at", function(row, column, forward)
    -- `get_parser()` returns `nil` on some Neovim versions and errors on others.
    local success, parser = pcall(vim.treesitter.get_parser, vim.api.nvim_get_current_buf())

    if not success or not parser then
        return nil
    end

    -- One column wide: `LanguageTree:parse()` skips an injected region when
    -- given a zero-width range at its exact start.
    parser:parse({ row, column, row, column + 1 })

    return _leaf_at(parser, row, column, forward)
end, function(row, column, forward)
    return string.format("%s:%s, forward=%s", row, column, forward)
end)

---@param ltree vim.treesitter.LanguageTree
---@param piece integer[]
---@return TSNode? # `nil` if `piece` has no leaf of its own.
local function _first_leaf_in_piece(ltree, piece)
    local leaf = _leaf_at(ltree, piece[1], piece[2], true)

    if leaf and injection.within_piece(leaf, piece) then
        return leaf
    end

    return nil
end

---@param ltree vim.treesitter.LanguageTree
---@param piece integer[]
---@return TSNode? # `nil` if `piece` has no leaf of its own.
local function _last_leaf_in_piece(ltree, piece)
    local leaf = _leaf_at(ltree, piece[4], piece[5], false)

    if leaf and injection.within_piece(leaf, piece) then
        return leaf
    end

    return nil
end

--- The first leaf in `node` (maybe `node` itself), entering injected content.
---
---@param node TSNode
---@return TSNode
---
function M.first_leaf(node)
    local child_ltree, piece = injection.injected_content(node)

    if child_ltree then
        local entry = _first_leaf_in_piece(child_ltree, assert(piece))

        if entry then
            return entry
        end
    end

    if leaf_shape.is_leaf(node) then
        return node
    end

    return M.first_leaf(assert(node:child(0)))
end

--- The last leaf in `node` (maybe `node` itself), entering injected content.
---
---@param node TSNode
---@return TSNode
---
function M.last_leaf(node)
    local child_ltree, piece = injection.injected_content(node)

    if child_ltree then
        local entry = _last_leaf_in_piece(child_ltree, assert(piece))

        if entry then
            return entry
        end
    end

    if leaf_shape.is_leaf(node) then
        return node
    end

    return M.last_leaf(assert(node:child(node:child_count() - 1)))
end

--- The first leaf of the nearest next sibling of `node` or an ancestor.
---
---@param node TSNode
---@return TSNode?
local function _climb_next(node)
    ---@type TSNode?
    local current = node

    while current do
        local sibling = current:next_sibling()

        if sibling then
            return M.first_leaf(sibling)
        end

        current = current:parent()
    end

    return nil
end

---@param node TSNode
---@return TSNode?
local function _climb_previous(node)
    ---@type TSNode?
    local current = node

    while current do
        local sibling = current:prev_sibling()

        if sibling then
            return M.last_leaf(sibling)
        end

        current = current:parent()
    end

    return nil
end

--- The leaf after `node`. Leaving an injected piece continues from its host node.
---
---@param node TSNode
---@return TSNode?
---
M.next_leaf = M.logged("next_leaf", function(node)
    local climbed = _climb_next(node)
    local piece, host_ltree = injection.enclosing_piece(node, node:start())

    if not piece then
        return climbed
    end

    host_ltree = assert(host_ltree)

    if climbed and injection.within_piece(climbed, piece) then
        return climbed
    end

    local host_node = injection.host_node_for_piece(host_ltree, piece)

    if not host_node then
        return climbed
    end

    return M.next_leaf(host_node)
end, M.describe_node)

--- The leaf before `node`. Leaving an injected piece continues from its host node.
---
---@param node TSNode
---@return TSNode?
---
M.previous_leaf = M.logged("previous_leaf", function(node)
    local climbed = _climb_previous(node)
    local piece, host_ltree = injection.enclosing_piece(node, node:start())

    if not piece then
        return climbed
    end

    host_ltree = assert(host_ltree)

    if climbed and injection.within_piece(climbed, piece) then
        return climbed
    end

    local host_node = injection.host_node_for_piece(host_ltree, piece)

    if not host_node then
        return climbed
    end

    return M.previous_leaf(host_node)
end, M.describe_node)

return M
