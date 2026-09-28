--- Sub-word-aware unit traversal for `W`/`E`/`B`/`gE`.
---
--- Mirrors `_commands.motion.word` one level coarser: where `word.lua` steps
--- through case-convention sub-words *inside* a single treesitter leaf,
--- this steps through them inside a whole *run* of contiguous leaves (see
--- `_commands.motion.leaf`'s module docstring for what a "run" is). By
--- default (`commands.motion.big.enabled = false`) a run is always exactly
--- one stop, ignoring case/delimiters entirely -- the same way real Vim's
--- `W` ignores punctuation inside a WORD; `subword.split_run()` is what
--- decides that, this module only adds the "next"/"previous" traversal on
--- top of whatever it returns.
---
--- The stepping itself is `_commands.motion.unit`'s, shared with
--- `_commands.motion.word`; this module only defines what a span is (a whole
--- run) and how to get past one. A unit's `_leaf` holds the run's *start*
--- leaf specifically (not just any leaf in it), since that's what
--- `leaf.run_end`/`leaf.previous_leaf` need to re-derive the run's bounds
--- when stepping past it.

local classify = require("treemotion._commands.motion.classify")
local leaf = require("treemotion._commands.motion.leaf")
local subword = require("treemotion._commands.motion.subword")
local unit = require("treemotion._commands.motion.unit")

---@alias treemotion.BigWordUnit treemotion.MotionUnit

--- Whether every leaf in the run from `run_start` to `run_end` is
--- `classify.is_insignificant` -- i.e. the whole run is punctuation the user
--- has configured as invisible (`commands.motion.insignificant_characters`),
--- not just one leaf within an otherwise-significant run.
---
--- A run that *mixes* insignificant and significant leaves (`foo;bar` as one
--- contiguous run, `;` unconfigured or not) is deliberately left alone here
--- -- it was already one `W`/`E`/`B`/`gE` stop before this feature existed,
--- and nothing about grouping leaves into runs changes because of it; only a
--- run that's *entirely* insignificant (an isolated `;` with whitespace on
--- both sides, which would otherwise be its own spurious stop) should be
--- skipped.
---
---@param run_start TSNode The run's first leaf.
---@param run_end TSNode The run's last leaf.
---@return boolean
---
local function _run_is_insignificant(run_start, run_end)
    local node = run_start

    while true do
        if not classify.is_insignificant(node) then
            return false
        end

        if node:equal(run_end) then
            return true
        end

        node = assert(leaf.next_leaf(node))
    end
end

--- Walk from `node` in `forward`'s direction until finding a leaf whose
--- *run* `subword.split_run()` actually produces units for, and that isn't
--- `_run_is_insignificant` either.
---
--- Steps a whole run at a time, not one leaf at a time (unlike `word.lua`'s
--- `_first_nonempty_split`): once a run turns out empty (an
--- `commands.motion.big.enabled = true` run that's entirely a dropped
--- `"skip"` delimiter run, see `subword.split_run`'s docstring) or entirely
--- insignificant (see `_run_is_insignificant` -- checked *before*
--- `subword.split_run` runs at all, since `split_run` has no notion of
--- insignificance of its own and, in the `enabled = false` default, never
--- produces an empty result regardless of a run's content), the next
--- candidate is the leaf right after (or before) that *whole* run --
--- `leaf.next_leaf(run_end)`/`leaf.previous_leaf(run_start)` -- not just the
--- next leaf inside it, since every leaf inside the same run would
--- re-derive the exact same (empty, or insignificant) run again.
---
---@param node TSNode? Where to start looking.
---@param forward boolean Search after `node` (`leaf.next_leaf` off each empty run's end) or
---    before it (`leaf.previous_leaf` off each empty run's start).
---@return TSNode?, treemotion.SubwordUnit[]? # The first nonempty, significant
---    run's *start* leaf, and its units -- both `nil` if none remain.
---
local function _first_nonempty_split(node, forward)
    while node do
        local run_start = leaf.run_start(node)
        local run_end = leaf.run_end(node)

        if not _run_is_insignificant(run_start, run_end) then
            local units = subword.split_run(run_start, run_end)

            if #units > 0 then
                return run_start, units
            end
        end

        node = forward and leaf.next_leaf(run_end) or leaf.previous_leaf(run_start)
    end

    return nil, nil
end

--- Step past the run whose start leaf is `run_start`.
---
---@param run_start TSNode The run's first leaf.
---@return TSNode? # The leaf right after the run's end, if any.
---
local function _after_run(run_start)
    return leaf.next_leaf(leaf.run_end(run_start))
end

return unit.new_source({
    logger = "treemotion._commands.motion.bigword",
    first_nonempty = _first_nonempty_split,
    after = _after_run,
})
