--- Treesitter language-injection bookkeeping for `_commands.motion.leaf`.
---
--- `:help treesitter-language-injections` lets one grammar mark part of its
--- own source (a Nix `''...''` string preceded by a `# bash` comment, a Lua
--- string passed to `vim.cmd()`, a fenced code block in Markdown, ...) to be
--- re-parsed as a *different* language, in its own `LanguageTree`/`TSTree`.
--- `TSNode:parent()` never crosses that boundary -- an injected tree's root
--- always reports a `nil` parent, even though there's real host-language
--- content both before and after it in the buffer. This module answers the
--- questions `leaf.lua` needs to cross it anyway: which injected tree (and
--- which piece of it) a host node stands in for (`M.injected_content`), which
--- piece a node inside injected content belongs to (`M.enclosing_piece`),
--- and which host node to climb back out to once that piece runs out
--- (`M.host_node_for_piece`).
---
--- One more wrinkle: an injection query can mark `injection.combined`,
--- stitching several separate, non-adjacent stretches of source into one
--- logical injected document (e.g. one Nix indented string split into
--- several pieces around its `${...}` interpolations) -- and, confirmed
--- against this very repository's own `flake.nix`, a coarsely-written query
--- can combine several genuinely *unrelated* strings into the very same
--- `LanguageTree` this way. Plain `TSNode:next_sibling()` inside a combined
--- tree can jump straight from one piece to a completely different one,
--- silently skipping over any host-language text in between -- so every
--- step `leaf.lua` takes inside an injected tree is bounds-checked
--- (`M.within_piece`) against the specific stitched sub-range (a "piece",
--- see `_piece_at`) the walk started in, not just "still inside the same
--- `LanguageTree`". Landing outside that range means the piece is
--- exhausted, which is what triggers the climb back into host content
--- instead of accepting wherever the tree jumped to.
---
--- A piece is always a
--- `{start_row, start_column, start_byte, end_row, end_column, end_byte}`
--- array, the same shape `LanguageTree:included_regions()` uses.

local M = {}

--- The root treesitter parser for the current buffer, if any.
---
--- `_owning_ltree` needs this to ask "which `LanguageTree` actually produced
--- this node" -- there's no way to go from a bare `TSNode` back to its
--- owning `LanguageTree` directly, only from the buffer's root parser via
--- `LanguageTree:language_for_range()`.
---
---@return vim.treesitter.LanguageTree?
local function _root_parser()
    local success, parser = pcall(vim.treesitter.get_parser, vim.api.nvim_get_current_buf())

    if not success or not parser then
        return nil
    end

    return parser
end

--- `TSTree` -> owning `LanguageTree`, populated lazily by `_owning_ltree`.
---
--- `leaf.run_start`/`leaf.run_end` call `leaf.next_leaf`/`leaf.previous_leaf` once per leaf in a
--- run, and each of those calls `_owning_ltree` -- without this cache, a
--- long run in a heavily-injected buffer would re-walk the *entire*
--- injection hierarchy from the root once per leaf (O(run_length x
--- injection_count) instead of O(run_length)), even though which
--- `LanguageTree` owns a given `TSTree` never changes once that `TSTree`
--- exists.
---
--- Weak-keyed so entries for a `TSTree` that treesitter has since discarded
--- (an edit reparsed that region into a brand new `TSTree` object, or the
--- buffer itself is gone) are garbage-collected away instead of pinning
--- stale trees in memory forever; a stale entry can never be *wrong*, since
--- `TSTree` identity is never reused for a different owner, only unreachable.
local _tree_to_ltree = setmetatable({}, { __mode = "k" })

--- The `LanguageTree` that actually produced `node` -- the buffer's root
--- tree, or (if `node` sits inside injected content) the injected tree that
--- owns it.
---
--- Deliberately searches by `TSTree` identity (`node:tree()`), *not*
--- position (`LanguageTree:language_for_range()`, which this used to call):
--- `language_for_range()` picks whichever language is deepest at a given
--- point, which is ambiguous in exactly the case that matters most here --
--- a host node standing in for a whole piece of injected content (a Nix
--- `string_fragment`, say) shares its own start position with the injected
--- tree's first token, and `language_for_range()` reports the *injected*
--- language for that point even when asked about the host node itself
--- (confirmed against `flake.nix`'s own `# bash` strings). Comparing
--- `TSTree`s directly has no such ambiguity: a `TSNode` always belongs to
--- exactly one `TSTree`, however many other trees happen to touch the same
--- buffer coordinates -- `LanguageTree:trees()`/`:children()` is what makes
--- that tree, in turn, findable back to the specific `LanguageTree` that
--- parsed it.
---
--- On a cache miss, `search` populates `_tree_to_ltree` for *every* `TSTree`
--- it walks past, not just `target` -- so the first lookup after a reparse
--- pays for one full walk, and every other `TSTree` that walk touched
--- (typically every tree in the buffer) is then a cache hit too.
---
---@param node TSNode
---@return vim.treesitter.LanguageTree?
local function _owning_ltree(node)
    local target = node:tree()
    local cached = _tree_to_ltree[target]

    if cached then
        return cached
    end

    local root = _root_parser()

    if not root then
        return nil
    end

    ---@param ltree vim.treesitter.LanguageTree
    local function search(ltree)
        for _, tree in ipairs(ltree:trees()) do
            _tree_to_ltree[tree] = ltree
        end

        for _, child in pairs(ltree:children()) do
            search(child)
        end
    end

    search(root)

    return _tree_to_ltree[target]
end

--- Merge `regions` (one `included_regions()` group -- one logical injected
--- instance) into maximal runs of regions that touch end-to-end, so a
--- grammar's own internal splitting of one span into several regions isn't
--- mistaken for a genuine gap between stitched pieces.
---
--- tree-sitter-markdown's line-oriented block parsing reports a single
--- fenced code block's content as several separate one-line regions (e.g.
--- `3,0-4,0`, `4,0-5,0`, `5,0-6,0`, `6,0-7,0` for a 4-line fence) even though
--- the underlying source has no gap between them at all -- each region's end
--- exactly equals the next one's start (confirmed against a real
--- `` ```rust `` fence: `code_fence_content:range()` on the *host* side is
--- one clean `3,0`-`7,0` span, but the injected child's own
--- `included_regions()` splits that identical span into those four pieces).
--- Left unmerged, `_piece_at`/`M.within_piece` would treat every line
--- boundary inside such a fence as if it were a real stitched-injection gap
--- -- the same shape a genuine Nix indented-string split around `${...}`
--- interpolations produces, where the gap really does contain host-language
--- text -- forcing `leaf.next_leaf`/`leaf.previous_leaf` to climb back out to the host
--- grammar at every line break instead of stepping across it, and leaving
--- `M.injected_content`'s exact-range match (against the host node's own single,
--- unsplit range) unable to ever succeed. Regions with a genuine gap between
--- them (nothing here touches end-to-end) are left as separate pieces,
--- unchanged.
---
--- Sorts by start position first: `included_regions()` isn't documented to
--- guarantee document order, and an out-of-order run would make the
--- end-equals-next-start check above miss real adjacency.
---
--- Single-region groups (the overwhelming majority -- most injections, e.g.
--- every non-combined one, never split into more than one region) skip the
--- sort/copy/merge work entirely and return `regions` as-is, since this runs
--- once per node `M.injected_content` touches.
---
---@param regions integer[][]
---@return integer[][]
local function _merge_contiguous(regions)
    if #regions <= 1 then
        return regions
    end

    local sorted = vim.list_extend({}, regions)

    table.sort(sorted, function(a, b)
        return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
    end)

    local merged = {}

    for _, region in ipairs(sorted) do
        local last = merged[#merged]

        if last and last[4] == region[1] and last[5] == region[2] then
            last[4], last[5], last[6] = region[4], region[5], region[6]
        else
            table.insert(merged, { region[1], region[2], region[3], region[4], region[5], region[6] })
        end
    end

    return merged
end

--- `_sorted_pieces` result cache, weak-keyed by the `included_regions()`
--- table's own identity.
---
--- `LanguageTree:included_regions()` (`vim/treesitter/languagetree.lua`,
--- not part of this repo) returns `self._regions` directly, not a copy --
--- and every path that can actually change what regions mean
--- (`set_included_regions`, called on injection discovery; `_edit`, called
--- on every buffer edit) unconditionally reassigns `self._regions` to a
--- *new* table, even when the new content happens to be identical to the
--- old. So keying on that table's identity is exactly as safe as
--- `_tree_to_ltree` above (and `leaf.lua`'s `_uncovered_text_cache`) keying on `TSTree`/`TSNode`
--- identity: a stale entry can never be read back, because the table it
--- would be stale *for* no longer exists (it's simply not the table
--- `included_regions()` returns anymore, and gets garbage-collected once
--- nothing else holds it).
local _sorted_pieces_cache = setmetatable({}, { __mode = "k" })

--- Every piece across every one of `ltree`'s `included_regions()` groups
--- (see `_merge_contiguous`), flattened into one array sorted by start
--- position -- what `_piece_at`/`M.injected_content` binary-search instead of
--- linearly scanning.
---
--- A flat sort across groups is safe for both callers' purposes even though
--- `_merge_contiguous` only ever merges *within* one group: regions
--- belonging to the same `LanguageTree` never overlap (each represents a
--- disjoint span of the one parse this `ltree` produces), so pieces from
--- different groups can't collide once mixed into the same sorted order --
--- unlike within a group, there's no adjacency to merge across groups
--- either, since separate groups are separate logical injected instances
--- (see this module's docstring on `injection.combined`).
---
---@param ltree vim.treesitter.LanguageTree
---@return integer[][]
local function _sorted_pieces(ltree)
    local regions = ltree:included_regions()
    local cached = _sorted_pieces_cache[regions]

    if cached then
        return cached
    end

    local pieces = {}

    for _, group in ipairs(regions) do
        for _, piece in ipairs(_merge_contiguous(group)) do
            table.insert(pieces, piece)
        end
    end

    table.sort(pieces, function(a, b)
        return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
    end)

    _sorted_pieces_cache[regions] = pieces

    return pieces
end

--- The rightmost index in `pieces` (see `_sorted_pieces`) whose start is
--- at-or-before `row`/`column`, or `0` if every piece starts later.
---
--- The one primitive `_piece_at`/`M.injected_content` share to avoid a linear
--- scan over every injected region in a language -- see `_sorted_pieces`'s
--- docstring for why an injection-heavy buffer makes that scan a real,
--- measured cost (O(total regions in the language) on every single node a
--- leaf-walk touches, not just ones near an injection).
---
---@param pieces integer[][]
---@param row integer
---@param column integer
---@return integer
local function _floor_index(pieces, row, column)
    local low, high = 1, #pieces
    local result = 0

    while low <= high do
        local mid = math.floor((low + high) / 2)
        local piece = pieces[mid]

        if piece[1] < row or (piece[1] == row and piece[2] <= column) then
            result = mid
            low = mid + 1
        else
            high = mid - 1
        end
    end

    return result
end

--- The specific stitched sub-range of `ltree`'s `included_regions()` that
--- contains `row`/`column` -- one atomic run of injected source text, e.g.
--- one line of a Nix indented string between two `${...}` interpolations.
---
--- Node ranges inside an injected tree always report their *true* position
--- in the host buffer (that's how the stitching in `:help
--- treesitter-language-injections` works even for a combined tree spanning
--- several disjoint pieces), so comparing raw coordinates against each piece
--- here is enough to tell them apart -- the same way `leaf.is_contiguous` already
--- compares raw coordinates to tell leaves apart from runs. Pieces come from
--- `_sorted_pieces` (in turn from `_merge_contiguous`), not
--- `included_regions()` directly -- see their docstrings for why a raw,
--- unmerged region can be narrower than the real gapless run of source it
--- belongs to, and why a sorted, cached array replaces a linear scan here.
---
--- The piece containing `row`/`column`, if any, is always the one at
--- `_floor_index` -- pieces never overlap within one `ltree` (see
--- `_sorted_pieces`), so no piece starting later than the floor could
--- contain an earlier point, and no piece starting earlier than the floor
--- could still be open at `row`/`column` without the floor search having
--- preferred it instead.
---
---@param ltree vim.treesitter.LanguageTree
---@param row integer
---@param column integer
---@return integer[]? # `{start_row, start_column, start_byte, end_row, end_column, end_byte}`, or
---    `nil` if `row`/`column` isn't covered by `ltree` at all.
local function _piece_at(ltree, row, column)
    local pieces = _sorted_pieces(ltree)
    local index = _floor_index(pieces, row, column)

    if index == 0 then
        return nil
    end

    local piece = pieces[index]
    local before_end = row < piece[4] or (row == piece[4] and column < piece[5])

    if before_end then
        return piece
    end

    return nil
end

--- Whether `node`'s start position falls inside `piece` (a `_piece_at` result).
---
--- What `leaf.lua`'s `next_leaf`/`previous_leaf`/`_nearest_leaf_in_gap` use to tell
--- "still inside the piece the walk started in" apart from "a combined
--- tree's sibling walk (or gap scan) jumped to a completely different,
--- unrelated piece" -- see this module's docstring.
---
---@param node TSNode
---@param piece integer[]
---@return boolean
function M.within_piece(node, piece)
    local row, column = node:start()
    local after_start = row > piece[1] or (row == piece[1] and column >= piece[2])
    local before_end = row < piece[4] or (row == piece[4] and column < piece[5])

    return after_start and before_end
end

--- If `node` sits inside injected content, the piece (see `_piece_at`)
--- containing `row`/`column`, plus the host `LanguageTree` that injected it.
---
--- `nil` when `node` belongs to the buffer's root tree, or when `row`/
--- `column` falls outside every piece of `node`'s own injected tree. This is
--- how `leaf.lua` tells "still inside the piece the walk started in" apart
--- from "a combined tree's sibling walk (or gap scan) jumped to a completely
--- different piece" -- see this module's docstring.
---
---@param node TSNode
---@param row integer
---@param column integer
---@return integer[]? piece
---@return vim.treesitter.LanguageTree? host_ltree
function M.enclosing_piece(node, row, column)
    local ltree = _owning_ltree(node)

    if not ltree then
        return nil
    end

    local host_ltree = ltree:parent()

    if not host_ltree then
        return nil
    end

    local piece = _piece_at(ltree, row, column)

    if not piece then
        return nil
    end

    return piece, host_ltree
end

--- Injected "languages" that exist purely to highlight fragments inside an
--- already-meaningful host node (a comment body, a printf-style format
--- string), not to represent that node's content as a different program in
--- its own right.
---
--- The exact-range check in `M.injected_content` below (only a piece covering a
--- node's *entire* span counts) was meant to filter these out on the theory
--- that a marker-only injection's pieces are always small -- true of
--- Neovim's own minimal bundled `queries/c/injections.scm`, but not of the
--- real nvim-treesitter query set virtually every actual user of this
--- plugin has installed: its `queries/c/injections.scm` (and the equivalent
--- for most other languages) injects `((comment) @injection.content (#set!
--- injection.language "comment"))`, whose piece covers a comment's *entire*
--- span exactly, same as a genuine injection would. Confirmed by running
--- this plugin's own test suite with that query active: a C block comment
--- stops being one `w`/`b` stop and gets split word-by-word instead,
--- exactly the "whole embedded block treated as one opaque leaf" bug this
--- module exists to prevent, inverted -- text that should stay one leaf
--- getting split apart instead. `printf`/`doxygen`/`re2c` are the same
--- shape (format-string highlighting, Doxygen tag highlighting, regex
--- syntax inside a comment) and are excluded for the same reason. This is a
--- denylist by name, not a structural test, because nothing in the query
--- itself marks "this injection is for highlighting only" -- it's
--- indistinguishable, at the `included_regions()` level, from a genuine
--- whole-node injection like Lua's `vim.cmd()` strings or a Markdown fence.
local _ANNOTATION_ONLY_LANGUAGES = {
    comment = true,
    doxygen = true,
    printf = true,
    re2c = true,
}

--- If `node`'s entire range is exactly what an injection query captured as
--- `@injection.content` (see `:help treesitter-language-injections`) --
--- i.e. `node` is the host-grammar node standing in for a whole piece of
--- injected content -- the tree that content should be parsed as, and which
--- piece it is.
---
--- The exact-range match is deliberate, not just "does some injection touch
--- `node` at all": a query can use injection for something far narrower
--- than "this whole node is actually a different language" -- see
--- `_ANNOTATION_ONLY_LANGUAGES`'s docstring for why the exact-range check
--- alone isn't enough to filter those out, and why this also checks the
--- injected language's name against that list.
---
--- Matched against `_sorted_pieces(child)`, not `child:included_regions()`
--- directly -- see `_merge_contiguous`'s docstring for why a grammar can
--- split one logical injected span (`node`'s own single, unsplit range)
--- into several gapless regions, which a match against the raw regions
--- could never succeed against, and `_sorted_pieces`'s docstring for why a
--- binary search over a cached, sorted array replaces what used to be a
--- linear scan over every region of every child language -- confirmed to
--- matter in practice, not just in theory: a fixed-size, fixed-position
--- walk measurably slows down as unrelated injection count grows elsewhere
--- in the *same* document (0.055 ms/step at 190 fences, 0.286 ms/step at
--- 2000, over the same first 300 steps in both), even though the walk
--- itself never gets any longer or touches more content.
---
--- Parses lazily, not upfront: `ltree:parse(...)` at `node`'s own start,
--- narrowed to one column (the same boundary-quirk-avoiding shape
--- `leaf.current_leaf` uses), discovers-and-parses whatever injected children
--- exist at `node` right before checking them, since this is the one choke
--- point every `leaf.lua` walk entry point (`first_leaf`/`last_leaf`/`_leaf_at`)
--- already calls on every node it touches -- see `leaf.current_leaf`'s own
--- comment on why a walk that reaches a not-yet-touched injected tree
--- elsewhere in the buffer still gets it parsed here, lazily, rather than
--- needing an upfront full-buffer parse to guarantee it's ready in advance.
---
--- Once a match is found, `child:parse(true)` commits that *entire* child
--- language, not just the one matched piece: `LanguageTree:is_valid()`'s
--- `_is_entirely_valid` fast path (an O(1) check instead of an O(region
--- count) scan on every later `parse()`/`is_valid()` call against this
--- child, including every later call this function makes for an unrelated
--- node) only kicks in once *all* of a language's discovered regions are
--- parsed -- so a language actually being walked (e.g. every `` ```rust ``
--- fence in a Markdown buffer, once any one of them is entered) is worth
--- paying for in full, once, while a language never entered at all (e.g.
--- `markdown_inline` in a walk that stays inside code fences) still costs
--- nothing. See `notes/injection-parse-performance.md` for the full
--- benchmark history: this exact mechanism (Attempts 3/4) was a severe
--- regression before `_merge_contiguous` existed, because a match could
--- never succeed for a multi-region language like Markdown code fences, so
--- `child:parse(true)` never fired and the fast path was never reached; once
--- matching was fixed, the same mechanism measures even or slightly ahead of
--- the eager baseline on long walks, and meaningfully ahead on cold-start
--- and on touching not-yet-visited territory in an already-warm buffer.
---
---@param node TSNode
---@return vim.treesitter.LanguageTree? child_ltree
---@return integer[]? piece
function M.injected_content(node)
    local ltree = _owning_ltree(node)

    if not ltree then
        return nil
    end

    local row1, column1, row2, column2 = node:range()
    ltree:parse({ row1, column1, row1, column1 + 1 })

    for _, child in pairs(ltree:children()) do
        if not _ANNOTATION_ONLY_LANGUAGES[child:lang()] then
            local pieces = _sorted_pieces(child)
            local index = _floor_index(pieces, row1, column1)

            -- `_floor_index` finds the rightmost piece starting at-or-before
            -- `row1`/`column1`, which is only a candidate match if its start
            -- is *exactly* `row1`/`column1` -- walk backward while ties on
            -- that exact start remain, since two pieces from different
            -- groups could in principle share a start without sharing an
            -- end (see `_sorted_pieces`'s docstring on why cross-group
            -- pieces are safe to compare this way at all).
            while index >= 1 do
                local piece = pieces[index]

                if piece[1] ~= row1 or piece[2] ~= column1 then
                    break
                end

                if piece[4] == row2 and piece[5] == column2 then
                    child:parse(true)
                    return child, piece
                end

                index = index - 1
            end
        end
    end

    return nil
end

--- The host-grammar node an injection query captured to produce `piece` --
--- the same node `M.injected_content` finds by descending from the host side,
--- reachable here from inside the injected tree instead, once `piece` runs
--- out of content of its own (see `leaf.next_leaf`/`leaf.previous_leaf`).
---
---@param host_ltree vim.treesitter.LanguageTree
---@param piece integer[]
---@return TSNode?
function M.host_node_for_piece(host_ltree, piece)
    return host_ltree:node_for_range({ piece[1], piece[2], piece[4], piece[5] }, { ignore_injections = true })
end

return M
