--- Make sure `_commands.motion.operator`'s range calculation follows its rules.
---
--- These call `operator.forward_range`/`operator.inclusive_range` and the
--- forward range's steps (`operator.trim_skipped_text`,
--- `operator.stop_at_line_end`, `operator.balance_brackets`) directly
--- with a hand-built `treemotion.OperatorSettings`, motion or range, so
--- they need neither operator-pending mode nor the global configuration. A few branches no
--- bundled grammar or real step reaches get a wrapped unit source or a
--- stand-in step instead.
---
--- Ranges are measured from a position, not the cursor: the cursor stays at
--- the buffer's start, and every measurement checks it's never moved.
--- `operator_pending_spec.lua` covers the same rules end to end, through
--- the `<Plug>` mappings.

local grammar_helpers = require("treemotion.grammar_helpers")
local operator = require("treemotion._commands.motion.operator")
local settings = require("treemotion._commands.motion.settings")
local bigword = require("treemotion._commands.motion.bigword")
local shape = require("treemotion._commands.motion.shape")
local word = require("treemotion._commands.motion.word")

---@type integer?
local _BUFFER

--- Where the operator starts in `_BUFFER`.
---
---@type integer[]
local _START = { 0, 0 }

--- Start a Lua buffer holding `lines`, with the operator starting at `row`/`column`.
---
--- The cursor stays at the buffer's start, since ranges never read it.
---
---@param lines string[]
---@param row integer 0-indexed row.
---@param column integer 0-indexed column.
local function _initialize_buffer(lines, row, column)
    _BUFFER = grammar_helpers.new_buffer("lua", lines)
    _START = { row, column }
end

--- Fail unless the cursor is still at the buffer's start.
local function _assert_cursor_untouched()
    assert.same({ 0, 0 }, { grammar_helpers.get_cursor() })
end

--- `operator.forward_range` from `_START`, checking it leaves the cursor alone.
---
---@param units treemotion._UnitSource
---@param count integer
---@param pending treemotion.OperatorSettings
---@param step treemotion._Step
---@return treemotion.OperatorRange
local function _forward_range(units, count, pending, step)
    local range = operator.forward_range(units, _START[1], _START[2], count, pending, step)

    _assert_cursor_untouched()

    return range
end

--- `operator.inclusive_range` from `_START`, checking it leaves the cursor alone.
---
---@param units treemotion._UnitSource
---@param count integer
---@param pending treemotion.OperatorSettings
---@param step treemotion._Step
---@return treemotion.OperatorRange
local function _inclusive_range(units, count, pending, step)
    local range = operator.inclusive_range(units, _START[1], _START[2], count, pending, step)

    _assert_cursor_untouched()

    return range
end

--- A `w`/`e`/`b`/`ge` unit source, with `insignificant` as Lua's insignificant leaves.
---
---@param insignificant string[]?
---@return treemotion._UnitSource
local function _units(insignificant)
    local split = settings.resolve("small")
    split.insignificant_characters = insignificant

    return word.new_source(split)
end

--- A `W`/`E`/`B`/`gE` unit source that splits on `_` but skips it.
---
--- The `W` defaults don't split at all, which would leave nothing for the
--- trimming rules to tell apart.
---
---@return treemotion._UnitSource
local function _big_units()
    local split = settings.resolve("big")
    split.enabled = true
    split.code = vim.tbl_extend("force", split.code, { snake_case = "skip" })

    return bigword.new_source(split)
end

--- `units`, except that every unit's span ends at the start of the next row.
---
--- Some grammars end a leaf there (its trailing newline). The bundled
--- parsers don't, so this fakes one. Each unit is wrapped rather than
--- edited, so its own methods still run.
---
---@param units treemotion._UnitSource
---@return treemotion._UnitSource
local function _span_to_next_row(units)
    local function wrap(unit)
        if not unit then
            return nil
        end

        return setmetatable({
            span_end = function()
                local row = unit:end_()

                return row + 1, 0
            end,
        }, { __index = unit })
    end

    return setmetatable({
        unit_at = function(row, column, forward)
            local unit, start_leaf = units.unit_at(row, column, forward)

            return wrap(unit), start_leaf
        end,
    }, { __index = units })
end

--- `units`, except that no leaf ever covers the position.
---
--- Skipped text is normally measured to the end of the leaf at the
--- position. This leaves only the character itself to measure, which the
--- bundled parsers never do.
---
---@param units treemotion._UnitSource
---@return treemotion._UnitSource
local function _without_cursor_leaf(units)
    return setmetatable({
        unit_at = function(row, column, forward)
            return (units.unit_at(row, column, forward)), nil
        end,
    }, { __index = units })
end

--- A step that lands at `row`/`column`, wherever it started.
---
--- For the branches no real step reaches: a step that stops where no unit
--- follows, or one that goes nowhere.
---
---@param row integer 0-indexed row.
---@param column integer 0-indexed column.
---@return treemotion._Step
local function _step_to(row, column)
    return function()
        return row, column
    end
end

--- A `treemotion.OperatorSettings` for `d`, with `overrides` applied.
---
---@param overrides table?
---@return treemotion.OperatorSettings
local function _settings(overrides)
    return vim.tbl_extend("force", {
        skipped_text = "keep_between_tokens",
        stop_at_line_end = true,
        inclusive = true,
        change = false,
        change_to_end = false,
    }, overrides or {})
end

--- A range as a plain list, for `assert.same`: `{ start, finish, inclusive }`.
---
---@param range treemotion.OperatorRange
---@return table
local function _flat(range)
    return {
        { range.start_row, range.start_column },
        { range.finish_row, range.finish_column },
        range.inclusive,
    }
end

--- A `treemotion.OperatorMotion` from `start` to `target`, its last unit ending at `tail`.
---
---@param start integer[] 0-indexed row and column.
---@param tail integer[]
---@param target integer[]
---@param token_end integer[]? `tail`, unless given.
---@return treemotion.OperatorMotion
local function _motion(start, tail, target, token_end)
    token_end = token_end or tail

    return {
        start_row = start[1],
        start_column = start[2],
        tail_row = tail[1],
        tail_column = tail[2],
        token_end_row = token_end[1],
        token_end_column = token_end[2],
        target_row = target[1],
        target_column = target[2],
    }
end

--- A range from `start` to `finish`, for the steps that take one.
---
---@param start integer[] 0-indexed row and column.
---@param finish integer[]
---@param inclusive boolean
---@return treemotion.OperatorRange
local function _range(start, finish, inclusive)
    return {
        start_row = start[1],
        start_column = start[2],
        finish_row = finish[1],
        finish_column = finish[2],
        inclusive = inclusive,
    }
end

describe("operator range calculation", function()
    after_each(function()
        grammar_helpers.remove_buffer(_BUFFER)
        _BUFFER = nil
    end)

    describe("forward_range", function()
        it("ends at the first non-blank character after the unit when skipped text is kept", function()
            _initialize_buffer({ "local foo = bar" }, 0, 6)

            local range = _forward_range(_units({ "=" }), 1, _settings(), shape.next_start)

            assert.same({ { 0, 6 }, { 0, 10 }, false }, _flat(range))
        end)

        it("keeps the plain motion's range with #delete", function()
            _initialize_buffer({ "local foo = bar" }, 0, 6)

            local range = _forward_range(_units({ "=" }), 1, _settings({ skipped_text = "delete" }), shape.next_start)

            assert.same({ { 0, 6 }, { 0, 12 }, false }, _flat(range))
        end)

        it("includes delimiters inside the token with #keep_between_tokens", function()
            _initialize_buffer({ "local foo_bar = 1" }, 0, 6)

            local range = _forward_range(_units(), 1, _settings(), shape.next_start)

            assert.same({ { 0, 6 }, { 0, 10 }, false }, _flat(range))
        end)

        it("stops before delimiters inside the token with #keep", function()
            _initialize_buffer({ "local foo_bar = 1" }, 0, 6)

            local range = _forward_range(_units(), 1, _settings({ skipped_text = "keep" }), shape.next_start)

            assert.same({ { 0, 6 }, { 0, 9 }, false }, _flat(range))
        end)

        it("covers skipped text under the cursor and the blanks after it", function()
            _initialize_buffer({ "local foo = bar" }, 0, 10)

            local range = _forward_range(_units({ "=" }), 1, _settings(), shape.next_start)

            assert.same({ { 0, 10 }, { 0, 12 }, false }, _flat(range))
        end)

        it("ends at the end of the line with #stop_at_line_end", function()
            _initialize_buffer({ "local x = foo  ", "  local y = 2" }, 0, 10)

            local range = _forward_range(_units(), 1, _settings(), shape.next_start)

            assert.same({ { 0, 10 }, { 0, 15 }, false }, _flat(range))
        end)

        it("crosses the line break without #stop_at_line_end", function()
            _initialize_buffer({ "local x = foo", "  local y = 2" }, 0, 10)

            local range = _forward_range(_units(), 1, _settings({ stop_at_line_end = false }), shape.next_start)

            assert.same({ { 0, 10 }, { 1, 2 }, false }, _flat(range))
        end)

        it("covers an empty line's line break, but nothing for #change", function()
            _initialize_buffer({ "local x = foo", "", "  local y = 2" }, 1, 0)

            local delete = _forward_range(_units(), 1, _settings(), shape.next_start)

            assert.same({ { 1, 0 }, { 1, 0 }, true }, _flat(delete))

            local change = _forward_range(_units(), 1, _settings({ change = true }), shape.next_start)

            assert.same({ { 1, 0 }, { 1, 0 }, false }, _flat(change))
        end)

        it("ends at the unit's last character for #change_to_end", function()
            _initialize_buffer({ "local fooBar = 1" }, 0, 6)

            local range =
                _forward_range(_units(), 1, _settings({ change = true, change_to_end = true }), shape.next_start)

            assert.same({ { 0, 6 }, { 0, 8 }, true }, _flat(range))
        end)

        it("only trims after the final step of a count", function()
            _initialize_buffer({ "local a, b, c = 1" }, 0, 6)

            local range = _forward_range(_units({ "=", "," }), 2, _settings(), shape.next_start)

            assert.same({ { 0, 6 }, { 0, 10 }, false }, _flat(range))
        end)

        it("still covers the last unit when a count runs out of units", function()
            _initialize_buffer({ "local x = foo" }, 0, 8)

            local range = _forward_range(_units(), 5, _settings(), shape.next_start)

            assert.same({ { 0, 8 }, { 0, 13 }, false }, _flat(range))
        end)
        it("keeps the plain motion's range without a parser", function()
            _BUFFER = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(_BUFFER, 0, -1, false, { "foo bar" })
            vim.api.nvim_set_current_buf(_BUFFER)
            _START = { 0, 0 }

            local range = _forward_range(_units(), 1, _settings(), shape.next_start)

            assert.same({ { 0, 0 }, { 0, 0 }, false }, _flat(range))
        end)

        it("runs to the end of the line when a count's first steps leave no unit ahead", function()
            _initialize_buffer({ "local x = foo  " }, 0, 10)

            local range = _forward_range(_units(), 2, _settings(), _step_to(0, 14))

            assert.same({ { 0, 10 }, { 0, 15 }, false }, _flat(range))
        end)

        describe("at the end of the buffer", function()
            -- Expected ranges match Neovim's built-in `dw`/`cw` on the same text.

            it("covers the last unit and the blanks after it", function()
                _initialize_buffer({ "x = foo  " }, 0, 4)

                local range = _forward_range(_units(), 1, _settings(), shape.next_start)

                assert.same({ { 0, 4 }, { 0, 9 }, false }, _flat(range))
            end)

            it("covers trailing blanks", function()
                _initialize_buffer({ "local x = foo  " }, 0, 13)

                local range = _forward_range(_units(), 1, _settings(), shape.next_start)

                assert.same({ { 0, 13 }, { 0, 15 }, false }, _flat(range))
            end)

            it("covers trailing blanks inside a comment", function()
                _initialize_buffer({ "-- c  " }, 0, 5)

                local range = _forward_range(_units(), 1, _settings(), shape.next_start)

                assert.same({ { 0, 5 }, { 0, 6 }, false }, _flat(range))
            end)

            it("covers trailing blanks on a later line", function()
                _initialize_buffer({ "local x = foo =  ", "  " }, 1, 1)

                local range = _forward_range(_units({ "=" }), 1, _settings(), shape.next_start)

                assert.same({ { 1, 1 }, { 1, 2 }, false }, _flat(range))
            end)

            it("covers skipped text and the blanks after it", function()
                _initialize_buffer({ "local x = foo =  " }, 0, 14)

                local range = _forward_range(_units({ "=" }), 1, _settings(), shape.next_start)

                assert.same({ { 0, 14 }, { 0, 17 }, false }, _flat(range))
            end)

            it("covers the rest of the line for a count past the last unit", function()
                _initialize_buffer({ "x = foo  bar" }, 0, 4)

                local range = _forward_range(_units(), 3, _settings(), shape.next_start)

                assert.same({ { 0, 4 }, { 0, 12 }, false }, _flat(range))
            end)

            it("covers only skipped text for #change_to_end", function()
                _initialize_buffer({ "local x = foo ==  " }, 0, 14)

                local range = _forward_range(
                    _units({ "==" }),
                    1,
                    _settings({ change = true, change_to_end = true }),
                    shape.next_start
                )

                assert.same({ { 0, 14 }, { 0, 15 }, true }, _flat(range))
            end)

            it("is empty on an empty last line", function()
                _initialize_buffer({ "local x = foo", "" }, 1, 0)

                local range = _forward_range(_units(), 1, _settings(), shape.next_start)

                assert.same({ { 1, 0 }, { 1, 0 }, false }, _flat(range))
            end)
        end)

        it("clamps a span that ends on the next row to the unit's own line", function()
            _initialize_buffer({ "local x = foo  ", "local y" }, 0, 10)

            local range = _forward_range(_span_to_next_row(_units()), 1, _settings(), shape.next_start)

            assert.same({ { 0, 10 }, { 0, 15 }, false }, _flat(range))
        end)

        it("crosses blank lines to the next unit without #stop_at_line_end", function()
            _initialize_buffer({ "local x = foo", "", "  ", "local y" }, 0, 10)

            local range = _forward_range(_units(), 1, _settings({ stop_at_line_end = false }), shape.next_start)

            assert.same({ { 0, 10 }, { 3, 0 }, false }, _flat(range))
        end)

        it("stops at skipped text on the next line without #stop_at_line_end", function()
            _initialize_buffer({ "local x = foo", "  = local y" }, 0, 10)

            local range = _forward_range(_units({ "=" }), 1, _settings({ stop_at_line_end = false }), shape.next_start)

            assert.same({ { 0, 10 }, { 1, 2 }, false }, _flat(range))
        end)

        it("ends at skipped text's last character for #change_to_end", function()
            _initialize_buffer({ "local foo == bar" }, 0, 10)

            local range = _forward_range(
                _units({ "==" }),
                1,
                _settings({ change = true, change_to_end = true }),
                shape.next_start
            )

            assert.same({ { 0, 10 }, { 0, 11 }, true }, _flat(range))
        end)

        it("steps like #e for a count with #change_to_end", function()
            _initialize_buffer({ "local fooBar = baz" }, 0, 6)

            local range =
                _forward_range(_units(), 2, _settings({ change = true, change_to_end = true }), shape.next_start)

            assert.same({ { 0, 6 }, { 0, 11 }, true }, _flat(range))
        end)

        it("trims like #dw on blanks with #change_to_end", function()
            _initialize_buffer({ "local x = foo  bar" }, 0, 13)

            local range =
                _forward_range(_units(), 1, _settings({ change = true, change_to_end = true }), shape.next_start)

            assert.same({ { 0, 13 }, { 0, 15 }, false }, _flat(range))
        end)

        it("covers a multibyte unit and the blanks after it", function()
            _initialize_buffer({ "-- foo — bar" }, 0, 7)

            local range = _forward_range(_units(), 1, _settings(), shape.next_start)

            assert.same({ { 0, 7 }, { 0, 11 }, false }, _flat(range))
        end)

        it("measures a multibyte skipped character by its width when no leaf covers it", function()
            _initialize_buffer({ "local x = a ≠ b" }, 0, 12)

            local range = _forward_range(_without_cursor_leaf(_units({ "≠" })), 1, _settings(), shape.next_start)

            assert.same({ { 0, 12 }, { 0, 16 }, false }, _flat(range))
        end)

        it("ends at a multibyte unit's first byte for #change_to_end", function()
            _initialize_buffer({ "-- foo — bar" }, 0, 7)

            local range =
                _forward_range(_units(), 1, _settings({ change = true, change_to_end = true }), shape.next_start)

            assert.same({ { 0, 7 }, { 0, 7 }, true }, _flat(range))
        end)

        describe("W", function()
            it("includes delimiters inside the run with #keep_between_tokens", function()
                _initialize_buffer({ "local x = foo_bar_ + 1" }, 0, 10)

                local range = _forward_range(_big_units(), 1, _settings(), shape.next_start)

                assert.same({ { 0, 10 }, { 0, 14 }, false }, _flat(range))
            end)

            it("stops before delimiters inside the run with #keep", function()
                _initialize_buffer({ "local x = foo_bar_ + 1" }, 0, 10)

                local range = _forward_range(_big_units(), 1, _settings({ skipped_text = "keep" }), shape.next_start)

                assert.same({ { 0, 10 }, { 0, 13 }, false }, _flat(range))
            end)

            it("covers a skipped run under the cursor and the blanks after it", function()
                _initialize_buffer({ "local x = a == b" }, 0, 12)

                local range = _forward_range(_big_units(), 1, _settings(), shape.next_start)

                assert.same({ { 0, 12 }, { 0, 15 }, false }, _flat(range))
            end)
        end)
    end)

    describe("trim_skipped_text", function()
        it("ends at the first non-blank character after the tail with #keep", function()
            _initialize_buffer({ "local foo = bar" }, 0, 6)

            local range = operator.trim_skipped_text(_motion({ 0, 6 }, { 0, 9 }, { 0, 12 }), "keep")

            assert.same({ { 0, 6 }, { 0, 10 }, false }, _flat(range))
        end)

        it("doesn't trim with #delete", function()
            _initialize_buffer({ "local foo = bar" }, 0, 6)

            local range = operator.trim_skipped_text(_motion({ 0, 6 }, { 0, 9 }, { 0, 12 }), "delete")

            assert.same({ { 0, 6 }, { 0, 12 }, false }, _flat(range))
        end)

        it("measures from the token's end with #keep_between_tokens", function()
            _initialize_buffer({ "local foo_bar = 1" }, 0, 6)

            local motion = _motion({ 0, 6 }, { 0, 9 }, { 0, 10 }, { 0, 13 })

            assert.same(
                { { 0, 6 }, { 0, 10 }, false },
                _flat(operator.trim_skipped_text(motion, "keep_between_tokens"))
            )
            assert.same({ { 0, 6 }, { 0, 9 }, false }, _flat(operator.trim_skipped_text(motion, "keep")))
        end)

        it("keeps the motion's range rather than emptying it", function()
            _initialize_buffer({ "local foo = bar" }, 0, 10)

            local range = operator.trim_skipped_text(_motion({ 0, 10 }, { 0, 10 }, { 0, 12 }), "keep")

            assert.same({ { 0, 10 }, { 0, 12 }, false }, _flat(range))
        end)
    end)

    describe("stop_at_line_end", function()
        it("ends a range that runs onto a later line at the end of the tail's line", function()
            _initialize_buffer({ "local x = foo  ", "  local y = 2" }, 0, 10)

            local motion = _motion({ 0, 10 }, { 0, 13 }, { 1, 2 })
            local range = operator.stop_at_line_end(motion, _range({ 0, 10 }, { 1, 2 }, false), false)

            assert.same({ { 0, 10 }, { 0, 15 }, false }, _flat(range))
        end)

        it("leaves a range on the tail's line alone", function()
            _initialize_buffer({ "local x = foo  ", "  local y = 2" }, 0, 6)

            local motion = _motion({ 0, 6 }, { 0, 7 }, { 0, 8 })
            local range = operator.stop_at_line_end(motion, _range({ 0, 6 }, { 0, 8 }, false), false)

            assert.same({ { 0, 6 }, { 0, 8 }, false }, _flat(range))
        end)

        it("covers an empty line's line break, but nothing for #change", function()
            _initialize_buffer({ "local x = foo", "", "  local y = 2" }, 1, 0)

            local motion = _motion({ 1, 0 }, { 1, 0 }, { 2, 2 })
            local range = _range({ 1, 0 }, { 2, 2 }, false)

            assert.same({ { 1, 0 }, { 1, 0 }, true }, _flat(operator.stop_at_line_end(motion, range, false)))
            assert.same({ { 1, 0 }, { 1, 0 }, false }, _flat(operator.stop_at_line_end(motion, range, true)))
        end)

        it("keeps the motion's range rather than emptying it", function()
            _initialize_buffer({ "local x = foo  ", "  local y = 2" }, 0, 15)

            local motion = _motion({ 0, 15 }, { 0, 15 }, { 1, 2 })
            local range = operator.stop_at_line_end(motion, _range({ 0, 15 }, { 1, 2 }, false), false)

            assert.same({ { 0, 15 }, { 1, 2 }, false }, _flat(range))
        end)
    end)

    describe("balance_brackets", function()
        it("ends an exclusive range before a closing bracket it didn't open", function()
            _initialize_buffer({ "f(config.lib)" }, 0, 2)

            local range = operator.balance_brackets(_range({ 0, 2 }, { 0, 13 }, false))

            assert.same({ { 0, 2 }, { 0, 12 }, false }, _flat(range))
        end)

        it("ends an inclusive range on the character before that bracket", function()
            _initialize_buffer({ "f(config.lib)" }, 0, 2)

            local range = operator.balance_brackets(_range({ 0, 2 }, { 0, 12 }, true))

            assert.same({ { 0, 2 }, { 0, 11 }, true }, _flat(range))
        end)

        it("keeps a range that opens its brackets", function()
            _initialize_buffer({ "f(config.lib)" }, 0, 1)

            local range = operator.balance_brackets(_range({ 0, 1 }, { 0, 13 }, false))

            assert.same({ { 0, 1 }, { 0, 13 }, false }, _flat(range))
        end)

        it("keeps an inclusive range on an empty line", function()
            _initialize_buffer({ "local x = foo", "", "  local y = 2" }, 1, 0)

            local range = operator.balance_brackets(_range({ 1, 0 }, { 1, 0 }, true))

            assert.same({ { 1, 0 }, { 1, 0 }, true }, _flat(range))
        end)
    end)

    describe("inclusive_range", function()
        it("includes both ends of #e", function()
            _initialize_buffer({ "local fooBar = 1" }, 0, 6)

            local range = _inclusive_range(_units(), 1, _settings(), shape.next_end)

            assert.same({ { 0, 6 }, { 0, 8 }, true }, _flat(range))
        end)

        it("keeps a backward #ge range exclusive", function()
            -- The `<Plug>` mapping forces `dge` inclusive with `v` instead.
            _initialize_buffer({ "local fooBar = 1" }, 0, 11)

            local range = _inclusive_range(_units(), 1, _settings(), shape.previous_end)

            assert.same({ { 0, 11 }, { 0, 8 }, false }, _flat(range))
        end)

        it("stays exclusive with #inclusive = false", function()
            _initialize_buffer({ "local fooBar = 1" }, 0, 6)

            local range = _inclusive_range(_units(), 1, _settings({ inclusive = false }), shape.next_end)

            assert.same({ { 0, 6 }, { 0, 8 }, false }, _flat(range))
        end)

        it("is empty when the motion doesn't move", function()
            _initialize_buffer({ "foo" }, 0, 2)

            local range = _inclusive_range(_units(), 1, _settings(), shape.next_end)

            assert.same({ { 0, 2 }, { 0, 2 }, false }, _flat(range))
        end)

        it("steps a count like #e", function()
            _initialize_buffer({ "local fooBar = 1" }, 0, 6)

            local range = _inclusive_range(_units(), 2, _settings(), shape.next_end)

            assert.same({ { 0, 6 }, { 0, 11 }, true }, _flat(range))
        end)

        it("spans lines for #e", function()
            _initialize_buffer({ "local foo", "local bar" }, 0, 8)

            local range = _inclusive_range(_units(), 1, _settings(), shape.next_end)

            assert.same({ { 0, 8 }, { 1, 4 }, true }, _flat(range))
        end)

        it("keeps a backward #ge range across lines exclusive", function()
            _initialize_buffer({ "local foo", "local bar" }, 1, 2)

            local range = _inclusive_range(_units(), 1, _settings(), shape.previous_end)

            assert.same({ { 1, 2 }, { 0, 8 }, false }, _flat(range))
        end)
    end)
end)
