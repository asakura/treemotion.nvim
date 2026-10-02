--- Treesitter language-injection bookkeeping for `_commands.motion.leaf`.
---
--- `:help treesitter-language-injections` lets one grammar mark part of its
--- source (a Nix `''...''` string after a `# bash` comment, a Lua string
--- passed to `vim.cmd()`, a fenced code block in Markdown, ...) to be
--- re-parsed as another language, in its own `LanguageTree`/`TSTree`.
--- `TSNode:parent()` never crosses that boundary. This module answers what a
--- leaf walk needs to cross it: which injected tree and piece a host node
--- stands in for (`M.injected_content`), which piece a node inside injected
--- content belongs to (`M.enclosing_piece`, `M.within_piece`), and which host
--- node to climb back out to (`M.host_node_for_piece`).
---
--- An injection query can mark `injection.combined`, stitching several
--- non-adjacent stretches of source into one injected tree (e.g. one Nix
--- indented string split around `${...}` interpolations, or even several
--- unrelated strings). Sibling navigation inside such a tree can jump from
--- one stretch to another and skip the host text in between, so walks are
--- bounds-checked against a single "piece": one gapless stretch of injected
--- source.
---
--- A piece is always a
--- `{start_row, start_column, start_byte, end_row, end_column, end_byte}`
--- array, the same shape `LanguageTree:included_regions()` uses.

local M = {}

--- The root treesitter parser for the current buffer, if any.
---
--- A bare `TSNode` can't be mapped back to its `LanguageTree`; the search
--- has to start from the buffer's root parser.
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
--- A leaf walk looks up the owner of every node it touches, and the owner of
--- a `TSTree` never changes. Weak-keyed so trees discarded by a reparse are
--- garbage-collected; a `TSTree` object is never reused for another owner.
local _tree_to_ltree = setmetatable({}, { __mode = "k" })

--- The `LanguageTree` that produced `node`: the buffer's root tree, or the
--- injected tree that owns it.
---
--- Matches by `TSTree` identity (`node:tree()`), not by position.
--- `LanguageTree:language_for_range()` reports the deepest language at a
--- point, so a host node that starts where its injected content starts would
--- be attributed to the injected language.
---
--- A cache miss records every `TSTree` the search passes, not just
--- `node`'s, so one walk after a reparse warms the cache for the whole
--- buffer.
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

--- Merge `regions` (one `included_regions()` group, i.e. one injected
--- instance) into maximal runs of regions that touch end-to-end.
---
--- Some grammars report one gapless span as several regions (e.g.
--- tree-sitter-markdown reports each line of a fenced code block as its own
--- region). Unmerged, every such boundary would look like a gap between
--- stitched pieces: walks would climb back out to the host at each line
--- break, and `M.injected_content`'s exact-range match against the host
--- node's single range could never succeed. Regions with a real gap between
--- them stay separate.
---
--- Sorts by start position first, since `included_regions()` doesn't
--- promise document order. A single-region group is returned as-is.
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
--- table's identity.
---
--- `LanguageTree:included_regions()` returns its internal table rather than
--- a copy, and Neovim replaces that table whenever the regions change
--- (injection discovery, buffer edits). An entry can therefore never be read
--- back once it's stale.
local _sorted_pieces_cache = setmetatable({}, { __mode = "k" })

--- Every piece of `ltree` (see `_merge_contiguous`), across all of its
--- `included_regions()` groups, as one array sorted by start position for
--- binary search.
---
--- Sorting across groups is safe: regions of one `LanguageTree` never
--- overlap, and separate groups are separate injected instances, so nothing
--- needs merging across them.
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
--- Lets lookups binary-search instead of scanning every injected region of a
--- language on each node a walk touches.
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

--- The piece of `ltree` that contains `row`/`column`, e.g. one line of a Nix
--- indented string between two `${...}` interpolations.
---
--- Node ranges inside an injected tree report their true buffer position,
--- so plain coordinate comparison tells pieces apart. Since pieces never
--- overlap, only the piece at `_floor_index` can contain the point.
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

--- Whether `node`'s start position falls inside `piece`.
---
--- Tells "still inside the piece the walk started in" apart from "a combined
--- tree's navigation jumped to another piece".
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

--- If `node` sits inside injected content, the piece containing
--- `row`/`column`, plus the host `LanguageTree` that injected it.
---
--- `nil` when `node` belongs to the buffer's root tree, or when `row`/
--- `column` falls outside every piece of `node`'s injected tree.
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

--- Injected languages that only highlight fragments of an already
--- meaningful host node (a comment body, a printf-style format string), as
--- opposed to embedding a different program.
---
--- These can cover a host node's entire span exactly, just like a real
--- embedded language (nvim-treesitter injects every C comment as `comment`,
--- for example), so `M.injected_content`'s exact-range check can't filter
--- them out. Nothing in a query marks an injection as highlight-only, hence
--- a denylist by name. Treating them as real injections would split a C
--- block comment word by word instead of keeping it one leaf.
local _ANNOTATION_ONLY_LANGUAGES = {
    comment = true,
    doxygen = true,
    printf = true,
    re2c = true,
}

--- If `node`'s entire range is exactly an injection's `@injection.content`
--- (see `:help treesitter-language-injections`), the injected tree and the
--- piece `node` stands in for.
---
--- Only an exact-range match counts, and `_ANNOTATION_ONLY_LANGUAGES` are
--- ignored, so injections that merely highlight part of a node don't turn
--- that node into a different language.
---
--- Parses lazily: `ltree` is parsed at `node`'s start (one column wide, as
--- in `leaf.leaf_at`) right before its children are checked, so a walk
--- that reaches an injected tree elsewhere in the buffer parses it on
--- arrival. On a match, `child:parse(true)` parses the whole child
--- language. Neovim only takes its cheap "entirely valid" path once every
--- region of a language is parsed, so a language being walked is worth
--- parsing in full once, while languages never entered cost nothing. See
--- `notes/injection-parse-performance.md`.
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
            -- `row1`/`column1`. Walk back over pieces sharing that exact
            -- start, since pieces from different groups could share a start
            -- without sharing an end.
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

--- The host-grammar node an injection query captured to produce `piece`:
--- the node `M.injected_content` matches from the host side, found here from
--- inside the injected tree once `piece` runs out.
---
---@param host_ltree vim.treesitter.LanguageTree
---@param piece integer[]
---@return TSNode?
function M.host_node_for_piece(host_ltree, piece)
    return host_ltree:node_for_range({ piece[1], piece[2], piece[4], piece[5] }, { ignore_injections = true })
end

return M
