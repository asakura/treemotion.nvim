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
---
--- A node with children still counts as a leaf, though, if those children
--- don't cover its entire span -- see `_has_uncovered_text`'s docstring for
--- why (tree-sitter-rust's plain `//`/`/* */` comments are the motivating,
--- confirmed-against-the-real-grammar case).
---
--- A `TSNode` only exposes tree-shaped navigation (`:parent()`, `:child(i)`,
--- `:next_sibling()`, `:prev_sibling()`) -- nothing gives you "the next leaf
--- in the document" directly. `next_leaf`/`previous_leaf` build that on top
--- by climbing to a parent when a node has no next/previous sibling, then
--- descending back down into the first/last leaf of whatever sibling turns
--- up; `run_start`/`run_end` are then just that walk repeated while
--- `is_contiguous` holds, giving `W`/`E`/`B`/`gE` their run boundaries.

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
--- every leaf-based motion: `next_leaf`/`previous_leaf` climb from a leaf
--- to its parent looking for a sibling, and a childless `//` leaf's only
--- "sibling" is the *next* `line_comment` entirely, so `w` jumps clean over
--- the rest of the comment (or, from a position past the `//` child,
--- `get_node()` returns `line_comment` itself, which `current_leaf`
--- mistakes for a blank-line-style gap and searches for neighbors that
--- don't exist). This is what tells the two situations apart: a genuine
--- gap (a blank line) is always blank between children; real leftover
--- content (Rust's comment text) never is.
---
---@param node TSNode
---@return boolean
---
local function _has_uncovered_text(node)
    local row, column = node:start()
    local count = node:child_count()

    for index = 0, count - 1 do
        local child = assert(node:child(index))
        local child_row, child_column = child:start()

        if _has_non_blank_between(row, column, child_row, child_column) then
            return true
        end

        row, column = child:end_()
    end

    local end_row, end_column = node:end_()

    return _has_non_blank_between(row, column, end_row, end_column)
end

--- Whether `node` should be treated as a leaf -- either a real childless
--- token, or a node with children that don't fully cover it (see
--- `_has_uncovered_text`).
---
---@param node TSNode
---@return boolean
---
local function _is_leaf(node)
    return node:child_count() == 0 or _has_uncovered_text(node)
end

--- Find the two leaves bracketing a gap no leaf covers (e.g. a blank line).
---
--- `get_node()` finds the *smallest* node whose range contains the cursor,
--- which lands here instead of on a leaf whenever the cursor sits somewhere
--- no leaf's range reaches -- a blank line being the common case, since
--- treesitter grammars have no node for "nothing." When that happens, none
--- of `gap_parent`'s own children contain the cursor either (otherwise
--- `get_node()` would have descended into that child instead), so the
--- cursor falls in the gap between two specific children -- or before the
--- first, or after the last. This walks those direct children once to find
--- which gap that is, then descends into whichever side `forward` asks for.
---
---@param gap_parent TSNode The non-leaf node `get_node()` returned.
---@param row integer 0-indexed cursor row.
---@param column integer 0-indexed cursor column.
---@param forward boolean Look for the next leaf after the gap, else the previous one.
---@return TSNode? # The nearest real leaf in the requested direction, if any.
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

    if forward then
        if after then
            return M.first_leaf(after)
        end

        -- The gap is after `gap_parent`'s last child (e.g. a blank line at
        -- the end of a block) -- the next leaf, if any, lives outside
        -- `gap_parent` entirely.
        return M.next_leaf(gap_parent)
    end

    if before then
        return M.last_leaf(before)
    end

    -- Mirror image: the gap is before `gap_parent`'s first child.
    return M.previous_leaf(gap_parent)
end

--- Find the leaf directly under the cursor, or nearest it.
---
--- `get_node()` can return a node with children instead of a real leaf --
--- whenever the cursor sits in a gap no leaf covers, most commonly a blank
--- line (treesitter grammars have no node for blank lines at all). Rather
--- than handing that ancestor to callers that expect an actual leaf (which
--- would silently strand `w`/`W`-family motions there, since a node with no
--- previous/next sibling of its own looks indistinguishable from the start
--- or end of the whole document), `_nearest_leaf_in_gap` finds the real
--- leaf immediately before or after the gap instead.
---
--- Before that, though, `get_node()`'s result is settled upward past any
--- parent with uncovered text of its own (see `_has_uncovered_text`) --
--- otherwise a cursor sitting exactly on a partial-coverage node's child
--- (tree-sitter-rust's anonymous `//` inside `line_comment`, e.g.) would
--- resolve to that child directly, even though `_is_leaf` would refuse to
--- descend into it from the other direction (starting at `line_comment`
--- and looking for its first leaf). Settling first keeps both directions
--- agreeing on the same leaf for the same span, however the cursor got there.
---
---@param forward boolean Off a leaf, prefer the nearest leaf after the cursor over the nearest one before it.
---@return TSNode? # The leaf under (or nearest) the cursor, if a parser and a leaf exist that way.
---
function M.current_leaf(forward)
    -- `get_parser()` returns `nil, message` when no parser can be created on
    -- some Neovim versions, but `error()`s with the same message on others
    -- (e.g. 0.11) -- `pcall` handles both the same way.
    local success, parser = pcall(vim.treesitter.get_parser, vim.api.nvim_get_current_buf())

    if not success or not parser then
        return nil
    end

    -- `get_node()` can return a stale/invalid node against an unparsed
    -- tree, so make sure the tree covering the cursor is up to date first.
    parser:parse()

    -- `include_anonymous` matters here: without it, `get_node()` only
    -- returns *named* nodes, so a cursor sitting on punctuation (which is
    -- unnamed in most grammars, see this module's docstring) would resolve
    -- to its named parent instead of the punctuation leaf itself.
    local node = vim.treesitter.get_node({ include_anonymous = true })

    if not node then
        return nil
    end

    while true do
        local parent = node:parent()

        if not parent or not _has_uncovered_text(parent) then
            break
        end

        node = parent
    end

    if _is_leaf(node) then
        return node
    end

    local row, column = M.cursor_position()

    return _nearest_leaf_in_gap(node, row, column, forward)
end

--- Read the cursor's position, converted to `TSNode`'s 0-indexed row convention.
---
--- `nvim_win_get_cursor` returns a 1-indexed row (matching `:` command-line
--- line numbers), but every `TSNode:start()`/`:end_()` row is 0-indexed --
--- this is the single place that conversion happens, so callers can compare
--- cursor positions against node positions directly.
---
---@return integer, integer # The cursor's 0-indexed row and column.
function M.cursor_position()
    local cursor = vim.api.nvim_win_get_cursor(0)

    return cursor[1] - 1, cursor[2]
end

--- Descend to the first leaf inside `node` (including `node` itself).
---
--- Repeatedly takes the 0th child until `_is_leaf` says to stop -- a node
--- with no children is, by definition, a leaf (see this module's
--- docstring), and so is a node whose children don't fully cover it (see
--- `_has_uncovered_text`), since descending into a partial child would
--- leave the rest of `node`'s own text unreachable. This is the base case
--- `next_leaf` lands on after climbing to a next sibling.
---
---@param node TSNode Any node to search from.
---@return TSNode # The first leaf, in document order.
---
function M.first_leaf(node)
    if _is_leaf(node) then
        return node
    end

    return M.first_leaf(assert(node:child(0)))
end

--- Descend to the last leaf inside `node` (including `node` itself).
---
--- Mirror image of `first_leaf`: repeatedly takes the last child until
--- `_is_leaf` says to stop. This is the base case `previous_leaf` lands on
--- after climbing to a previous sibling.
---
---@param node TSNode Any node to search from.
---@return TSNode # The last leaf, in document order.
---
function M.last_leaf(node)
    if _is_leaf(node) then
        return node
    end

    return M.last_leaf(assert(node:child(node:child_count() - 1)))
end

--- Find the leaf directly after `node`, in document order.
---
--- `TSNode` has no "next node in the document" operation, only tree
--- navigation -- so this climbs from `node` toward the root, checking each
--- ancestor (starting with `node` itself) for a next sibling. The first one
--- found is where the next leaf lives; `first_leaf` descends into it to
--- find the actual leaf, rather than stopping at that sibling subtree's
--- root. Reaching the root with no sibling anywhere along the way means
--- `node` was the last leaf in the whole tree.
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
--- Mirror image of `next_leaf`: climbs toward the root looking for a
--- previous sibling, then `last_leaf` descends into it.
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
--- The one primitive `run_start`/`run_end` build their whole-run walk on:
--- comparing raw coordinates, not tree structure, since two leaves can sit
--- in entirely different branches of the tree (e.g. the last token of one
--- nested expression, and the first token of the next) while still being
--- immediately adjacent in the document.
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
--- Walks `next_leaf` forward one step at a time, stopping as soon as
--- `is_contiguous` fails (a gap) or there's no next leaf at all -- giving
--- `W`/`E`'s notion of a "WORD" boundary.
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
--- Mirror image of `run_end`, walking `previous_leaf` backward instead --
--- gives `B`/`gE`'s notion of a "WORD" boundary.
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
