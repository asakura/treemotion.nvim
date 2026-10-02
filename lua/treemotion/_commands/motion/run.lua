--- Runs: maximal sequences of leaves with no gap between them (a `W` WORD).

local leaf = require("treemotion._commands.motion.leaf")

local M = {}

--- Whether `first` ends exactly where `second` starts.
---
---@param first TSNode
---@param second TSNode
---@return boolean
---
function M.is_contiguous(first, second)
    local end_row, end_column = first:end_()
    local start_row, start_column = second:start()

    return end_row == start_row and end_column == start_column
end

---@param node TSNode
---@return TSNode # The last leaf of `node`'s run.
---
M.run_end = leaf.logged("run_end", function(node)
    local current = node

    while true do
        local next_ = leaf.next_leaf(current)

        if not next_ or not M.is_contiguous(current, next_) then
            return current
        end

        current = next_
    end
end, leaf.describe_node)

---@param node TSNode
---@return TSNode # The first leaf of `node`'s run.
---
M.run_start = leaf.logged("run_start", function(node)
    local current = node

    while true do
        local previous = leaf.previous_leaf(current)

        if not previous or not M.is_contiguous(previous, current) then
            return current
        end

        current = previous
    end
end, leaf.describe_node)
return M
