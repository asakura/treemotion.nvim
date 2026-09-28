--- Split a word on `-`/`_`/`:`/`/` and comment-marker runs, per the
--- user's `kebab_case`/`snake_case`/`colon_case`/`slash_case`/
--- `comment_marker_case` settings.
---
--- Pure string functions: the caller passes in every mode and the current
--- language's comment-marker set (see
--- `_commands.motion.classify.comment_marker_characters`).

local motion_constant = require("treemotion._commands.motion.constant")

local M = {}

--- Look up how `char` should be treated, per `kebab_case`/`snake_case`/`comment_marker_case`.
---
---@param char string A single character.
---@param kebab_case treemotion.SubwordDelimiterMode How to treat `-`.
---@param snake_case treemotion.SubwordDelimiterMode How to treat `_`.
---@param colon_case treemotion.SubwordDelimiterMode How to treat `:`.
---@param slash_case treemotion.SubwordDelimiterMode How to treat `/`.
---@param comment_marker_case treemotion.SubwordDelimiterMode How to treat `comment_marker_characters`.
---@param comment_marker_characters table<string, true> This language's comment-marker punctuation (see
---    `classify.comment_marker_characters`).
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
--- `offset` lets `subword.split` translate each chunk's position back into an
--- absolute buffer column.
---
--- `kebab_case`/`snake_case` only apply when `text` actually has an
--- identifier to case-split -- i.e. `-`/`_` sit between (or beside) real
--- alphanumeric content, like `hello-world` or `snake_case`. When `text` is
--- *entirely* delimiter characters (no letter or digit anywhere in it --
--- Lua's `--` comment opener, a `---` doc-comment marker, a `-----`
--- separator line), there's no identifier being kebab/snake-cased at all --
--- it's a bare punctuation run, the same kind of thing `#`/`/`/`%` already
--- always are (`prose.lua`'s `_char_class` isolates them into their own word before this
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
---@param text string A word to split (a whole leaf's text, for code; one `prose.split_words` word, for prose).
---@param kebab_case treemotion.SubwordDelimiterMode How to treat `-` next to real identifier content.
---@param snake_case treemotion.SubwordDelimiterMode How to treat `_` next to real identifier content.
---@param colon_case treemotion.SubwordDelimiterMode How to treat `:` next to real identifier content.
---@param slash_case treemotion.SubwordDelimiterMode How to treat `/` next to real identifier content.
---@param comment_marker_case treemotion.SubwordDelimiterMode How to treat `comment_marker_characters`, or
---    `text`-wide `-`/`_`/`:`/`/` runs.
---@param comment_marker_characters table<string, true> This language's comment-marker punctuation (see
---    `classify.comment_marker_characters`).
---@return {text: string, offset: integer}[] # Each chunk and its 1-indexed start column in `text`.
---
function M.split(text, kebab_case, snake_case, colon_case, slash_case, comment_marker_case, comment_marker_characters)
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

return M
