--- A declarative description of every `treemotion.Configuration` value.
---
--- `M.SCHEMA` mirrors the shape of `configuration.lua`'s `_DEFAULTS`: each
--- section is a table of named fields, and each field is a check plus the
--- human-readable description `:checkhealth` shows when a value fails it.
--- `M.get_issues` walks it, so adding a configuration value means adding
--- one line here, not another hand-written `vim.validate` call in
--- `health.lua`. `spec/treemotion/configuration_spec.lua` checks that the
--- schema and `_DEFAULTS` declare exactly the same values, so the two can't
--- drift apart.
---
--- Fields are stored as ordered `{ name, node }` pairs, not as a map, so
--- issues come back in a stable, documented order.

local hints_constant = require("treemotion._core.hints")
local motion_constant = require("treemotion._commands.motion.constant")

local M = {}

---@alias treemotion._SchemaNode treemotion._SchemaValue | treemotion._SchemaSection

--- A single configuration value, e.g. `logging.use_file`.
---
---@class treemotion._SchemaValue
---@field kind "value"
---@field check fun(value: any): boolean Return `true` if `value` is valid.
---@field expected string What a valid value looks like, e.g. `"a boolean"`.
---@field required boolean? If `true`, `nil` is an issue. Otherwise `nil` is always fine.

--- A table of configuration values, e.g. `logging`.
---
--- A missing (`nil`) section is fine and none of its fields are checked. A
--- section that's present but isn't a table is reported once, without
--- checking its fields.
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

---@param choices table<string, string> A symbolic-value table, e.g. `hints.Kind`. Its keys are the valid values.
---@param expected string
---@param required boolean?
---@return treemotion._SchemaValue
local function _enum(choices, expected, required)
    return _value(function(value)
        return vim.tbl_contains(vim.tbl_keys(choices), value)
    end, expected, required)
end

--- Check that `value` is a `table<string, T>` whose every `T` passes `check`.
---
---@param check fun(item: table): boolean Validate one language's entry, already known to be a table.
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

--- Unlike `comment_markers`, an entry here may be a hybrid table
--- (`treemotion.InsignificantCharacterList`): its array part lists
--- characters to add (string elements only, the same shape
--- `comment_markers` validates), while a string key mapped to `false`
--- negates one character from `_OPTIONAL_INSIGNIFICANT_CHARACTERS`/
--- `_DEFAULTS` instead of adding one -- see
--- `configuration.get_insignificant_characters`'s docstring. `pairs` (not
--- `ipairs`) here so both parts get checked; a string key must map to a
--- boolean, an integer key must map to a string, and any other key is
--- invalid.
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

--- The rules for one `code`/`prose` context. See `treemotion.ConfigurationMotionSubwordRules`.
---
---@return treemotion._SchemaSection
local function _subword_rules()
    local fields = {
        { "camel_case", _boolean() },
        { "pascal_case", _boolean() },
    }

    for _, name in ipairs({ "kebab_case", "snake_case", "colon_case", "slash_case", "comment_marker_case" }) do
        table.insert(fields, { name, _enum(motion_constant.DelimiterMode, '"none" or "skip" or "stop"') })
    end

    table.insert(fields, { "opaque_token_min_length", _positive_integer() })

    return _section(fields)
end

--- One `small`/`big` group. See `treemotion.ConfigurationMotionGroup`.
---
---@param has_enabled boolean Whether this group has an `enabled` switch. Only `big` does.
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

--- Every `mega.logging` level `logging.level` accepts.
local _LOG_LEVELS = {
    trace = "trace",
    debug = "debug",
    info = "info",
    warning = "warning",
    error = "error",
    fatal = "fatal",
}

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
                    { "small", _group(false) },
                    { "big", _group(true) },
                }),
            },
        }),
    },
    { "hints", _enum(hints_constant.Kind, '"word_boundaries" or "motions" or "none"', true) },
    {
        "logging",
        _section({
            {
                "level",
                _enum(_LOG_LEVELS, 'an enum. e.g. "trace" | "debug" | "info" | "warning" | "error" | "fatal"', true),
            },
            { "use_console", _boolean() },
            { "use_file", _boolean() },
        }, 'a table. e.g. { level = "info", ... }'),
    },
})

--- Check `value` against `node`, appending every issue found to `output`.
---
---@param node treemotion._SchemaNode The schema to check against.
---@param value any The configuration value at `path`.
---@param path string The dotted configuration key, e.g. `"logging.level"`. `""` for the root.
---@param output string[] All issues found so far.
---
local function _append_issues(node, value, path, output)
    if value == nil and (node.kind == "section" or not node.required) then
        return
    end

    local valid

    if node.kind == "section" then
        valid = type(value) == "table"
    else
        valid = node.check(value)
    end

    if not valid then
        table.insert(output, string.format("%s: expected %s, got %s", path, node.expected, tostring(value)))

        return
    end

    if node.kind == "section" then
        for _, field in ipairs(node.fields) do
            local name, child = field[1], field[2]

            _append_issues(child, value[name], path == "" and name or path .. "." .. name, output)
        end
    end
end

--- Check `data` against `M.SCHEMA`.
---
---@param data table The configuration to check, e.g. a `treemotion.Configuration`.
---@return string[] # Every issue found, e.g. `"logging.use_file: expected a boolean, got aaa"`.
---
function M.get_issues(data)
    local output = {}

    _append_issues(M.SCHEMA, data, "", output)

    return output
end

return M
