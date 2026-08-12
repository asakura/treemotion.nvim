--- Generic treesitter leaf-node traversal, shared by every `motion` runner.
---
--- A "leaf" is any node with no children (e.g. an identifier, a number, or a
--- single punctuation token like `.` or `,`) -- the finest-grained unit
--- `word` motions move between. Punctuation nodes are unnamed in most treesitter
--- grammars but still count as leaves here, since real Vim's `w` stops on
--- punctuation too. A "run" is a maximal sequence of leaves with no gap
--- (whitespace/newline) between them -- the coarser unit `WORD` motions move
--- between, mirroring how Vim's real `w` is bounded by character-class changes
--- while `W` is bounded only by blanks.

local M = {}

--- Descend to the first leaf inside `node` (including `node` itself).
---
---@param node TSNode Any node to search from.
---@return TSNode # The first leaf, in document order.
---
function M.first_leaf(node)
    local child = node:child(0)

    if not child then
        return node
    end

    return M.first_leaf(child)
end

--- Descend to the last leaf inside `node` (including `node` itself).
---
---@param node TSNode Any node to search from.
---@return TSNode # The last leaf, in document order.
---
function M.last_leaf(node)
    local count = node:child_count()

    if count == 0 then
        return node
    end

    return M.last_leaf(assert(node:child(count - 1)))
end

--- Find the leaf directly after `node`, in document order.
---
---@param node TSNode A leaf (or any node) to start searching from.
---@return TSNode? # The next leaf, if `node` isn't the last leaf in the tree.
---
function M.next_leaf(node)
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

--- Find the leaf directly before `node`, in document order.
---
---@param node TSNode A leaf (or any node) to start searching from.
---@return TSNode? # The previous leaf, if `node` isn't the first leaf in the tree.
---
function M.previous_leaf(node)
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

--- Check if `first` ends exactly where `second` starts.
---
---@param first TSNode The earlier of the two leaves.
---@param second TSNode The later of the two leaves.
---@return boolean # `true` if there's no whitespace/newline between them.
---
function M.is_contiguous(first, second)
    local end_row, end_column = first:end_()
    local start_row, start_column = second:start()

    return end_row == start_row and end_column == start_column
end

--- Find the last leaf in the contiguous run that `node` belongs to.
---
---@param node TSNode Any leaf.
---@return TSNode # `node` itself, or a later leaf if the run continues.
---
function M.run_end(node)
    local current = node

    while true do
        local next_ = M.next_leaf(current)

        if not next_ or not M.is_contiguous(current, next_) then
            return current
        end

        current = next_
    end
end

--- Find the first leaf in the contiguous run that `node` belongs to.
---
---@param node TSNode Any leaf.
---@return TSNode # `node` itself, or an earlier leaf if the run continues.
---
function M.run_start(node)
    local current = node

    while true do
        local previous = M.previous_leaf(current)

        if not previous or not M.is_contiguous(previous, current) then
            return current
        end

        current = previous
    end
end

return M
