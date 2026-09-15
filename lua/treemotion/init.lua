--- All function(s) that can be called externally by other Lua modules.
---
--- If a function's signature here changes in some incompatible way, this
--- package must get a new **major** version.
---

local configuration = require("treemotion._core.configuration")
local motion_runner = require("treemotion._commands.motion.runner")

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

--- Move the cursor like `w`: to the start of the next treesitter leaf.
---
---@param count number?
---    A 1-or-more value. How many leaves to move over.
---
function M.run_motion_w(count)
    motion_runner.run_w(count)
end

--- Move the cursor like `ge`: to the end of the previous treesitter leaf.
---
---@param count number?
---    A 1-or-more value. How many leaves to move over.
---
function M.run_motion_ge(count)
    motion_runner.run_ge(count)
end

--- Move the cursor like `e`: to the end of the current or next treesitter leaf.
---
---@param count number?
---    A 1-or-more value. How many leaves to move over.
---
function M.run_motion_e(count)
    motion_runner.run_e(count)
end

--- Move the cursor like `b`: to the start of the current or previous treesitter leaf.
---
---@param count number?
---    A 1-or-more value. How many leaves to move over.
---
function M.run_motion_b(count)
    motion_runner.run_b(count)
end

--- Move the cursor like `W`: to the start of the next run of contiguous treesitter leaves.
---
---@param count number?
---    A 1-or-more value. How many runs to move over.
---
function M.run_motion_W(count)
    motion_runner.run_W(count)
end

--- Move the cursor like `gE`: to the end of the previous run of contiguous treesitter leaves.
---
---@param count number?
---    A 1-or-more value. How many runs to move over.
---
function M.run_motion_gE(count)
    motion_runner.run_gE(count)
end

--- Move the cursor like `E`: to the end of the current or next run of contiguous treesitter leaves.
---
---@param count number?
---    A 1-or-more value. How many runs to move over.
---
function M.run_motion_E(count)
    motion_runner.run_E(count)
end

--- Move the cursor like `B`: to the start of the current or previous run of contiguous treesitter leaves.
---
---@param count number?
---    A 1-or-more value. How many runs to move over.
---
function M.run_motion_B(count)
    motion_runner.run_B(count)
end

return M
