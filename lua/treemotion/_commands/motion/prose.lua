--- Divide prose text (comments, string content, see
--- `_commands.motion.classify`) into Vim-style words.
---
--- Real Vim's `w` stops on every change between blanks, keyword characters
--- and punctuation in a text file; `M.words` reproduces that for prose,
--- with two extras: backtick-enclosed identifiers (`` `fooBar` ``) are
--- flagged so `_commands.motion.subword` can apply `.code`'s rules to
--- them, and a trailing `=` run is merged back into a base64-looking word
--- before it (see `_merge_opaque_padding`).
---
--- Pure string functions: no buffer, treesitter or configuration access.

local case = require("treemotion._commands.motion.case")

local M = {}

--- Classify one character the way real Vim's `w` classifies it in a text file.
---
--- Real Vim's word motions only recognize three classes: blank, "keyword"
--- (`'iskeyword'`, which defaults to letters/digits/`_`), and everything
--- else -- and critically, *every* non-blank, non-keyword character shares
--- that one "everything else" class, so a run like `?!` is a single word,
--- not two.
---
--- `-`/`:`/`/` are deliberately grouped into `"word"` here too, even though
--- real Vim's default `'iskeyword'` excludes them: `delimiters.split` is
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
--- `classify.is_prose`) leaves -- code leaves never contain embedded blanks,
--- so there's nothing for this pass to do for them.
---
---@param text string A leaf's full text.
---@return {text: string, offset: integer}[] # Each word and its 1-indexed start column in `text`.
---
function M.split_words(text)
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
--- Deliberately reuses `M.split_words`'s own run classification rather
--- than a bespoke identifier pattern, so "a single word" here means the same
--- thing it already means everywhere else `w`/`b`/`e`/`ge` land -- `fooBar`
--- and `foo-bar` both qualify (`-`/case are further split per `.code`'s
--- rules once `subword.split` treats the span as an identifier), but `foo bar`
--- (two words) and `foo.bar` (a class change between `foo`/`.`/`bar`) don't.
---
---@param content string Text between one matched pair of backticks. May be empty.
---@return boolean
---
local function _is_single_word(content)
    if content == "" then
        return false
    end

    local words = M.split_words(content)

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
--- `delimiters.split` already takes for `-`/`_`/comment markers. A pair
--- that fails the single-word check is left untouched (not even flagged as
--- its own segment) so it folds back into whichever prose segment
--- eventually gets flushed around it -- exactly the same text `M.split_words`
--- would have produced without this feature at all.
---
---@param text string A prose leaf's full text (see `subword.split`).
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

--- Merge a trailing all-`=` word into the word right before it, when the
--- combined span passes `case.looks_like_hash` -- so `sha256-A8Yg...SgU` and a
--- separate `=` word (produced by `M.split_words`, since `=` isn't in
--- `_char_class`'s `"word"` class) become one word before delimiter/case
--- splitting ever sees either half.
---
---@param words {text: string, offset: integer, is_identifier: boolean?}[]
---    `M.split_words`' (or the backtick-identifier-aware equivalent's) output.
---@param min_length integer See `case.looks_like_hash`.
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

            if adjacent and case.looks_like_hash(combined, min_length) then
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

--- Split a prose leaf's `text` into words, the same shape `M.split_words`
--- returns, except each word also carries whether it's a backtick-enclosed
--- identifier (see `_split_backtick_identifiers`) for `subword.split` to apply
--- `.code`'s rules to instead of `.prose`'s.
---
---@param text string A prose leaf's full text (see `subword.split`).
---@param backtick_identifiers boolean Whether `commands.motion[group].backtick_identifiers` is enabled.
---@param opaque_token_min_length integer See `case.looks_like_hash`.
---@return {text: string, offset: integer, is_identifier: boolean?}[]
---
function M.words(text, backtick_identifiers, opaque_token_min_length)
    local words

    if not backtick_identifiers then
        words = M.split_words(text)
    else
        words = {}

        for _, segment in ipairs(_split_backtick_identifiers(text)) do
            if segment.kind == "identifier" then
                table.insert(words, { text = segment.text, offset = segment.offset, is_identifier = true })
            else
                for _, word in ipairs(M.split_words(segment.text)) do
                    table.insert(words, { text = word.text, offset = segment.offset + word.offset - 1 })
                end
            end
        end
    end

    return _merge_opaque_padding(words, opaque_token_min_length)
end

return M
