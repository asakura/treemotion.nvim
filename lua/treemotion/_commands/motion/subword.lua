--- Split a treesitter leaf's (`M.split`), or a whole run's (`M.split_run`),
--- text into case-convention-aware sub-word units.
---
--- `M.split` backs `w`/`e`/`b`/`ge` (see `_commands.motion.word`), reading
--- `commands.motion.small`. `M.split_run` backs `W`/`E`/`B`/`gE` (see
--- `_commands.motion.bigword`), reading `commands.motion.big` -- but only
--- once `commands.motion.big.enabled` is `true`; by default it always
--- returns one unit spanning the whole run, ignoring case entirely, the
--- same way real Vim's `W` ignores punctuation inside a WORD.
---
--- Everything here is plain text/coordinate analysis -- no treesitter tree
--- walking happens in this file, that's `_commands.motion.leaf`'s and
--- `_commands.motion.word`'s/`_commands.motion.bigword`'s job; the
--- treesitter features this file does use are reading a leaf's highlight
--- captures (`:help treesitter-highlight-spell`) to tell "code" leaves
--- (identifiers, ...) apart from "prose" leaves (comments, string content,
--- or whatever else a language's highlight query marks `@spell` or
--- `@string`, see `_is_prose_capture`), and reading the attached parser's
--- language name (`_current_language`) to look up that language's
--- comment-marker characters (`_comment_marker_characters`).
---
--- `M.split`/`M.split_run` narrow their input down to eligible text, then
--- both hand off to the shared `_split_text`, which composes up to three
--- passes: `_prose_words` runs first, but *only* for prose-tagged text -- it
--- divides prose into individual words the way real Vim's `w` divides a
--- text file (on whitespace and punctuation), since comment/string/run text
--- has no other word boundaries in it at all. Code text skips straight past
--- this pass, treating the whole thing as a single "word". Every resulting
--- word (one, for code) then goes through `_split_delimiters` (dividing on
--- `_`/`-`/`:`/`/`) and, unless the chunk looks like an opaque hash/digest
--- (`_looks_like_hash`), `_split_case` (dividing on camelCase/PascalCase
--- boundaries) -- using `.code` or `.prose`'s rules, whichever matched.
--- Each produced `treemotion.SubwordUnit` is just a coordinate range, not a
--- real tree node -- there's no parent/child/sibling structure to a
--- sub-word slice, only a start and an end.
---
--- When `backtick_identifiers` is enabled (the default), prose word-splitting
--- gets one more wrinkle: a backtick-enclosed span that's exactly one Vim
--- word (`` `fooBar` ``, `` `foo-bar` ``, not `` `foo bar` `` or `` `` ``)
--- is pulled out and run through `.code`'s rules instead of `.prose`'s, and
--- the backticks themselves produce no unit at all -- invisible to
--- `w`/`b`/`e`/`ge`, the same way a `"skip"` comment-marker run already is.
--- See `_split_backtick_identifiers`.

local logging = require("mega.logging")

local codepoint = require("treemotion._commands.motion.codepoint")
local configuration = require("treemotion._core.configuration")
local leaf = require("treemotion._commands.motion.leaf")
local motion_constant = require("treemotion._commands.motion.constant")

local _LOGGER = logging.get_logger("treemotion._commands.motion.subword")

local M = {}

--- A coordinate range identifying one sub-word slice of a leaf's text.
---
--- Deliberately dumber than a `TSNode`: just the four numbers that bound it,
--- no parent/child/sibling links -- a sub-word slice isn't a real tree node,
--- it's a range `M.split` invents on top of one. Exposing the same
--- `:start()`/`:end_()` shape a `TSNode` has is what lets `_commands.motion.runner`
--- treat this and a `TSNode` interchangeably (see its `TSNode|treemotion.WordUnit` params).
---@class treemotion.SubwordUnit
---@field private _start_row integer
---@field private _start_col integer
---@field private _end_row integer
---@field private _end_col integer
local _Unit = {}
_Unit.__index = _Unit

--- This unit's first character.
---@return integer, integer
function _Unit:start()
    return self._start_row, self._start_col
end

--- This unit's last character, exclusive (one column past the end, matching `TSNode:end_()`).
---@return integer, integer
function _Unit:end_()
    return self._end_row, self._end_col
end

--- Build a `treemotion.SubwordUnit` from raw coordinates.
---
---@param start_row integer
---@param start_col integer
---@param end_row integer
---@param end_col integer
---@return treemotion.SubwordUnit
local function _new_unit(start_row, start_col, end_row, end_col)
    return setmetatable(
        { _start_row = start_row, _start_col = start_col, _end_row = end_row, _end_col = end_col },
        _Unit
    )
end

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
--- literal collapses into a handful of huge `_split_delimiters`/`_split_case`
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
local function _is_prose(node)
    local row, column = node:start()

    for _, capture in ipairs(vim.treesitter.get_captures_at_pos(0, row, column)) do
        if _is_prose_capture(capture.capture) then
            return true
        end
    end

    return false
end

--- Read the user's splitting configuration for `is_prose`'s context, within
--- `group` ("small" for `w`/`e`/`b`/`ge`, "big" for `W`/`E`/`B`/`gE`).
---
---@param is_prose boolean Whether to read `.prose` or `.code`.
---@param group "small"|"big" Which motion family's configuration to read.
---@return treemotion.ConfigurationMotionSubwordRules
---
local function _rules(is_prose, group)
    -- `assert()`: `commands.motion.small`/`.big` and their `.code`/`.prose`
    -- are optional in the LuaCATS types (they double as valid partial
    -- user-override input), but `configuration._DEFAULTS` always fills all
    -- of them in, so `resolve_data()`'s result always has them.
    local motion_group = assert(configuration.resolve_data().commands.motion[group])

    return assert(is_prose and motion_group.prose or motion_group.code)
end

--- Whether `commands.motion[group].backtick_identifiers` is enabled.
---
---@param group "small"|"big" Which motion family's configuration to read.
---@return boolean
---
local function _backtick_identifiers_enabled(group)
    -- `assert()`: see `_rules`'s identical use above -- `commands.motion[group]`
    -- is optional in the LuaCATS types, but `configuration._DEFAULTS` always
    -- fills it in, so `resolve_data()`'s result always has it. Don't `assert()`
    -- the boolean field itself, though (unlike `_rules`' table) -- `false` is
    -- a legitimate value here, and `assert(false)` would raise.
    local motion_group = assert(configuration.resolve_data().commands.motion[group])

    return motion_group.backtick_identifiers
end

--- Classify one character the way real Vim's `w` classifies it in a text file.
---
--- Real Vim's word motions only recognize three classes: blank, "keyword"
--- (`'iskeyword'`, which defaults to letters/digits/`_`), and everything
--- else -- and critically, *every* non-blank, non-keyword character shares
--- that one "everything else" class, so a run like `?!` is a single word,
--- not two.
---
--- `-`/`:`/`/` are deliberately grouped into `"word"` here too, even though
--- real Vim's default `'iskeyword'` excludes them: `_split_delimiters` is
--- the single place that decides what happens to a `-`/`_`/`:`/`/` it finds
--- *within* a word, via `kebab_case`/`snake_case`/`colon_case`/`slash_case`.
--- If this function split them off as their own run instead, `"none"` mode
--- could never put them back together -- the split would already have
--- happened a layer up, before that setting was even consulted. Grouping
--- `:`/`/` this way is also what keeps a structured token like
--- `github:NixOS/nixpkgs` or a URL/path from being fragmented at every `:`/`/`
--- before `colon_case`/`slash_case` ever get a say.
---
---@param char string A single character.
---@return "blank"|"word"|"other"
---
local function _char_class(char)
    if char:match("%s") then
        return "blank"
    elseif char:match("[%w_%-:/]") then
        return "word"
    end

    return "other"
end

--- Split `text` into Vim-style words: runs of keyword chars, or runs of
--- punctuation, with blank runs dropped entirely (never landed on, exactly
--- like Vim's `w` always skips whitespace).
---
--- Only used for prose (`@spell`- or `@string`-tagged, see
--- `_is_prose_capture`) leaves -- code leaves never contain embedded blanks
--- in the first place, so there's nothing for this pass to do for them.
---
---@param text string A leaf's full text.
---@return {text: string, offset: integer}[] # Each word and its 1-indexed start column in `text`.
---
local function _split_prose_words(text)
    local chunks = {}
    local start = 1

    ---@type "blank"|"word"|"other"?
    local class = nil

    for index = 1, #text do
        local current_class = _char_class(text:sub(index, index))

        if current_class ~= class then
            if class ~= nil and class ~= "blank" then
                table.insert(chunks, { text = text:sub(start, index - 1), offset = start })
            end

            start = index
            class = current_class
        end
    end

    if class ~= nil and class ~= "blank" then
        table.insert(chunks, { text = text:sub(start), offset = start })
    end

    return chunks
end

--- Whether `content` -- backtick-enclosed text with the backticks already
--- stripped -- is exactly one Vim word: a single uninterrupted run of
--- "word"-class or "other"-class characters (see `_char_class`), with no
--- leading/trailing blanks and no embedded class change.
---
--- Deliberately reuses `_split_prose_words`'s own run classification rather
--- than a bespoke identifier pattern, so "a single word" here means the same
--- thing it already means everywhere else `w`/`b`/`e`/`ge` land -- `fooBar`
--- and `foo-bar` both qualify (`-`/case are further split per `.code`'s
--- rules once `M.split` treats the span as an identifier), but `foo bar`
--- (two words) and `foo.bar` (a class change between `foo`/`.`/`bar`) don't.
---
---@param content string Text between one matched pair of backticks. May be empty.
---@return boolean
---
local function _is_single_word(content)
    if content == "" then
        return false
    end

    local words = _split_prose_words(content)

    return #words == 1 and words[1].offset == 1 and #words[1].text == #content
end

--- Locate backtick-enclosed spans in `text` and classify each as a candidate
--- identifier (its content is exactly one Vim word, per `_is_single_word`)
--- or ordinary prose (anything else -- multiple words, or an empty
--- `` `` ``, backticks included).
---
--- Only adjacent, non-nested backtick *pairs* are recognized (`` `([^`]*)` ``
--- via plain Lua pattern matching, not a real parser) -- there's no markdown
--- grammar backing this, just the same punctuation-as-delimiter approach
--- `_split_delimiters` already takes for `-`/`_`/comment markers. A pair
--- that fails the single-word check is left untouched (not even flagged as
--- its own segment) so it folds back into whichever prose segment
--- eventually gets flushed around it -- exactly the same text `_split_prose_words`
--- would have produced without this feature at all.
---
---@param text string A prose leaf's full text (see `M.split`).
---@return {kind: "prose"|"identifier", text: string, offset: integer}[] # `offset` is
---    each segment's 1-indexed start column in `text` -- for `"identifier"` segments,
---    that's the character right after the opening backtick, since the backticks
---    themselves are excluded from the segment (and, in turn, never become a unit).
---
local function _split_backtick_identifiers(text)
    local segments = {}
    local search_start = 1
    local prose_start = 1

    while true do
        local match_start, match_end, content = text:find("`([^`\n]*)`", search_start)

        if not match_start then
            break
        end

        if _is_single_word(content) then
            if match_start > prose_start then
                table.insert(
                    segments,
                    { kind = "prose", text = text:sub(prose_start, match_start - 1), offset = prose_start }
                )
            end

            table.insert(segments, { kind = "identifier", text = content, offset = match_start + 1 })

            prose_start = match_end + 1
        end

        search_start = match_end + 1
    end

    if prose_start <= #text then
        table.insert(segments, { kind = "prose", text = text:sub(prose_start), offset = prose_start })
    end

    return segments
end

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
---@param text string A candidate run (e.g. one `_split_delimiters` chunk).
---@param min_length integer Minimum length, after stripping `=` padding, to
---    even consider `text` (see `opaque_token_min_length`'s docstring in
---    `types.lua`).
---@return boolean
---
local function _looks_like_hash(text, min_length)
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

--- Merge a trailing all-`=` word into the word right before it, when the
--- combined span passes `_looks_like_hash` -- so `sha256-A8Yg...SgU` and a
--- separate `=` word (produced by `_split_prose_words`, since `=` isn't in
--- `_char_class`'s `"word"` class) become one word before delimiter/case
--- splitting ever sees either half.
---
---@param words {text: string, offset: integer, is_identifier: boolean?}[]
---    `_split_prose_words`' (or the backtick-identifier-aware equivalent's) output.
---@param min_length integer See `_looks_like_hash`.
---@return {text: string, offset: integer, is_identifier: boolean?}[]
---
local function _merge_opaque_padding(words, min_length)
    if #words < 2 then
        return words
    end

    local merged = {}
    local index = 1

    while index <= #words do
        local word = words[index]
        local next_word = words[index + 1]

        if next_word and not word.is_identifier and next_word.text:match("^=+$") then
            local adjacent = word.offset + #word.text == next_word.offset
            local combined = word.text .. next_word.text

            if adjacent and _looks_like_hash(combined, min_length) then
                table.insert(merged, { text = combined, offset = word.offset })
                index = index + 2
            else
                table.insert(merged, word)
                index = index + 1
            end
        else
            table.insert(merged, word)
            index = index + 1
        end
    end

    return merged
end

--- Split a prose leaf's `text` into words, the same shape `_split_prose_words`
--- returns, except each word also carries whether it's a backtick-enclosed
--- identifier (see `_split_backtick_identifiers`) for `M.split` to apply
--- `.code`'s rules to instead of `.prose`'s.
---
---@param text string A prose leaf's full text (see `M.split`).
---@param backtick_identifiers boolean Whether `commands.motion[group].backtick_identifiers` is enabled.
---@param opaque_token_min_length integer See `_looks_like_hash`.
---@return {text: string, offset: integer, is_identifier: boolean?}[]
---
local function _prose_words(text, backtick_identifiers, opaque_token_min_length)
    local words

    if not backtick_identifiers then
        words = _split_prose_words(text)
    else
        words = {}

        for _, segment in ipairs(_split_backtick_identifiers(text)) do
            if segment.kind == "identifier" then
                table.insert(words, { text = segment.text, offset = segment.offset, is_identifier = true })
            else
                for _, word in ipairs(_split_prose_words(segment.text)) do
                    table.insert(words, { text = word.text, offset = segment.offset + word.offset - 1 })
                end
            end
        end
    end

    return _merge_opaque_padding(words, opaque_token_min_length)
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
local function _split_case(text, camel_case, pascal_case)
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

--- Look up which single characters count as comment-marker punctuation for `language`.
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
--- `_leading_continuation_length`'s docstring for the same philosophy
--- applied to leaf-boundary tokenization quirks).
---
--- Beyond the shipped/user-configured languages, `comment_marker_case` also
--- activates automatically for any language in
--- `configuration.get_comment_markers`'s optional table whose treesitter
--- parser is actually installed -- no configuration needed for those.
---
---@param language string? A treesitter language name (see `_current_language`), or `nil` if unknown.
---@return table<string, true>
---
local function _comment_marker_characters(language)
    local characters = language and configuration.get_comment_markers(language)

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
local function _current_language()
    local ok, parser = pcall(vim.treesitter.get_parser, 0)

    if not ok or not parser then
        return nil
    end

    return parser:lang()
end

--- Whether `node` should be treated as invisible to `w`/`e`/`b`/`ge` (and, via
--- `M.is_insignificant`, `W`/`E`/`B`/`gE`) entirely -- a leaf-level token
--- (`;`, `{`, `}`, ...) the user has configured as insignificant for its
--- language, via `commands.motion.insignificant_characters`.
---
--- Code leaves only: a *named* prose leaf (`@spell`-/`@string`-tagged, see
--- `_is_prose`) keeps every character significant, since prose already does
--- its own punctuation-is-a-word splitting (`_split_prose_words`),
--- deliberately mirroring how real Vim's `w` treats punctuation as a landing
--- stop in a text file -- the same reason `.code`/`.prose` are configured
--- separately everywhere else in this module.
---
--- `node:named()` gates that exemption, deliberately -- `:help
--- TSNode:named()`: "Named nodes correspond to named rules in the grammar,
--- whereas anonymous nodes correspond to string literals in the grammar."
--- An *unnamed* leaf that's still `_is_prose` (Lua's `--` comment opener,
--- captured via its parent `comment` node's `(comment) @comment @spell`
--- span) is left alone here -- `comment_marker_case` already governs
--- whether markers like that are a landing stop, and this function must
--- keep calling them prose so `_split`/`_run_segments` route them through
--- `.prose`'s rules, not `.code`'s. But an unnamed leaf whose *own* prose
--- capture comes from a query pattern that targets it directly rather than
--- from an ancestor's span (Nix's `"`/`''` string delimiters: confirmed
--- against `tree-sitter-nix`'s `queries/highlights.scm`, `(string_expression
--- "\"" @string)` captures the literal quote child for uniform coloring,
--- while the actual text sits in a sibling, named `string_fragment`) has no
--- real prose content of its own to protect -- it's a one-character
--- structural delimiter that merely renders the same color as the string it
--- wraps. Exempting `_is_prose` here (not in `_is_prose` itself, which stays
--- untouched for `.code`/`.prose` rule selection) is what lets
--- `insignificant_characters` reach it at all; without this, no
--- configuration could ever hide a quote delimiter, since the code/prose
--- gate came first. Not Nix-specific: any grammar whose highlight query
--- paints an anonymous delimiter leaf the same color as the content it
--- encloses hits the same thing.
---
--- Deliberately not injection-aware, same as every other language-resolution
--- point in this module (see `_current_language`'s docstring).
---
--- `pcall` guards `get_node_text`: `bigword.lua`'s `_run_is_insignificant`
--- calls this for every leaf in a candidate run *before* `M.split_run` ever
--- runs, so a read that would otherwise only ever fail inside
--- `_split_run_segment`'s own already-guarded call (a leaf's `:end_()`
--- sitting one row past the buffer's last line, the same rare case
--- `_has_non_blank_between` in `leaf.lua` guards too) can now fail here
--- first instead. Treating a failed read as "not insignificant" is exactly
--- right, not just a safe fallback: unreadable text can never match a
--- configured entry anyway, so this just reaches the same answer
--- `_split_run_segment`'s fallback already would have.
---
---@param node TSNode Any leaf (see `_commands.motion.leaf`).
---@return boolean
---
local function _is_insignificant(node)
    if node:named() and _is_prose(node) then
        return false
    end

    local language = _current_language()
    local characters = language and configuration.get_insignificant_characters(language)

    if not characters then
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

--- Whether `node` should be treated as invisible to word motions entirely --
--- public wrapper around `_is_insignificant`, for `_commands.motion.bigword`
--- to skip a `W`/`E`/`B`/`gE` run made up entirely of insignificant leaves
--- (an isolated `;` with whitespace on both sides, say) -- see its
--- `_first_nonempty_split`.
---
---@param node TSNode Any leaf (see `_commands.motion.leaf`).
---@return boolean
---
function M.is_insignificant(node)
    return _is_insignificant(node)
end

--- Look up how `char` should be treated, per `kebab_case`/`snake_case`/`comment_marker_case`.
---
---@param char string A single character.
---@param kebab_case treemotion.SubwordDelimiterMode How to treat `-`.
---@param snake_case treemotion.SubwordDelimiterMode How to treat `_`.
---@param colon_case treemotion.SubwordDelimiterMode How to treat `:`.
---@param slash_case treemotion.SubwordDelimiterMode How to treat `/`.
---@param comment_marker_case treemotion.SubwordDelimiterMode How to treat `comment_marker_characters`.
---@param comment_marker_characters table<string, true> This language's comment-marker punctuation (see
---    `_comment_marker_characters`).
---@return treemotion.SubwordDelimiterMode # `"none"` for any character that isn't covered by one of the above.
---
local function _delimiter_mode(
    char,
    kebab_case,
    snake_case,
    colon_case,
    slash_case,
    comment_marker_case,
    comment_marker_characters
)
    if char == "-" then
        return kebab_case
    elseif char == "_" then
        return snake_case
    elseif char == ":" then
        return colon_case
    elseif char == "/" then
        return slash_case
    elseif comment_marker_characters[char] then
        return comment_marker_case
    end

    return motion_constant.DelimiterMode.none
end

--- Split `text` on runs of `_`/`-`/comment-marker delimiters, per their configured modes.
---
--- A run of consecutive same-mode delimiter characters (e.g. the `---` in a
--- LuaCATS doc comment, or the `///` in a Rust one) is treated as *one*
--- stop, not one per character -- matching real Vim's `w`, where a run of
--- same-class punctuation is always a single word no matter how long it is.
--- In `"skip"` mode the run closes off the chunk before it and starts a new
--- one right after it, without appearing in either chunk -- `w`/`b`/`e`/`ge`
--- skip over it entirely instead of landing on it. `"stop"` does the same,
--- but also inserts the run itself as its own chunk in between, so it
--- *does* become a landing stop. `"none"` isn't a split point at all -- the
--- run just stays embedded in whichever chunk it's already part of.
--- `offset` lets `M.split` translate each chunk's position back into an
--- absolute buffer column.
---
--- `kebab_case`/`snake_case` only apply when `text` actually has an
--- identifier to case-split -- i.e. `-`/`_` sit between (or beside) real
--- alphanumeric content, like `hello-world` or `snake_case`. When `text` is
--- *entirely* delimiter characters (no letter or digit anywhere in it --
--- Lua's `--` comment opener, a `---` doc-comment marker, a `-----`
--- separator line), there's no identifier being kebab/snake-cased at all --
--- it's a bare punctuation run, the same kind of thing `#`/`/`/`%` already
--- always are (`_char_class` isolates them into their own word before this
--- function even runs, since they're never grouped as `"word"` class). So
--- for a text like that, `comment_marker_case` takes over for `-`/`_`
--- too, exactly like it already does for `#`/`/`/`%` -- but only if the
--- current language's `comment_markers` actually lists `-`/`_` (see
--- `_DEFAULTS`' `lua = { "-" }`, for Lua's `--`); a language that doesn't
--- list them there leaves `kebab_case`/`snake_case` in charge even for a
--- bare run, the same "no entry means no effect" rule every other marker
--- character already follows -- there's deliberately no special, always-on
--- carve-out for `-`/`_` the way `comment_markers`' other characters don't
--- get one either.
---
---@param text string A word to split (a whole leaf's text, for code; one `_split_prose_words` word, for prose).
---@param kebab_case treemotion.SubwordDelimiterMode How to treat `-` next to real identifier content.
---@param snake_case treemotion.SubwordDelimiterMode How to treat `_` next to real identifier content.
---@param colon_case treemotion.SubwordDelimiterMode How to treat `:` next to real identifier content.
---@param slash_case treemotion.SubwordDelimiterMode How to treat `/` next to real identifier content.
---@param comment_marker_case treemotion.SubwordDelimiterMode How to treat `comment_marker_characters`, or
---    `text`-wide `-`/`_`/`:`/`/` runs.
---@param comment_marker_characters table<string, true> This language's comment-marker punctuation (see
---    `_comment_marker_characters`).
---@return {text: string, offset: integer}[] # Each chunk and its 1-indexed start column in `text`.
---
local function _split_delimiters(
    text,
    kebab_case,
    snake_case,
    colon_case,
    slash_case,
    comment_marker_case,
    comment_marker_characters
)
    if not text:find("%w") then
        if comment_marker_characters["-"] then
            kebab_case = comment_marker_case
        end

        if comment_marker_characters["_"] then
            snake_case = comment_marker_case
        end

        if comment_marker_characters[":"] then
            colon_case = comment_marker_case
        end

        if comment_marker_characters["/"] then
            slash_case = comment_marker_case
        end
    end

    local chunks = {}
    local start = 1
    local index = 1

    while index <= #text do
        local mode = _delimiter_mode(
            text:sub(index, index),
            kebab_case,
            snake_case,
            colon_case,
            slash_case,
            comment_marker_case,
            comment_marker_characters
        )

        if mode == motion_constant.DelimiterMode.none then
            index = index + 1
        else
            if index > start then
                table.insert(chunks, { text = text:sub(start, index - 1), offset = start })
            end

            local run_end = index

            while
                run_end < #text
                and _delimiter_mode(
                        text:sub(run_end + 1, run_end + 1),
                        kebab_case,
                        snake_case,
                        colon_case,
                        slash_case,
                        comment_marker_case,
                        comment_marker_characters
                    )
                    == mode
            do
                run_end = run_end + 1
            end

            if mode == motion_constant.DelimiterMode.stop then
                table.insert(chunks, { text = text:sub(index, run_end), offset = index })
            end

            start = run_end + 1
            index = run_end + 1
        end
    end

    if start <= #text then
        table.insert(chunks, { text = text:sub(start), offset = start })
    end

    return chunks
end

--- Collapse `node` to a single-row span, if it only spans multiple rows
--- because of trailing blank characters.
---
--- Some grammars bake a trailing terminator into a token's own span instead
--- of stopping right after its real content: tree-sitter-rust's
--- `doc_comment` (everything after `///`) is produced by an external
--- scanner that folds the line's trailing newline into the token itself --
--- confirmed against the real grammar, its range ends at `(next_row, 0)`
--- and its text literally ends in `"\n"`, even though every real character
--- is still on `node`'s start row. That's not a Rust-only quirk: any
--- grammar whose scanner consumes trailing whitespace/newline(s) as part of
--- a token (commonly done so the scanner can disambiguate that token from
--- whatever follows) produces the same shape, the same way any grammar
--- can split a fixed-width comment-marker literal the way
--- `_leading_continuation_length` above handles. Rather than special-casing
--- node types per grammar, this asks the one question that's actually true
--- generically: after trimming trailing blank characters, is everything
--- that's left still on one row? A leaf with *real* content on more than
--- one row (e.g. a Lua long string's `string_content`, confirmed to keep
--- its embedded newline even after trimming) fails this check, so `M.split`
--- keeps treating it as genuinely multi-row.
---
---@param node TSNode The leaf to check.
---@param text string `node`'s full text.
---@return string?, integer?, integer? # `nil` if `node` is genuinely
---    multi-row; otherwise the trimmed text and its end row/column, both
---    still `node`'s start row.
---
local function _single_row_span(node, text)
    local trimmed = text:gsub("%s+$", "")

    if trimmed == text or trimmed:find("\n") then
        return nil
    end

    local start_row, start_col = node:start()

    return trimmed, start_row, start_col + #trimmed
end

--- How many of `text`'s leading characters continue a punctuation run that
--- started in the character immediately before `node`, on the same line.
---
--- Tokenization is a grammar concern, not a textual one, and this isn't a
--- Lua-only quirk -- e.g. tree-sitter-lua's comment opener is a fixed
--- 2-character `--` literal no matter how many dashes actually follow, so a
--- `---` doc comment's third dash ends up as `comment_content`'s leading
--- character instead of staying part of the same `-` run as its two
--- siblings in the `--` leaf; tree-sitter-rust does the exact same thing
--- one level deeper for `///` outer doc comments, which parse as a `//`
--- leaf, then a *lone* `/` leaf (`outer_doc_comment_marker`), then the
--- `doc_comment` text -- confirmed against the real grammar, not just
--- Lua's. Left alone, that stray leading character would read as a fresh
--- 1-character word/chunk of its own once `M.split` runs on the sibling
--- leaf it landed in -- a landing stop real Vim's `w` would never produce,
--- since a run of same-class punctuation is always one word regardless of
--- how a particular grammar happened to tokenize it. `M.split` strips this
--- many characters off `text` before splitting, so the run's only landing
--- stop stays wherever it started -- in the previous leaf.
---
--- Not restricted to `-`/`_` (the two characters `kebab_case`/`snake_case`
--- know about) -- any non-blank, non-alphanumeric character qualifies,
--- since the same fixed-width-literal-token tokenization can split any
--- punctuation-based comment/doc-comment marker (`#`, `/`, `%`, ...) the
--- same way. Alphanumeric characters are deliberately excluded: an
--- identifier or number split across a leaf boundary is a different,
--- riskier kind of grammar quirk (e.g. a number literal's mantissa and
--- exponent as separate leaves) where blindly merging could swallow a
--- genuinely distinct token instead of a stray delimiter fragment.
---
--- Can return `#text` itself -- tree-sitter-rust's lone `/` leaf (the
--- `outer_doc_comment_marker` mentioned above) is *entirely* consumed this
--- way, not just a prefix of it. `M.split` handles that by producing no
--- units at all for `node` rather than falling back to its full span --
--- see `M.split`'s docstring.
---
--- Works in whole characters throughout, via `_commands.motion.codepoint`,
--- not raw bytes: `char` is `text`'s first full codepoint (not just its
--- first byte), `before` is read from `codepoint.last_character_column`'s
--- lead-byte column rather than a blind `start_col - 1` (which can itself
--- land mid-character, reading a bare continuation byte out of the buffer),
--- and the run-length walk below advances one whole character at a time. No
--- real grammar this plugin has been verified against actually produces a
--- multi-byte comment-marker character, but this keeps the guarantee exact
--- -- `text:sub(continuation + 1, ...)` in `_split` always lands on a
--- character boundary -- rather than merely "safe in every case tested so far."
---
---@param node TSNode The leaf `text` came from.
---@param text string `node`'s full text (see `M.split`).
---@return integer # 0 if `text`'s start doesn't continue a punctuation run.
---
local function _leading_continuation_length(node, text)
    if text == "" then
        return 0
    end

    local char = text:sub(1, codepoint.char_width(text, 1))

    if char:match("%s") or char:match("%w") then
        return 0
    end

    local start_row, start_col = node:start()

    if start_col == 0 then
        return 0
    end

    local before_col = codepoint.last_character_column(start_row, start_col)
    local before = vim.api.nvim_buf_get_text(0, start_row, before_col, start_row, start_col, {})[1]

    if before ~= char then
        return 0
    end

    local length = 0

    while length < #text do
        local width = codepoint.char_width(text, length + 1)

        if text:sub(length + 1, length + width) ~= char then
            break
        end

        length = length + width
    end

    return length
end

--- Every offset in `text` (1-indexed, plus one entry for `#text + 1`, one
--- past the last character) mapped to the buffer row/column it corresponds
--- to, given `text`'s own first character sits at `start_row`/`start_col`.
---
--- `_split_text`'s per-chunk column arithmetic (`start_col + offset - 1`) is
--- only valid for single-row `text` -- a `\n` anywhere in `text` resets the
--- real buffer column back to `0`, which flat addition can't express. This
--- is what lets a multi-row *prose* leaf (a hard/soft-wrapped markdown
--- paragraph, confirmed against Neovim's own bundled `markdown_inline`
--- grammar: a whole paragraph parses as one leaf whose prose text has no
--- per-word node of its own at all, see this module's docstring) still get
--- split word-by-word across every line it spans, instead of `_split`/
--- `_split_run_segment` falling back to one giant unit the moment the leaf
--- (or run) turns out to be genuinely multi-row -- the fallback that's
--- still correct for genuinely atomic multi-row *code* content (a Lua long
--- string, a C block comment), just not for prose.
---
--- Built once per multi-row `_split_text` call (only when `text` actually
--- contains a `\n` -- the overwhelming majority of leaves, every code leaf
--- and every prose leaf/run that doesn't wrap across lines, never pay for
--- this at all), then indexed by `_make_unit` for every chunk boundary
--- instead of re-scanning `text` from the start each time.
---
---@param start_row integer
---@param start_col integer
---@param text string
---@return integer[][] # 1-indexed; entry `offset` is `{row, column}`.
---
local function _multirow_positions(start_row, start_col, text)
    local positions = {}
    local row, col = start_row, start_col

    for offset = 1, #text + 1 do
        positions[offset] = { row, col }

        if text:sub(offset, offset) == "\n" then
            row = row + 1
            col = 0
        else
            col = col + 1
        end
    end

    return positions
end

--- The buffer row/column one past `text`'s last character, given `text`'s
--- own first character sits at `start_row`/`start_col`.
---
--- The one entry of `_multirow_positions`'s table `_split_run_segment` needs
--- up front (as the "no words at all" fallback endpoint `_split_text` takes
--- as a parameter) before `_split_text` itself builds -- and indexes into --
--- the full table for every chunk boundary. Delegates to
--- `_multirow_positions` rather than re-walking `text` itself, so the two
--- stay in lockstep instead of duplicating the same row/column walk.
---
---@param start_row integer
---@param start_col integer
---@param text string
---@return integer, integer
---
local function _end_of_text(start_row, start_col, text)
    local positions = _multirow_positions(start_row, start_col, text)
    local row, col = unpack(positions[#text + 1])
    return row, col
end

--- Build one `treemotion.SubwordUnit` spanning `length` characters starting
--- at `text_offset` (1-indexed into the leaf/run's full text).
---
--- Single-row text -- `positions` is `nil` -- stays exactly the cheap
--- arithmetic `_split_text` always used: `row`/`column`, tracked by the
--- caller alongside `text_offset`, are already the right buffer position.
--- Multi-row text looks `text_offset` (and `text_offset + length`, this
--- unit's exclusive end) up in `positions` (`_multirow_positions`) instead,
--- since flat column arithmetic can't cross a line break.
---
---@param positions integer[][]? `_multirow_positions`'s result, or `nil` for single-row text.
---@param row integer The row to use when `positions` is `nil`.
---@param column integer The column to use when `positions` is `nil`.
---@param text_offset integer 1-indexed offset of this unit's first character in the full text.
---@param length integer How many characters this unit spans.
---@return treemotion.SubwordUnit
---
local function _make_unit(positions, row, column, text_offset, length)
    if not positions then
        return _new_unit(row, column, row, column + length)
    end

    local start_row, start_col = positions[text_offset][1], positions[text_offset][2]
    local end_row, end_col = positions[text_offset + length][1], positions[text_offset + length][2]

    return _new_unit(start_row, start_col, end_row, end_col)
end

--- Shared tail of `M.split`/`M.split_run`: `text` -> words -> per-word
--- delimiter/case split -> `treemotion.SubwordUnit[]`.
---
--- For prose (`@spell`- or `@string`-tagged) text only, `_prose_words` first
--- divides `text` into individual words; code text is treated as a single
--- word instead, since a normal token never contains embedded blanks. Every
--- word then goes through `_split_delimiters` (dividing on `_`/`-`/`:`/`/`)
--- and, unless the resulting chunk looks like an opaque hash/digest (see
--- `_looks_like_hash`), `_split_case` (dividing on camelCase/PascalCase
--- boundaries). A chunk that *does* look like a hash skips `_split_case`
--- entirely -- it's one unit no matter its internal case transitions. Two
--- running offsets -- `word.offset` from the outer pass, `delimited.offset`/
--- chunk length from the inner ones -- compose into each unit's absolute
--- buffer column, both relative to `start_col`.
---
--- If `text` produces no words at all (e.g. an all-whitespace prose
--- comment), this falls back to one unit spanning `start_row`/`start_col`
--- to `end_row`/`end_col` -- nothing for any delimiter setting to have acted
--- on, so there's nothing to split. One more empty case falls out of
--- `_split_delimiters` itself, though, and does *not* get that fallback:
--- text that's *entirely* a `comment_marker_case = "skip"` run has real
--- content -- unlike all-whitespace text -- but every bit of it is a marker
--- `_split_delimiters` was told to drop, so `words` is non-empty while the
--- returned units end up empty anyway. That's `"skip"` doing exactly what
--- it says -- forcing a landing stop back in for it would silently override
--- the user's own setting.
---
---@param text string The text to split (already narrowed to what's eligible -- see `M.split`/`M.split_run`).
---@param start_row integer `text`'s row in the buffer (0-indexed).
---@param start_col integer `text`'s first column in the buffer (0-indexed).
---@param end_row integer The row to fall back to if `text` produces no words at all.
---@param end_col integer The column to fall back to if `text` produces no words at all.
---@param is_prose boolean Whether to read `.prose` or `.code` from `commands.motion[group]`.
---@param rules treemotion.ConfigurationMotionSubwordRules `_rules(is_prose, group)`'s result.
---@param group "small"|"big" Which motion family's configuration to read (for backtick identifiers,
---    and for resolving `.code`'s rules when a backtick-identifier word is encountered in prose).
---@param comment_marker_characters table<string, true> This language's comment-marker punctuation (see
---    `_comment_marker_characters`).
---@return treemotion.SubwordUnit[]
---
local function _split_text(
    text,
    start_row,
    start_col,
    end_row,
    end_col,
    is_prose,
    rules,
    group,
    comment_marker_characters
)
    local words = is_prose and _prose_words(text, _backtick_identifiers_enabled(group), rules.opaque_token_min_length)
        or { { text = text, offset = 1 } }

    if #words == 0 then
        return { _new_unit(start_row, start_col, end_row, end_col) }
    end

    -- `nil` for the overwhelming majority of calls (every code leaf, and
    -- every prose leaf/run that doesn't wrap across lines) -- see
    -- `_multirow_positions`'s docstring for why only genuinely multi-row
    -- `text` (a hard/soft-wrapped markdown paragraph, e.g.) needs it.
    local positions = text:find("\n") and _multirow_positions(start_row, start_col, text) or nil

    -- Fetched lazily, at most once, only if a backtick-identifier word is
    -- actually encountered below -- most prose leaves have none, and
    -- `_rules(false, group)` is an extra `resolve_data()` walk not worth
    -- paying for on every prose leaf regardless.
    local identifier_rules

    local units = {}

    for _, word in ipairs(words) do
        local word_column = start_col + word.offset - 1
        local word_rules = rules

        if word.is_identifier then
            identifier_rules = identifier_rules or _rules(false, group)
            word_rules = identifier_rules
        end

        for _, delimited in
            ipairs(
                _split_delimiters(
                    word.text,
                    word_rules.kebab_case,
                    word_rules.snake_case,
                    word_rules.colon_case,
                    word_rules.slash_case,
                    word_rules.comment_marker_case,
                    comment_marker_characters
                )
            )
        do
            local column = word_column + delimited.offset - 1
            local text_offset = word.offset + delimited.offset - 1

            if _looks_like_hash(delimited.text, word_rules.opaque_token_min_length) then
                table.insert(units, _make_unit(positions, start_row, column, text_offset, #delimited.text))
            else
                for _, chunk in ipairs(_split_case(delimited.text, word_rules.camel_case, word_rules.pascal_case)) do
                    table.insert(units, _make_unit(positions, start_row, column, text_offset, #chunk))
                    column = column + #chunk
                    text_offset = text_offset + #chunk
                end
            end
        end
    end

    return units
end

--- Split `node`'s text into sub-word units, per `commands.motion.small`.
---
--- Two passes narrow `node` down to the text that's actually eligible to
--- split, before handing off to `_split_text`. `_single_row_span` first
--- collapses a multi-row `node` down to one row when the only reason it
--- spans rows is a trailing run of blank characters (tree-sitter-rust's
--- `doc_comment`, see its docstring) -- genuinely multi-row content (a long
--- string) is left alone and falls back to one whole-leaf unit, same as
--- always. Then `_leading_continuation_length` strips off (and shifts past)
--- any leading characters that are really the tail of the previous leaf's
--- delimiter run -- see its docstring. When that continuation consumes
--- `node` in its entirety (tree-sitter-rust's lone `/` `outer_doc_comment_marker`
--- leaf, for `///` doc comments), `node` has no content of its own left to
--- become a unit, so this returns an empty list instead of the usual
--- whole-leaf fallback -- `_commands.motion.word` treats that as "no stop
--- here", skipping straight to the next/previous leaf, the same way it
--- already skips punctuation runs collapsed into a single stop elsewhere.
---
---@param node TSNode Any leaf (see `_commands.motion.leaf`).
---@return treemotion.SubwordUnit[] # Empty when `node` is `_is_insignificant`,
---    entirely a punctuation-run continuation of the leaf before it, or
---    entirely a dropped (`"skip"`) delimiter run with no other content;
---    otherwise `node`'s full span if nothing else splits it.
---
local function _split(node)
    if _is_insignificant(node) then
        return {}
    end

    local start_row, start_col = node:start()
    local end_row, end_col = node:end_()
    local text = vim.treesitter.get_node_text(node, 0)
    local is_prose = _is_prose(node)

    if start_row ~= end_row then
        local collapsed_text, collapsed_end_row, collapsed_end_col = _single_row_span(node, text)

        if collapsed_text then
            text, end_row, end_col = collapsed_text, assert(collapsed_end_row), assert(collapsed_end_col)
        elseif not is_prose then
            -- Genuinely multi-row, non-prose content; sub-word splitting
            -- only makes sense within a single line for code-shaped text,
            -- so no real-world code leaf (an identifier, a long string, a
            -- block comment, ...) needs it across lines. Multi-row *prose*
            -- (a hard/soft-wrapped markdown paragraph, e.g.) falls through
            -- to `_split_text` below instead, which is row/column-aware
            -- (see `_multirow_positions`) and splits it word-by-word across
            -- every line it spans, the same as a single-line paragraph
            -- already does.
            return { _new_unit(start_row, start_col, end_row, end_col) }
        end
    end

    local continuation = _leading_continuation_length(node, text)

    if continuation > 0 and continuation == #text then
        return {}
    end

    local text_start_col = start_col

    if continuation > 0 then
        text = text:sub(continuation + 1)
        text_start_col = start_col + continuation
    end

    local rules = _rules(is_prose, "small")
    local comment_marker_characters = _comment_marker_characters(_current_language())

    return _split_text(
        text,
        start_row,
        text_start_col,
        end_row,
        end_col,
        is_prose,
        rules,
        "small",
        comment_marker_characters
    )
end

--- Split `node`'s text into sub-word units, per `commands.motion.small` --
--- logging wrapper around `_split`.
---
---@param node TSNode Any leaf (see `_commands.motion.leaf`).
---@return treemotion.SubwordUnit[] # See `_split`'s docstring.
---
function M.split(node)
    local units = _split(node)
    local row, column = node:start()

    _LOGGER:fmt_debug("split(%s at %s:%s) -> %s unit(s).", node:type(), row, column, #units)

    return units
end

--- Break the run from `start_node` to `end_node` into maximal stretches of
--- leaves that all share the same `_is_prose` classification.
---
--- A contiguous run (see `_commands.motion.leaf`'s `is_contiguous`) can mix
--- a code leaf with a prose/string leaf right next to it with no whitespace
--- in between -- e.g. Lua's sugar call syntax `foo"bar"` parses as an
--- `identifier` leaf (code) immediately followed by a `"`/`string_content`/`"`
--- trio (all `@string`-tagged, i.e. prose per `_is_prose_capture`). Splitting
--- the run's text as one undifferentiated blob would apply whichever leaf
--- happens to come first's rules to the whole thing, bleeding `.code`'s
--- `camel_case`/`opaque_token_min_length` (or `.prose`'s) into content that
--- should have used the other. Grouping by classification first, and
--- splitting each stretch with its own rules, keeps that boundary exact
--- while still treating same-classification leaves as one merged span the
--- way `M.split_run` always has.
---
---@param start_node TSNode The run's first leaf.
---@param end_node TSNode The run's last leaf.
---@return {is_prose: boolean, start_row: integer, start_col: integer, end_row: integer, end_col: integer}[]
---
local function _run_segments(start_node, end_node)
    local end_row, end_col = end_node:end_()
    local segments = {}
    local node = start_node

    while true do
        local is_prose = _is_prose(node)
        local segment_start_row, segment_start_col = node:start()
        local segment_end_row, segment_end_col = node:end_()

        while segment_end_row ~= end_row or segment_end_col ~= end_col do
            local next_node = assert(leaf.next_leaf(node))

            if _is_prose(next_node) ~= is_prose then
                node = next_node

                break
            end

            node = next_node
            segment_end_row, segment_end_col = node:end_()
        end

        table.insert(segments, {
            is_prose = is_prose,
            start_row = segment_start_row,
            start_col = segment_start_col,
            end_row = segment_end_row,
            end_col = segment_end_col,
        })

        if segment_end_row == end_row and segment_end_col == end_col then
            return segments
        end
    end
end

--- Split one `_run_segments` segment into sub-word units.
---
--- `pcall` guards `nvim_buf_get_text` the same way `_commands.motion.leaf`'s
--- `_has_non_blank_between` already guards its own identical call: a leaf's
--- `:end_()` can sit one row past the buffer's last line (a root node
--- covering an implicit trailing newline is the common case), which isn't a
--- valid range to read. `M.split` never hits this because it reads leaf text
--- via `vim.treesitter.get_node_text`, whose internal `buf_range_get_text`
--- special-cases `end_col == 0` before ever calling `nvim_buf_get_text` --
--- there's no equivalent to reach for here, since a run spans multiple
--- leaves and has no single `TSNode` of its own. Falling back to one
--- whole-segment unit on failure matches every other "can't split this"
--- fallback in this file (a genuinely multi-row span, a `text` with no words
--- in it, ...).
---
---@param segment {is_prose: boolean, start_row: integer, start_col: integer, end_row: integer, end_col: integer}
---@param group "small"|"big"
---@param comment_marker_characters table<string, true>
---@return treemotion.SubwordUnit[]
---
local function _split_run_segment(segment, group, comment_marker_characters)
    local start_row, start_col = segment.start_row, segment.start_col
    local end_row, end_col = segment.end_row, segment.end_col

    local ok, lines = pcall(vim.api.nvim_buf_get_text, 0, start_row, start_col, end_row, end_col, {})

    if not ok then
        return { _new_unit(start_row, start_col, end_row, end_col) }
    end

    local text = table.concat(lines, "\n")
    local trimmed = text:gsub("%s+$", "")

    local trimmed_end_row, trimmed_end_col = start_row, start_col + #trimmed

    if trimmed:find("\n") then
        if not segment.is_prose then
            -- Genuinely multi-row, non-prose content; sub-word splitting
            -- only makes sense within a single line for code-shaped runs --
            -- see `_split`'s identical branch for why multi-row *prose*
            -- runs fall through below instead.
            return { _new_unit(start_row, start_col, end_row, end_col) }
        end

        trimmed_end_row, trimmed_end_col = _end_of_text(start_row, start_col, trimmed)
    end

    local rules = _rules(segment.is_prose, group)

    return _split_text(
        trimmed,
        start_row,
        start_col,
        trimmed_end_row,
        trimmed_end_col,
        segment.is_prose,
        rules,
        group,
        comment_marker_characters
    )
end

--- Split the contiguous run from `start_node` to `end_node`'s text into
--- sub-word units, per `commands.motion.big` -- the `W`/`E`/`B`/`gE`
--- counterpart to `M.split`.
---
--- A run's leaves are contiguous by construction (see `_commands.motion.leaf`'s
--- `is_contiguous`), so the raw buffer text from `start_node`'s start to
--- `end_node`'s end is already exactly the run's text -- no leaf-boundary
--- artifact-stitching like `_leading_continuation_length` is needed the way
--- `M.split` needs it for a single leaf. `_run_segments` first divides the
--- run into same-classification (code vs. prose, see its docstring)
--- stretches; each stretch is then handled by `_split_run_segment`, which
--- trims trailing blank characters the same way `_single_row_span` trims a
--- leaf (a run can end in one, the same trailing-terminator grammar quirk
--- `_single_row_span`'s docstring covers), falling back to one whole-segment
--- unit for genuinely multi-row content left after trimming, same as
--- `M.split` does for a multi-row leaf.
---
--- When `commands.motion.big.enabled` is `false` (the default), this always
--- returns one whole-run unit -- the exact behavior `W`/`E`/`B`/`gE`
--- had before this feature existed, ignoring case/delimiters entirely.
--- Setting it to `true` opts into real splitting, reading
--- `commands.motion.big.code`/`.prose` instead of `.small`'s.
---
---@param start_node TSNode The run's first leaf (e.g. `leaf.run_start(node)`).
---@param end_node TSNode The run's last leaf (e.g. `leaf.run_end(node)`).
---@return treemotion.SubwordUnit[] # Empty when `enabled` is `true` and the whole run is a dropped
---    (`"skip"`) delimiter run with no other content -- same as `M.split`, see `_split_text`'s docstring;
---    otherwise the run's full (trimmed) span if nothing else splits it.
---
local function _split_run(start_node, end_node)
    local start_row, start_col = start_node:start()
    local end_row, end_col = end_node:end_()

    if not configuration.resolve_data().commands.motion.big.enabled then
        -- Deliberately skips `_run_segments`/trimming entirely: that
        -- machinery exists only to make real splitting land on sensible
        -- boundaries, and applying it here too would change `W`/`E`/`B`/`gE`'s
        -- landing column in the same rare trailing-terminator-grammar-quirk
        -- case `_single_row_span` handles for `M.split` -- exactly the
        -- byte-for-byte parity with pre-`enabled` behavior this default is
        -- supposed to guarantee. So the disabled path returns the raw
        -- `start_node`/`end_node` span untouched, identical to what
        -- `_commands.motion.runner` used to compute directly from
        -- `leaf.run_start`/`leaf.run_end` before this function existed.
        return { _new_unit(start_row, start_col, end_row, end_col) }
    end

    local comment_marker_characters = _comment_marker_characters(_current_language())
    local units = {}

    for _, segment in ipairs(_run_segments(start_node, end_node)) do
        vim.list_extend(units, _split_run_segment(segment, "big", comment_marker_characters))
    end

    return units
end

--- Split the contiguous run from `start_node` to `end_node`'s text into
--- sub-word units, per `commands.motion.big` -- logging wrapper around `_split_run`.
---
---@param start_node TSNode The run's first leaf (e.g. `leaf.run_start(node)`).
---@param end_node TSNode The run's last leaf (e.g. `leaf.run_end(node)`).
---@return treemotion.SubwordUnit[] # See `_split_run`'s docstring.
---
function M.split_run(start_node, end_node)
    local units = _split_run(start_node, end_node)
    local start_row, start_col = start_node:start()
    local end_row, end_col = end_node:end_()

    _LOGGER:fmt_debug(
        "split_run(%s at %s:%s -> %s:%s) -> %s unit(s).",
        start_node:type(),
        start_row,
        start_col,
        end_row,
        end_col,
        #units
    )

    return units
end

return M
