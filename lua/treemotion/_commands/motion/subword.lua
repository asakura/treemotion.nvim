--- Split a single treesitter leaf's text into case-convention-aware sub-word units.
---
--- This only ever applies to `w`/`e`/`b`/`ge` (see `_commands.motion.word`) --
--- `W`/`E`/`B`/`gE` intentionally ignore case entirely, the same way real
--- Vim's `W` ignores punctuation inside a WORD.
---
--- Everything here is plain text/coordinate analysis -- no treesitter tree
--- walking happens in this file, that's `_commands.motion.leaf`'s and
--- `_commands.motion.word`'s job; the one treesitter feature this file does
--- use is reading a leaf's `@spell` highlight capture (`:help
--- treesitter-highlight-spell`) to tell "code" leaves (identifiers, string
--- content, ...) apart from "prose" leaves (comments, or whatever else a
--- language's highlight query marks as natural-language text).
---
--- `M.split` is the entry point, and composes up to three passes:
--- `_split_prose_words` runs first, but *only* for `@spell`-tagged leaves --
--- it divides prose into individual words the way real Vim's `w` divides a
--- text file (on whitespace and punctuation), since a comment leaf's text
--- has no other word boundaries in it at all. Code leaves skip straight
--- past this pass, treating their whole text as a single "word". Every
--- resulting word (one, for code) then goes through `_split_delimiters`
--- (dividing on `_`/`-`) and `_split_case` (dividing on camelCase/PascalCase
--- boundaries), using `commands.motion.subword.code` or `.prose`'s rules,
--- whichever matched. Each produced `treemotion.SubwordUnit` is just a
--- coordinate range, not a real tree node -- there's no parent/child/sibling
--- structure to a sub-word slice, only a start and an end.

local configuration = require("treemotion._core.configuration")
local motion_constant = require("treemotion._commands.motion.constant")

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

--- Check whether `node` is tagged `@spell` -- i.e. natural-language prose, not code.
---
--- Reuses Nvim's own spellchecking boundary (`:help treesitter-highlight-spell`)
--- rather than hand-listing prose-ish node type names (`comment`,
--- `line_comment`, markdown's `inline`, ...) per language -- those names are
--- grammar-specific and would need maintaining forever, while `@spell` is
--- already correct (and user-overridable) for every language with a
--- highlight query. Note this can, and often does, differ from a whole
--- node *kind*: Lua's `(comment) @spell` tags comments, but its
--- `string_content` isn't tagged at all, so string leaves stay "code".
---
---@param node TSNode Any leaf (see `_commands.motion.leaf`).
---@return boolean
---
local function _is_prose(node)
    local row, column = node:start()

    for _, capture in ipairs(vim.treesitter.get_captures_at_pos(0, row, column)) do
        if capture.capture == "spell" then
            return true
        end
    end

    return false
end

--- Read the user's `subword` splitting configuration for `is_prose`'s context.
---
---@param is_prose boolean Whether to read `commands.motion.subword.prose` or `.code`.
---@return boolean # camel_case
---@return boolean # pascal_case
---@return treemotion.SubwordDelimiterMode # kebab_case
---@return treemotion.SubwordDelimiterMode # snake_case
---@return treemotion.SubwordDelimiterMode # comment_marker_case
---
local function _options(is_prose)
    -- `assert()`: `commands.motion.subword.code`/`.prose` are optional in
    -- the LuaCATS types (they double as valid partial user-override input),
    -- but `configuration._DEFAULTS` always fills both in, so
    -- `resolve_data()`'s result always has them.
    local subword = assert(configuration.resolve_data().commands.motion.subword)
    local rules = assert(is_prose and subword.prose or subword.code)

    return rules.camel_case, rules.pascal_case, rules.kebab_case, rules.snake_case, rules.comment_marker_case
end

--- Classify one character the way real Vim's `w` classifies it in a text file.
---
--- Real Vim's word motions only recognize three classes: blank, "keyword"
--- (`'iskeyword'`, which defaults to letters/digits/`_`), and everything
--- else -- and critically, *every* non-blank, non-keyword character shares
--- that one "everything else" class, so a run like `?!` is a single word,
--- not two.
---
--- `-` is deliberately grouped into `"word"` here too, even though real
--- Vim's default `'iskeyword'` excludes it: `_split_delimiters` is the
--- single place that decides what happens to a `-`/`_` it finds *within* a
--- word, via `kebab_case`/`snake_case`. If this function split `-` off as
--- its own run instead, `"none"` mode could never put it back together --
--- the split would already have happened a layer up, before that setting
--- was even consulted.
---
---@param char string A single character.
---@return "blank"|"word"|"other"
---
local function _char_class(char)
    if char:match("%s") then
        return "blank"
    elseif char:match("[%w_%-]") then
        return "word"
    end

    return "other"
end

--- Split `text` into Vim-style words: runs of keyword chars, or runs of
--- punctuation, with blank runs dropped entirely (never landed on, exactly
--- like Vim's `w` always skips whitespace).
---
--- Only used for `@spell`-tagged (prose) leaves -- code leaves never
--- contain embedded blanks in the first place, so there's nothing for this
--- pass to do for them.
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

--- The punctuation characters `comment_marker_case` applies to.
---
--- Deliberately a small, curated set rather than "any punctuation" (unlike
--- `_leading_continuation_length`'s leaf-boundary-continuation fix, which
--- has to handle arbitrary tokenization quirks generically): these are the
--- comment-opener characters this plugin has been verified against across
--- grammars (`#` for Python/Bash/Elixir, `/` for Rust/C/JS, `%` for
--- LaTeX/Erlang/Matlab -- see `_leading_continuation_length`'s docstring).
--- Applying `"skip"` to arbitrary punctuation instead would also eat real
--- operator runs (`===`, `**`, ...) that have nothing to do with comments.
--- `-` is deliberately excluded even though it's a comment marker too
--- (Lua's `--`) -- `kebab_case` already owns that character.
---
---@type table<string, true>
local _COMMENT_MARKER_CHARACTERS = { ["#"] = true, ["/"] = true, ["%"] = true }

--- Look up how `char` should be treated, per `kebab_case`/`snake_case`/`comment_marker_case`.
---
---@param char string A single character.
---@param kebab_case treemotion.SubwordDelimiterMode How to treat `-`.
---@param snake_case treemotion.SubwordDelimiterMode How to treat `_`.
---@param comment_marker_case treemotion.SubwordDelimiterMode How to treat `_COMMENT_MARKER_CHARACTERS`.
---@return treemotion.SubwordDelimiterMode # `"none"` for any character that isn't covered by one of the three above.
---
local function _delimiter_mode(char, kebab_case, snake_case, comment_marker_case)
    if char == "-" then
        return kebab_case
    elseif char == "_" then
        return snake_case
    elseif _COMMENT_MARKER_CHARACTERS[char] then
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
---@param text string A word to split (a whole leaf's text, for code; one `_split_prose_words` word, for prose).
---@param kebab_case treemotion.SubwordDelimiterMode How to treat `-`.
---@param snake_case treemotion.SubwordDelimiterMode How to treat `_`.
---@param comment_marker_case treemotion.SubwordDelimiterMode How to treat `#`/`/`/`%`.
---@return {text: string, offset: integer}[] # Each chunk and its 1-indexed start column in `text`.
---
local function _split_delimiters(text, kebab_case, snake_case, comment_marker_case)
    local chunks = {}
    local start = 1
    local index = 1

    while index <= #text do
        local mode = _delimiter_mode(text:sub(index, index), kebab_case, snake_case, comment_marker_case)

        if mode == motion_constant.DelimiterMode.none then
            index = index + 1
        else
            if index > start then
                table.insert(chunks, { text = text:sub(start, index - 1), offset = start })
            end

            local run_end = index

            while
                run_end < #text
                and _delimiter_mode(text:sub(run_end + 1, run_end + 1), kebab_case, snake_case, comment_marker_case)
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

---@param node TSNode The leaf `text` came from.
---@param text string `node`'s full text (see `M.split`).
---@return integer # 0 if `text`'s start doesn't continue a punctuation run.
---
local function _leading_continuation_length(node, text)
    local char = text:sub(1, 1)

    if char == "" or char:match("%s") or char:match("%w") then
        return 0
    end

    local start_row, start_col = node:start()

    if start_col == 0 then
        return 0
    end

    local before = vim.api.nvim_buf_get_text(0, start_row, start_col - 1, start_row, start_col, {})[1]

    if before ~= char then
        return 0
    end

    local length = 0

    while length < #text and text:sub(length + 1, length + 1) == char do
        length = length + 1
    end

    return length
end

--- Split `node`'s text into sub-word units, per the user's `subword` configuration.
---
--- Composes up to three passes: for prose (`@spell`-tagged) leaves only,
--- `_split_prose_words` first divides the text into individual words; code
--- leaves treat their whole text as a single word instead, since a normal
--- token never contains embedded blanks. Every word then goes through
--- `_split_delimiters` (dividing on `_`/`-`) and `_split_case` (dividing on
--- camelCase/PascalCase boundaries), in that order. Two running offsets --
--- `word.offset` from the outer pass, `delimited.offset`/chunk length from
--- the inner ones -- compose into each unit's absolute buffer column.
---
--- Before any of that, two passes narrow `node` down to the text that's
--- actually eligible to split. `_single_row_span` first collapses a
--- multi-row `node` down to one row when the only reason it spans rows is a
--- trailing run of blank characters (tree-sitter-rust's `doc_comment`, see
--- its docstring) -- genuinely multi-row content (a long string) is left
--- alone and falls back to one whole-leaf unit, same as always. Then
--- `_leading_continuation_length` strips off (and shifts past) any leading
--- characters that are really the tail of the previous leaf's delimiter run
--- -- see its docstring. When that continuation consumes `node` in its
--- entirety (tree-sitter-rust's lone `/` `outer_doc_comment_marker` leaf,
--- for `///` doc comments), `node` has no content of its own left to become
--- a unit, so this returns an empty list instead of the usual whole-leaf
--- fallback -- `_commands.motion.word` treats that as "no stop here",
--- skipping straight to the next/previous leaf, the same way it already
--- skips punctuation runs collapsed into a single stop elsewhere.
---
---@param node TSNode Any leaf (see `_commands.motion.leaf`).
---@return treemotion.SubwordUnit[] # Empty only when `node` is entirely a
---    punctuation-run continuation of the leaf before it; otherwise
---    `node`'s full span if nothing else splits it.
---
function M.split(node)
    local start_row, start_col = node:start()
    local end_row, end_col = node:end_()
    local text = vim.treesitter.get_node_text(node, 0)

    if start_row ~= end_row then
        local collapsed_text, collapsed_end_row, collapsed_end_col = _single_row_span(node, text)

        if not collapsed_text then
            -- Genuinely multi-row content; sub-word splitting only makes
            -- sense within a single line, so no real-world leaf (an
            -- identifier, a long string, ...) needs it across lines.
            return { _new_unit(start_row, start_col, end_row, end_col) }
        end

        text, end_row, end_col = collapsed_text, assert(collapsed_end_row), assert(collapsed_end_col)
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

    local is_prose = _is_prose(node)
    local camel_case, pascal_case, kebab_case, snake_case, comment_marker_case = _options(is_prose)
    local words = is_prose and _split_prose_words(text) or { { text = text, offset = 1 } }
    local units = {}

    for _, word in ipairs(words) do
        local word_column = text_start_col + word.offset - 1

        for _, delimited in ipairs(_split_delimiters(word.text, kebab_case, snake_case, comment_marker_case)) do
            local column = word_column + delimited.offset - 1

            for _, chunk in ipairs(_split_case(delimited.text, camel_case, pascal_case)) do
                table.insert(units, _new_unit(start_row, column, start_row, column + #chunk))
                column = column + #chunk
            end
        end
    end

    if #units == 0 then
        -- The whole leaf was delimiter/blank characters (e.g. a lone `_`,
        -- or an all-whitespace comment); fall back to treating it as one
        -- unit so motions still land somewhere.
        return { _new_unit(start_row, start_col, end_row, end_col) }
    end

    return units
end

return M
