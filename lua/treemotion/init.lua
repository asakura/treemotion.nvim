--- The public Lua API. Incompatible changes need a new major version.

local configuration = require("treemotion._core.configuration")
local motion_runner = require("treemotion._commands.motion.runner")

local M = {}

configuration.initialize_data_if_needed()

--- Configure `treemotion`, e.g. from a plugin manager's `opts`.
---
---@param opts treemotion.Configuration?
---
function M.setup(opts)
    configuration.merge_data(opts)
end

--- Move like `w`: to the start of the next word.
---
---@param count number? How many to move over (default 1).
---
function M.run_motion_w(count)
    motion_runner.run("w", count)
end

--- Move like `ge`: to the end of the previous word.
---
---@param count number? How many to move over (default 1).
---
function M.run_motion_ge(count)
    motion_runner.run("ge", count)
end

--- Move like `e`: to the end of the current or next word.
---
---@param count number? How many to move over (default 1).
---
function M.run_motion_e(count)
    motion_runner.run("e", count)
end

--- Move like `b`: to the start of the current or previous word.
---
---@param count number? How many to move over (default 1).
---
function M.run_motion_b(count)
    motion_runner.run("b", count)
end

--- Move like `W`: to the start of the next WORD.
---
---@param count number? How many to move over (default 1).
---
function M.run_motion_W(count)
    motion_runner.run("W", count)
end

--- Move like `gE`: to the end of the previous WORD.
---
---@param count number? How many to move over (default 1).
---
function M.run_motion_gE(count)
    motion_runner.run("gE", count)
end

--- Move like `E`: to the end of the current or next WORD.
---
---@param count number? How many to move over (default 1).
---
function M.run_motion_E(count)
    motion_runner.run("E", count)
end

--- Move like `B`: to the start of the current or previous WORD.
---
---@param count number? How many to move over (default 1).
---
function M.run_motion_B(count)
    motion_runner.run("B", count)
end

return M
