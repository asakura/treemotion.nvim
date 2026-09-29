--- Resolve everything the motion modules read from the user's configuration.
---
--- `_commands.motion.subword` and `_commands.motion.classify` take a
--- `treemotion.SplitSettings` rather than reading `_core.configuration`;
--- `_commands.motion.runner` resolves one with `M.resolve` once per motion.
--- The splitter itself then does only string and range work, and tests can
--- hand it any rules without touching the global configuration.
---
--- `_commands.motion.operator` takes a `treemotion.OperatorSettings` the same
--- way, from `M.resolve_operator`, which also reads the editor state its
--- rules depend on (the mode, `v:operator`, `'cpoptions'`).

local classify = require("treemotion._commands.motion.classify")
local configuration = require("treemotion._core.configuration")

local M = {}

--- Everything `subword.split`/`subword.split_run` read from the configuration.
---
---@class treemotion.SplitSettings
---@field enabled boolean? `commands.motion[group].enabled`. Only `subword.split_run` reads it
---    (`commands.motion.big.enabled`); `commands.motion.small` has no such field.
---@field backtick_identifiers boolean `commands.motion[group].backtick_identifiers`.
---@field code treemotion.ConfigurationMotionSubwordRules `commands.motion[group].code`.
---@field prose treemotion.ConfigurationMotionSubwordRules `commands.motion[group].prose`.
---@field comment_marker_characters table<string, true> The current language's comment-marker
---    punctuation (see `classify.comment_marker_characters`).
---@field insignificant_characters string[]? The current language's insignificant leaf texts
---    (see `classify.is_insignificant`), or `nil` if it has none.

--- Resolve `group`'s splitting settings for the current buffer's language.
---
---@param group "small"|"big" Which motion family's configuration to read:
---    "small" for `w`/`e`/`b`/`ge`, "big" for `W`/`E`/`B`/`gE`.
---@return treemotion.SplitSettings
---
function M.resolve(group)
    -- `assert()`: `commands.motion.small`/`.big` and their `.code`/`.prose`
    -- are optional in the LuaCATS types (they double as valid partial
    -- user-override input), but `configuration._DEFAULTS` always fills all
    -- of them in, so `resolve_data()`'s result always has them. Don't
    -- `assert()` the boolean fields, though -- `false` is a legitimate
    -- value there, and `assert(false)` would raise.
    local motion_group = assert(configuration.resolve_data().commands.motion[group])
    local language = classify.current_language()

    return {
        enabled = motion_group.enabled,
        backtick_identifiers = motion_group.backtick_identifiers,
        code = assert(motion_group.code),
        prose = assert(motion_group.prose),
        comment_marker_characters = classify.comment_marker_characters(
            language and configuration.get_comment_markers(language)
        ),
        insignificant_characters = language and configuration.get_insignificant_characters(language) or nil,
    }
end

--- Everything `_commands.motion.operator` reads, for one operator.
---
---@class treemotion.OperatorSettings
---@field skipped_text treemotion.SkippedTextMode `commands.motion.operator_pending.skipped_text`.
---@field stop_at_line_end boolean `commands.motion.operator_pending.stop_at_line_end`.
---@field inclusive boolean `commands.motion.operator_pending.inclusive`.
---@field change boolean Whether the pending operator is `c` (`v:operator`).
---@field change_to_end boolean Whether `cw`/`cW` work like `ce`/`cE` right now:
---    `change`, `commands.motion.operator_pending.change_to_end`, and
---    `'cpoptions'` containing `_`, the condition Vim's own `cw` checks
---    (`:help cpo-_`).

--- Resolve the settings for the pending operator, if its behavior applies at all.
---
--- `vim.fn.mode(true)` is exactly `"no"` for an operator without a forced
--- motion type. `"nov"`/`"noV"`/`"no<C-v>"` (`dvw`, `dVw`, ...) mean the
--- user chose the range's shape themselves, so those get the plain motion.
---
---@return treemotion.OperatorSettings? # `nil` when `commands.motion.operator_pending`
---    is disabled, or no unforced operator is pending.
---
function M.resolve_operator()
    local pending = assert(configuration.resolve_data().commands.motion.operator_pending)

    if not pending.enabled or vim.fn.mode(true) ~= "no" then
        return nil
    end

    local change = vim.v.operator == "c"

    return {
        skipped_text = assert(pending.skipped_text),
        stop_at_line_end = pending.stop_at_line_end == true,
        inclusive = pending.inclusive == true,
        change = change,
        change_to_end = change and pending.change_to_end == true and vim.o.cpoptions:find("_", 1, true) ~= nil,
    }
end

return M
