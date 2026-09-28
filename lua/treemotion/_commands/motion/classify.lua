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
--- `@spell` is `:help treesitter-highlight-spell`'s own natural-language
--- boundary, already correct (and user-overridable) per language without
--- this plugin hand-listing prose-ish node type names. `@string` (and its
--- dotted specializations, `@string.special.url`, `@string.regexp`, ...) is
--- folded in here too: nvim-treesitter's highlight convention almost never
--- tags a plain string's content `@spell` even when it holds free text (a
--- Nix `description = "..."` value, a Lua error message, ...) -- confirmed
--- against tree-sitter-nix's own `queries/highlights.scm`, which captures
--- `string_expression` as `@string` and never emits `@spell` anywhere in the
--- file at all. Without treating `@string` as prose too, a whole string
--- literal collapses into a handful of huge `delimiters.split`/`case.split`
--- chunks instead of stopping at each word, since code leaves are assumed
--- (correctly, for real identifiers) to "never contain embedded blanks in
--- the first place" -- an assumption free-form string content breaks. Using
--- the capture *name* rather than a node type keeps this the same
--- grammar-agnostic check `@spell` alone already was: any language whose
--- highlight query uses the standard `@string`/`@spell` capture names gets
--- this for free, no per-language query of this plugin's own required.
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
--- Deliberately per-language rather than one fixed global set: the same
--- punctuation means different, unrelated things in different grammars --
--- `"` opens a comment in Vimscript but closes a string everywhere else;
--- `;` ends a comment in a treesitter query file but ends a *statement* in
--- every C-family language. Applying `comment_marker_case` to a character
--- globally would make `"skip"` start eating string-quote or
--- statement-terminator leaves in every *other* language that happens to
--- reuse the same character for something unrelated -- so a character only
--- ever gets `comment_marker_case` treatment in the languages
--- `commands.motion.comment_markers` actually lists it for (see
--- that field's docstring in `types.lua`). A language with no entry at all
--- has no comment-marker characters, so `comment_marker_case` is silently a
--- no-op there until the user configures one -- consistent with this
--- plugin's general approach of only claiming behavior it's actually
--- verified against a real grammar, never guessing (see
--- `subword.lua`'s `_leading_continuation_length` docstring for the same philosophy
--- applied to leaf-boundary tokenization quirks).
---
--- Beyond the shipped/user-configured languages, `comment_marker_case` also
--- activates automatically for any language in
--- `configuration.get_comment_markers`'s optional table whose treesitter
--- parser is actually installed -- no configuration needed for those.
--- `_commands.motion.settings` does that lookup and passes the result here.
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
--- Reads the *language* a parser actually attached
--- (`vim.treesitter.get_parser():lang()`), not `vim.bo.filetype` -- the two
--- usually match for the languages this plugin has been verified against,
--- but don't have to (e.g. a filetype attached to a differently-named
--- parser). Doesn't attempt injection-aware resolution (a node inside an
--- injected language block, e.g. a fenced code block in markdown, still
--- reports the *root* parser's language) -- narrower than fully correct,
--- but matches every other language-resolution point in this plugin, none
--- of which are injection-aware either.
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

--- Whether `node` should be treated as invisible to `w`/`e`/`b`/`ge` (and, via
--- `bigword.lua`'s `_run_is_insignificant`, `W`/`E`/`B`/`gE`) entirely -- a leaf-level token
--- (`;`, `{`, `}`, ...) the user has configured as insignificant for its
--- language, via `commands.motion.insignificant_characters`.
---
--- Code leaves only: a *named* prose leaf (`@spell`-/`@string`-tagged, see
--- `M.is_prose`) keeps every character significant, since prose already does
--- its own punctuation-is-a-word splitting (`prose.split_words`),
--- deliberately mirroring how real Vim's `w` treats punctuation as a landing
--- stop in a text file -- the same reason `.code`/`.prose` are configured
--- separately everywhere in `_commands.motion.subword`.
---
--- `node:named()` gates that exemption, deliberately -- `:help
--- TSNode:named()`: "Named nodes correspond to named rules in the grammar,
--- whereas anonymous nodes correspond to string literals in the grammar."
--- An *unnamed* leaf that's still `M.is_prose` (Lua's `--` comment opener,
--- captured via its parent `comment` node's `(comment) @comment @spell`
--- span) is left alone here -- `comment_marker_case` already governs
--- whether markers like that are a landing stop, and this function must
--- keep calling them prose so `subword.lua`'s `split`/`_run_segments` route them through
--- `.prose`'s rules, not `.code`'s. But an unnamed leaf whose *own* prose
--- capture comes from a query pattern that targets it directly rather than
--- from an ancestor's span (Nix's `"`/`''` string delimiters: confirmed
--- against `tree-sitter-nix`'s `queries/highlights.scm`, `(string_expression
--- "\"" @string)` captures the literal quote child for uniform coloring,
--- while the actual text sits in a sibling, named `string_fragment`) has no
--- real prose content of its own to protect -- it's a one-character
--- structural delimiter that merely renders the same color as the string it
--- wraps. Exempting `M.is_prose` here (not in `M.is_prose` itself, which stays
--- untouched for `.code`/`.prose` rule selection) is what lets
--- `insignificant_characters` reach it at all; without this, no
--- configuration could ever hide a quote delimiter, since the code/prose
--- gate came first. Not Nix-specific: any grammar whose highlight query
--- paints an anonymous delimiter leaf the same color as the content it
--- encloses hits the same thing.
---
--- Deliberately not injection-aware, same as every other language-resolution
--- point in this module (see `M.current_language`'s docstring).
---
--- `pcall` guards `get_node_text`: `bigword.lua`'s `_run_is_insignificant`
--- calls this for every leaf in a candidate run *before* `subword.split_run` ever
--- runs, so a read that would otherwise only ever fail inside
--- `subword.lua`'s `_split_run_segment`'s own already-guarded call (a leaf's `:end_()`
--- sitting one row past the buffer's last line, the same rare case
--- `_has_non_blank_between` in `leaf.lua` guards too) can now fail here
--- first instead. Treating a failed read as "not insignificant" is exactly
--- right, not just a safe fallback: unreadable text can never match a
--- configured entry anyway, so this just reaches the same answer
--- `_split_run_segment`'s fallback already would have.
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
