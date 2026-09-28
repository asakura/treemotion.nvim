--- Make sure `treemotion` will work as expected.

local configuration_ = require("treemotion._core.configuration")
local logging_ = require("mega.logging")
local schema = require("treemotion._core.schema")
local tabler = require("treemotion._core.tabler")

local _LOGGER = logging_.get_logger("treemotion.health")

local M = {}

-- This file is defer-loaded so it's okay to run this in the global scope
configuration_.initialize_data_if_needed()

--- Check `data` for problems and return each of them.
---
--- `data` is merged over the defaults first, so a partial configuration
--- (e.g. just `{ logging = { use_file = true } }`) isn't reported as missing
--- every value it leaves out.
---
---@param data treemotion.Configuration? All extra customizations for this plugin.
---@return string[] # All found issues, if any.
---
function M.get_issues(data)
    if not data or vim.tbl_isempty(data) then
        data = vim.g.treemotion_configuration
    end

    return schema.get_issues(configuration_.resolve_data(data))
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

--- Warn (never error) if a `commands.motion.<field>` language key the
--- *user* configured names a treesitter language with no installed parser.
---
--- Used for both `comment_markers` and `insignificant_characters`, which
--- are both `table<language, ...>`.
---
--- This only looks at the user's own raw override, not the fully-resolved
--- configuration -- the shipped defaults (`c`, `cpp`, `rust`, `python`,
--- ...) intentionally cover languages most users won't have every parser
--- for (that's the point of being pre-configured ahead of installing e.g.
--- Python's or Rust's parser later), so warning about *those* on every
--- `:checkhealth` run would be noise, not signal. A language the user typed themselves, though, is
--- worth a warning if it can't be found -- most likely a typo, or a parser
--- that still needs installing.
---
--- The optional languages behind `configuration.get_comment_markers`/
--- `get_insignificant_characters` (auto-detected when their parser is
--- installed) are exempt for the same reason as the shipped defaults --
--- they aren't part of the user's raw override this function inspects.
--- They're also already pre-gated by a `vim.treesitter.language.add()`
--- check before those functions ever return one of their entries, so there's never a "missing parser" case
--- to warn about for them in the first place.
---
---@param raw treemotion.Configuration The user's own configuration, unresolved.
---@param field "comment_markers" | "insignificant_characters" The `commands.motion` key to inspect.
---@param title string The `:checkhealth` section heading, shown only if a warning is.
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

    local raw = data or vim.g.treemotion_configuration or {}

    for _, key in ipairs(schema.get_unknown_keys(raw)) do
        vim.health.warn(string.format('Unknown key "%s" is ignored. Is it a typo?', key))
    end

    _check_motion()

    _check_missing_parsers(raw, "comment_markers", "Comment markers")
    _check_missing_parsers(raw, "insignificant_characters", "Insignificant characters")
end

return M
