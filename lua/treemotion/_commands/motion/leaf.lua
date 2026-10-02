--- Walk treesitter leaves in document order, across language injections.
---
--- A childless node is a leaf. So is a node whose children leave some of its
--- non-blank text uncovered, such as tree-sitter-rust's `line_comment`, whose
--- only child is the `//`.
---
--- Inside an injected tree every step is checked against the piece the walk
--- started in, because an `injection.combined` tree stitches unrelated
--- stretches of source together.

local injection = require("treemotion._commands.motion.injection")

local M = {}

--- Whether the text strictly between the two positions has a non-blank character.
---
---@param row1 integer
---@param column1 integer
---@param row2 integer
---@param column2 integer
---@return boolean
---
local function _has_non_blank_between(row1, column1, row2, column2)
    if row1 > row2 or (row1 == row2 and column1 >= column2) then
        return false
    end

    -- A root node's end can sit one row past the last line, which is unreadable.
    local ok, lines = pcall(vim.api.nvim_buf_get_text, 0, row1, column1, row2, column2, {})

    if not ok then
        return false
    end

    return table.concat(lines, "\n"):find("%S") ~= nil
end

--- Weak-keyed by node. A reparse creates new node objects, so entries never go stale.
local _uncovered_text_cache = setmetatable({}, { __mode = "k" })

--- Whether `node` has non-blank text that none of its children cover.
---
---@param node TSNode
---@return boolean
---
local function _has_uncovered_text(node)
    local cached = _uncovered_text_cache[node]

    if cached ~= nil then
        return cached
    end

    local row, column = node:start()
    local count = node:child_count()
    local result = false

    for index = 0, count - 1 do
        local child = assert(node:child(index))
        local child_row, child_column = child:start()

        if _has_non_blank_between(row, column, child_row, child_column) then
            result = true

            break
        end

        row, column = child:end_()
    end

    if not result then
        local end_row, end_column = node:end_()

        result = _has_non_blank_between(row, column, end_row, end_column)
    end

    _uncovered_text_cache[node] = result

    return result
end

---@param node TSNode
---@return boolean
---
local function _is_leaf(node)
    return node:child_count() == 0 or _has_uncovered_text(node)
end

--- Climb from `node` to its outermost ancestor with uncovered text, if any.
---
---@param node TSNode
---@return TSNode
---
local function _settle(node)
    while true do
        local parent = node:parent()

        if not parent or not _has_uncovered_text(parent) then
            return node
        end

        node = parent
    end
end

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

    node = _settle(node)

    local child_ltree, piece = injection.injected_content(node)

    if child_ltree then
        piece = assert(piece)
        local entry = _leaf_at(child_ltree, row, column, forward)

        if entry and injection.within_piece(entry, piece) then
            return entry
        end
    end

    if _is_leaf(node) then
        return node
    end

    return _nearest_leaf_in_gap(node, row, column, forward)
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
function M.leaf_at(row, column, forward)
    -- `get_parser()` returns `nil` on some Neovim versions and errors on others.
    local success, parser = pcall(vim.treesitter.get_parser, vim.api.nvim_get_current_buf())

    if not success or not parser then
        return nil
    end

    -- One column wide: `LanguageTree:parse()` skips an injected region when
    -- given a zero-width range at its exact start. See `DESIGN.md`.
    parser:parse({ row, column, row, column + 1 })

    return _leaf_at(parser, row, column, forward)
end

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

    if _is_leaf(node) then
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

    if _is_leaf(node) then
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
function M.next_leaf(node)
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
end

--- The leaf before `node`. Leaving an injected piece continues from its host node.
---
---@param node TSNode
---@return TSNode?
---
function M.previous_leaf(node)
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
end

return M
