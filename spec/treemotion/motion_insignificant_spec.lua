--- `insignificant_characters` hides configured code tokens from the motions.
--- Named prose leaves are never hidden; unnamed ones, such as a string's
--- quotes, can be.

local treemotion = require("treemotion")

---@type integer?
local _BUFFER

---@param lines string[]
local function _initialize_buffer(lines)
    _BUFFER = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(_BUFFER, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(_BUFFER)
    vim.treesitter.start(_BUFFER, "lua")
end

local function _remove_buffer()
    if _BUFFER and vim.api.nvim_buf_is_valid(_BUFFER) then
        vim.api.nvim_buf_delete(_BUFFER, { force = true })
    end

    _BUFFER = nil
end

---@param column integer A 0-indexed column, on line 1.
local function _set_cursor(column)
    vim.api.nvim_win_set_cursor(0, { 1, column })
end

---@return integer # The cursor's current 0-indexed column, on line 1.
local function _get_cursor_column()
    return vim.api.nvim_win_get_cursor(0)[2]
end

describe("motion API - insignificant_characters", function()
    after_each(function()
        _remove_buffer()

        -- Reset the shared configuration to the default `{}`.
        treemotion.setup({
            commands = { motion = { insignificant_characters = {}, big = { enabled = false } } },
        })
    end)

    it("#w/#b skip a configured leaf entirely, landing on the leaf beyond it", function()
        treemotion.setup({ commands = { motion = { insignificant_characters = { lua = { ";" } } } } })
        _initialize_buffer({ "foo ; bar" })

        _set_cursor(0) -- start of `foo`
        treemotion.run_motion_w()
        assert.same(6, _get_cursor_column()) -- straight to `bar`, never landing on `;`

        _set_cursor(6) -- start of `bar`
        treemotion.run_motion_b()
        assert.same(0, _get_cursor_column()) -- straight back to `foo`
    end)

    it("#W/#B skip a run that's entirely a configured, isolated leaf", function()
        treemotion.setup({ commands = { motion = { insignificant_characters = { lua = { ";" } } } } })
        _initialize_buffer({ "foo ; bar" })

        _set_cursor(0)
        treemotion.run_motion_W()
        assert.same(6, _get_cursor_column())

        _set_cursor(6)
        treemotion.run_motion_B()
        assert.same(0, _get_cursor_column())
    end)

    it("leaves a #w stop alone unless its entire text matches a configured entry", function()
        -- `;` is configured, but this leaf's text is `;;` (Lua parses each
        -- as its own one-character leaf either way) -- proving the match is
        -- against a whole leaf's *own* text, not "contains this character".
        treemotion.setup({ commands = { motion = { insignificant_characters = { lua = { ";" } } } } })
        _initialize_buffer({ "foo ; ; bar" })

        _set_cursor(0)
        treemotion.run_motion_w()
        assert.same(8, _get_cursor_column()) -- both `;` leaves skipped in turn
    end)

    it("never treats a leaf as insignificant inside prose (string content)", function()
        treemotion.setup({ commands = { motion = { insignificant_characters = { lua = { ";" } } } } })
        _initialize_buffer({ [[local s = "foo ; bar"]] })

        _set_cursor(11) -- start of `foo`, inside the string
        treemotion.run_motion_w()
        assert.same(15, _get_cursor_column()) -- lands ON `;` -- prose keeps every character significant
    end)

    it("can hide a string's own quote delimiters, even though they're @string-tagged", function()
        -- The quotes are unnamed leaves, so they can be hidden, unlike
        -- `string_content`.
        treemotion.setup({ commands = { motion = { insignificant_characters = { lua = { '"' } } } } })
        _initialize_buffer({ [[local s = "foo bar";]] })

        _set_cursor(8) -- `=`
        treemotion.run_motion_w()
        assert.same(11, _get_cursor_column()) -- straight to `foo`, past the opening `"`

        _set_cursor(15) -- start of `bar`
        treemotion.run_motion_w()
        assert.same(19, _get_cursor_column()) -- past `bar` and the closing `"` to `;`, itself unconfigured
    end)

    it("supports multi-character leaf text, not just single characters", function()
        treemotion.setup({ commands = { motion = { insignificant_characters = { lua = { ".." } } } } })
        _initialize_buffer({ "foo .. bar" })

        _set_cursor(0)
        treemotion.run_motion_w()
        assert.same(7, _get_cursor_column()) -- straight past the `..` operator leaf to `bar`
    end)

    it("still skips an isolated insignificant run once #commands.motion.big.enabled is true", function()
        treemotion.setup({
            commands = {
                motion = {
                    insignificant_characters = { lua = { ";" } },
                    big = { enabled = true },
                },
            },
        })
        _initialize_buffer({ "foo ; bar" })

        _set_cursor(0)
        treemotion.run_motion_W()
        assert.same(6, _get_cursor_column())
    end)

    it("leaves a mixed run (no whitespace around the configured token) untouched", function()
        -- `;` sitting directly against its neighbors, with no whitespace, is
        -- already one contiguous `W` run regardless of this feature -- only
        -- an *isolated* insignificant leaf (its own whole run) is skipped.
        treemotion.setup({ commands = { motion = { insignificant_characters = { lua = { ";" } } } } })
        _initialize_buffer({ "foo;bar baz" })

        _set_cursor(0)
        treemotion.run_motion_W()
        assert.same(8, _get_cursor_column()) -- `foo;bar` is one stop, straight to `baz`
    end)
end)
