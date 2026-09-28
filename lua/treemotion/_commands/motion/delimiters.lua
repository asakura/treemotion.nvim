--- Split a word on `-`/`_`/`:`/`/` and comment-marker runs, per the
--- user's `kebab_case`/`snake_case`/`colon_case`/`slash_case`/
--- `comment_marker_case` settings.
---
--- Pure string functions: the caller passes in its subword rules and the
--- current language's comment-marker set (see
--- `_commands.motion.classify.comment_marker_characters`).

local motion_constant = require("treemotion._commands.motion.constant")

local M = {}

--- Which `treemotion.ConfigurationMotionSubwordRules` field governs each
--- identifier delimiter character.
---
---@type table<string, string>
local _DELIMITER_FIELDS = { ["-"] = "kebab_case", ["_"] = "snake_case", [":"] = "colon_case", ["/"] = "slash_case" }

--- Look up how `char` should be treated, per `rules`.
---
---@param char string A single character.
---@param rules treemotion.ConfigurationMotionSubwordRules Each delimiter's mode.
---@param comment_marker_characters table<string, true> This language's comment-marker punctuation (see
---    `classify.comment_marker_characters`).
---@return treemotion.SubwordDelimiterMode # `"none"` for any character that isn't covered by one of the above.
---
local function _delimiter_mode(char, rules, comment_marker_characters)
    local field = _DELIMITER_FIELDS[char]

    if field then
        return rules[field]
    elseif comment_marker_characters[char] then
        return rules.comment_marker_case
    end

    return motion_constant.DelimiterMode.none
end

--- `rules`, with `comment_marker_case` taking over every identifier
--- delimiter the current language also lists as a comment marker.
---
--- Returns `rules` itself (no copy) when no such delimiter is listed.
---
---@param rules treemotion.ConfigurationMotionSubwordRules
---@param comment_marker_characters table<string, true>
---@return treemotion.ConfigurationMotionSubwordRules
---
local function _bare_run_rules(rules, comment_marker_characters)
    local result = rules

    for char, field in pairs(_DELIMITER_FIELDS) do
        if comment_marker_characters[char] then
            if result == rules then
                result = vim.tbl_extend("force", {}, rules)
            end

            result[field] = rules.comment_marker_case
        end
    end

    return result
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
--- always are (`prose.words` isolates them into their own word before this
--- function even runs). So for a text like that, `comment_marker_case`
--- takes over for `-`/`_` too, exactly like it already does for `#`/`/`/`%`
--- -- but only if the current language's `comment_markers` actually lists
--- `-`/`_` (see the default `comment_markers.lua = { "-" }`, for Lua's
--- `--`); a language that doesn't list them there leaves `kebab_case`/`snake_case` in charge even for a
--- bare run, the same "no entry means no effect" rule every other marker
--- character already follows -- there's deliberately no special, always-on
--- carve-out for `-`/`_` the way `comment_markers`' other characters don't
--- get one either.
---
---@param text string A word to split (a whole leaf's text, for code; one `prose.split_words` word, for prose).
---@param rules treemotion.ConfigurationMotionSubwordRules Reads `kebab_case`/`snake_case`/`colon_case`/
---    `slash_case` (how to treat `-`/`_`/`:`/`/` next to real identifier content) and `comment_marker_case`
---    (how to treat `comment_marker_characters`, or `text`-wide `-`/`_`/`:`/`/` runs).
---@param comment_marker_characters table<string, true> This language's comment-marker punctuation (see
---    `classify.comment_marker_characters`).
---@return {text: string, offset: integer}[] # Each chunk and its 1-indexed start column in `text`.
---
function M.split(text, rules, comment_marker_characters)
    if not text:find("%w") then
        rules = _bare_run_rules(rules, comment_marker_characters)
    end

    local chunks = {}
    local start = 1
    local index = 1

    while index <= #text do
        local mode = _delimiter_mode(text:sub(index, index), rules, comment_marker_characters)

        if mode == motion_constant.DelimiterMode.none then
            index = index + 1
        else
            if index > start then
                table.insert(chunks, { text = text:sub(start, index - 1), offset = start })
            end

            local run_end = index

            while
                run_end < #text
                and _delimiter_mode(text:sub(run_end + 1, run_end + 1), rules, comment_marker_characters) == mode
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
