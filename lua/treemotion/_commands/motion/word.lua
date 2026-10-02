--- `w`/`e`/`b`/`ge` units: the sub-words of a single leaf.

local leaf = require("treemotion._commands.motion.leaf")
local subword = require("treemotion._commands.motion.subword")
local unit = require("treemotion._commands.motion.unit")

---@alias treemotion.WordUnit treemotion.MotionUnit

local M = {}

--- From `node` (inclusive), find the first leaf in `forward`'s direction that
--- splits into any units.
---
---@param node TSNode?
---@param forward boolean
---@param settings treemotion.SplitSettings
---@return TSNode?, treemotion.SubwordUnit[]?
local function _first_nonempty_split(node, forward, settings)
    local step = forward and leaf.next_leaf or leaf.previous_leaf

    while node do
        local units = subword.split(node, settings)

        if #units > 0 then
            return node, units
        end

        node = step(node)
    end

    return nil, nil
end

---@param settings treemotion.SplitSettings
---@return treemotion._UnitSource
---
function M.new_source(settings)
    return unit.new_source({
        logger = "treemotion._commands.motion.word",
        first_nonempty = function(node, forward)
            return _first_nonempty_split(node, forward, settings)
        end,
        after = leaf.next_leaf,
        span_end = function(node)
            local row, column = node:end_()

            return row, column
        end,
    })
end

return M
