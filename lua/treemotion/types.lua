--- Types for the configuration and the public API.

---@alias treemotion.HintKind "word_boundaries" | "motions" | "none"

---@alias treemotion.InsignificantCharacterList string[] | table<string, boolean>
---    One language's `insignificant_characters`. A plain list replaces the
---    language's characters. A string key set to `false` (`{ [";"] = false }`)
---    removes that one character instead, keeping the rest.

---@class treemotion.Configuration
---    The user's customizations.
---@field commands treemotion.ConfigurationCommands?
---@field hints treemotion.HintKind?
---    Which motion hints are visible. One kind at a time.
---@field logging treemotion.LoggingConfiguration?

---@class treemotion.ResolvedConfiguration : treemotion.Configuration
---    `treemotion.Configuration` merged over the defaults: every field is set.
---@field logging treemotion.LoggingConfiguration

---@class treemotion.ConfigurationCommands
---@field motion treemotion.ConfigurationMotion?

---@class treemotion.ConfigurationMotion
---    How the motions split text into stops.
---@field small treemotion.ConfigurationMotionGroup?
---    Rules for `w`/`e`/`b`/`ge`.
---@field big treemotion.ConfigurationMotionGroup?
---    Rules for `W`/`E`/`B`/`gE`. Only used with `enabled = true`; otherwise a
---    WORD is one stop, as in Vim.
---@field comment_markers table<string, string[]>?
---    Comment-marker characters per treesitter language (`"lua"`, `"c"`,
---    ...), which `comment_marker_case` applies to. Per language because the
---    same character means different things: `"` starts a Vimscript comment
---    but ends a string elsewhere. About 120 more languages are covered
---    automatically once their parser is installed.
---@field operator_pending treemotion.ConfigurationMotionOperatorPending?
---    How the motions behave after an operator. Off by default.
---@field insignificant_characters table<string, treemotion.InsignificantCharacterList>?
---    Code tokens the motions never stop on, per language, e.g. `";"` or
---    `"{"`. An entry must match a leaf's whole text, so `"->"` works too.
---    Prose is never affected. Empty by default, except for a few
---    near-universal choices (Nix's structural punctuation) used once that
---    language's parser is installed.

---@alias treemotion.SkippedTextMode "keep" | "keep_between_tokens" | "delete"

---@class treemotion.ConfigurationMotionOperatorPending
---    How the motions behave after an operator (`dw`, `cw`, `yW`, `de`, ...).
---    Forced motions (`dvw`, `dVw`) always get the plain motion.
---@field enabled boolean?
---    Whether the fields below apply. Defaults to `false`.
---@field skipped_text treemotion.SkippedTextMode?
---    What `dw` does with skipped non-blank text before the next stop
---    (insignificant characters, `"skip"` delimiters, comment markers).
---    `"keep"` leaves it, `"delete"` takes it, and the default
---    `"keep_between_tokens"` leaves it only between tokens, so `dw` on
---    `foo_bar` leaves `bar`.
---@field stop_at_line_end boolean?
---    Whether `dw` on a line's last word stops at the line's end, like Vim's
---    (`:help word`). Defaults to `true`.
---@field change_to_end boolean?
---    Whether `cw` acts like `ce` while `'cpoptions'` contains `_`, like
---    Vim's (`:help cw`). Defaults to `true`.
---@field inclusive boolean?
---    Whether `e`/`E`/`ge`/`gE` include the character they land on, like
---    Vim's (`:help inclusive`). Defaults to `true`.

---@class treemotion.ConfigurationMotionGroup
---    Splitting rules for one motion family, separately for code and prose.
---    Prose is anything highlighted `@spell` or `@string`; it is split into
---    words first, like Vim's `w` in a text file.
---@field enabled boolean?
---    `big` only: whether `W`/`E`/`B`/`gE` split runs at all. Defaults to `false`.
---@field backtick_identifiers boolean?
---    Whether a single word in backticks inside prose (`` `fooBar` ``) uses
---    the `code` rules, with no stop on the backticks. Defaults to `true`.
---@field code treemotion.ConfigurationMotionSubwordRules?
---@field prose treemotion.ConfigurationMotionSubwordRules?

---@alias treemotion.SubwordDelimiterMode "none" | "skip" | "stop"
---    `"none"` doesn't split, `"skip"` splits without stopping on the
---    delimiter, and `"stop"` also stops on it.

---@class treemotion.ConfigurationMotionSubwordRules
---@field camel_case boolean?
---    Split `fooBar` into `foo`, `Bar`.
---@field pascal_case boolean?
---    Split `FooBar` into `Foo`, `Bar`.
---@field kebab_case treemotion.SubwordDelimiterMode?
---    How to treat `-` in `foo-bar`. A run of only `-` (Lua's `--`) uses
---    `comment_marker_case` instead if the language lists `-` as a marker.
---@field snake_case treemotion.SubwordDelimiterMode?
---    How to treat `_` in `foo_bar`. Bare runs as for `kebab_case`.
---@field comment_marker_case treemotion.SubwordDelimiterMode?
---    How to treat a run of the language's `comment_markers`, such as `///`.
---@field colon_case treemotion.SubwordDelimiterMode?
---    How to treat `:` in `github:owner/repo` or `https:`.
---@field slash_case treemotion.SubwordDelimiterMode?
---    How to treat `/` in URLs and paths.
---@field opaque_token_min_length integer?
---    Minimum length for a token to count as a hash and never be split: all
---    hex, or base64 with an uppercase letter, a lowercase letter and a
---    digit. Trailing `=` is ignored. Defaults to `20`.

---@class treemotion.LoggingConfiguration
---@field level ("trace" | "debug" | "info" | "warning" | "error" | "fatal")?
---    The lowest level to log. `mega.logging` doesn't accept numeric levels.
---@field use_console boolean?
---    Print logs in Neovim. Very noisy.
---@field use_file boolean?
---    Write logs to a file.
---@field output_path string?
---    Where to write the log file.
