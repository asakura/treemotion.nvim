--- Contiguous leaf runs: the coarser unit `W`/`E`/`B`/`gE` move between.
---
--- A "run" is a maximal sequence of leaves (see `_commands.motion.leaf`)
--- with no gap (whitespace/newline) between them. `run_start`/`run_end`
--- are `leaf.previous_leaf`/`leaf.next_leaf` repeated while `is_contiguous`
--- holds.

local leaf = require("treemotion._commands.motion.leaf")

local M = {}

--- Check if `first` ends exactly where `second` starts.
---
--- The one primitive `run_start`/`run_end` build their whole-run walk on:
--- comparing raw coordinates, not tree structure, since two leaves can sit
--- in entirely different branches of the tree (e.g. the last token of one
--- nested expression, and the first token of the next) while still being
--- immediately adjacent in the document.
---
---@param first TSNode The earlier of the two leaves.
---@param second TSNode The later of the two leaves.
---@return boolean # `true` if there's no whitespace/newline between them.
---
function M.is_contiguous(first, second)
    local end_row, end_column = first:end_()
    local start_row, start_column = second:start()

    return end_row == start_row and end_column == start_column
end

--- Find the last leaf in the contiguous run that `node` belongs to.
---
--- Walks `leaf.next_leaf` forward one step at a time, stopping as soon as
--- `is_contiguous` fails (a gap) or there's no next leaf at all -- giving
--- `W`/`E`'s notion of a "WORD" boundary.
---
---@param node TSNode Any leaf.
---@return TSNode # `node` itself, or a later leaf if the run continues.
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

--- Find the first leaf in the contiguous run that `node` belongs to.
---
--- Mirror image of `run_end`, walking `leaf.previous_leaf` backward instead --
--- gives `B`/`gE`'s notion of a "WORD" boundary.
---
---@param node TSNode Any leaf.
---@return TSNode # `node` itself, or an earlier leaf if the run continues.
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
