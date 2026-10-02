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
---@field move treemotion._Move One of `_commands.motion.shape`'s shapes.
---@field operator treemotion._OperatorMove? How `move` runs under an operator (see
---    `_commands.motion.operator`). `nil` runs `move` unchanged, as for `b`/`B`,
---    which are exclusive in Vim too.
---@field units {new_source: fun(settings: treemotion.SplitSettings): treemotion._UnitSource}
---    `_commands.motion.word` or `_commands.motion.bigword`.
---@field group "small"|"big" Which `commands.motion` group configures `units`.
---@field backward_inclusive boolean? Whether the motion is inclusive while moving
---    backward (`ge`/`gE`), which needs a forced `v` (see `M.force`).

--- Every motion, by its Vim-facing name (see `constant.MOTION_NAMES`).
---
--- `w`/`W` trim their range under an operator; `e`/`E`/`ge`/`gE` become
--- inclusive, like Vim's.
---
---@type table<string, treemotion._Motion>
local _MOTIONS = {
    w = { move = shape.forward_to_start, operator = operator.forward_to_start, units = word, group = "small" },
    ge = {
        move = shape.backward_to_end,
        operator = operator.inclusive,
        units = word,
        group = "small",
        backward_inclusive = true,
    },
    e = { move = shape.forward_to_end, operator = operator.inclusive, units = word, group = "small" },
    b = { move = shape.backward_to_start, units = word, group = "small" },
    W = { move = shape.forward_to_start, operator = operator.forward_to_start, units = bigword, group = "big" },
    gE = {
        move = shape.backward_to_end,
        operator = operator.inclusive,
        units = bigword,
        group = "big",
        backward_inclusive = true,
    },
    E = { move = shape.forward_to_end, operator = operator.inclusive, units = bigword, group = "big" },
    B = { move = shape.backward_to_start, units = bigword, group = "big" },
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

--- The motion-type key (`:help o_v`) to type before the motion called `name`.
---
--- `dge` must act on the character the operator started from, but the
--- operator-pending text always stops short of it for a motion that moves
--- the cursor backward. Forcing the motion with `v` makes it inclusive
--- instead, the same way `dvb` does, without starting Visual mode. The
--- motion then runs as a plain one (see `settings.resolve_operator`).
---
--- Only for `ge`/`gE`, while `commands.motion.operator_pending.inclusive`
--- applies and the motion would move: a motion that doesn't move must leave
--- an empty range, not the character under the cursor. Finding out moves
--- the cursor, so this is meant for an `<expr>` mapping, after which Vim
--- puts the cursor back (`:help map-expr`); the view is restored here.
---
---@param name string The motion's Vim-facing name (`"w"`, `"gE"`, ...).
---@param count number? A 1-or-more value. How many units to move over.
---@return string # `"v"`, or `""` when the motion needs no forcing.
---
function M.force(name, count)
    local motion = _get_motion(name, 2)

    if not motion.backward_inclusive then
        return ""
    end

    local pending = settings.resolve_operator()

    if not pending or not pending.inclusive then
        return ""
    end

    local view = vim.fn.winsaveview()
    local start_row, start_column = position.cursor_position()
    local ok, result = pcall(motion.move, motion.units.new_source(settings.resolve(motion.group)), count or 1)
    local end_row, end_column = position.cursor_position()

    vim.fn.winrestview(view)

    if not ok then
        error(result, 0)
    end

    if end_row == start_row and end_column == start_column then
        return ""
    end

    return "v"
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
        motion.operator(units, count, pending, motion.move)
    else
        motion.move(units, count)
    end

    local end_row, end_column = position.cursor_position()

    _LOGGER:fmt_debug('Finished treemotion motion "%s" at %s:%s.', name, end_row, end_column)
end

return M
