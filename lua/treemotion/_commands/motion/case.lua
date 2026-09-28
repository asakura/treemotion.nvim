--- Camel/Pascal case splitting, plus the opaque-token (hash/digest)
--- heuristic that decides when *not* to case-split a chunk.
---
--- Pure string functions: no buffer, treesitter or configuration access.
--- `_commands.motion.subword` calls these on every chunk
--- `_commands.motion.delimiters` produces.

local M = {}

--- Whether `text` looks like an opaque hash/digest -- a run this plugin
--- should treat as one unit and never case-split internally, e.g. a sha1 hex
--- digest or a base64-encoded sha256 (`sha256-A8Yg...SgU=`).
---
--- Pure heuristic (charset + minimum length), not a hardcoded list of known
--- algorithms -- deliberately, so it also matches things that merely happen
--- to look hash-shaped. Trailing `=` (base64 padding) is stripped before the
--- length/charset check runs, but doesn't itself have to be hex/base64.
---
--- The base64-shaped branch also requires at least one digit somewhere in
--- `text`: without that, "at least `min_length` characters, purely
--- alphanumeric, with both an uppercase and a lowercase letter" matches
--- virtually any real-world camelCase/PascalCase identifier of that length
--- too (`handleSubmitButtonClick`, `getUserAuthenticationToken`, ...), not
--- just genuine digests -- a random base64 run of `min_length`+ characters
--- is overwhelmingly likely to contain at least one digit (each character
--- has a 10/64 chance of being one), while an ordinary hand-written
--- identifier of that length usually has none at all. The pure-hex branch
--- doesn't need this: its alphabet (`%x`) already includes `0`-`9`.
---
---@param text string A candidate run (e.g. one `delimiters.split` chunk).
---@param min_length integer Minimum length, after stripping `=` padding, to
---    even consider `text` (see `opaque_token_min_length`'s docstring in
---    `types.lua`).
---@return boolean
---
function M.looks_like_hash(text, min_length)
    local stripped = text:gsub("=+$", "")

    if #stripped < min_length then
        return false
    end

    if stripped:match("^%x+$") then
        return true
    end

    return stripped:match("^[%w+/]+$") ~= nil
        and stripped:match("%u") ~= nil
        and stripped:match("%l") ~= nil
        and stripped:match("%d") ~= nil
end

--- Find every column in `text` where a new camelCase/PascalCase word starts.
---
--- A boundary falls right before an uppercase letter that either follows a
--- lowercase letter/digit (`fooBar` -> boundary before `B`) or follows
--- another uppercase letter that is itself followed by a lowercase letter
--- (`XMLHttp` -> boundary before the `H` in `Http`, keeping `XML` together).
---
---@param text string A run of characters with no snake/kebab delimiters in it.
---@return integer[] # 1-indexed columns (into `text`) where a new subword starts.
---
local function _case_boundaries(text)
    local boundaries = {}

    for index = 2, #text do
        local current = text:sub(index, index)

        if current:match("%u") then
            local previous = text:sub(index - 1, index - 1)

            if previous:match("[%l%d]") then
                table.insert(boundaries, index)
            elseif previous:match("%u") and text:sub(index + 1, index + 1):match("%l") then
                table.insert(boundaries, index)
            end
        end
    end

    return boundaries
end

--- Split `text` into camelCase/PascalCase-aware chunks.
---
--- Whether `text` counts as camelCase or PascalCase is decided purely by its
--- first letter's case, and only that variant's option is consulted -- this
--- is what makes `camel_case` and `pascal_case` independently toggleable:
--- disabling one leaves every identifier of *that* leading case unsplit
--- while the other option keeps working, since a single call to this
--- function never looks at both.
---
---@param text string A run of characters with no snake/kebab delimiters in it.
---@param camel_case boolean Split lowercase-leading identifiers (`fooBar`).
---@param pascal_case boolean Split uppercase-leading identifiers (`FooBar`).
---@return string[] # `text`, split at each enabled case boundary.
---
function M.split(text, camel_case, pascal_case)
    local starts_upper = text:sub(1, 1):match("%u") ~= nil
    local enabled = starts_upper and pascal_case or (not starts_upper and camel_case)

    if not enabled then
        return { text }
    end

    local chunks = {}
    local start = 1

    for _, boundary in ipairs(_case_boundaries(text)) do
        table.insert(chunks, text:sub(start, boundary - 1))
        start = boundary
    end

    table.insert(chunks, text:sub(start))

    return chunks
end

return M
