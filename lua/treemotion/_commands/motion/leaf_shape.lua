--- Leaf detection for `_commands.motion.leaf`: which treesitter nodes count
--- as a single leaf.
---
--- A node with no children is always a leaf. A node with children still
--- counts as one if those children don't cover its entire span -- see
--- `M.has_uncovered_text`'s docstring for why (tree-sitter-rust's plain
--- `//`/`/* */` comments are the motivating, confirmed-against-the-real-grammar
--- case). `M.settle` climbs from a node to the outermost such ancestor, so a
--- position on a partial-coverage node's child resolves to the whole node.

local M = {}

--- Whether the buffer text strictly between `(row1, column1)` and `(row2,
--- column2)` has any non-blank character in it.
---
--- `pcall` guards `nvim_buf_get_text`: a node's own `:end_()` can sit one
--- row past the buffer's last line (a root node covering an implicit
--- trailing newline is the common case), which isn't a valid range to read
--- -- but a range like that can never hold real text anyway, so treating a
--- read failure as "nothing non-blank here" is exactly right, not just a
--- safe fallback.
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

--- Whether `node` has any of its own span that isn't covered by a child,
--- where that leftover text has a real (non-blank) character in it.
---
--- Most grammars only ever produce nodes that are pure containers (every
--- byte belongs to some child -- two statements either side of a blank
--- line still fully "cover" their parent this way, since the blank line
--- itself is real text, just whitespace-only, so it doesn't count) or pure
--- tokens (no children at all). tree-sitter-rust's regular `//`/`/* */`
--- comments are neither: `line_comment` has exactly one child, an
--- anonymous `//` covering only its first two bytes, with nothing at all
--- representing the rest of the comment's real text -- confirmed against
--- the real grammar, where `// foo bar`'s only child is `(// 0,0-0,2)`,
--- leaving `" foo bar"` with no node of its own whatsoever (unlike `///`
--- doc comments, whose marker and text are full sibling nodes, the same
--- shape as Lua's `--` opener and `comment_content`). Treating a node like
--- that as a normal container -- descend into its one child, treat the
--- child as the leaf -- leaves everything past the child invisible to
--- every leaf-based motion: `leaf.next_leaf`/`leaf.previous_leaf` climb from a leaf
--- to its parent looking for a sibling, and a childless `//` leaf's only
--- "sibling" is the *next* `line_comment` entirely, so `w` jumps clean over
--- the rest of the comment (or, from a position past the `//` child,
--- `get_node()` returns `line_comment` itself, which `leaf.current_leaf`
--- mistakes for a blank-line-style gap and searches for neighbors that
--- don't exist). This is what tells the two situations apart: a genuine
--- gap (a blank line) is always blank between children; real leftover
--- content (Rust's comment text) never is.
---
--- `M.has_uncovered_text` result cache, weak-keyed by node identity.
---
--- `M.is_leaf` (and through it `leaf.first_leaf`/`leaf.last_leaf`) and `M.settle`'s
--- settle-upward loop all call `M.has_uncovered_text` on the *same* node
--- every time a walk re-descends into (or re-settles on) it -- e.g. `gg`/`G`
--- repeatedly re-entering the same wide node from outside, or several
--- separate motions each landing near it. Uncached, the cost is
--- O(node's own child count) `nvim_buf_get_text` calls every single time,
--- since most grammars put every sibling of a wide construct (a large
--- object/table/array literal's fields, say) as *direct* children of one
--- node -- confirmed to scale linearly and repeat in full on every call,
--- with no warm-up speedup, against a synthetic Lua table with thousands of
--- fields (a first `leaf.first_leaf` descent into a 15000-field table's
--- `table_constructor` cost ~32ms, unchanged across repeated calls).
---
--- Weak-keyed on the `TSNode` itself, not `node:id()`: repeated queries for
--- the same underlying tree-sitter node return the *same* Lua object
--- (confirmed directly -- `root:child(0) == root:child(0)` is `true`, not
--- just `:equal()`), so this is safe to key on identity the same way
--- `injection.lua`'s `_tree_to_ltree` keys on `TSTree` identity -- a stale entry can
--- never be observed, since a node whose underlying tree was replaced by a
--- reparse is a different, unreachable object, garbage-collected away
--- rather than silently answering for content that no longer exists there.
local _uncovered_text_cache = setmetatable({}, { __mode = "k" })

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
--- A node sitting exactly on a partial-coverage node's child (tree-sitter-rust's
--- anonymous `//` inside `line_comment`, e.g.) would otherwise resolve to
--- that child directly, even though `M.is_leaf` refuses to descend into it
--- from the other direction. See `leaf.current_leaf`'s docstring.
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
