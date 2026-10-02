--- Run a motion by name: pick its shape and unit family, or its operator
--- behavior under an operator.

local logging = require("mega.logging")

local operator = require("treemotion._commands.motion.operator")
local position = require("treemotion._commands.motion.position")
local settings = require("treemotion._commands.motion.settings")
local shape = require("treemotion._commands.motion.shape")
local unit = require("treemotion._commands.motion.unit")

local _LOGGER = logging.get_logger("treemotion._commands.motion.runner")

local M = {}

---@class treemotion._Motion
---@field move treemotion._Move
---@field step treemotion._Step
---@field operator treemotion._OperatorMove? `nil` for `b`/`B`, which are exclusive in Vim too.
---@field units fun(settings: treemotion.SplitSettings): treemotion._UnitSource
---@field group "small"|"big"
---@field backward_inclusive boolean? Inclusive while moving backward (`ge`/`gE`).

---@type table<string, treemotion._Motion>
local _MOTIONS = {
    w = {
        move = shape.forward_to_start,
        step = shape.next_start,
        operator = operator.forward_to_start,
        units = unit.word,
        group = "small",
    },
    ge = {
        move = shape.backward_to_end,
        step = shape.previous_end,
        operator = operator.inclusive,
        units = unit.word,
        group = "small",
        backward_inclusive = true,
    },
    e = {
        move = shape.forward_to_end,
        step = shape.next_end,
        operator = operator.inclusive,
        units = unit.word,
        group = "small",
    },
    b = { move = shape.backward_to_start, step = shape.previous_start, units = unit.word, group = "small" },
    W = {
        move = shape.forward_to_start,
        step = shape.next_start,
        operator = operator.forward_to_start,
        units = unit.bigword,
        group = "big",
    },
    gE = {
        move = shape.backward_to_end,
        step = shape.previous_end,
        operator = operator.inclusive,
        units = unit.bigword,
        group = "big",
        backward_inclusive = true,
    },
    E = {
        move = shape.forward_to_end,
        step = shape.next_end,
        operator = operator.inclusive,
        units = unit.bigword,
        group = "big",
    },
    B = { move = shape.backward_to_start, step = shape.previous_start, units = unit.bigword, group = "big" },
}

---@param name string
---@param level integer The `error` level for an unknown `name`.
---@return treemotion._Motion
local function _get_motion(name, level)
    local motion = _MOTIONS[name]

    if not motion then
        error(string.format('Unknown treemotion motion "%s".', name), level + 1)
    end

    return motion
end

--- Cancel the pending operator silently: an empty error from a `<Cmd>`
--- motion cancels it without adding to `:messages`.
local function _cancel_operator()
    vim.api.nvim_echo({ { "" } }, false, { err = true })
end

--- The keys an operator-pending `<expr>` mapping runs `name` with.
---
--- An inclusive `dge` must include the character the operator started on,
--- which no backward cursor move can do, so `ge`/`gE` are forced with `v`
--- (`:help o_v`). The keys don't depend on the cursor, so `.` repeats them.
---
---@param name string
---@return string
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

--- Run a `v`-forced motion from `M.operator_keys`. If it doesn't move, the
--- operator is cancelled, like Vim's `dge` at the start of the buffer.
---
---@param name string
---@param count number?
---
function M.run_forced(name, count)
    local start_row, start_column = position.cursor_position()

    M.run(name, count)

    local end_row, end_column = position.cursor_position()

    if end_row == start_row and end_column == start_column then
        _cancel_operator()
    end
end

--- Run the motion called `name`. Every entry point goes through here.
---
---@param name string `"w"`, `"gE"`, ...
---@param count number?
---
function M.run(name, count)
    local motion = _get_motion(name, 2)

    count = count or 1

    local start_row, start_column = position.cursor_position()

    _LOGGER:fmt_debug('Running treemotion motion "%s" (count=%s) from %s:%s.', name, count, start_row, start_column)

    local units = motion.units(settings.resolve(motion.group))
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
