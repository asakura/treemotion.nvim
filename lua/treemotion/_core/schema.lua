--- Every configuration value, with its check and the description
--- `:checkhealth` shows when it fails. A spec keeps it in sync with the
--- defaults. Fields are ordered so issues come back in a stable order.

local hints_constant = require("treemotion._core.hints")
local motion_constant = require("treemotion._commands.motion.constant")

local M = {}

---@alias treemotion._SchemaNode treemotion._SchemaValue | treemotion._SchemaSection

---@class treemotion._SchemaValue
---@field kind "value"
---@field check fun(value: any): boolean Return `true` if `value` is valid.
---@field expected string What a valid value looks like, e.g. `"a boolean"`.
---@field required boolean? If `true`, `nil` is an issue. Otherwise `nil` is always fine.

--- A missing section is fine; a non-table one is reported once.
---
---@class treemotion._SchemaSection
---@field kind "section"
---@field fields {[1]: string, [2]: treemotion._SchemaNode}[] Every field, in the order it's checked.
---@field expected string What a valid value looks like, e.g. `"a table"`.

---@param check fun(value: any): boolean
---@param expected string
---@param required boolean?
---@return treemotion._SchemaValue
local function _value(check, expected, required)
    return { kind = "value", check = check, expected = expected, required = required }
end

---@param fields {[1]: string, [2]: treemotion._SchemaNode}[]
---@param expected string?
---@return treemotion._SchemaSection
local function _section(fields, expected)
    return { kind = "section", fields = fields, expected = expected or "a table" }
end

---@return treemotion._SchemaValue
local function _boolean()
    return _value(function(value)
        return type(value) == "boolean"
    end, "a boolean")
end

---@return treemotion._SchemaValue
local function _positive_integer()
    return _value(function(value)
        return type(value) == "number" and value > 0 and value == math.floor(value)
    end, "a positive integer")
end

---@param choices string[]
---@return string # e.g. `'"none" or "skip" or "stop"'`.
---
local function _describe_choices(choices)
    local quoted = {}

    for _, choice in ipairs(choices) do
        table.insert(quoted, string.format("%q", choice))
    end

    return table.concat(quoted, " or ")
end

--- A value that must be one of `choices`: a list, or a symbolic table like
--- `hints.Kind` whose keys are the choices.
---
---@param choices string[] | table<string, string>
---@param required boolean?
---@return treemotion._SchemaValue
local function _enum(choices, required)
    local values = choices

    if not vim.islist(choices) then
        values = vim.tbl_keys(choices)
        table.sort(values)
    end

    return _value(function(value)
        return vim.tbl_contains(values, value)
    end, _describe_choices(values), required)
end

--- A `table<string, table>` whose every entry passes `check`.
---
---@param check fun(item: table): boolean
---@param expected string
---@return treemotion._SchemaValue
local function _per_language(check, expected)
    return _value(function(value)
        if type(value) ~= "table" then
            return false
        end

        for language, item in pairs(value) do
            if type(language) ~= "string" or type(item) ~= "table" or not check(item) then
                return false
            end
        end

        return true
    end, expected)
end

---@return treemotion._SchemaValue
local function _comment_markers()
    return _per_language(function(characters)
        for _, character in ipairs(characters) do
            if type(character) ~= "string" then
                return false
            end
        end

        return true
    end, "a table<string, string[]> (treesitter language name -> comment-marker characters)")
end

--- Entries list characters (integer keys) or remove them (string keys set
--- to `false`); see `configuration.get_insignificant_characters`.
---
---@return treemotion._SchemaValue
local function _insignificant_characters()
    return _per_language(
        function(characters)
            for key, item in pairs(characters) do
                if type(key) == "string" then
                    if type(item) ~= "boolean" then
                        return false
                    end
                elseif type(key) == "number" then
                    if type(item) ~= "string" then
                        return false
                    end
                else
                    return false
                end
            end

            return true
        end,
        "a table<string, treemotion.InsignificantCharacterList> (treesitter language name -> insignificant leaf texts)"
    )
end

---@return treemotion._SchemaSection
local function _subword_rules()
    local fields = {
        { "camel_case", _boolean() },
        { "pascal_case", _boolean() },
    }

    for _, name in ipairs({ "kebab_case", "snake_case", "colon_case", "slash_case", "comment_marker_case" }) do
        table.insert(fields, { name, _enum(motion_constant.DelimiterMode) })
    end

    table.insert(fields, { "opaque_token_min_length", _positive_integer() })

    return _section(fields)
end

---@param has_enabled boolean Only `big` has `enabled`.
---@return treemotion._SchemaSection
local function _group(has_enabled)
    local fields = {}

    if has_enabled then
        table.insert(fields, { "enabled", _boolean() })
    end

    table.insert(fields, { "backtick_identifiers", _boolean() })
    table.insert(fields, { "code", _subword_rules() })
    table.insert(fields, { "prose", _subword_rules() })

    return _section(fields)
end

--- `mega.logging`'s levels, which it doesn't export.
local _LOG_LEVELS = { "trace", "debug", "info", "warning", "error", "fatal" }

---@type treemotion._SchemaSection
M.SCHEMA = _section({
    {
        "commands",
        _section({
            {
                "motion",
                _section({
                    { "comment_markers", _comment_markers() },
                    { "insignificant_characters", _insignificant_characters() },
                    {
                        "operator_pending",
                        _section({
                            { "enabled", _boolean() },
                            { "skipped_text", _enum(motion_constant.SkippedText) },
                            { "stop_at_line_end", _boolean() },
                            { "change_to_end", _boolean() },
                            { "inclusive", _boolean() },
                        }),
                    },
                    { "small", _group(false) },
                    { "big", _group(true) },
                }),
            },
        }),
    },
    { "hints", _enum(hints_constant.Kind, true) },
    {
        "logging",
        _section({
            { "level", _enum(_LOG_LEVELS, true) },
            { "use_console", _boolean() },
            { "use_file", _boolean() },
        }, 'a table. e.g. { level = "info", ... }'),
    },
})

---@param path string
---@param expected string
---@param value any
---@return string # e.g. `"logging.use_file: expected a boolean, got aaa"`.
---
local function _format_issue(path, expected, value)
    return string.format("%s: expected %s, got %s", path, expected, tostring(value))
end

---@param node treemotion._SchemaNode
---@param value any
---@param path string `""` for the root.
---@param output string[]
---
local function _append_issues(node, value, path, output)
    if node.kind == "value" then
        ---@cast node treemotion._SchemaValue

        if value == nil and not node.required then
            return
        end

        if not node.check(value) then
            table.insert(output, _format_issue(path, node.expected, value))
        end

        return
    end

    ---@cast node treemotion._SchemaSection

    if value == nil then
        return
    end

    if type(value) ~= "table" then
        table.insert(output, _format_issue(path, node.expected, value))

        return
    end

    for _, field in ipairs(node.fields) do
        local name, child = field[1], field[2]

        _append_issues(child, value[name], path == "" and name or path .. "." .. name, output)
    end
end

--- Collect keys `node` doesn't declare. Only sections are walked; a value's
--- own keys (language names) are free-form.
---
---@param node treemotion._SchemaNode
---@param value any
---@param path string
---@param output string[]
---
local function _append_unknown_keys(node, value, path, output)
    if node.kind ~= "section" or type(value) ~= "table" then
        return
    end

    ---@cast node treemotion._SchemaSection

    local children = {}

    for _, field in ipairs(node.fields) do
        children[field[1]] = field[2]
    end

    local keys = vim.tbl_keys(value)
    table.sort(keys, function(left, right)
        return tostring(left) < tostring(right)
    end)

    for _, key in ipairs(keys) do
        local name = tostring(key)
        local child_path = path == "" and name or path .. "." .. name
        local child = children[key]

        if child then
            _append_unknown_keys(child, value[key], child_path, output)
        else
            table.insert(output, child_path)
        end
    end
end

--- Keys in `data` the schema doesn't declare, likely typos.
---
---@param data table
---@return string[] # Dotted paths.
---
function M.get_unknown_keys(data)
    local output = {}

    _append_unknown_keys(M.SCHEMA, data, "", output)

    return output
end

---@param data table
---@return string[]
---
function M.get_issues(data)
    local output = {}

    _append_issues(M.SCHEMA, data, "", output)

    return output
end

return M
