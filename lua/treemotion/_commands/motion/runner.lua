--- The `motion` implementation, independent of `:TreeMotion`'s command-line parsing.
---
--- Maps each motion name to one of `_commands.motion.shape`'s four shapes
--- and a unit family: `w`/`e`/`b`/`ge` move between sub-word units of single
--- treesitter leaves (`_commands.motion.word`), `W`/`E`/`B`/`gE` between
--- contiguous runs of leaves (`_commands.motion.bigword`). Under an operator,
--- a motion with an `operator` entry runs through `_commands.motion.operator`
--- instead.

local logging = require("mega.logging")

local bigword = require("treemotion._commands.motion.bigword")
local operator = require("treemotion._commands.motion.operator")
local position = require("treemotion._commands.motion.position")
local settings = require("treemotion._commands.motion.settings")
local shape = require("treemotion._commands.motion.shape")
local word = require("treemotion._commands.motion.word")

local _LOGGER = logging.get_logger("treemotion._commands.motion.runner")

local M = {}

---@class treemotion._Motion
---@field move treemotion._Move One of `_commands.motion.shape`'s cursor-moving shapes.
---@field step treemotion._Step The position-based step `move` wraps.
---@field operator treemotion._OperatorMove? How the motion runs under an operator,
---    measured with `step` (see `_commands.motion.operator`). `nil` runs `move`
---    unchanged, as for `b`/`B`, which are exclusive in Vim too.
---@field units {new_source: fun(settings: treemotion.SplitSettings): treemotion._UnitSource}
---    `_commands.motion.word` or `_commands.motion.bigword`.
---@field group "small"|"big" Which `commands.motion` group configures `units`.
---@field backward_inclusive boolean? Whether the motion is inclusive while moving
---    backward (`ge`/`gE`), which needs a forced `v` (see `M.operator_keys`).

--- Every motion, by its Vim-facing name (see `constant.MOTION_NAMES`).
---
--- `w`/`W` trim their range under an operator; `e`/`E`/`ge`/`gE` become
--- inclusive, like Vim's.
---
---@type table<string, treemotion._Motion>
local _MOTIONS = {
    w = {
        move = shape.forward_to_start,
        step = shape.next_start,
        operator = operator.forward_to_start,
        units = word,
        group = "small",
    },
    ge = {
        move = shape.backward_to_end,
        step = shape.previous_end,
        operator = operator.inclusive,
        units = word,
        group = "small",
        backward_inclusive = true,
    },
    e = {
        move = shape.forward_to_end,
        step = shape.next_end,
        operator = operator.inclusive,
        units = word,
        group = "small",
    },
    b = { move = shape.backward_to_start, step = shape.previous_start, units = word, group = "small" },
    W = {
        move = shape.forward_to_start,
        step = shape.next_start,
        operator = operator.forward_to_start,
        units = bigword,
        group = "big",
    },
    gE = {
        move = shape.backward_to_end,
        step = shape.previous_end,
        operator = operator.inclusive,
        units = bigword,
        group = "big",
        backward_inclusive = true,
    },
    E = {
        move = shape.forward_to_end,
        step = shape.next_end,
        operator = operator.inclusive,
        units = bigword,
        group = "big",
    },
    B = { move = shape.backward_to_start, step = shape.previous_start, units = bigword, group = "big" },
}

--- Get the motion called `name`.
---
---@param name string The motion's Vim-facing name (`"w"`, `"gE"`, ...).
---@param level integer The `error` level to report an unknown `name` at.
---@return treemotion._Motion
local function _get_motion(name, level)
    local motion = _MOTIONS[name]

    if not motion then
        error(string.format('Unknown treemotion motion "%s".', name), level + 1)
    end

    return motion
end

--- Cancel the pending operator, the way a motion that fails does.
---
--- A `<Cmd>` motion that gives an error cancels the operator. An empty one
--- does that without showing anything or adding to `:messages`.
local function _cancel_operator()
    vim.api.nvim_echo({ { "" } }, false, { err = true })
end

--- The keys an operator-pending `<Plug>` mapping (an `<expr>` one) runs `name` with.
---
--- `dge` must act on the character the operator started from, but the
--- operator-pending text always stops short of it for a motion that moves
--- the cursor backward. So while `commands.motion.operator_pending.inclusive`
--- applies, `ge`/`gE` are forced with `v` (`:help o_v`), which makes them
--- inclusive the same way `dvb` does, without starting Visual mode, and run
--- through `M.run_forced`. Everything else runs as typed.
---
--- The keys don't depend on the cursor, since `.` repeats them as they are.
---
---@param name string The motion's Vim-facing name (`"w"`, `"gE"`, ...).
---@return string # Keys in `:help keycodes` notation.
---
function M.operator_keys(name)
    local motion = _get_motion(name, 2)
    local pending = motion.backward_inclusive and settings.resolve_operator()

    if pending and pending.inclusive then
        return string.format(
            'v<Cmd>lua require("treemotion._commands.motion.runner").run_forced(%q, vim.v.count1)<CR>',
            name
        )
    end

    return string.format('<Cmd>lua require("treemotion").run_motion_%s(vim.v.count1)<CR>', name)
end

--- Run the motion called `name` under an operator `M.operator_keys` forced with `v`.
---
--- The forced motion runs as a plain one (see `settings.resolve_operator`).
--- One that doesn't move would still make the operator act on the
--- character under the cursor, so the operator is cancelled instead, like
--- Vim's `dge` at the start of the buffer.
---
---@param name string The motion's Vim-facing name (`"ge"`, `"gE"`).
---@param count number? A 1-or-more value. How many units to move over.
---
function M.run_forced(name, count)
    local start_row, start_column = position.cursor_position()

    M.run(name, count)

    local end_row, end_column = position.cursor_position()

    if end_row == start_row and end_column == start_column then
        _cancel_operator()
    end
end

--- Run the motion called `name`, logging the cursor's position before and after.
---
--- Every entry point (`treemotion.run_motion_*`, `:TreeMotion motion`, the
--- `<Plug>` mappings) goes through this, so logging here covers all eight
--- motions with one implementation, and reports exactly what a user would
--- want to reproduce a "cursor didn't land where I expected" report: which
--- motion ran, with what `count`, from where, to where.
---
--- The configuration is resolved here, once per motion (see
--- `_commands.motion.settings`), and handed down to the splitter, so a
--- `count` of several units reads it only once.
---
--- In operator-pending mode, with `commands.motion.operator_pending.enabled`,
--- a motion with an `operator` entry runs through it instead (see `_MOTIONS`).
---
---@param name string The motion's Vim-facing name (`"w"`, `"gE"`, ...).
---@param count number? A 1-or-more value. How many units to move over.
---
function M.run(name, count)
    local motion = _get_motion(name, 2)

    count = count or 1

    local start_row, start_column = position.cursor_position()

    _LOGGER:fmt_debug('Running treemotion motion "%s" (count=%s) from %s:%s.', name, count, start_row, start_column)

    local units = motion.units.new_source(settings.resolve(motion.group))
    local pending = motion.operator and settings.resolve_operator()

    if pending then
        motion.operator(units, count, pending, motion.step)
    else
        motion.move(units, count)
    end

    local end_row, end_column = position.cursor_position()

    _LOGGER:fmt_debug('Finished treemotion motion "%s" at %s:%s.', name, end_row, end_column)
end

return M
