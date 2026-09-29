--- Symbolic values for `treemotion`'s `motion` feature.

return {
    DelimiterMode = { none = "none", skip = "skip", stop = "stop" },

    --- `commands.motion.operator_pending.skipped_text`'s values.
    SkippedText = { delete = "delete", keep = "keep", keep_between_tokens = "keep_between_tokens" },

    ---@type string[] # Every motion name, `word` (lowercase) then `WORD` (uppercase).
    MOTION_NAMES = { "w", "e", "b", "ge", "W", "E", "B", "gE" },
}
