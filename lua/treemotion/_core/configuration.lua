--- All functions and data to help customize `treemotion` for this user.

local hints_constant = require("treemotion._core.hints")
local motion_constant = require("treemotion._commands.motion.constant")
local say_constant = require("treemotion._commands.hello_world.say.constant")

local logging = require("mega.logging")

local _LOGGER = logging.get_logger("treemotion._core.configuration")

local M = {}

vim.g.loaded_treemotion = false

-- NOTE: `M.DATA` starts empty and is always filled out by
-- `M.initialize_data_if_needed()` before any other function in this module
-- reads it, so the "missing `logging`" warning below is a false positive.
---@type treemotion.ResolvedConfiguration
---@diagnostic disable-next-line: missing-fields
M.DATA = {}

---@type treemotion.ResolvedConfiguration
local _DEFAULTS = {
    hints = hints_constant.Kind.none,
    logging = { level = "info", use_console = false, use_file = false },
    commands = {
        goodnight_moon = { read = { phrase = "A good book" } },
        hello_world = {
            say = { ["repeat"] = 1, style = say_constant.Keyword.style.lowercase },
        },
        motion = {
            subword = {
                comment_markers = {
                    c = { "/" },
                    cpp = { "/" },
                    rust = { "/" },
                    python = { "#" },
                    bash = { "#" },
                    sh = { "#" },
                    latex = { "%" },
                    tex = { "%" },
                    vim = { '"' },
                    query = { ";" },
                },
                code = {
                    camel_case = true,
                    pascal_case = true,
                    kebab_case = motion_constant.DelimiterMode.skip,
                    snake_case = motion_constant.DelimiterMode.skip,
                    comment_marker_case = motion_constant.DelimiterMode.stop,
                },
                prose = {
                    camel_case = true,
                    pascal_case = true,
                    kebab_case = motion_constant.DelimiterMode.stop,
                    snake_case = motion_constant.DelimiterMode.none,
                    comment_marker_case = motion_constant.DelimiterMode.stop,
                },
            },
        },
    },
}

--- Setup `treemotion` for the first time, if needed.
function M.initialize_data_if_needed()
    if vim.g.loaded_treemotion then
        return
    end

    M.DATA = vim.tbl_deep_extend("force", _DEFAULTS, vim.g.treemotion_configuration or {})

    vim.g.loaded_treemotion = true

    local configuration = M.DATA.logging

    -- NOTE: `treemotion.LoggingConfiguration` and `mega.logging.SparseLoggerOptions`
    -- are separately-declared classes with no inheritance relationship, so
    -- lua-language-server won't treat this cast as valid on nominal-type
    -- grounds alone, even though every field the two types share matches
    -- exactly.
    ---@diagnostic disable-next-line: cast-type-mismatch
    ---@cast configuration mega.logging.SparseLoggerOptions
    logging.set_configuration("treemotion", configuration)

    _LOGGER:fmt_debug("Initialized treemotion's configuration.")
end

--- Merge `data` with the user's current configuration.
---
---@param data treemotion.Configuration? All extra customizations for this plugin.
---@return treemotion.ResolvedConfiguration # The configuration with 100% filled out values.
---
function M.resolve_data(data)
    M.initialize_data_if_needed()

    return vim.tbl_deep_extend("force", M.DATA, data or {})
end

--- Merge `data` into the current configuration, in-place.
---
--- Unlike `M.resolve_data()`, this permanently updates `M.DATA` rather than
--- returning a one-off merged copy. Use this to apply configuration after
--- `M.initialize_data_if_needed()` has already run and latched (e.g. from a
--- plugin manager's `opts` table, which is applied after `require()` has
--- already triggered initialization).
---
---@param data treemotion.Configuration? Extra customizations to apply now.
---
function M.merge_data(data)
    M.initialize_data_if_needed()

    M.DATA = vim.tbl_deep_extend("force", M.DATA, data or {})
end

--- Turn `kind` on, replacing whichever hint kind (if any) was previously active.
---
---@param kind treemotion.HintKind Which hints to show. e.g. `"word_boundaries"`.
---
function M.set_hints(kind)
    M.initialize_data_if_needed()

    M.DATA.hints = kind
end

--- Turn `kind` on if it isn't already active, otherwise turn all hints off.
---
--- Because `M.DATA.hints` holds a single value, enabling `kind` always
--- implicitly disables whichever other kind was previously active.
---
---@param kind treemotion.HintKind Which hints to toggle. e.g. `"word_boundaries"`.
---
function M.toggle_hints(kind)
    M.initialize_data_if_needed()

    if M.DATA.hints == kind then
        M.DATA.hints = hints_constant.Kind.none
    else
        M.DATA.hints = kind
    end
end

return M
