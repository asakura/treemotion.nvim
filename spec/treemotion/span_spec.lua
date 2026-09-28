--- Direct unit tests for `_commands.motion.span`, isolated from the motion
--- machinery that consumes it.

local span = require("treemotion._commands.motion.span")

--- Every position `mapper` produces for `text`'s offsets `1 .. #text + 1`.
---
---@param mapper fun(offset: integer): integer, integer
---@param text string
---@return integer[][]
local function _all_positions(mapper, text)
    local positions = {}

    for offset = 1, #text + 1 do
        table.insert(positions, { mapper(offset) })
    end

    return positions
end

describe("span.new", function()
    it("exposes its coordinates through start/end_", function()
        local unit = span.new(1, 2, 3, 4)

        assert.same({ 1, 2 }, { unit:start() })
        assert.same({ 3, 4 }, { unit:end_() })
    end)
end)

describe("span.end_position", function()
    it("adds the length for single-row text", function()
        assert.same({ 2, 9 }, { span.end_position(2, 5, "abcd") })
    end)

    it("handles empty text", function()
        assert.same({ 2, 5 }, { span.end_position(2, 5, "") })
    end)

    it("counts rows and the bytes after the last newline for multi-row text", function()
        assert.same({ 4, 2 }, { span.end_position(2, 5, "ab\ncd\nef") })
    end)

    it("lands at column 0 when text ends in a newline", function()
        assert.same({ 3, 0 }, { span.end_position(2, 5, "ab\n") })
    end)
end)

describe("span.position_mapper", function()
    it("uses flat column arithmetic for single-row text", function()
        assert.same(
            { { 1, 3 }, { 1, 4 }, { 1, 5 }, { 1, 6 } },
            _all_positions(span.position_mapper(1, 3, "abc"), "abc")
        )
    end)

    it("resets the column after each newline for multi-row text", function()
        local text = "ab\nc\n\nde"

        assert.same({
            { 1, 3 }, -- a
            { 1, 4 }, -- b
            { 1, 5 }, -- \n
            { 2, 0 }, -- c
            { 2, 1 }, -- \n
            { 3, 0 }, -- \n
            { 4, 0 }, -- d
            { 4, 1 }, -- e
            { 4, 2 }, -- one past the end
        }, _all_positions(span.position_mapper(1, 3, text), text))
    end)

    it("agrees with end_position one past the last character", function()
        local text = "foo\nbar baz\nqux"
        local mapper = span.position_mapper(7, 4, text)

        assert.same({ span.end_position(7, 4, text) }, { mapper(#text + 1) })
    end)
end)
