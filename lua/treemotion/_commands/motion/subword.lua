--- Split a leaf (`w`) or a run (`W`) into sub-word units.
---
--- Prose is split into words first; code is one word. Each word is then split
--- on delimiters and, unless it looks like a hash, on camelCase/PascalCase.

local logging = require("mega.logging")

local codepoint = require("treemotion._commands.motion.codepoint")
local case = require("treemotion._commands.motion.case")
local classify = require("treemotion._commands.motion.classify")
local delimiters = require("treemotion._commands.motion.delimiters")
local leaf = require("treemotion._commands.motion.leaf")
local prose = require("treemotion._commands.motion.prose")
local span = require("treemotion._commands.motion.span")

local _LOGGER = logging.get_logger("treemotion._commands.motion.subword")

local M = {}

--- Strip trailing blanks. Some grammars end a token at the next row's
--- column 0, so callers check whether the trimmed text is single-row.
---
---@param text string
---@param start_row integer
---@param start_col integer
---@return string, integer, integer # The trimmed text and its exclusive end.
---
local function _trim_span(text, start_row, start_col)
    local trimmed = text:gsub("%s+$", "")
    local end_row, end_col = span.end_position(start_row, start_col, trimmed)

    return trimmed, end_row, end_col
end

--- How many leading bytes of `text` continue a punctuation run from the
--- character just before `node`, such as the third dash of Lua's `---`.
--- Vim treats such a run as one word, so its only stop stays in the earlier
--- leaf. May be `#text` (Rust's lone `/` in `///`).
---
---@param node TSNode
---@param text string
---@return integer
---
local function _leading_continuation_length(node, text)
    if text == "" then
        return 0
    end

    local char_width = codepoint.char_width(text, 1)
    local char = text:sub(1, char_width)

    if codepoint.class(char) == codepoint.BLANK or codepoint.is_alphanumeric(char) then
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

    if char_width == 1 then
        local byte = char:byte()

        while length < #text and text:byte(length + 1) == byte do
            length = length + 1
        end
    else
        while length < #text do
            local width = codepoint.char_width(text, length + 1)

            if text:sub(length + 1, length + width) ~= char then
                break
            end

            length = length + width
        end
    end

    return length
end

--- Split `text` into units. Returns `fallback` if `text` has no words. A
--- text that is only a skipped marker run returns no units.
---
---@param text string
---@param fallback treemotion.SubwordUnit Starts where `text` does.
---@param is_prose boolean
---@param settings treemotion.SplitSettings
---@return treemotion.SubwordUnit[]
---
local function _split_text(text, fallback, is_prose, settings)
    local rules = is_prose and settings.prose or settings.code
    local words = is_prose and prose.words(text, settings.backtick_identifiers, rules.opaque_token_min_length)
        or { { text = text, offset = 1 } }

    if #words == 0 then
        return { fallback }
    end

    local start_row, start_col = fallback:start()
    local position = span.position_mapper(start_row, start_col, text)

    ---@param offset integer 1-indexed into `text`.
    ---@param length integer
    ---@return treemotion.SubwordUnit
    local function make_unit(offset, length)
        local unit_start_row, unit_start_col = position(offset)
        local unit_end_row, unit_end_col = position(offset + length)

        return span.new(unit_start_row, unit_start_col, unit_end_row, unit_end_col)
    end

    local units = {}

    for _, word in ipairs(words) do
        local word_rules = word.is_identifier and settings.code or rules

        for _, delimited in ipairs(delimiters.split(word.text, word_rules, settings.comment_marker_characters)) do
            local offset = word.offset + delimited.offset - 1

            if case.looks_like_hash(delimited.text, word_rules.opaque_token_min_length) then
                table.insert(units, make_unit(offset, #delimited.text))
            else
                for _, chunk in ipairs(case.split(delimited.text, word_rules.camel_case, word_rules.pascal_case)) do
                    table.insert(units, make_unit(offset, #chunk))
                    offset = offset + #chunk
                end
            end
        end
    end

    return units
end

---@generic F: function
---@param name string
---@param fn F
---@param describe_args fun(...: any): string
---@return F
---
local function _logged(name, fn, describe_args)
    return function(...)
        local units = fn(...)

        _LOGGER:fmt_debug("%s(%s) -> %s unit(s).", name, describe_args(...), #units)

        return units
    end
end

--- Split a leaf. Multi-row code stays one unit; multi-row prose is split
--- across rows.
---
---@param node TSNode
---@param settings treemotion.SplitSettings
---@return treemotion.SubwordUnit[] # Empty when the leaf has no stop of its own.
---
M.split = _logged("split", function(node, settings)
    if classify.is_insignificant(node, settings.insignificant_characters) then
        return {}
    end

    local start_row, start_col = node:start()
    local end_row, end_col = node:end_()
    local text = vim.treesitter.get_node_text(node, 0)
    local is_prose = classify.is_prose(node)

    if start_row ~= end_row then
        local trimmed, trimmed_end_row, trimmed_end_col = _trim_span(text, start_row, start_col)

        if trimmed_end_row == start_row then
            text, end_row, end_col = trimmed, trimmed_end_row, trimmed_end_col
        elseif not is_prose then
            return { span.new(start_row, start_col, end_row, end_col) }
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

    return _split_text(text, span.new(start_row, text_start_col, end_row, end_col), is_prose, settings)
end, function(node)
    local row, column = node:start()

    return string.format("%s at %s:%s", node:type(), row, column)
end)

--- Break a run into stretches of leaves that are all prose or all code,
--- such as Lua's `foo"bar"`, so each gets its own rules.
---
---@param start_node TSNode
---@param end_node TSNode
---@return {is_prose: boolean, start_row: integer, start_col: integer, end_row: integer, end_col: integer}[]
---
local function _run_segments(start_node, end_node)
    local end_row, end_col = end_node:end_()
    local segments = {}
    local node = start_node

    while true do
        local is_prose = classify.is_prose(node)
        local segment_start_row, segment_start_col = node:start()
        local segment_end_row, segment_end_col = node:end_()

        while segment_end_row ~= end_row or segment_end_col ~= end_col do
            local next_node = assert(leaf.next_leaf(node))

            if classify.is_prose(next_node) ~= is_prose then
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

---@param segment {is_prose: boolean, start_row: integer, start_col: integer, end_row: integer, end_col: integer}
---@param settings treemotion.SplitSettings
---@return treemotion.SubwordUnit[]
---
local function _split_run_segment(segment, settings)
    local start_row, start_col = segment.start_row, segment.start_col
    local end_row, end_col = segment.end_row, segment.end_col

    -- A leaf's end can sit one row past the last line, which is unreadable.
    local ok, lines = pcall(vim.api.nvim_buf_get_text, 0, start_row, start_col, end_row, end_col, {})

    if not ok then
        return { span.new(start_row, start_col, end_row, end_col) }
    end

    local trimmed, trimmed_end_row, trimmed_end_col = _trim_span(table.concat(lines, "\n"), start_row, start_col)

    if trimmed_end_row ~= start_row and not segment.is_prose then
        return { span.new(start_row, start_col, end_row, end_col) }
    end

    return _split_text(
        trimmed,
        span.new(start_row, start_col, trimmed_end_row, trimmed_end_col),
        segment.is_prose,
        settings
    )
end

--- Split a run. With `settings.enabled` off (the default) the whole run is
--- one unit, like Vim's `W`.
---
---@param start_node TSNode
---@param end_node TSNode
---@param settings treemotion.SplitSettings
---@return treemotion.SubwordUnit[]
---
M.split_run = _logged("split_run", function(start_node, end_node, settings)
    local start_row, start_col = start_node:start()
    local end_row, end_col = end_node:end_()

    if not settings.enabled then
        return { span.new(start_row, start_col, end_row, end_col) }
    end

    local units = {}

    for _, segment in ipairs(_run_segments(start_node, end_node)) do
        vim.list_extend(units, _split_run_segment(segment, settings))
    end

    return units
end, function(start_node, end_node)
    local start_row, start_col = start_node:start()
    local end_row, end_col = end_node:end_()

    return string.format("%s at %s:%s -> %s:%s", start_node:type(), start_row, start_col, end_row, end_col)
end)

return M
