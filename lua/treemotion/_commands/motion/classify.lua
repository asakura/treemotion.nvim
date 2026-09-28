--- Classify leaves and look up per-language character sets.
---
--- Answers the questions `_commands.motion.subword` asks about a leaf
--- before it splits any text: is it prose or code (`M.is_prose`), is it a
--- token the user wants skipped entirely (`M.is_insignificant`), and which
--- characters count as comment markers in the current language
--- (`M.comment_marker_characters`). These read treesitter highlight
--- captures and the attached parser's language, which is what separates
--- this module from the pure string splitters in
--- `_commands.motion.case`/`.prose`/`.delimiters`. The per-language
--- character lists themselves are passed in by the caller (see
--- `_commands.motion.settings`), not read from the configuration here.

local M = {}

--- Whether `capture` (a raw capture name from `vim.treesitter.get_captures_at_pos`)
--- marks its node as prose rather than code.
---
--- `@spell` is `:help treesitter-highlight-spell`'s natural-language marker.
--- `@string` and its dotted variants (`@string.special.url`, ...) count too,
--- because highlight queries rarely tag string content `@spell` even when it
--- holds free text, and splitting such a string by code rules would leave
--- it as a few huge chunks. Matching capture names keeps the check
--- grammar-agnostic.
---
---@param capture string A capture name, as returned by `get_captures_at_pos` (dots and all).
---@return boolean
---
local function _is_prose_capture(capture)
    return capture == "spell" or capture == "string" or capture:match("^string%.") ~= nil
end

--- Check whether `node` is tagged `@spell` or `@string` -- i.e. natural-language
--- prose (or string content, treated the same way), not code.
---
--- See `_is_prose_capture`'s docstring for why both capture families count.
---
---@param node TSNode Any leaf (see `_commands.motion.leaf`).
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

--- Turn a language's comment-marker characters into a set.
---
--- Markers are per language because the same punctuation means different
--- things in different grammars (`"` opens a Vimscript comment but closes a
--- string elsewhere). A character only gets `comment_marker_case` treatment
--- in the languages `commands.motion.comment_markers` lists it for, and a
--- language with no entry has no markers.
---
---@param characters string[]? The language's comment markers (see
---    `configuration.get_comment_markers`), or `nil` if it has none.
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

--- The treesitter language attached to the current buffer, if any.
---
--- Uses the parser's language, not `vim.bo.filetype`, which can differ. Not
--- injection-aware: inside an injected block this still reports the root
--- parser's language.
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

--- Whether `node` is invisible to `w`/`e`/`b`/`ge` (and, per leaf of a run,
--- `W`/`E`/`B`/`gE`): a token such as `;` or `}` that
--- `commands.motion.insignificant_characters` lists for the language.
---
--- Named prose leaves are never insignificant, since prose splitting already
--- treats punctuation as words. Unnamed prose leaves can be: an anonymous
--- delimiter such as Nix's `"` is often highlighted `@string` only to match
--- the string it wraps, and has no prose content of its own. `M.is_prose`
--- itself still reports such leaves as prose, for rule selection.
---
--- Not injection-aware (see `M.current_language`).
---
--- `pcall` guards `get_node_text`, since a leaf's `:end_()` can sit one row
--- past the buffer's last line. Unreadable text can't match a configured
--- entry, so a failed read means "not insignificant".
---
---@param node TSNode Any leaf (see `_commands.motion.leaf`).
---@param characters string[]? The current language's insignificant leaf texts (see
---    `configuration.get_insignificant_characters`), or `nil` if it has none.
---@return boolean
---
function M.is_insignificant(node, characters)
    if not characters then
        return false
    end

    if node:named() and M.is_prose(node) then
        return false
    end

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
