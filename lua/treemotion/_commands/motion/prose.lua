--- Split prose (comments, strings) into Vim-style words.

local case = require("treemotion._commands.motion.case")
local codepoint = require("treemotion._commands.motion.codepoint")

local M = {}

--- Classify a character as Vim's `w` does in a text file. All non-blank,
--- non-keyword ASCII shares one class, so `?!` is one word.
---
--- `-`, `:` and `/` count as word characters so that `delimiters.split`
--- alone decides how to split them (`kebab_case`, `colon_case`, ...).
---
---@param char string
---@return "blank"|"word"|"other"|integer
---
local function _char_class(char)
    if char:byte(1) < 128 then
        if char:match("%s") then
            return "blank"
        elseif char:match("[%w_%-:/]") then
            return "word"
        end

        return "other"
    end

    local class = codepoint.class(char)

    if class == codepoint.BLANK then
        return "blank"
    elseif class == codepoint.WORD then
        return "word"
    elseif class == codepoint.PUNCTUATION then
        return "other"
    end

    return class
end

--- Split `text` into runs of one class, dropping blank runs.
---
---@param text string
---@return {text: string, offset: integer}[] # Words and their 1-indexed offsets.
---
function M.split_words(text)
    local chunks = {}
    local start = 1

    ---@type "blank"|"word"|"other"|integer?
    local class = nil

    ---@param index integer
    ---@param character string
    local function step(index, character)
        local current_class = _char_class(character)

        if current_class ~= class then
            if class ~= nil and class ~= "blank" then
                table.insert(chunks, { text = text:sub(start, index - 1), offset = start })
            end

            start = index
            class = current_class
        end
    end

    if codepoint.is_ascii(text) then
        for index = 1, #text do
            step(index, text:sub(index, index))
        end
    else
        for _, character in ipairs(codepoint.characters(text)) do
            step(character.offset, character.text)
        end
    end

    if class ~= nil and class ~= "blank" then
        table.insert(chunks, { text = text:sub(start), offset = start })
    end

    return chunks
end

--- Whether `content` is exactly one word by `M.split_words`'s rules.
---
---@param content string
---@return boolean
---
local function _is_single_word(content)
    if content == "" then
        return false
    end

    local words = M.split_words(content)

    return #words == 1 and words[1].offset == 1 and #words[1].text == #content
end

--- Split out backtick pairs that hold a single word. Other pairs stay in
--- the surrounding prose.
---
---@param text string
---@return {kind: "prose"|"identifier", text: string, offset: integer}[] # An
---    identifier's offset is just after its opening backtick.
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

--- Join a trailing `=` run to the word before it when together they look
--- like a hash (base64 padding).
---
---@param words {text: string, offset: integer, is_identifier: boolean?}[]
---@param min_length integer
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

--- Split prose into words, flagging backtick identifiers so they get the
--- `.code` rules.
---
---@param text string
---@param backtick_identifiers boolean
---@param opaque_token_min_length integer
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
