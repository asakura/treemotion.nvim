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

---@alias treemotion.HintKind "word_boundaries" | "motions" | "none"

---@class treemotion.ConfigurationCommands
---    Customize the fallback behavior of all `:TreeMotion` commands.
---@field goodnight_moon treemotion.ConfigurationGoodnightMoon?
---    The default values when a user calls `:TreeMotion goodnight-moon`.
---@field hello_world treemotion.ConfigurationHelloWorld?
---    The default values when a user calls `:TreeMotion hello-world`.

---@class treemotion.ConfigurationGoodnightMoon
---    The default values when a user calls `:TreeMotion goodnight-moon`.
---@field read treemotion.ConfigurationGoodnightMoonRead?
---    The default values when a user calls `:TreeMotion goodnight-moon read`.

---@class treemotion.LoggingConfiguration
---    Control whether or not logging is printed to the console or to disk.
---@field level (
---    | "trace"
---    | "debug"
---    | "info"
---    | "warn" | "error"
---    | "fatal"
---    | vim.log.levels.DEBUG
---    | vim.log.levels.ERROR
---    | vim.log.levels.INFO
---    | vim.log.levels.TRACE
---    | vim.log.levels.WARN)?
---    Any messages above this level will be logged.
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
