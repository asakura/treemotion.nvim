--- A collection of types to be included / used in other Lua files.
---
--- These types are either required by the Lua API or required for the normal
--- operation of this Lua plugin.
---

---@class treemotion.Configuration
---    The user's customizations for this plugin.
---@field commands treemotion.ConfigurationCommands?
---    Customize the fallback behavior of all `:TreeMotion` commands.
---@field hints treemotion.HintKind?
---    Which motion hints are currently visible. Only one kind may be active
---    at a time.
---@field logging treemotion.LoggingConfiguration?
---    Control how and which logs print to file / Neovim.

---@class treemotion.ResolvedConfiguration : treemotion.Configuration
---    `treemotion.Configuration` after the plugin's defaults have been merged
---    in (see `configuration._DEFAULTS`). Unlike `treemotion.Configuration`,
---    which may be a partial user override (e.g. `vim.g.treemotion_configuration`),
---    every field here is guaranteed to be present.
---@field logging treemotion.LoggingConfiguration
---    Control how and which logs print to file / Neovim. Always present,
---    though its own `use_console` / `use_file` fields may both be `false`.

---@alias treemotion.HintKind "word_boundaries" | "motions" | "none"

---@class treemotion.ConfigurationCommands
---    Customize the fallback behavior of all `:TreeMotion` commands.
---@field goodnight_moon treemotion.ConfigurationGoodnightMoon?
---    The default values when a user calls `:TreeMotion goodnight-moon`.
---@field hello_world treemotion.ConfigurationHelloWorld?
---    The default values when a user calls `:TreeMotion hello-world`.
---@field motion treemotion.ConfigurationMotion?
---    Customize the `w`/`e`/`b`/`ge` sub-word splitting behavior.

---@class treemotion.ConfigurationMotion
---    Customize the `w`/`e`/`b`/`ge` sub-word splitting behavior.
---@field subword treemotion.ConfigurationMotionSubword?
---    Which naming conventions `w`/`e`/`b`/`ge` additionally split identifiers
---    on, on top of whole treesitter leaves. All default to `true` and may be
---    combined freely. `W`/`E`/`B`/`gE` are unaffected -- they ignore case
---    the same way real Vim's `W` ignores punctuation.

---@class treemotion.ConfigurationMotionSubword
---    Which naming conventions `w`/`e`/`b`/`ge` additionally split identifiers on.
---@field camel_case boolean?
---    Split lowercase-leading identifiers at case transitions, e.g. `fooBar` -> `foo`, `Bar`.
---@field pascal_case boolean?
---    Split uppercase-leading identifiers at case transitions, e.g. `FooBar` -> `Foo`, `Bar`.
---@field kebab_case boolean?
---    Split on `-`, e.g. `foo-bar` -> `foo`, `bar`. The `-` itself is skipped, not landed on.
---@field snake_case boolean?
---    Split on `_`, e.g. `foo_bar` -> `foo`, `bar`. The `_` itself is skipped, not landed on.

---@class treemotion.ConfigurationGoodnightMoon
---    The default values when a user calls `:TreeMotion goodnight-moon`.
---@field read treemotion.ConfigurationGoodnightMoonRead?
---    The default values when a user calls `:TreeMotion goodnight-moon read`.

---@class treemotion.LoggingConfiguration
---    Control whether or not logging is printed to the console or to disk.
---@field level ("trace" | "debug" | "info" | "warning" | "error" | "fatal")?
---    Any messages above this level will be logged. Only these string values
---    are accepted -- unlike Neovim's own `vim.log.levels.*`, `mega.logging`
---    (which this field is passed into) does not handle numeric levels
---    correctly, so they are intentionally not part of this type.
---@field use_console boolean?
---    Should print the output to neovim while running. Warning: This is very
---    spammy. You probably don't want to enable this unless you have to.
---@field use_file boolean?
---    Should write to a file.
---@field output_path string?
---    The default path on-disk where log files will be written to.
---    Defaults to "/home/selecaoone/.local/share/nvim/plugin_name.log".

---@class treemotion.ConfigurationGoodnightMoonRead
---    The default values when a user calls `:TreeMotion goodnight-moon read`.
---@field phrase string
---    The book to read if no book is given by the user.

---@class treemotion.ConfigurationHelloWorld
---    The default values when a user calls `:TreeMotion hello-world`.
---@field say treemotion.ConfigurationHelloWorldSay?
---    The default values when a user calls `:TreeMotion hello-world say`.

---@class treemotion.ConfigurationHelloWorldSay
---    The default values when a user calls `:TreeMotion hello-world say`.
---@field repeat number
---    A 1-or-more value. When 1, the phrase is said once. When 2+, the phrase
---    is repeated that many times.
---@field style "lowercase" | "uppercase"
---    Control how the text is displayed. e.g. "uppercase" changes "hello" to "HELLO".
