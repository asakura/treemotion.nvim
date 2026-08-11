--- Make sure `treemotion` will work as expected.

local configuration_ = require("treemotion._core.configuration")
local logging_ = require("mega.logging")
local say_constant = require("treemotion._commands.hello_world.say.constant")
local tabler = require("treemotion._core.tabler")

local _LOGGER = logging_.get_logger("treemotion.health")

local M = {}

-- This file is defer-loaded so it's okay to run this in the global scope
configuration_.initialize_data_if_needed()

--- Add issues to `array` if there are errors.
---
--- TODO: `vim.validate()` still uses its old, deprecated table-spec call
---       shape here (`vim.validate({[name] = {value, expected, message}})`)
---       because Neovim 0.11 is the first version with the newer, flatter
---       `vim.validate(name, value, validator, optional, message)` signature.
---       Once Neovim 0.10 support is dropped, switch to that signature.
---
---@param array string[]
---    All of the cumulated errors, if any.
---@param name string
---    The key to check for.
---@param value_creator fun(): any
---    A function that generates the value.
---@param expected string | fun(value: any): boolean
---    If `value_creator()` does not match `expected`, this error message is
---    shown to the user.
---@param message (string | boolean)?
---    If it's a string, it's the error message when `value_creator()` does
---    not match `expected`. When it's `true`, it means it's okay for
---    `value_creator()` not to match `expected`.
---
local function _append_validated(array, name, value_creator, expected, message)
    local success, value = pcall(value_creator)

    if not success then
        table.insert(array, value)

        return
    end

    local validated

    success, validated = pcall(vim.validate, {
        -- TODO: `lua-language-server`'s type stubs only describe the newer
        -- (0.11+) `vim.validate` signature, so this deprecated table-spec
        -- call is flagged as a type mismatch even though it's valid at
        -- runtime on Neovim 0.10. Remove this suppression once the
        -- signature above is switched over.
        ---@diagnostic disable-next-line: assign-type-mismatch
        [name] = { value, expected, message },
    })

    if not success then
        table.insert(array, validated)
    end
end

--- Check if `data` is a boolean under `key`.
---
---@param key string The configuration value that we are checking.
---@param data any The object to validate.
---@return string? # The found error message, if any.
---
local function _get_boolean_issue(key, data)
    local success, message = pcall(vim.validate, {
        [key] = {
            data,
            function(value)
                if value == nil then
                    -- NOTE: This value is optional so it's fine it if is not defined.
                    return true
                end

                return type(value) == "boolean"
            end,
            -- TODO: `lua-language-server`'s type stubs only describe the
            -- newer (0.11+) `vim.validate` signature, so this deprecated
            -- table-spec call is flagged as a type mismatch even though
            -- it's valid at runtime on Neovim 0.10. Remove this
            -- suppression once this call is switched to the newer
            -- `vim.validate(name, value, validator, optional, message)`
            -- signature.
            ---@diagnostic disable-next-line: assign-type-mismatch
            "a boolean",
        },
    })

    if success then
        return nil
    end

    return message
end

--- Check all "commands" values for issues.
---
---@param data treemotion.Configuration All of the user's fallback settings.
---@return string[] # All found issues, if any.
---
local function _get_command_issues(data)
    local output = {}

    _append_validated(output, "commands.goodnight_moon.read.phrase", function()
        return tabler.get_value(data, { "commands", "goodnight_moon", "read", "phrase" })
    end, "string")

    _append_validated(output, "commands.hello_world.say.repeat", function()
        return tabler.get_value(data, { "commands", "hello_world", "say", "repeat" })
    end, function(value)
        return type(value) == "number" and value > 0
    end, "a number (value must be 1-or-more)")

    _append_validated(output, "commands.hello_world.say.style", function()
        return tabler.get_value(data, { "commands", "hello_world", "say", "style" })
    end, function(value)
        local choices = vim.tbl_keys(say_constant.Keyword.style)

        return vim.tbl_contains(choices, value)
    end, '"lowercase" or "uppercase"')

    return output
end

--- Check if logging configuration `data` has any issues.
---
---@param data treemotion.LoggingConfiguration The user's logger settings.
---@return string[] # All of the found issues, if any.
---
local function _get_logging_issues(data)
    local output = {}

    _append_validated(output, "logging", function()
        return data
    end, function(value)
        if type(value) ~= "table" then
            return false
        end

        return true
    end, 'a table. e.g. { level = "info", ... }')

    if not vim.tbl_isempty(output) then
        return output
    end

    _append_validated(output, "logging.level", function()
        return data.level
    end, function(value)
        if type(value) ~= "string" then
            return false
        end

        if not vim.tbl_contains({ "trace", "debug", "info", "warn", "error", "fatal" }, value) then
            return false
        end

        return true
    end, 'an enum. e.g. "trace" | "debug" | "info" | "warn" | "error" | "fatal"')

    local message = _get_boolean_issue("logging.use_console", data.use_console)

    if message ~= nil then
        table.insert(output, message)
    end

    message = _get_boolean_issue("logging.use_file", data.use_file)

    if message ~= nil then
        table.insert(output, message)
    end

    return output
end

--- Check `data` for problems and return each of them.
---
---@param data treemotion.Configuration? All extra customizations for this plugin.
---@return string[] # All found issues, if any.
---
function M.get_issues(data)
    if not data or vim.tbl_isempty(data) then
        data = configuration_.resolve_data(vim.g.treemotion_configuration)
    end

    local output = {}
    vim.list_extend(output, _get_command_issues(data))

    local logging = data.logging

    if logging ~= nil then
        vim.list_extend(output, _get_logging_issues(data.logging))
    end

    return output
end

--- Make sure `data` will work for `treemotion`.
---
---@param data treemotion.Configuration? All extra customizations for this plugin.
---
function M.check(data)
    _LOGGER:debug("Running treemotion health check.")

    vim.health.start("Configuration")

    local issues = M.get_issues(data)

    if vim.tbl_isempty(issues) then
        vim.health.ok("Your vim.g.treemotion_configuration variable is great!")
    end

    for _, issue in ipairs(issues) do
        vim.health.error(issue)
    end
end

return M
