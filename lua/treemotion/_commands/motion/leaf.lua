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
--- don't cover its entire span -- see `leaf_shape.has_uncovered_text`'s docstring for
--- why (tree-sitter-rust's plain `//`/`/* */` comments are the motivating,
--- confirmed-against-the-real-grammar case).
---
--- Nodes aren't always all in the same `TSTree`, either: `:help
--- treesitter-language-injections` lets one grammar mark part of its own
--- source (a Nix `''...''` string preceded by a `# bash` comment, a Lua
--- string passed to `vim.cmd()`, a fenced code block in Markdown, ...) to be
--- re-parsed as a *different* language, in its own `LanguageTree`/`TSTree`.
--- `TSNode:parent()` never crosses that boundary -- an injected tree's root
--- always reports a `nil` parent, even though there's real host-language
--- content both before and after it in the buffer. `_commands.motion.injection`
--- is what lets `first_leaf`/`last_leaf`/`next_leaf`/`previous_leaf` cross
--- it anyway: descending *into* injected
--- content when a would-be leaf turns out to be exactly what an injection
--- query captured, and climbing back *out* to the host node's own neighbors
--- once that content runs out.
---
--- An injection query can also mark `injection.combined`, stitching several
--- non-adjacent stretches of source into one injected tree, so every step
--- taken inside an injected tree is bounds-checked against the piece the
--- walk started in -- see `_commands.motion.injection`'s docstring.
---
--- A `TSNode` only exposes tree-shaped navigation (`:parent()`, `:child(i)`,
--- `:next_sibling()`, `:prev_sibling()`) -- nothing gives you "the next leaf
--- in the document" directly. `next_leaf`/`previous_leaf` build that on top
--- by climbing to a parent when a node has no next/previous sibling, then
--- descending back down into the first/last leaf of whatever sibling turns
--- up; `_commands.motion.run`'s `run_start`/`run_end` are then just that
--- walk repeated while `is_contiguous` holds, giving `W`/`E`/`B`/`gE` their
--- run boundaries. Which nodes count as a leaf at all is
--- `_commands.motion.leaf_shape`'s call.

local logging = require("mega.logging")

local injection = require("treemotion._commands.motion.injection")
local leaf_shape = require("treemotion._commands.motion.leaf_shape")
local position = require("treemotion._commands.motion.position")

local _LOGGER = logging.get_logger("treemotion._commands.motion.leaf")

local M = {}

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
--- If `gap_parent` sits inside an injected tree, the child scan below can
--- find a real "before"/"after" child that nonetheless belongs to a
--- *different* piece than the gap itself (a combined tree's children are
--- sorted by true document position across every piece it owns, not just
--- the one nearest `row`/`column`) -- `injection.enclosing_piece` is what
--- lets it reject that child instead of accepting unrelated, possibly
--- far-away content. See `_commands.motion.injection`'s docstring.
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

        -- The gap is after `gap_parent`'s last child (e.g. a blank line at
        -- the end of a block), or `after` belongs to a piece other than
        -- `gap_parent`'s own -- either way the next leaf, if any, lives
        -- outside `gap_parent`'s own content entirely.
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
--- Mirrors `M.current_leaf`'s own node-or-gap resolution, but for an
--- arbitrary tree/position instead of the live cursor -- used both by
--- `M.current_leaf` itself (once it's confirmed the cursor sits inside a
--- real injection) and to enter a piece of injected content at its exact
--- start/end boundary (see `_first_leaf_in_piece`/`_last_leaf_in_piece`),
--- where there's no real cursor position to read `get_node()` off of.
---
--- Includes the same settle-upward-past-uncovered-text-parent step
--- `M.current_leaf` does (see its docstring), for the same reason: an
--- injected tree can have exactly the same partial-coverage shape a host
--- tree can (confirmed against Neovim's own bundled `markdown`, which
--- injects `inline` content into a separate `markdown_inline` tree whose
--- `emphasis` node has two `emphasis_delimiter` children with real,
--- uncovered `text` between them -- the identical shape `leaf_shape.has_uncovered_text`
--- was originally written against, just one injection boundary deeper).
--- Skipping this step would resolve a position sitting exactly on such a
--- child straight to that child, defeating the whole-node,
--- `subword`-splits-it-into-words handling `leaf_shape.is_leaf`/`leaf_shape.has_uncovered_text`
--- exist to provide in the first place.
---
--- Also checks `injection.injected_content` on the node it resolves, recursing into
--- `_leaf_at` again if it finds one -- an injection can itself contain
--- another injection (confirmed against a Markdown fence tagged as `lua`
--- whose Lua content has its own `vim.cmd([[...]])` -> Vimscript injection,
--- three `LanguageTree`s deep). Without this, resolving a position inside
--- the innermost language would stop one level short, at the host-grammar
--- node the *outer* injection captured -- exactly the "whole embedded block
--- treated as one opaque leaf" bug this module exists to fix, just
--- recurring one injection boundary deeper. The recursive call is
--- bounds-checked against the deeper piece the same way every other
--- injection crossing in this module is (see the module docstring on
--- `injection.combined`); if it fails, this falls back to treating `node`
--- itself as the leaf, same as if no further injection had been found.
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
        -- See `M.current_leaf`'s identical `assert` for why this is safe.
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

--- Log `name`'s result at trace level -- shared by every traversal entry
--- point `M.logged` wraps (`M.current_leaf`/`M.next_leaf`/`M.previous_leaf`/
--- `run.run_start`/`run.run_end`), so a leaf walk's outcome (or lack of one) is
--- reported the same way no matter which of them produced it. Trace, not
--- debug, since these can fire many times over for a single motion (once
--- per leaf a `run_start`/`run_end` walk crosses) -- `mega.logging`'s
--- default level (`info`) never pays even the varargs-table cost for a call
--- site that isn't reporting anything, per `Logger:_log_at_level`.
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
--- Recursive entry points (`M.next_leaf`/`M.previous_leaf`, whose
--- injection-crossing branch calls itself again on the host node) recurse
--- through the wrapped function, so each hop across an injection boundary
--- gets its own log line too, not just the outermost call.
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
--- parent with uncovered text of its own (see `leaf_shape.has_uncovered_text`) --
--- otherwise a cursor sitting exactly on a partial-coverage node's child
--- (tree-sitter-rust's anonymous `//` inside `line_comment`, e.g.) would
--- resolve to that child directly, even though `leaf_shape.is_leaf` would refuse to
--- descend into it from the other direction (starting at `line_comment`
--- and looking for its first leaf). Settling first keeps both directions
--- agreeing on the same leaf for the same span, however the cursor got there.
---
--- Deliberately resolves with `get_node()`'s default `ignore_injections =
--- true` (host grammar only), then hands off to `injection.injected_content` explicitly,
--- rather than just passing `ignore_injections = false` and trusting
--- whatever `get_node()` resolves into on its own -- a grammar can use
--- `:help treesitter-language-injections` for things that have nothing to
--- do with "real" embedded source, e.g. a real-world C query (see
--- `injection.lua`'s `_ANNOTATION_ONLY_LANGUAGES`) injects comment bodies into a tiny
--- marker-only pseudo-language for highlighting (confirmed against `int x;
--- /* foo\nbar */`, where `ignore_injections = false` alone resolves the
--- cursor to a single `/` token deep inside that pseudo-language instead of
--- the intended, already-correct whole-`comment` leaf). `injection.injected_content`'s
--- exact-range match plus its `_ANNOTATION_ONLY_LANGUAGES` name check is
--- what tells that apart from a genuine injection like Nix's `# bash`
--- strings: the exact-range match alone isn't enough, since a marker-only
--- injection can (and, in the real `"comment"` case, does) cover a whole
--- host leaf too.
---
---@param forward boolean Off a leaf, prefer the nearest leaf after the cursor over the nearest one before it.
---@return TSNode? # The leaf under (or nearest) the cursor, if a parser and a leaf exist that way.
---
M.current_leaf = M.logged("current_leaf", function(forward)
    -- `get_parser()` returns `nil, message` when no parser can be created on
    -- some Neovim versions, but `error()`s with the same message on others
    -- (e.g. 0.11) -- `pcall` handles both the same way.
    local success, parser = pcall(vim.treesitter.get_parser, vim.api.nvim_get_current_buf())

    if not success or not parser then
        return nil
    end

    -- `get_node()` can return a stale/invalid node against an unparsed
    -- tree, so make sure the tree covering the cursor is up to date first.
    --
    -- Only the root tree, at the cursor's own one-column-wide range, not a
    -- full `true` parse (`:help LanguageTree:parse()` calls `true` "Can be
    -- slow!") -- this used to call `parser:parse(true)` unconditionally, see
    -- `notes/injection-parse-performance.md` for the two narrowing attempts
    -- that were tried and reverted before this one, and why *this* one
    -- avoids both problems: a *zero-width* range at an injected region's
    -- exact start boundary is what `LanguageTree:parse()`'s intersects-check
    -- silently mishandles, and a one-column-wide range sidesteps that; and
    -- unlike those attempts, this one never depends on `next_leaf`/
    -- `previous_leaf` reaching an as-yet-unparsed tree on their own --
    -- `injection.injected_content` below (the single choke point every leaf-walk entry
    -- point already calls on every node it touches, since an injection can
    -- start at any depth) now does its own lazy, narrow `parse()` right
    -- before checking whether a node matches, so a walk that climbs into a
    -- completely different injected tree elsewhere in the buffer still gets
    -- that tree parsed at the moment it's about to be trusted, not before.
    local row, column = position.cursor_position()
    parser:parse({ row, column, row, column + 1 })

    -- `include_anonymous` matters here: without it, `get_node()` only
    -- returns *named* nodes, so a cursor sitting on punctuation (which is
    -- unnamed in most grammars, see this module's docstring) would resolve
    -- to its named parent instead of the punctuation leaf itself.
    local node = vim.treesitter.get_node({ include_anonymous = true })

    if not node then
        return nil
    end

    node = leaf_shape.settle(node)

    local child_ltree, piece = injection.injected_content(node)

    if child_ltree then
        -- `injection.injected_content` only ever returns `child_ltree` and `piece`
        -- together (both `nil`, or both set) -- `assert` narrows `piece`
        -- back to non-optional for `injection.within_piece`, the same way `piece`'s
        -- own `?` return type can't express that pairing on its own.
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
end, function(forward)
    return string.format("forward=%s", forward)
end)

--- The first real leaf inside `piece` (a single stitched sub-range of an
--- injected tree, from `injection.injected_content`), or `nil` if `piece` has no real
--- content of its own (e.g. a blank line inside the embedded script).
---
--- `_leaf_at`'s own gap fallback can, in principle, walk straight out of
--- `piece` entirely -- a combined tree's root has no parent of its own, so
--- `_nearest_leaf_in_gap` would otherwise keep searching into whatever
--- unrelated piece happens to be next (see this module's docstring on
--- `injection.combined`) -- `injection.within_piece` is what catches that and turns
--- it back into "nothing here", rather than returning content from
--- somewhere else in the buffer.
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
--- Repeatedly takes the 0th child until `leaf_shape.is_leaf` says to stop -- a node
--- with no children is, by definition, a leaf (see this module's
--- docstring), and so is a node whose children don't fully cover it (see
--- `leaf_shape.has_uncovered_text`), since descending into a partial child would
--- leave the rest of `node`'s own text unreachable. This is the base case
--- `next_leaf` lands on after climbing to a next sibling.
---
--- Checked first, though: whether `node` is exactly an injection query's
--- captured content (`injection.injected_content`), in which case the real first leaf
--- lives in the injected tree, not `node`'s own (host-grammar) children --
--- see this module's docstring on `treesitter-language-injections`. A
--- `nil` piece result (e.g. a blank embedded script) falls through to the
--- normal host-grammar descent below, same as `node` having no injection at all.
---
---@param node TSNode Any node to search from.
---@return TSNode # The first leaf, in document order.
---
function M.first_leaf(node)
    local child_ltree, piece = injection.injected_content(node)

    if child_ltree then
        -- See `M.current_leaf`'s identical `assert` for why this is safe.
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
--- Mirror image of `first_leaf`: repeatedly takes the last child until
--- `leaf_shape.is_leaf` says to stop. This is the base case `previous_leaf` lands on
--- after climbing to a previous sibling. Also mirrors `first_leaf`'s
--- injection check -- see its docstring.
---
---@param node TSNode Any node to search from.
---@return TSNode # The last leaf, in document order.
---
function M.last_leaf(node)
    local child_ltree, piece = injection.injected_content(node)

    if child_ltree then
        -- See `M.current_leaf`'s identical `assert` for why this is safe.
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

--- The plain "climb to a next sibling, descend into it" walk, with no
--- awareness of tree/injection boundaries at all -- what `next_leaf` used to
--- be in full, before injection support. Still correct on its own for a
--- node outside any injection, and for one inside a *non-combined*
--- injection (a single, self-contained piece); `M.next_leaf` adds the
--- piece-boundary check on top, for the combined case (see this module's
--- docstring).
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
--- `TSNode` has no "next node in the document" operation, only tree
--- navigation -- so `_climb_next` climbs from `node` toward the root,
--- checking each ancestor (starting with `node` itself) for a next sibling.
--- The first one found is where the next leaf lives; `first_leaf` descends
--- into it to find the actual leaf, rather than stopping at that sibling
--- subtree's root. Reaching the root with no sibling anywhere along the way
--- means `node` was the last leaf in *its own* tree.
---
--- That last part matters once injections are involved: "the last leaf in
--- its own tree" isn't necessarily "the last leaf in the buffer" -- `node`
--- might be inside injected content with real host-language text still
--- ahead of it. So when `node` sits inside a piece of injected content
--- (`injection.enclosing_piece`), `_climb_next`'s result additionally has to
--- fall *inside that same piece* (`injection.within_piece`) to be trusted -- climbing
--- within a `injection.combined` tree can otherwise land on a completely
--- unrelated piece instead (see this module's docstring). Whenever the climb
--- doesn't produce a same-piece result, this falls back to the host-grammar
--- node the injection query captured (`injection.host_node_for_piece`) and asks
--- *its* next leaf instead -- the mirror image of `first_leaf`'s descent
--- into a fresh piece.
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
--- Mirror image of `next_leaf`, including its injection-boundary handling:
--- `_climb_previous` climbs toward the root looking for a previous sibling,
--- then `last_leaf` descends into it; if `node` sits inside a piece of
--- injected content and the climb doesn't stay within that same piece, this
--- falls back to the host-grammar node the injection query captured and
--- asks *its* previous leaf instead.
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
