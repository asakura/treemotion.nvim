--- All function(s) that can be called externally by other Lua modules.
---
--- If a function's signature here changes in some incompatible way, this
--- package must get a new **major** version.
---

local configuration = require("treemotion._core.configuration")
local arbitrary_thing_runner = require("treemotion._commands.arbitrary_thing.runner")
local copy_logs_runner = require("treemotion._commands.copy_logs.runner")
local count_sheep = require("treemotion._commands.goodnight_moon.count_sheep")
local motion_runner = require("treemotion._commands.motion.runner")
local read = require("treemotion._commands.goodnight_moon.read")
local say_runner = require("treemotion._commands.hello_world.say.runner")
local sleep = require("treemotion._commands.goodnight_moon.sleep")

local M = {}

configuration.initialize_data_if_needed()

--- Configure `treemotion`, e.g. from a plugin manager's `opts` table.
---
--- This is separate from `vim.g.treemotion_configuration` so that plugin
--- managers using the `opts = {...}` convention (which calls this function
--- after `treemotion` has already loaded) still work as expected.
---
---@param opts treemotion.Configuration? Extra customizations for this plugin.
---
function M.setup(opts)
    configuration.merge_data(opts)
end

--- Print the `names`.
---
---@param names string[]? Some text to print out. e.g. `{"a", "b", "c"}`.
---
function M.run_arbitrary_thing(names)
    arbitrary_thing_runner.run(names)
end

--- Copy the log data from the given `path` to the user's clipboard.
---
---@param path string?
---    A path on-disk to look for logs. If none is given, the default fallback
---    location is used instead.
---
function M.run_copy_logs(path)
    copy_logs_runner.run(path)
end

--- Print `phrase` according to the other options.
---
---@param phrase string[]
---    The text to say.
---@param repeat_ number?
---    A 1-or-more value. The number of times to print `word`.
---@param style string?
---    Control how the text should be shown.
---
function M.run_hello_world_say_phrase(phrase, repeat_, style)
    say_runner.run_say_phrase(phrase, repeat_, style)
end

--- Print `phrase` according to the other options.
---
---@param word string
---    The text to say.
---@param repeat_ number?
---    A 1-or-more value. The number of times to print `word`.
---@param style string?
---    Control how the text should be shown.
---
function M.run_hello_world_say_word(word, repeat_, style)
    say_runner.run_say_word(word, repeat_, style)
end

--- Move the cursor like `w`: to the start of the next treesitter leaf.
---
---@param count number? A 1-or-more value. How many leaves to move over.
---
function M.run_motion_w(count)
    motion_runner.run_w(count)
end

--- Move the cursor like `ge`: to the end of the previous treesitter leaf.
---
---@param count number? A 1-or-more value. How many leaves to move over.
---
function M.run_motion_ge(count)
    motion_runner.run_ge(count)
end

--- Move the cursor like `e`: to the end of the current or next treesitter leaf.
---
---@param count number? A 1-or-more value. How many leaves to move over.
---
function M.run_motion_e(count)
    motion_runner.run_e(count)
end

--- Move the cursor like `b`: to the start of the current or previous treesitter leaf.
---
---@param count number? A 1-or-more value. How many leaves to move over.
---
function M.run_motion_b(count)
    motion_runner.run_b(count)
end

--- Move the cursor like `W`: to the start of the next run of contiguous treesitter leaves.
---
---@param count number? A 1-or-more value. How many runs to move over.
---
function M.run_motion_W(count)
    motion_runner.run_W(count)
end

--- Move the cursor like `gE`: to the end of the previous run of contiguous treesitter leaves.
---
---@param count number? A 1-or-more value. How many runs to move over.
---
function M.run_motion_gE(count)
    motion_runner.run_gE(count)
end

--- Move the cursor like `E`: to the end of the current or next run of contiguous treesitter leaves.
---
---@param count number? A 1-or-more value. How many runs to move over.
---
function M.run_motion_E(count)
    motion_runner.run_E(count)
end

--- Move the cursor like `B`: to the start of the current or previous run of contiguous treesitter leaves.
---
---@param count number? A 1-or-more value. How many runs to move over.
---
function M.run_motion_B(count)
    motion_runner.run_B(count)
end

--- Count a sheep for each `count`.
---
---@param count number Prints 1 sheep per `count`. A value that is 1-or-greater.
---
function M.run_goodnight_moon_count_sheep(count)
    count_sheep.run(count)
end

--- Print the name of the book.
---
---@param book string The name of the book.
---
function M.run_goodnight_moon_read(book)
    read.run(book)
end

--- Print Zzz each `count`.
---
---@param count number? Prints 1 Zzz per `count`. A value that is 1-or-greater.
---
function M.run_goodnight_moon_sleep(count)
    sleep.run(count)
end

return M
