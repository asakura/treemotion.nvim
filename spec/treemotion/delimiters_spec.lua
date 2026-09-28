--- Direct unit tests for `_commands.motion.delimiters`'s `M.split`, isolated
--- from the motion machinery that consumes it. See `treemotion_spec.lua`
--- and `motion_comment_marker_spec.lua` for the end-to-end tests.

local delimiters = require("treemotion._commands.motion.delimiters")

local _NONE, _SKIP, _STOP = "none", "skip", "stop"

--- Split `text` with every identifier delimiter set to `mode`.
---
---@param text string
---@param mode treemotion.SubwordDelimiterMode
---@param comment_marker_case treemotion.SubwordDelimiterMode?
---@param comment_marker_characters table<string, true>?
---@return {text: string, offset: integer}[]
local function _split(text, mode, comment_marker_case, comment_marker_characters)
    return delimiters.split(text, mode, mode, mode, mode, comment_marker_case or _NONE, comment_marker_characters or {})
end

describe("delimiters.split", function()
    it("drops a skip-mode delimiter run and splits around it", function()
        assert.same({ { text = "foo", offset = 1 }, { text = "bar", offset = 6 } }, _split("foo__bar", _SKIP))
    end)

    it("keeps a stop-mode delimiter run as its own chunk", function()
        assert.same({
            { text = "foo", offset = 1 },
            { text = "-", offset = 4 },
            { text = "bar", offset = 5 },
        }, _split("foo-bar", _STOP))
    end)

    it("leaves none-mode delimiters embedded", function()
        assert.same({ { text = "foo-bar_baz", offset = 1 } }, _split("foo-bar_baz", _NONE))
    end)

    it("reads each delimiter's own mode", function()
        assert.same(
            { { text = "a-b", offset = 1 }, { text = "c", offset = 5 } },
            delimiters.split("a-b_c", _NONE, _SKIP, _NONE, _NONE, _NONE, {})
        )
    end)

    it("applies comment_marker_case to a listed marker character", function()
        assert.same(
            { { text = "#", offset = 1 }, { text = "foo", offset = 2 } },
            _split("#foo", _NONE, _STOP, { ["#"] = true })
        )
    end)

    it("lets comment_marker_case take over a bare - run when - is a listed marker", function()
        assert.same({}, _split("---", _STOP, _SKIP, { ["-"] = true }))
        assert.same({ { text = "---", offset = 1 } }, _split("---", _SKIP, _STOP, { ["-"] = true }))
    end)

    it("keeps kebab_case in charge of a bare - run when - isn't a listed marker", function()
        assert.same({ { text = "---", offset = 1 } }, _split("---", _STOP, _SKIP, {}))
    end)
end)
