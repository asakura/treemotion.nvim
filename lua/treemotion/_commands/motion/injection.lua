--- Language-injection lookups for `_commands.motion.leaf`.
---
--- A piece is one gapless stretch of injected source, as
--- `{start_row, start_column, start_byte, end_row, end_column, end_byte}`
--- (the shape `LanguageTree:included_regions()` uses). Walks check pieces
--- because an `injection.combined` tree can jump between distant stretches.

local M = {}

---@return vim.treesitter.LanguageTree?
local function _root_parser()
    local success, parser = pcall(vim.treesitter.get_parser, vim.api.nvim_get_current_buf())

    if not success or not parser then
        return nil
    end

    return parser
end

--- `TSTree` -> owning `LanguageTree`. Weak-keyed; a tree's owner never changes.
local _tree_to_ltree = setmetatable({}, { __mode = "k" })

--- The `LanguageTree` whose tree holds `node`. Matches by tree identity,
--- since `language_for_range()` would credit a host node to the language
--- injected at its start. A miss caches every tree in the buffer.
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

--- Merge regions that touch end-to-end. tree-sitter-markdown, for example,
--- reports each line of a code fence as its own region.
---
---@param regions integer[][] One `included_regions()` group.
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

--- Keyed by the `included_regions()` table, which Neovim replaces whenever
--- the regions change, so entries never go stale.
local _sorted_pieces_cache = setmetatable({}, { __mode = "k" })

--- All of `ltree`'s pieces, sorted by start.
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

--- The last index in `pieces` starting at or before `row`/`column`, else `0`.
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

---@param ltree vim.treesitter.LanguageTree
---@param row integer
---@param column integer
---@return integer[]? # The piece of `ltree` containing `row`/`column`.
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

--- Whether `node` starts inside `piece`.
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

--- For a node in an injected tree, the piece containing `row`/`column` and
--- the host tree. `nil` for root-tree nodes.
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

--- Injections that only highlight part of a meaningful host node. They can
--- match a node's range exactly (nvim-treesitter injects every C comment as
--- `comment`), and no query flag tells them apart, hence this list.
local _ANNOTATION_ONLY_LANGUAGES = {
    comment = true,
    doxygen = true,
    printf = true,
    re2c = true,
}

--- If `node`'s range is exactly an injection's content, the injected tree
--- and the piece `node` stands for.
---
--- Parses lazily: the host tree at `node`, then the whole child language on
--- a match. Neovim only takes its cheap path once a language is fully
--- parsed, and languages never entered cost nothing.
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

            -- Pieces from different groups can share a start but not an end.
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

--- The host node that was injected to produce `piece`.
---
---@param host_ltree vim.treesitter.LanguageTree
---@param piece integer[]
---@return TSNode?
function M.host_node_for_piece(host_ltree, piece)
    return host_ltree:node_for_range({ piece[1], piece[2], piece[4], piece[5] }, { ignore_injections = true })
end

return M
