--- Make sure `_commands.motion.operator`'s range calculation follows its rules.
---
--- These call `operator.forward_range`/`operator.inclusive_range` directly
--- with a hand-built `treemotion.OperatorSettings`, so they need neither
--- operator-pending mode nor the global configuration. A few branches no
--- bundled grammar or real move reaches get a wrapped unit source or a
--- stand-in move instead.
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

--- Start a Lua buffer holding `lines`, with the cursor at `row`/`column`.
---
---@param lines string[]
---@param row integer 0-indexed row.
---@param column integer 0-indexed column.
local function _initialize_buffer(lines, row, column)
    _BUFFER = grammar_helpers.new_buffer("lua", lines)
    grammar_helpers.set_cursor(row, column)
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
        current_unit = function(forward)
            local unit, cursor_leaf = units.current_unit(forward)

            return wrap(unit), cursor_leaf
        end,
    }, { __index = units })
end

--- `units`, except that no leaf ever covers the cursor.
---
--- Skipped text is normally measured to the end of the leaf under the
--- cursor. This leaves only the character itself to measure, which the
--- bundled parsers never do.
---
---@param units treemotion._UnitSource
---@return treemotion._UnitSource
local function _without_cursor_leaf(units)
    return setmetatable({
        current_unit = function(forward)
            return (units.current_unit(forward)), nil
        end,
    }, { __index = units })
end

--- A move that puts the cursor at `row`/`column`, wherever it started.
---
--- For the branches no real move reaches: a step that stops where no unit
--- follows, or one that goes nowhere.
---
---@param row integer 0-indexed row.
---@param column integer 0-indexed column.
---@return treemotion._Move
local function _move_to(row, column)
    return function()
        grammar_helpers.set_cursor(row, column)
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

describe("operator range calculation", function()
    after_each(function()
        grammar_helpers.remove_buffer(_BUFFER)
        _BUFFER = nil
    end)

    describe("forward_range", function()
        it("ends at the first non-blank character after the unit when skipped text is kept", function()
            _initialize_buffer({ "local foo = bar" }, 0, 6)

            local range = operator.forward_range(_units({ "=" }), 1, _settings(), shape.forward_to_start)

            assert.same({ { 0, 6 }, { 0, 10 }, false }, _flat(range))
        end)

        it("keeps the plain motion's range with #delete", function()
            _initialize_buffer({ "local foo = bar" }, 0, 6)

            local range = operator.forward_range(
                _units({ "=" }),
                1,
                _settings({ skipped_text = "delete" }),
                shape.forward_to_start
            )

            assert.same({ { 0, 6 }, { 0, 12 }, false }, _flat(range))
        end)

        it("includes delimiters inside the token with #keep_between_tokens", function()
            _initialize_buffer({ "local foo_bar = 1" }, 0, 6)

            local range = operator.forward_range(_units(), 1, _settings(), shape.forward_to_start)

            assert.same({ { 0, 6 }, { 0, 10 }, false }, _flat(range))
        end)

        it("stops before delimiters inside the token with #keep", function()
            _initialize_buffer({ "local foo_bar = 1" }, 0, 6)

            local range =
                operator.forward_range(_units(), 1, _settings({ skipped_text = "keep" }), shape.forward_to_start)

            assert.same({ { 0, 6 }, { 0, 9 }, false }, _flat(range))
        end)

        it("covers skipped text under the cursor and the blanks after it", function()
            _initialize_buffer({ "local foo = bar" }, 0, 10)

            local range = operator.forward_range(_units({ "=" }), 1, _settings(), shape.forward_to_start)

            assert.same({ { 0, 10 }, { 0, 12 }, false }, _flat(range))
        end)

        it("ends at the end of the line with #stop_at_line_end", function()
            _initialize_buffer({ "local x = foo  ", "  local y = 2" }, 0, 10)

            local range = operator.forward_range(_units(), 1, _settings(), shape.forward_to_start)

            assert.same({ { 0, 10 }, { 0, 15 }, false }, _flat(range))
        end)

        it("crosses the line break without #stop_at_line_end", function()
            _initialize_buffer({ "local x = foo", "  local y = 2" }, 0, 10)

            local range =
                operator.forward_range(_units(), 1, _settings({ stop_at_line_end = false }), shape.forward_to_start)

            assert.same({ { 0, 10 }, { 1, 2 }, false }, _flat(range))
        end)

        it("covers an empty line's line break, but nothing for #change", function()
            _initialize_buffer({ "local x = foo", "", "  local y = 2" }, 1, 0)

            local delete = operator.forward_range(_units(), 1, _settings(), shape.forward_to_start)

            assert.same({ { 1, 0 }, { 1, 0 }, true }, _flat(delete))

            grammar_helpers.set_cursor(1, 0)

            local change = operator.forward_range(_units(), 1, _settings({ change = true }), shape.forward_to_start)

            assert.same({ { 1, 0 }, { 1, 0 }, false }, _flat(change))
        end)

        it("ends at the unit's last character for #change_to_end", function()
            _initialize_buffer({ "local fooBar = 1" }, 0, 6)

            local range = operator.forward_range(
                _units(),
                1,
                _settings({ change = true, change_to_end = true }),
                shape.forward_to_start
            )

            assert.same({ { 0, 6 }, { 0, 8 }, true }, _flat(range))
        end)

        it("only trims after the final step of a count", function()
            _initialize_buffer({ "local a, b, c = 1" }, 0, 6)

            local range = operator.forward_range(_units({ "=", "," }), 2, _settings(), shape.forward_to_start)

            assert.same({ { 0, 6 }, { 0, 10 }, false }, _flat(range))
        end)

        it("still covers the last unit when a count runs out of units", function()
            _initialize_buffer({ "local x = foo" }, 0, 8)

            local range = operator.forward_range(_units(), 5, _settings(), shape.forward_to_start)

            assert.same({ { 0, 8 }, { 0, 13 }, false }, _flat(range))
        end)
        it("keeps the plain motion's range without a parser", function()
            _BUFFER = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(_BUFFER, 0, -1, false, { "foo bar" })
            vim.api.nvim_set_current_buf(_BUFFER)
            grammar_helpers.set_cursor(0, 0)

            local range = operator.forward_range(_units(), 1, _settings(), shape.forward_to_start)

            assert.same({ { 0, 0 }, { 0, 0 }, false }, _flat(range))
        end)

        it("keeps the plain motion's range when a count's first steps leave no unit ahead", function()
            _initialize_buffer({ "local x = foo  " }, 0, 10)

            local range = operator.forward_range(_units(), 2, _settings(), _move_to(0, 14))

            assert.same({ { 0, 10 }, { 0, 14 }, false }, _flat(range))
        end)

        it("keeps the plain motion's range when a step from outside every unit goes nowhere", function()
            _initialize_buffer({ "local foo = bar" }, 0, 10)

            local range = operator.forward_range(_units({ "=" }), 1, _settings(), _move_to(0, 10))

            assert.same({ { 0, 10 }, { 0, 10 }, false }, _flat(range))
        end)

        it("clamps a span that ends on the next row to the unit's own line", function()
            _initialize_buffer({ "local x = foo  ", "local y" }, 0, 10)

            local range = operator.forward_range(_span_to_next_row(_units()), 1, _settings(), shape.forward_to_start)

            assert.same({ { 0, 10 }, { 0, 15 }, false }, _flat(range))
        end)

        it("crosses blank lines to the next unit without #stop_at_line_end", function()
            _initialize_buffer({ "local x = foo", "", "  ", "local y" }, 0, 10)

            local range =
                operator.forward_range(_units(), 1, _settings({ stop_at_line_end = false }), shape.forward_to_start)

            assert.same({ { 0, 10 }, { 3, 0 }, false }, _flat(range))
        end)

        it("stops at skipped text on the next line without #stop_at_line_end", function()
            _initialize_buffer({ "local x = foo", "  = local y" }, 0, 10)

            local range = operator.forward_range(
                _units({ "=" }),
                1,
                _settings({ stop_at_line_end = false }),
                shape.forward_to_start
            )

            assert.same({ { 0, 10 }, { 1, 2 }, false }, _flat(range))
        end)

        it("ends at skipped text's last character for #change_to_end", function()
            _initialize_buffer({ "local foo == bar" }, 0, 10)

            local range = operator.forward_range(
                _units({ "==" }),
                1,
                _settings({ change = true, change_to_end = true }),
                shape.forward_to_start
            )

            assert.same({ { 0, 10 }, { 0, 11 }, true }, _flat(range))
        end)

        it("steps like #e for a count with #change_to_end", function()
            _initialize_buffer({ "local fooBar = baz" }, 0, 6)

            local range = operator.forward_range(
                _units(),
                2,
                _settings({ change = true, change_to_end = true }),
                shape.forward_to_start
            )

            assert.same({ { 0, 6 }, { 0, 11 }, true }, _flat(range))
        end)

        it("trims like #dw on blanks with #change_to_end", function()
            _initialize_buffer({ "local x = foo  bar" }, 0, 13)

            local range = operator.forward_range(
                _units(),
                1,
                _settings({ change = true, change_to_end = true }),
                shape.forward_to_start
            )

            assert.same({ { 0, 13 }, { 0, 15 }, false }, _flat(range))
        end)

        it("covers a multibyte unit and the blanks after it", function()
            _initialize_buffer({ "-- foo — bar" }, 0, 7)

            local range = operator.forward_range(_units(), 1, _settings(), shape.forward_to_start)

            assert.same({ { 0, 7 }, { 0, 11 }, false }, _flat(range))
        end)

        it("measures a multibyte skipped character by its width when no leaf covers it", function()
            _initialize_buffer({ "local x = a ≠ b" }, 0, 12)

            local range =
                operator.forward_range(_without_cursor_leaf(_units({ "≠" })), 1, _settings(), shape.forward_to_start)

            assert.same({ { 0, 12 }, { 0, 16 }, false }, _flat(range))
        end)

        it("ends at a multibyte unit's first byte for #change_to_end", function()
            _initialize_buffer({ "-- foo — bar" }, 0, 7)

            local range = operator.forward_range(
                _units(),
                1,
                _settings({ change = true, change_to_end = true }),
                shape.forward_to_start
            )

            assert.same({ { 0, 7 }, { 0, 7 }, true }, _flat(range))
        end)

        describe("W", function()
            it("includes delimiters inside the run with #keep_between_tokens", function()
                _initialize_buffer({ "local x = foo_bar_ + 1" }, 0, 10)

                local range = operator.forward_range(_big_units(), 1, _settings(), shape.forward_to_start)

                assert.same({ { 0, 10 }, { 0, 14 }, false }, _flat(range))
            end)

            it("stops before delimiters inside the run with #keep", function()
                _initialize_buffer({ "local x = foo_bar_ + 1" }, 0, 10)

                local range = operator.forward_range(
                    _big_units(),
                    1,
                    _settings({ skipped_text = "keep" }),
                    shape.forward_to_start
                )

                assert.same({ { 0, 10 }, { 0, 13 }, false }, _flat(range))
            end)

            it("covers a skipped run under the cursor and the blanks after it", function()
                _initialize_buffer({ "local x = a == b" }, 0, 12)

                local range = operator.forward_range(_big_units(), 1, _settings(), shape.forward_to_start)

                assert.same({ { 0, 12 }, { 0, 15 }, false }, _flat(range))
            end)
        end)
    end)

    describe("inclusive_range", function()
        it("includes both ends of #e", function()
            _initialize_buffer({ "local fooBar = 1" }, 0, 6)

            local range = operator.inclusive_range(_units(), 1, _settings(), shape.forward_to_end)

            assert.same({ { 0, 6 }, { 0, 8 }, true }, _flat(range))
        end)

        it("orders a backward #ge range from its target", function()
            _initialize_buffer({ "local fooBar = 1" }, 0, 11)

            local range = operator.inclusive_range(_units(), 1, _settings(), shape.backward_to_end)

            assert.same({ { 0, 8 }, { 0, 11 }, true }, _flat(range))
        end)

        it("stays exclusive with #inclusive = false", function()
            _initialize_buffer({ "local fooBar = 1" }, 0, 6)

            local range = operator.inclusive_range(_units(), 1, _settings({ inclusive = false }), shape.forward_to_end)

            assert.same({ { 0, 6 }, { 0, 8 }, false }, _flat(range))
        end)

        it("is empty when the motion doesn't move", function()
            _initialize_buffer({ "foo" }, 0, 2)

            local range = operator.inclusive_range(_units(), 1, _settings(), shape.forward_to_end)

            assert.same({ { 0, 2 }, { 0, 2 }, false }, _flat(range))
        end)

        it("steps a count like #e", function()
            _initialize_buffer({ "local fooBar = 1" }, 0, 6)

            local range = operator.inclusive_range(_units(), 2, _settings(), shape.forward_to_end)

            assert.same({ { 0, 6 }, { 0, 11 }, true }, _flat(range))
        end)

        it("spans lines for #e", function()
            _initialize_buffer({ "local foo", "local bar" }, 0, 8)

            local range = operator.inclusive_range(_units(), 1, _settings(), shape.forward_to_end)

            assert.same({ { 0, 8 }, { 1, 4 }, true }, _flat(range))
        end)

        it("orders a backward #ge range across lines", function()
            _initialize_buffer({ "local foo", "local bar" }, 1, 2)

            local range = operator.inclusive_range(_units(), 1, _settings(), shape.backward_to_end)

            assert.same({ { 0, 8 }, { 1, 2 }, true }, _flat(range))
        end)
    end)
end)
