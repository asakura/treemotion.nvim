--- Make sure `_commands.motion.shape`'s steps work from a position, not the cursor.
---
--- The steps (`next_start`, ...) are measured from any position without
--- touching the cursor, and the cursor-moving motions (`forward_to_start`,
--- ...) must land exactly where their step says.

local grammar_helpers = require("treemotion.grammar_helpers")
local settings = require("treemotion._commands.motion.settings")
local shape = require("treemotion._commands.motion.shape")
local unit = require("treemotion._commands.motion.unit")

---@type integer?
local _BUFFER

--- Every step, with the cursor-moving motion that wraps it.
---
---@type {name: string, step: treemotion._Step, move: treemotion._Move}[]
local _SHAPES = {
    { name = "next_start", step = shape.next_start, move = shape.forward_to_start },
    { name = "previous_end", step = shape.previous_end, move = shape.backward_to_end },
    { name = "next_end", step = shape.next_end, move = shape.forward_to_end },
    { name = "previous_start", step = shape.previous_start, move = shape.backward_to_start },
}

---@return treemotion._UnitSource
local function _units()
    return unit.word(settings.resolve("small"))
end

--- Start a Lua buffer holding `lines`, with the cursor at its start.
---
---@param lines string[]
local function _initialize_buffer(lines)
    _BUFFER = grammar_helpers.new_buffer("lua", lines)
end

describe("shape steps", function()
    after_each(function()
        grammar_helpers.remove_buffer(_BUFFER)
        _BUFFER = nil
    end)

    it("measures from the given position and leaves the cursor alone", function()
        _initialize_buffer({ "local fooBar = 1" })

        local units = _units()

        assert.same({ 0, 9 }, { shape.next_start(units, 0, 6, 1) })
        assert.same({ 0, 8 }, { shape.next_end(units, 0, 6, 1) })
        assert.same({ 0, 6 }, { shape.previous_start(units, 0, 8, 1) })
        assert.same({ 0, 8 }, { shape.previous_end(units, 0, 11, 1) })
        assert.same({ 0, 0 }, { grammar_helpers.get_cursor() })
    end)

    it("steps a count", function()
        _initialize_buffer({ "local fooBar = 1" })

        assert.same({ 0, 13 }, { shape.next_start(_units(), 0, 0, 3) })
    end)

    it("returns the start when there's nowhere to go", function()
        _initialize_buffer({ "local foo" })

        local units = _units()

        assert.same({ 0, 0 }, { shape.previous_start(units, 0, 0, 1) })
        assert.same({ 0, 8 }, { shape.next_end(units, 0, 8, 1) })
    end)

    it("lands on the nearest unit from a blank line", function()
        _initialize_buffer({ "local foo", "", "local bar" })

        local units = _units()

        assert.same({ 2, 0 }, { shape.next_start(units, 1, 0, 1) })
        assert.same({ 0, 8 }, { shape.previous_end(units, 1, 0, 1) })
    end)

    for _, entry in ipairs(_SHAPES) do
        it(string.format("moves the cursor where %s lands, from every position", entry.name), function()
            local lines = { "local fooBar = { a_b, 'x y' }", "", "  -- some comment", "return fooBar" }
            _initialize_buffer(lines)

            for row, line in ipairs(lines) do
                for column = 0, math.max(#line - 1, 0) do
                    for count = 1, 2 do
                        local units = _units()
                        local expected = { entry.step(units, row - 1, column, count) }

                        grammar_helpers.set_cursor(row - 1, column)
                        entry.move(units, count)

                        assert.same(expected, { grammar_helpers.get_cursor() })
                    end
                end
            end
        end)
    end
end)
