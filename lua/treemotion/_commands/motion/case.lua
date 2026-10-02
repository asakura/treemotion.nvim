--- camelCase/PascalCase splitting and the hash heuristic. Unicode-aware.

local codepoint = require("treemotion._commands.motion.codepoint")

local M = {}

--- Whether `text` looks like a hash or digest that should stay one unit.
---
--- Hex of at least `min_length`, or base64-shaped with upper, lower and a
--- digit. Without the digit, any long camelCase identifier would match.
--- Trailing `=` padding is ignored.
---
---@param text string
---@param min_length integer
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

--- Byte offsets where a new word starts: an uppercase letter after a
--- lowercase letter or digit (`fooBar`), or before a lowercase letter after
--- another uppercase one (`XMLHttp` -> `XML`, `Http`).
---
---@param text string
---@return integer[]
---
local function _case_boundaries(text)
    local boundaries = {}

    if codepoint.is_ascii(text) then
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

    local characters = codepoint.characters(text)

    for index = 2, #characters do
        local current = characters[index].text

        if codepoint.is_upper(current) then
            local previous = characters[index - 1].text
            local following = characters[index + 1]

            if codepoint.is_lower(previous) or previous:match("^%d") then
                table.insert(boundaries, characters[index].offset)
            elseif codepoint.is_upper(previous) and following and codepoint.is_lower(following.text) then
                table.insert(boundaries, characters[index].offset)
            end
        end
    end

    return boundaries
end

--- Split `text` at case boundaries. The first letter's case decides whether
--- `camel_case` or `pascal_case` applies.
---
---@param text string
---@param camel_case boolean
---@param pascal_case boolean
---@return string[]
---
function M.split(text, camel_case, pascal_case)
    local starts_upper = text ~= "" and codepoint.is_upper(text:sub(1, codepoint.char_width(text, 1)))
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
