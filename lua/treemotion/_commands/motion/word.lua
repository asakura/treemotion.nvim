--- Sub-word-aware unit traversal for `w`/`e`/`b`/`ge`.
---
--- Unlike `W`/`E`/`B`/`gE` (which move by whole treesitter leaves/runs, see
--- `_commands.motion.leaf`), `w`/`e`/`b`/`ge` additionally step through
--- case-convention sub-words *inside* a single leaf (e.g. `fooBar` is two
--- units, `foo` and `Bar`) per `_commands.motion.subword`'s splitting rules.
---
--- This module is the traversal counterpart to `_commands.motion.subword`:
--- `subword.split()` only knows how to slice *one* leaf's text into ranges,
--- it has no notion of "next"/"previous" or of crossing into another leaf --
--- that's what `_commands.motion.unit` adds on top, given the one-leaf
--- spans defined here, mirroring `_commands.motion.leaf`'s
--- `next_leaf`/`previous_leaf` one level finer.

local leaf = require("treemotion._commands.motion.leaf")
local subword = require("treemotion._commands.motion.subword")
local unit = require("treemotion._commands.motion.unit")

---@alias treemotion.WordUnit treemotion.MotionUnit

local M = {}

--- Walk from `node` in `forward`'s direction until finding a leaf
--- `subword.split()` actually produces units for.
---
--- A leaf entirely consumed by `_commands.motion.subword`'s
--- `_leading_continuation_length` (e.g. tree-sitter-rust's lone `/`
--- `outer_doc_comment_marker` leaf inside a `///` doc comment) splits into
--- zero units -- it has no content of its own, just the tail of the
--- previous leaf's punctuation run -- so it should never be a landing spot.
--- `node` itself is checked first, so passing a leaf straight from
--- `leaf.current_leaf()` (which may or may not already be empty) works the
--- same as passing one already stepped past a known-empty leaf.
---
---@param node TSNode? Where to start looking.
---@param forward boolean Search after `node` (`leaf.next_leaf`) or before it (`leaf.previous_leaf`).
---@param settings treemotion.SplitSettings Passed to `subword.split`.
---@return TSNode?, treemotion.SubwordUnit[]? # The first leaf with real
---    units, and its units -- both `nil` if none remain.
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

--- Build a `treemotion._UnitSource` stepping through `w`/`e`/`b`/`ge` units.
---
---@param settings treemotion.SplitSettings `commands.motion.small`'s settings
---    (see `_commands.motion.settings.resolve`).
---@return treemotion._UnitSource
---
function M.new_source(settings)
    return unit.new_source({
        logger = "treemotion._commands.motion.word",
        first_nonempty = function(node, forward)
            return _first_nonempty_split(node, forward, settings)
        end,
        after = leaf.next_leaf,
    })
end

return M
