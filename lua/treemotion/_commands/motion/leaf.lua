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
--- Nodes aren't always all in the same `TSTree`, either: `:help
--- treesitter-language-injections` lets one grammar mark part of its own
--- source (a Nix `''...''` string preceded by a `# bash` comment, a Lua
--- string passed to `vim.cmd()`, a fenced code block in Markdown, ...) to be
--- re-parsed as a *different* language, in its own `LanguageTree`/`TSTree`.
--- `TSNode:parent()` never crosses that boundary -- an injected tree's root
--- always reports a `nil` parent, even though there's real host-language
--- content both before and after it in the buffer. `_owning_ltree`/
--- `_injection_at`/`_piece_at` below are what let `first_leaf`/`last_leaf`/
--- `next_leaf`/`previous_leaf` cross it anyway: descending *into* injected
--- content when a would-be leaf turns out to be exactly what an injection
--- query captured, and climbing back *out* to the host node's own neighbors
--- once that content runs out.
---
--- One more wrinkle: an injection query can mark `injection.combined`,
--- stitching several separate, non-adjacent stretches of source into one
--- logical injected document (e.g. one Nix indented string split into
--- several pieces around its `${...}` interpolations) -- and, confirmed
--- against this very file's own `flake.nix`, a coarsely-written query can
--- combine several genuinely *unrelated* strings into the very same
--- `LanguageTree` this way. Plain `TSNode:next_sibling()` inside a combined
--- tree can jump straight from one piece to a completely different one,
--- silently skipping over any host-language text in between -- so every
--- step taken inside an injected tree is bounds-checked against the
--- specific stitched sub-range (`_piece_at`'s "piece") the walk started in,
--- not just "still inside the same `LanguageTree`". Landing outside that
--- range means the piece is exhausted, which is what triggers the climb
--- back into host content instead of accepting wherever the tree jumped to.
---
--- A `TSNode` only exposes tree-shaped navigation (`:parent()`, `:child(i)`,
--- `:next_sibling()`, `:prev_sibling()`) -- nothing gives you "the next leaf
--- in the document" directly. `next_leaf`/`previous_leaf` build that on top
--- by climbing to a parent when a node has no next/previous sibling, then
--- descending back down into the first/last leaf of whatever sibling turns
--- up; `run_start`/`run_end` are then just that walk repeated while
--- `is_contiguous` holds, giving `W`/`E`/`B`/`gE` their run boundaries.

local logging = require("mega.logging")

local _LOGGER = logging.get_logger("treemotion._commands.motion.leaf")

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
--- `_has_uncovered_text` result cache, weak-keyed by node identity.
---
--- `_is_leaf`/`M.first_leaf`/`M.last_leaf` (via `_is_leaf`) and `M.current_leaf`'s
--- settle-upward loop all call `_has_uncovered_text` on the *same* node
--- every time a walk re-descends into (or re-settles on) it -- e.g. `gg`/`G`
--- repeatedly re-entering the same wide node from outside, or several
--- separate motions each landing near it. Uncached, the cost is
--- O(node's own child count) `nvim_buf_get_text` calls every single time,
--- since most grammars put every sibling of a wide construct (a large
--- object/table/array literal's fields, say) as *direct* children of one
--- node -- confirmed to scale linearly and repeat in full on every call,
--- with no warm-up speedup, against a synthetic Lua table with thousands of
--- fields (a first `M.first_leaf` descent into a 15000-field table's
--- `table_constructor` cost ~32ms, unchanged across repeated calls).
---
--- Weak-keyed on the `TSNode` itself, not `node:id()`: repeated queries for
--- the same underlying tree-sitter node return the *same* Lua object
--- (confirmed directly -- `root:child(0) == root:child(0)` is `true`, not
--- just `:equal()`), so this is safe to key on identity the same way
--- `_tree_to_ltree` above keys on `TSTree` identity -- a stale entry can
--- never be observed, since a node whose underlying tree was replaced by a
--- reparse is a different, unreachable object, garbage-collected away
--- rather than silently answering for content that no longer exists there.
local _uncovered_text_cache = setmetatable({}, { __mode = "k" })

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
--- `run_start`/`run_end` call `next_leaf`/`previous_leaf` once per leaf in a
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
--- Left unmerged, `_piece_at`/`_within_piece` would treat every line
--- boundary inside such a fence as if it were a real stitched-injection gap
--- -- the same shape a genuine Nix indented-string split around `${...}`
--- interpolations produces, where the gap really does contain host-language
--- text -- forcing `next_leaf`/`previous_leaf` to climb back out to the host
--- grammar at every line break instead of stepping across it, and leaving
--- `_injection_at`'s exact-range match (against the host node's own single,
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
--- once per node `_injection_at` touches.
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
--- `_tree_to_ltree`/`_uncovered_text_cache` above keying on `TSTree`/`TSNode`
--- identity: a stale entry can never be read back, because the table it
--- would be stale *for* no longer exists (it's simply not the table
--- `included_regions()` returns anymore, and gets garbage-collected once
--- nothing else holds it).
local _sorted_pieces_cache = setmetatable({}, { __mode = "k" })

--- Every piece across every one of `ltree`'s `included_regions()` groups
--- (see `_merge_contiguous`), flattened into one array sorted by start
--- position -- what `_piece_at`/`_injection_at` binary-search instead of
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
--- The one primitive `_piece_at`/`_injection_at` share to avoid a linear
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
--- here is enough to tell them apart -- the same way `is_contiguous` already
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
--- What `next_leaf`/`previous_leaf`/`_nearest_leaf_in_gap` use to tell
--- "still inside the piece the walk started in" apart from "a combined
--- tree's sibling walk (or gap scan) jumped to a completely different,
--- unrelated piece" -- see this module's docstring.
---
---@param node TSNode
---@param piece integer[]
---@return boolean
local function _within_piece(node, piece)
    local row, column = node:start()
    local after_start = row > piece[1] or (row == piece[1] and column >= piece[2])
    local before_end = row < piece[4] or (row == piece[4] and column < piece[5])

    return after_start and before_end
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
--- If `gap_parent` sits inside an injected tree, the piece (`_piece_at`)
--- that `row`/`column` -- the gap being resolved -- falls inside, else `nil`.
---
--- `_nearest_leaf_in_gap`'s own child scan below can find a real "before"/
--- "after" child that nonetheless belongs to a *different* piece than the
--- gap itself (a combined tree's children are sorted by true document
--- position across every piece it owns, not just the one nearest `row`/
--- `column`) -- this is what lets it reject that child instead of accepting
--- unrelated, possibly far-away content. See this module's docstring.
---
---@param gap_parent TSNode
---@param row integer
---@param column integer
---@return integer[]?
local function _gap_piece(gap_parent, row, column)
    local ltree = _owning_ltree(gap_parent)

    if not ltree or not ltree:parent() then
        return nil
    end

    return _piece_at(ltree, row, column)
end

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

    local piece = _gap_piece(gap_parent, row, column)

    if forward then
        if after and (not piece or _within_piece(after, piece)) then
            return M.first_leaf(after)
        end

        -- The gap is after `gap_parent`'s last child (e.g. a blank line at
        -- the end of a block), or `after` belongs to a piece other than
        -- `gap_parent`'s own -- either way the next leaf, if any, lives
        -- outside `gap_parent`'s own content entirely.
        return M.next_leaf(gap_parent)
    end

    if before and (not piece or _within_piece(before, piece)) then
        return M.last_leaf(before)
    end

    -- Mirror image: the gap is before `gap_parent`'s first child, or
    -- `before` belongs to a different piece.
    return M.previous_leaf(gap_parent)
end

--- Injected "languages" that exist purely to highlight fragments inside an
--- already-meaningful host node (a comment body, a printf-style format
--- string), not to represent that node's content as a different program in
--- its own right.
---
--- The exact-range check in `_injection_at` below (only a piece covering a
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
--- `M.current_leaf` uses), discovers-and-parses whatever injected children
--- exist at `node` right before checking them, since this is the one choke
--- point every leaf-walk entry point (`first_leaf`/`last_leaf`/`_leaf_at`)
--- already calls on every node it touches -- see `M.current_leaf`'s own
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
local function _injection_at(node)
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
--- uncovered `text` between them -- the identical shape `_has_uncovered_text`
--- was originally written against, just one injection boundary deeper).
--- Skipping this step would resolve a position sitting exactly on such a
--- child straight to that child, defeating the whole-node,
--- `subword`-splits-it-into-words handling `_is_leaf`/`_has_uncovered_text`
--- exist to provide in the first place.
---
--- Also checks `_injection_at` on the node it resolves, recursing into
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

    while true do
        local parent = node:parent()

        if not parent or not _has_uncovered_text(parent) then
            break
        end

        node = parent
    end

    local child_ltree, piece = _injection_at(node)

    if child_ltree then
        -- See `M.current_leaf`'s identical `assert` for why this is safe.
        piece = assert(piece)
        local entry = _leaf_at(child_ltree, row, column, forward)

        if entry and _within_piece(entry, piece) then
            return entry
        end
    end

    if _is_leaf(node) then
        return node
    end

    return _nearest_leaf_in_gap(node, row, column, forward)
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
--- Deliberately resolves with `get_node()`'s default `ignore_injections =
--- true` (host grammar only), then hands off to `_injection_at` explicitly,
--- rather than just passing `ignore_injections = false` and trusting
--- whatever `get_node()` resolves into on its own -- a grammar can use
--- `:help treesitter-language-injections` for things that have nothing to
--- do with "real" embedded source, e.g. a real-world C query (see
--- `_ANNOTATION_ONLY_LANGUAGES`) injects comment bodies into a tiny
--- marker-only pseudo-language for highlighting (confirmed against `int x;
--- /* foo\nbar */`, where `ignore_injections = false` alone resolves the
--- cursor to a single `/` token deep inside that pseudo-language instead of
--- the intended, already-correct whole-`comment` leaf). `_injection_at`'s
--- exact-range match plus its `_ANNOTATION_ONLY_LANGUAGES` name check is
--- what tells that apart from a genuine injection like Nix's `# bash`
--- strings: the exact-range match alone isn't enough, since a marker-only
--- injection can (and, in the real `"comment"` case, does) cover a whole
--- host leaf too.
---
---@param forward boolean Off a leaf, prefer the nearest leaf after the cursor over the nearest one before it.
---@return TSNode? # The leaf under (or nearest) the cursor, if a parser and a leaf exist that way.
---
local function _current_leaf(forward)
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
    -- `_injection_at` below (the single choke point every leaf-walk entry
    -- point already calls on every node it touches, since an injection can
    -- start at any depth) now does its own lazy, narrow `parse()` right
    -- before checking whether a node matches, so a walk that climbs into a
    -- completely different injected tree elsewhere in the buffer still gets
    -- that tree parsed at the moment it's about to be trusted, not before.
    local row, column = M.cursor_position()
    parser:parse({ row, column, row, column + 1 })

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

    local child_ltree, piece = _injection_at(node)

    if child_ltree then
        -- `_injection_at` only ever returns `child_ltree` and `piece`
        -- together (both `nil`, or both set) -- `assert` narrows `piece`
        -- back to non-optional for `_within_piece`, the same way `piece`'s
        -- own `?` return type can't express that pairing on its own.
        piece = assert(piece)
        local entry = _leaf_at(child_ltree, row, column, forward)

        if entry and _within_piece(entry, piece) then
            return entry
        end
    end

    if _is_leaf(node) then
        return node
    end

    return _nearest_leaf_in_gap(node, row, column, forward)
end

--- Log `name`'s result at trace level -- shared by every wrapped traversal
--- entry point below (`M.current_leaf`/`M.next_leaf`/`M.previous_leaf`/
--- `M.run_start`/`M.run_end`), so a leaf walk's outcome (or lack of one) is
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

--- Find the leaf directly under the cursor, or nearest it -- logging wrapper around `_current_leaf`.
---
---@param forward boolean Off a leaf, prefer the nearest leaf after the cursor over the nearest one before it.
---@return TSNode? # The leaf under (or nearest) the cursor, if a parser and a leaf exist that way.
---
function M.current_leaf(forward)
    local node = _current_leaf(forward)

    _log_leaf_result(string.format("current_leaf(forward=%s)", forward), node)

    return node
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

--- The first real leaf inside `piece` (a single stitched sub-range of an
--- injected tree, from `_injection_at`), or `nil` if `piece` has no real
--- content of its own (e.g. a blank line inside the embedded script).
---
--- `_leaf_at`'s own gap fallback can, in principle, walk straight out of
--- `piece` entirely -- a combined tree's root has no parent of its own, so
--- `_nearest_leaf_in_gap` would otherwise keep searching into whatever
--- unrelated piece happens to be next (see this module's docstring on
--- `injection.combined`) -- `_within_piece` is what catches that and turns
--- it back into "nothing here", rather than returning content from
--- somewhere else in the buffer.
---
---@param ltree vim.treesitter.LanguageTree
---@param piece integer[]
---@return TSNode?
local function _first_leaf_in_piece(ltree, piece)
    local leaf = _leaf_at(ltree, piece[1], piece[2], true)

    if leaf and _within_piece(leaf, piece) then
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

    if leaf and _within_piece(leaf, piece) then
        return leaf
    end

    return nil
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
--- Checked first, though: whether `node` is exactly an injection query's
--- captured content (`_injection_at`), in which case the real first leaf
--- lives in the injected tree, not `node`'s own (host-grammar) children --
--- see this module's docstring on `treesitter-language-injections`. A
--- `nil` piece result (e.g. a blank embedded script) falls through to the
--- normal host-grammar descent below, same as `node` having no injection at all.
---
---@param node TSNode Any node to search from.
---@return TSNode # The first leaf, in document order.
---
function M.first_leaf(node)
    local child_ltree, piece = _injection_at(node)

    if child_ltree then
        -- See `M.current_leaf`'s identical `assert` for why this is safe.
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

--- Descend to the last leaf inside `node` (including `node` itself).
---
--- Mirror image of `first_leaf`: repeatedly takes the last child until
--- `_is_leaf` says to stop. This is the base case `previous_leaf` lands on
--- after climbing to a previous sibling. Also mirrors `first_leaf`'s
--- injection check -- see its docstring.
---
---@param node TSNode Any node to search from.
---@return TSNode # The last leaf, in document order.
---
function M.last_leaf(node)
    local child_ltree, piece = _injection_at(node)

    if child_ltree then
        -- See `M.current_leaf`'s identical `assert` for why this is safe.
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

--- The host-grammar node an injection query captured to produce `piece` --
--- the same node `_injection_at` finds by descending from the host side,
--- reachable here from inside the injected tree instead, once `piece` runs
--- out of content of its own (see `M.next_leaf`/`M.previous_leaf`).
---
---@param host_ltree vim.treesitter.LanguageTree
---@param piece integer[]
---@return TSNode?
local function _host_node_for_piece(host_ltree, piece)
    return host_ltree:node_for_range({ piece[1], piece[2], piece[4], piece[5] }, { ignore_injections = true })
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
--- (`_owning_ltree`/`_piece_at`), `_climb_next`'s result additionally has to
--- fall *inside that same piece* (`_within_piece`) to be trusted -- climbing
--- within a `injection.combined` tree can otherwise land on a completely
--- unrelated piece instead (see this module's docstring). Whenever the climb
--- doesn't produce a same-piece result, this falls back to the host-grammar
--- node the injection query captured (`_host_node_for_piece`) and asks
--- *its* next leaf instead -- the mirror image of `first_leaf`'s descent
--- into a fresh piece.
---
---@param node TSNode A leaf (or any node) to start searching from.
---@return TSNode? # The next leaf, if `node` isn't the last leaf in the buffer.
---
local function _next_leaf(node)
    local climbed = _climb_next(node)
    local ltree = _owning_ltree(node)

    if not ltree then
        return climbed
    end

    local host_ltree = ltree:parent()

    if not host_ltree then
        return climbed
    end

    local piece = _piece_at(ltree, node:start())

    if not piece then
        return climbed
    end

    if climbed and _within_piece(climbed, piece) then
        return climbed
    end

    local host_node = _host_node_for_piece(host_ltree, piece)

    if not host_node then
        return climbed
    end

    return M.next_leaf(host_node)
end

--- Find the leaf directly after `node`, in document order -- logging wrapper around `_next_leaf`.
---
--- The injection-crossing recursion inside `_next_leaf` calls back into
--- this wrapper (not `_next_leaf` directly), so each hop across an
--- injection boundary gets its own log line too, not just the outermost call.
---
---@param node TSNode A leaf (or any node) to start searching from.
---@return TSNode? # The next leaf, if `node` isn't the last leaf in the buffer.
---
function M.next_leaf(node)
    local result = _next_leaf(node)

    _log_leaf_result(string.format("next_leaf(%s at %s:%s)", node:type(), node:start()), result)

    return result
end

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
local function _previous_leaf(node)
    local climbed = _climb_previous(node)
    local ltree = _owning_ltree(node)

    if not ltree then
        return climbed
    end

    local host_ltree = ltree:parent()

    if not host_ltree then
        return climbed
    end

    local piece = _piece_at(ltree, node:start())

    if not piece then
        return climbed
    end

    if climbed and _within_piece(climbed, piece) then
        return climbed
    end

    local host_node = _host_node_for_piece(host_ltree, piece)

    if not host_node then
        return climbed
    end

    return M.previous_leaf(host_node)
end

--- Find the leaf directly before `node`, in document order -- logging wrapper around `_previous_leaf`.
---
--- Same recursion-through-the-wrapper reasoning as `M.next_leaf`'s docstring.
---
---@param node TSNode A leaf (or any node) to start searching from.
---@return TSNode? # The previous leaf, if `node` isn't the first leaf in the buffer.
---
function M.previous_leaf(node)
    local result = _previous_leaf(node)

    _log_leaf_result(string.format("previous_leaf(%s at %s:%s)", node:type(), node:start()), result)

    return result
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
local function _run_end(node)
    local current = node

    while true do
        local next_ = M.next_leaf(current)

        if not next_ or not M.is_contiguous(current, next_) then
            return current
        end

        current = next_
    end
end

--- Find the last leaf in the contiguous run that `node` belongs to -- logging wrapper around `_run_end`.
---
---@param node TSNode Any leaf.
---@return TSNode # `node` itself, or a later leaf if the run continues.
---
function M.run_end(node)
    local result = _run_end(node)

    _log_leaf_result(string.format("run_end(%s at %s:%s)", node:type(), node:start()), result)

    return result
end

--- Find the first leaf in the contiguous run that `node` belongs to.
---
--- Mirror image of `run_end`, walking `previous_leaf` backward instead --
--- gives `B`/`gE`'s notion of a "WORD" boundary.
---
---@param node TSNode Any leaf.
---@return TSNode # `node` itself, or an earlier leaf if the run continues.
---
local function _run_start(node)
    local current = node

    while true do
        local previous = M.previous_leaf(current)

        if not previous or not M.is_contiguous(previous, current) then
            return current
        end

        current = previous
    end
end

--- Find the first leaf in the contiguous run that `node` belongs to -- logging wrapper around `_run_start`.
---
---@param node TSNode Any leaf.
---@return TSNode # `node` itself, or an earlier leaf if the run continues.
---
function M.run_start(node)
    local result = _run_start(node)

    _log_leaf_result(string.format("run_start(%s at %s:%s)", node:type(), node:start()), result)

    return result
end

return M
