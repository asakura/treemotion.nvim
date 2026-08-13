--- Make sure `treemotion` will work as expected.

local configuration_ = require("treemotion._core.configuration")
local hints_constant = require("treemotion._core.hints")
local logging_ = require("mega.logging")
local motion_constant = require("treemotion._commands.motion.constant")
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
                    -- This value is optional so it's fine it if is not defined.
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

--- Check if `data` is one of `choices` under `key`.
---
---@param key string The configuration value that we are checking.
---@param data any The object to validate.
---@param choices string[] Every value `data` is allowed to be.
---@param expected string Human-readable description of `choices`, shown when `data` doesn't match.
---@return string? # The found error message, if any.
---
local function _get_enum_issue(key, data, choices, expected)
    local success, message = pcall(vim.validate, {
        [key] = {
            data,
            function(value)
                if value == nil then
                    -- This value is optional so it's fine it if is not defined.
                    return true
                end

                return vim.tbl_contains(choices, value)
            end,
            -- TODO: `lua-language-server`'s type stubs only describe the
            -- newer (0.11+) `vim.validate` signature, so this deprecated
            -- table-spec call is flagged as a type mismatch even though
            -- it's valid at runtime on Neovim 0.10. Remove this
            -- suppression once this call is switched to the newer
            -- `vim.validate(name, value, validator, optional, message)`
            -- signature.
            ---@diagnostic disable-next-line: assign-type-mismatch
            expected,
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

    _append_validated(output, "commands.motion.subword.comment_markers", function()
        return tabler.get_value(data, { "commands", "motion", "subword", "comment_markers" })
    end, function(value)
        if value == nil then
            -- This value is optional so it's fine if it is not defined.
            return true
        end

        if type(value) ~= "table" then
            return false
        end

        for language, characters in pairs(value) do
            if type(language) ~= "string" or type(characters) ~= "table" then
                return false
            end

            for _, character in ipairs(characters) do
                if type(character) ~= "string" then
                    return false
                end
            end
        end

        return true
    end, "a table<string, string[]> (treesitter language name -> comment-marker characters)")

    for _, context in ipairs({ "code", "prose" }) do
        for _, field in ipairs({ "camel_case", "pascal_case" }) do
            local message = _get_boolean_issue(
                "commands.motion.subword." .. context .. "." .. field,
                tabler.get_value(data, { "commands", "motion", "subword", context, field })
            )

            if message ~= nil then
                table.insert(output, message)
            end
        end

        for _, field in ipairs({ "kebab_case", "snake_case", "comment_marker_case" }) do
            local message = _get_enum_issue(
                "commands.motion.subword." .. context .. "." .. field,
                tabler.get_value(data, { "commands", "motion", "subword", context, field }),
                vim.tbl_keys(motion_constant.DelimiterMode),
                '"none" or "skip" or "stop"'
            )

            if message ~= nil then
                table.insert(output, message)
            end
        end
    end

    return output
end

--- Check if `data.hints` is a valid hint kind.
---
---@param data treemotion.Configuration All of the user's fallback settings.
---@return string[] # All found issues, if any.
---
local function _get_hints_issues(data)
    local output = {}

    _append_validated(output, "hints", function()
        return data.hints
    end, function(value)
        local choices = vim.tbl_keys(hints_constant.Kind)

        return vim.tbl_contains(choices, value)
    end, '"word_boundaries" or "motions" or "none"')

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

        if not vim.tbl_contains({ "trace", "debug", "info", "warning", "error", "fatal" }, value) then
            return false
        end

        return true
    end, 'an enum. e.g. "trace" | "debug" | "info" | "warning" | "error" | "fatal"')

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
    vim.list_extend(output, _get_hints_issues(data))

    local logging = data.logging

    if logging ~= nil then
        vim.list_extend(output, _get_logging_issues(data.logging))
    end

    return output
end

--- Check whether this Neovim version can run `motion` commands at full fidelity.
---
--- `vim.treesitter.get_node()`'s `include_anonymous` option -- which lets
--- `w`/`e`/`b`/`ge`/`W`/`E`/`B`/`gE` stop on punctuation leaves (`.`, `(`,
--- `,`, ...) and not just named nodes -- only exists on Neovim 0.11+. On
--- older Neovim it's silently ignored rather than erroring, so the motions
--- still "work", just coarser than intended -- worth surfacing here since
--- nothing else would tell the user why punctuation gets skipped.
local function _check_motion()
    vim.health.start("Motion")

    if vim.fn.has("nvim-0.11") == 1 then
        vim.health.ok(
            "Neovim supports `vim.treesitter.get_node({ include_anonymous = true })`, "
                .. "so `w`/`e`/`b`/`ge`/`W`/`E`/`B`/`gE` stop on punctuation leaves too."
        )
    else
        vim.health.warn(
            "Neovim is older than 0.11, so `vim.treesitter.get_node()` doesn't support "
                .. "`include_anonymous`. `w`/`e`/`b`/`ge`/`W`/`E`/`B`/`gE` will silently skip over "
                .. "punctuation leaves (e.g. `.`, `(`, `,`) on this version."
        )
    end
end

--- Warn (never error) if a `commands.motion.subword.comment_markers` key
--- the *user* configured names a treesitter language with no installed
--- parser.
---
--- This only looks at the user's own raw override, not the fully-resolved
--- configuration -- the shipped defaults (`c`, `cpp`, `rust`, `python`,
--- ..., see `configuration.lua`'s `_DEFAULTS`) intentionally cover
--- languages most users won't have every parser for (that's the point of
--- being pre-configured ahead of installing e.g. Python's or Rust's parser
--- later), so warning about *those* on every `:checkhealth` run would be
--- noise, not signal. A language the user typed themselves, though, is
--- worth a warning if it can't be found -- most likely a typo, or a parser
--- that still needs installing.
---
--- `configuration.lua`'s `_OPTIONAL_COMMENT_MARKERS` (~120 additional
--- languages, auto-detected when their parser is installed) is exempt from
--- this warning for the same reason as the shipped defaults -- it also
--- isn't part of the user's raw override this function inspects. Unlike the
--- shipped defaults, though, it's not merely low-noise to skip: it's
--- already pre-gated by a `vim.treesitter.language.add()` check before
--- `configuration.get_comment_markers` ever returns one of its entries, so
--- there's never a "missing parser" case to warn about for it in the first
--- place.
---
---@param raw treemotion.Configuration The user's own configuration, unresolved.
---
local function _check_comment_markers(raw)
    local markers = tabler.get_value(raw, { "commands", "motion", "subword", "comment_markers" })

    if type(markers) ~= "table" or vim.tbl_isempty(markers) then
        return
    end

    local languages = vim.tbl_keys(markers)
    table.sort(languages)

    local missing = {}

    for _, language in ipairs(languages) do
        if type(language) == "string" and not vim.treesitter.language.add(language) then
            table.insert(missing, language)
        end
    end

    if vim.tbl_isempty(missing) then
        return
    end

    vim.health.start("Comment markers")

    for _, language in ipairs(missing) do
        vim.health.warn(
            string.format(
                'No treesitter parser named "%s" is installed, so `comment_markers.%s` has no effect until one is.',
                language,
                language
            )
        )
    end
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

    _check_motion()
    _check_comment_markers(data or vim.g.treemotion_configuration or {})
end

return M
