--- Generic treesitter leaf-node traversal, shared by every `motion` runner.
---
--- A "leaf" is the finest-grained unit `word` motions move between: a node
--- with no children (an identifier, a number, a single punctuation token),
--- or a node whose children don't cover its whole span (see
--- `_commands.motion.leaf_shape`). Unnamed punctuation nodes count as leaves
--- too, since real Vim's `w` stops on punctuation.
---
--- `TSNode` only offers tree navigation (`:parent()`, `:child(i)`,
--- `:next_sibling()`, `:prev_sibling()`). `next_leaf`/`previous_leaf` build
--- "the next leaf in the document" on top of it: climb until an ancestor has
--- a sibling, then descend into that sibling's first/last leaf.
---
--- Walks also cross `:help treesitter-language-injections` boundaries, which
--- `TSNode:parent()` never does (an injected tree's root has no parent).
--- `_commands.motion.injection` supplies the bookkeeping: a host node that
--- stands in for injected content is descended into, and a walk that runs
--- out of an injected piece climbs back out to the host node's neighbors.
--- Every step inside an injected tree is bounds-checked against the piece
--- the walk started in, because an `injection.combined` tree stitches
--- several unrelated stretches of source together.

local logging = require("mega.logging")

local injection = require("treemotion._commands.motion.injection")
local leaf_shape = require("treemotion._commands.motion.leaf_shape")

local _LOGGER = logging.get_logger("treemotion._commands.motion.leaf")

local M = {}

--- Find the leaf on one side of a gap that no leaf covers (e.g. a blank line).
---
--- `get_node()` returns the smallest node containing the cursor, so when no
--- leaf covers the cursor it returns an ancestor instead. None of that
--- ancestor's children contain the cursor, so the cursor sits between two
--- of them (or before the first, or after the last). This finds that gap and
--- descends into the child on the `forward` side.
---
--- A child found this way is only accepted if it belongs to the same
--- injected piece as the gap, since a combined injected tree's children can
--- come from other, far-away pieces.
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

    local piece = injection.enclosing_piece(gap_parent, row, column)

    if forward then
        if after and (not piece or injection.within_piece(after, piece)) then
            return M.first_leaf(after)
        end

        -- The gap is after `gap_parent`'s last child, or `after` belongs to
        -- another piece: the next leaf lives outside `gap_parent`.
        return M.next_leaf(gap_parent)
    end

    if before and (not piece or injection.within_piece(before, piece)) then
        return M.last_leaf(before)
    end

    -- Mirror image: the gap is before `gap_parent`'s first child, or
    -- `before` belongs to a different piece.
    return M.previous_leaf(gap_parent)
end

--- The leaf at (or nearest to) `row`/`column` within `ltree`.
---
--- `M.leaf_at` resolves the buffer's root tree with this, then recurses
--- through it into injected trees. Also used to enter an injected piece at
--- its exact start or end.
---
--- The node is looked up with `descendant_for_range()` (`node_for_range`),
--- not the named-only variant: a position on (usually unnamed) punctuation
--- must resolve to the punctuation itself, not its parent.
---
--- Settles upward past partial-coverage parents (`leaf_shape.settle`), since
--- an injected tree can have that shape too (e.g. `markdown_inline`'s
--- `emphasis`). Recurses when the resolved node is itself injected content,
--- so nested injections (a Markdown fence containing Lua containing
--- `vim.cmd([[...]])`) resolve to the innermost language. If the recursive
--- result falls outside the deeper piece, `node` itself is used instead.
---
---@param ltree vim.treesitter.LanguageTree
---@param row integer
---@param column integer
---@param forward boolean Passed straight to `_nearest_leaf_in_gap`.
---@return TSNode?
local function _leaf_at(ltree, row, column, forward)
    local node = ltree:node_for_range({ row, column, row, column }, { ignore_injections = true })

    if not node then
        return nil
    end

    node = leaf_shape.settle(node)

    local child_ltree, piece = injection.injected_content(node)

    if child_ltree then
        -- `injection.injected_content` returns `child_ltree` and `piece`
        -- together (both `nil`, or both set); `assert` narrows `piece` to
        -- non-optional for `injection.within_piece`.
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

--- Log `name`'s result at trace level.
---
--- Shared by every `M.logged` entry point, so every leaf walk reports its
--- outcome the same way. Trace rather than debug because a single motion can
--- call these once per leaf it crosses.
---
---@param name string The wrapped function's name (plus any arguments worth reporting), for the log message.
---@param node TSNode? The result to report.
---
local function _log_leaf_result(name, node)
    if not node then
        _LOGGER:fmt_trace("%s -> nil.", name)

        return
    end

    local row, column = node:start()

    _LOGGER:fmt_trace("%s -> %s at %s:%s.", name, node:type(), row, column)
end

--- Describe `node` the way every `M.logged` traversal entry point reports its argument.
---
---@param node TSNode
---@return string # e.g. `"identifier at 3:4"`.
---
function M.describe_node(node)
    return string.format("%s at %s:%s", node:type(), node:start())
end

--- Wrap `fn` so each call logs its result via `_log_leaf_result`.
---
--- Recursive entry points recurse through the wrapped function, so each hop
--- across an injection boundary gets its own log line.
---
---@generic F: function
---@param name string The public function's name, for the log message.
---@param fn F The function doing the actual work.
---@param describe_args fun(...: any): string Render `fn`'s arguments for the log message.
---@return F # `fn`, plus logging.
---
function M.logged(name, fn, describe_args)
    return function(...)
        local result = fn(...)

        _log_leaf_result(string.format("%s(%s)", name, describe_args(...)), result)

        return result
    end
end

--- Find the leaf at `row`/`column`, or nearest it.
---
--- When the position sits in a gap no leaf covers (most commonly a blank
--- line), the smallest node containing it is an ancestor rather than a
--- leaf, and `_nearest_leaf_in_gap` finds the real leaf before or after the
--- gap.
---
--- Resolves in the host grammar only (`ignore_injections = true`, see
--- `_leaf_at`) and then asks `injection.injected_content` whether that node
--- is injected content. Following injections straight away would also
--- follow highlight-only injections (e.g. a C comment injected as the
--- `comment` language) down to a single marker token.
---
--- Never reads or moves the cursor, so callers can ask about any position.
---
---@param row integer 0-indexed row.
---@param column integer 0-indexed column.
---@param forward boolean Off a leaf, prefer the nearest leaf after the position over the nearest one before it.
---@return TSNode? # The leaf at (or nearest) the position, if a parser and a leaf exist that way.
---
M.leaf_at = M.logged("leaf_at", function(row, column, forward)
    -- `get_parser()` returns `nil, message` when no parser can be created on
    -- some Neovim versions, but `error()`s with the same message on others
    -- (e.g. 0.11) -- `pcall` handles both the same way.
    local success, parser = pcall(vim.treesitter.get_parser, vim.api.nvim_get_current_buf())

    if not success or not parser then
        return nil
    end

    -- A node can be stale in an unparsed tree, so parse the root tree at the
    -- position first. The range is one column wide, not zero-width:
    -- `LanguageTree:parse()` mishandles a zero-width range at an injected
    -- region's exact start. Injected trees elsewhere are parsed lazily by
    -- `injection.injected_content` as a walk reaches them. See
    -- `notes/injection-parse-performance.md`.
    parser:parse({ row, column, row, column + 1 })

    return _leaf_at(parser, row, column, forward)
end, function(row, column, forward)
    return string.format("%s:%s, forward=%s", row, column, forward)
end)

--- The first real leaf inside `piece` of `ltree`, or `nil` if `piece` has no
--- content of its own (e.g. a blank line inside an embedded script).
---
--- `_leaf_at`'s gap fallback can walk out of `piece` into an unrelated one,
--- so a result outside `piece` is discarded.
---
---@param ltree vim.treesitter.LanguageTree
---@param piece integer[]
---@return TSNode?
local function _first_leaf_in_piece(ltree, piece)
    local leaf = _leaf_at(ltree, piece[1], piece[2], true)

    if leaf and injection.within_piece(leaf, piece) then
        return leaf
    end

    return nil
end

--- Mirror image of `_first_leaf_in_piece`: the last real leaf inside `piece`.
---
---@param ltree vim.treesitter.LanguageTree
---@param piece integer[]
---@return TSNode?
local function _last_leaf_in_piece(ltree, piece)
    local leaf = _leaf_at(ltree, piece[4], piece[5], false)

    if leaf and injection.within_piece(leaf, piece) then
        return leaf
    end

    return nil
end

--- Descend to the first leaf inside `node` (including `node` itself).
---
--- If `node` is exactly an injection's captured content, the first leaf of
--- that injected piece is returned instead. Otherwise takes the first child
--- until `leaf_shape.is_leaf` says to stop.
---
---@param node TSNode Any node to search from.
---@return TSNode # The first leaf, in document order.
---
function M.first_leaf(node)
    local child_ltree, piece = injection.injected_content(node)

    if child_ltree then
        -- See `_leaf_at`'s identical `assert` for why this is safe.
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

--- Descend to the last leaf inside `node` (including `node` itself).
---
--- Mirror image of `M.first_leaf`.
---
---@param node TSNode Any node to search from.
---@return TSNode # The last leaf, in document order.
---
function M.last_leaf(node)
    local child_ltree, piece = injection.injected_content(node)

    if child_ltree then
        -- See `_leaf_at`'s identical `assert` for why this is safe.
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

--- Climb from `node` to the first ancestor (or `node` itself) with a next
--- sibling, and return that sibling's first leaf.
---
--- Unaware of injection pieces; `M.next_leaf` adds that check.
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

--- Mirror image of `_climb_next`, used by `M.previous_leaf`.
---
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

--- Find the leaf directly after `node`, in document order.
---
--- Inside injected content, the climb's result is only trusted if it stays
--- in the same piece. Otherwise the piece is exhausted, and the walk
--- continues from the host node that captured it.
---
---@param node TSNode A leaf (or any node) to start searching from.
---@return TSNode? # The next leaf, if `node` isn't the last leaf in the buffer.
---
M.next_leaf = M.logged("next_leaf", function(node)
    local climbed = _climb_next(node)
    local piece, host_ltree = injection.enclosing_piece(node, node:start())

    if not piece then
        return climbed
    end

    -- `enclosing_piece` only ever returns `piece` and `host_ltree` together.
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

--- Find the leaf directly before `node`, in document order.
---
--- Mirror image of `M.next_leaf`, including its injection handling.
---
---@param node TSNode A leaf (or any node) to start searching from.
---@return TSNode? # The previous leaf, if `node` isn't the first leaf in the buffer.
---
M.previous_leaf = M.logged("previous_leaf", function(node)
    local climbed = _climb_previous(node)
    local piece, host_ltree = injection.enclosing_piece(node, node:start())

    if not piece then
        return climbed
    end

    -- `enclosing_piece` only ever returns `piece` and `host_ltree` together.
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
