--- `W`/`E`/`B`/`gE` units: the sub-words of a whole run of contiguous leaves.

local classify = require("treemotion._commands.motion.classify")
local leaf = require("treemotion._commands.motion.leaf")
local run = require("treemotion._commands.motion.run")
local subword = require("treemotion._commands.motion.subword")
local unit = require("treemotion._commands.motion.unit")

---@alias treemotion.BigWordUnit treemotion.MotionUnit

local M = {}

--- Whether every leaf from `run_start` to `run_end` is insignificant.
---
---@param run_start TSNode
---@param run_end TSNode
---@param characters string[]?
---@return boolean
---
local function _run_is_insignificant(run_start, run_end, characters)
    local node = run_start

    while true do
        if not classify.is_insignificant(node, characters) then
            return false
        end

        if node:equal(run_end) then
            return true
        end

        node = assert(leaf.next_leaf(node))
    end
end

--- From `node`'s run, find the first run in `forward`'s direction that is
--- significant and has units. Steps a whole run at a time.
---
---@param node TSNode?
---@param forward boolean
---@param settings treemotion.SplitSettings
---@return TSNode?, treemotion.SubwordUnit[]? # The run's start leaf and its units.
---
local function _first_nonempty_split(node, forward, settings)
    while node do
        local run_start = run.run_start(node)
        local run_end = run.run_end(node)

        if not _run_is_insignificant(run_start, run_end, settings.insignificant_characters) then
            local units = subword.split_run(run_start, run_end, settings)

            if #units > 0 then
                return run_start, units
            end
        end

        node = forward and leaf.next_leaf(run_end) or leaf.previous_leaf(run_start)
    end

    return nil, nil
end

---@param run_start TSNode
---@return TSNode? # The leaf after the run.
---
local function _after_run(run_start)
    return leaf.next_leaf(run.run_end(run_start))
end

---@param settings treemotion.SplitSettings
---@return treemotion._UnitSource
---
function M.new_source(settings)
    return unit.new_source({
        logger = "treemotion._commands.motion.bigword",
        first_nonempty = function(node, forward)
            return _first_nonempty_split(node, forward, settings)
        end,
        after = _after_run,
        span_end = function(node)
            local row, column = run.run_end(node):end_()

            return row, column
        end,
    })
end

return M
