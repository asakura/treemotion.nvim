--- Read the configuration once per motion, so the splitter and operator code
--- take plain tables and never touch global state.

local classify = require("treemotion._commands.motion.classify")
local configuration = require("treemotion._core.configuration")

local M = {}

---@class treemotion.SplitSettings
---@field enabled boolean? `commands.motion.big.enabled`; unset for `small`.
---@field backtick_identifiers boolean
---@field code treemotion.ConfigurationMotionSubwordRules
---@field prose treemotion.ConfigurationMotionSubwordRules
---@field comment_marker_characters table<string, true>
---@field insignificant_characters string[]?

--- Resolve `group`'s settings for the current buffer's language.
---
---@param group "small"|"big" `w`/`e`/`b`/`ge` or `W`/`E`/`B`/`gE`.
---@return treemotion.SplitSettings
---
function M.resolve(group)
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

---@class treemotion.OperatorSettings
---@field skipped_text treemotion.SkippedTextMode
---@field stop_at_line_end boolean
---@field inclusive boolean
---@field change boolean Whether the operator is `c`.
---@field change_to_end boolean Whether `cw` acts like `ce` (`:help cpo-_`).

--- The settings for the pending operator, or `nil` when the feature is off
--- or the motion is forced (`dvw`, `dVw`, ...).
---
---@return treemotion.OperatorSettings?
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
