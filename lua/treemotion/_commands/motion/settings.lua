--- Resolve everything the sub-word splitter reads from the user's configuration.
---
--- `_commands.motion.subword` and `_commands.motion.classify` used to read
--- `_core.configuration` directly, several times per leaf. They now take a
--- `treemotion.SplitSettings` instead, which `_commands.motion.runner`
--- resolves with `M.resolve` once per motion. Keeping the configuration
--- lookups here means the splitter itself does only string and range work,
--- and tests can hand it any rules they like without touching the global
--- configuration.

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

return M
