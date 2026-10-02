--- Make sure `treemotion` will work as expected.

local configuration_ = require("treemotion._core.configuration")
local logging_ = require("mega.logging")
local schema = require("treemotion._core.schema")
local tabler = require("treemotion._core.tabler")

local _LOGGER = logging_.get_logger("treemotion.health")

local M = {}

-- This file is defer-loaded so it's okay to run this in the global scope
configuration_.initialize_data_if_needed()

--- Problems with `data`, merged over the defaults first.
---
---@param data treemotion.Configuration?
---@return string[]
---
function M.get_issues(data)
    if not data or vim.tbl_isempty(data) then
        data = vim.g.treemotion_configuration
    end

    return schema.get_issues(configuration_.resolve_data(data))
end

--- Report whether Neovim supports stopping on anonymous (punctuation) leaves.
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

--- Warn about languages in the user's own `commands.motion[field]` that have
--- no parser installed. Shipped defaults are not checked.
---
---@param raw treemotion.Configuration
---@param field "comment_markers" | "insignificant_characters"
---@param title string
---
local function _check_missing_parsers(raw, field, title)
    local ok, entries = pcall(tabler.get_value, raw, { "commands", "motion", field })

    if not ok or type(entries) ~= "table" or vim.tbl_isempty(entries) then
        return
    end

    local languages = vim.tbl_keys(entries)
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

    vim.health.start(title)

    for _, language in ipairs(missing) do
        vim.health.warn(
            string.format(
                'No treesitter parser named "%s" is installed, so `%s.%s` has no effect until one is.',
                language,
                field,
                language
            )
        )
    end
end

---@param data treemotion.Configuration?
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

    local raw = data or vim.g.treemotion_configuration or {}

    for _, key in ipairs(schema.get_unknown_keys(raw)) do
        vim.health.warn(string.format('Unknown key "%s" is ignored. Is it a typo?', key))
    end

    _check_motion()

    _check_missing_parsers(raw, "comment_markers", "Comment markers")
    _check_missing_parsers(raw, "insignificant_characters", "Insignificant characters")
end

return M
