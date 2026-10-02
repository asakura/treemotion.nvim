--- Which treesitter nodes count as a single leaf.
---
--- A childless node is a leaf. So is a node whose children leave some of its
--- non-blank text uncovered, such as tree-sitter-rust's `line_comment`, whose
--- only child is the `//`.

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

---@param node TSNode
---@return boolean
---
function M.is_leaf(node)
    return node:child_count() == 0 or M.has_uncovered_text(node)
end

--- Climb from `node` to its outermost ancestor with uncovered text, if any.
---
---@param node TSNode
---@return TSNode
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
