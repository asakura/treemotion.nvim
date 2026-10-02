--- Split a word on `-`, `_`, `:`, `/` and comment-marker runs.

local codepoint = require("treemotion._commands.motion.codepoint")
local motion_constant = require("treemotion._commands.motion.constant")

local M = {}

---@type table<string, string> Delimiter -> the rules field for it.
local _DELIMITER_FIELDS = { ["-"] = "kebab_case", ["_"] = "snake_case", [":"] = "colon_case", ["/"] = "slash_case" }

---@param char string
---@param rules treemotion.ConfigurationMotionSubwordRules
---@param comment_marker_characters table<string, true>
---@return treemotion.SubwordDelimiterMode
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

--- `rules` with `comment_marker_case` applied to any delimiter that is also
--- a comment marker in this language. Returns `rules` itself if none is.
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

--- Split `text` on delimiter runs. A run of same-mode delimiters is one stop,
--- as in Vim. `"skip"` drops the run, `"stop"` keeps it as its own chunk,
--- and `"none"` doesn't split.
---
--- Text with no letters or digits (Lua's `--`, a `-----` line) is a bare
--- punctuation run, so `comment_marker_case` governs any of its delimiters
--- that the language lists as comment markers.
---
---@param text string
---@param rules treemotion.ConfigurationMotionSubwordRules
---@param comment_marker_characters table<string, true>
---@return {text: string, offset: integer}[] # Chunks and their 1-indexed offsets.
---
function M.split(text, rules, comment_marker_characters)
    if not codepoint.has_alphanumeric(text) then
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
