--- Classify leaves (prose, insignificant) and find the buffer's language.

local M = {}

--- `@spell` marks prose. `@string*` counts too, since string content is
--- rarely tagged `@spell` even when it holds free text.
---
---@param capture string
---@return boolean
---
local function _is_prose_capture(capture)
    return capture == "spell" or capture == "string" or capture:match("^string%.") ~= nil
end

--- Whether `node` is prose (`@spell` or `@string*`) rather than code.
---
---@param node TSNode
---@return boolean
---
function M.is_prose(node)
    local row, column = node:start()

    for _, capture in ipairs(vim.treesitter.get_captures_at_pos(0, row, column)) do
        if _is_prose_capture(capture.capture) then
            return true
        end
    end

    return false
end

---@param characters string[]? The language's comment markers.
---@return table<string, true>
---
function M.comment_marker_characters(characters)
    if not characters then
        return {}
    end

    local set = {}

    for _, character in ipairs(characters) do
        set[character] = true
    end

    return set
end

--- The root parser's language. This can differ from `'filetype'`, and inside
--- an injection it is still the root language.
---
---@return string?
---
function M.current_language()
    local ok, parser = pcall(vim.treesitter.get_parser, 0)

    if not ok or not parser then
        return nil
    end

    return parser:lang()
end

--- Whether `node`'s text is one of the language's `insignificant_characters`.
---
--- Named prose leaves never are. Unnamed ones can be, such as Nix's `"`,
--- which is highlighted `@string` only because of the string it wraps.
---
---@param node TSNode
---@param characters string[]?
---@return boolean
---
function M.is_insignificant(node, characters)
    if not characters then
        return false
    end

    if node:named() and M.is_prose(node) then
        return false
    end

    -- A leaf's end can sit one row past the last line, which is unreadable.
    local ok, text = pcall(vim.treesitter.get_node_text, node, 0)

    if not ok then
        return false
    end

    for _, character in ipairs(characters) do
        if character == text then
            return true
        end
    end

    return false
end

return M
