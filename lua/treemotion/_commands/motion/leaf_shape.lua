--- Leaf detection for `_commands.motion.leaf`: which treesitter nodes count
--- as a single leaf.
---
--- A node with no children is always a leaf. A node with children still
--- counts as one if those children don't cover its entire span (see
--- `M.has_uncovered_text`). `M.settle` climbs from a node to the outermost
--- such ancestor, so a position on a partial-coverage node's child resolves
--- to the whole node.

local M = {}

--- Whether the buffer text strictly between `(row1, column1)` and `(row2,
--- column2)` has any non-blank character in it.
---
--- `pcall` guards `nvim_buf_get_text`: a node's `:end_()` can sit one row
--- past the buffer's last line (a root node covering the implicit trailing
--- newline), which isn't a readable range but can't hold text either.
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

    local ok, lines = pcall(vim.api.nvim_buf_get_text, 0, row1, column1, row2, column2, {})

    if not ok then
        return false
    end

    return table.concat(lines, "\n"):find("%S") ~= nil
end

--- `M.has_uncovered_text` result cache, weak-keyed by node.
---
--- Walks re-check the same nodes repeatedly, and each uncached check reads
--- the buffer once per child, which is expensive for wide nodes (a table
--- literal with thousands of fields). Neovim returns the same Lua object for
--- repeated lookups of one tree-sitter node, and a reparse produces new
--- objects, so a stale entry is never observed.
local _uncovered_text_cache = setmetatable({}, { __mode = "k" })

--- Whether `node` has non-blank text of its own that no child covers.
---
--- Most nodes are either pure containers, where children cover every
--- non-blank byte, or childless tokens. tree-sitter-rust's `//` and `/* */`
--- comments are neither: `line_comment`'s only child is the anonymous `//`,
--- and the comment text has no node. Treating such a node as a container
--- would make that text unreachable by leaf walks, so it is a leaf instead.
--- Blank text between children (e.g. a blank line) doesn't count.
---
---@param node TSNode
---@return boolean
---
function M.has_uncovered_text(node)
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

--- Whether `node` should be treated as a leaf -- either a real childless
--- token, or a node with children that don't fully cover it (see
--- `M.has_uncovered_text`).
---
---@param node TSNode
---@return boolean
---
function M.is_leaf(node)
    return node:child_count() == 0 or M.has_uncovered_text(node)
end

--- Climb from `node` past every ancestor with uncovered text of its own.
---
--- Without this, a position on a partial-coverage node's child (Rust's `//`
--- inside `line_comment`) would resolve to that child, even though
--- `M.is_leaf` never descends into it.
---
---@param node TSNode
---@return TSNode # `node` itself, or its outermost uncovered-text ancestor.
---
function M.settle(node)
    while true do
        local parent = node:parent()

        if not parent or not M.has_uncovered_text(parent) then
            return node
        end

        node = parent
    end
end

return M
