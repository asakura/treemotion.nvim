--- Make sure the treesitter `w`/`e`/`b`/`ge`/`W`/`E`/`B`/`gE` motions work.
---
--- The fixture text is `foo.bar(1, 2)`, whose leaves are
--- `foo . bar ( 1 , 2 )` (0-indexed start columns 0, 3, 4, 7, 8, 9, 11, 12).
--- The space before `2` is the only gap, so it splits the leaves into
--- exactly two "WORD" runs: `foo.bar(1,` (columns 0-10) and `2)` (columns
--- 11-13) -- that boundary is what every `W`/`E`/`B`/`gE` test below exists
--- to exercise, since it's the one place `word` and `WORD` motions disagree.

local treemotion = require("treemotion")

---@type integer?
local _BUFFER

--- Make a scratch buffer with `foo.bar(1, 2)` in it and attach the Lua parser.
local function _initialize_buffer()
    _BUFFER = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(_BUFFER, 0, -1, false, { "foo.bar(1, 2)" })
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

describe("motion API - word (leaf) motions", function()
    before_each(_initialize_buffer)
    after_each(_remove_buffer)

    it("#w moves to the start of each next leaf", function()
        _set_cursor(0)

        local expected = { 3, 4, 7, 8, 9, 11, 12, 12 }

        for _, column in ipairs(expected) do
            treemotion.run_motion_w()
            assert.same(column, _get_cursor_column())
        end
    end)

    it("#w with a count moves over multiple leaves at once", function()
        _set_cursor(0)

        treemotion.run_motion_w(3)

        assert.same(7, _get_cursor_column())
    end)

    it("#b moves to the start of each previous leaf", function()
        _set_cursor(12)

        local expected = { 11, 9, 8, 7, 4, 3, 0, 0 }

        for _, column in ipairs(expected) do
            treemotion.run_motion_b()
            assert.same(column, _get_cursor_column())
        end
    end)

    it("#e moves to the end of the current, then each next, leaf", function()
        _set_cursor(0)

        local expected = { 2, 3, 6, 7, 8, 9, 11, 12 }

        for _, column in ipairs(expected) do
            treemotion.run_motion_e()
            assert.same(column, _get_cursor_column())
        end
    end)

    it("#ge moves to the end of each previous leaf", function()
        _set_cursor(12)

        local expected = { 11, 9, 8, 7, 6, 3, 2, 2 }

        for _, column in ipairs(expected) do
            treemotion.run_motion_ge()
            assert.same(column, _get_cursor_column())
        end
    end)
end)

describe("motion API - WORD (contiguous run) motions", function()
    before_each(_initialize_buffer)
    after_each(_remove_buffer)

    it("#W jumps over an entire run, not leaf-by-leaf", function()
        _set_cursor(0)

        treemotion.run_motion_W()
        assert.same(11, _get_cursor_column())

        treemotion.run_motion_W()
        assert.same(11, _get_cursor_column()) -- no run after the last one
    end)

    it("#b moves leaf-by-leaf where #B moves run-by-run", function()
        _set_cursor(12)

        treemotion.run_motion_B()
        assert.same(11, _get_cursor_column()) -- to the start of the current run

        treemotion.run_motion_B()
        assert.same(0, _get_cursor_column()) -- to the start of the previous run
    end)

    it("#E jumps to the end of the current, then next, run", function()
        _set_cursor(0)

        treemotion.run_motion_E()
        assert.same(9, _get_cursor_column())

        treemotion.run_motion_E()
        assert.same(12, _get_cursor_column())
    end)

    it("#gE jumps to the end of the previous run, skipping leaves inside it", function()
        _set_cursor(12)

        treemotion.run_motion_gE()
        assert.same(9, _get_cursor_column()) -- end of the previous run

        treemotion.run_motion_gE()
        assert.same(9, _get_cursor_column()) -- no run before the first one
    end)
end)

describe("motion API - no parser", function()
    it("does nothing instead of erroring when the buffer has no treesitter parser", function()
        local buffer = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "plain text" })
        vim.api.nvim_set_current_buf(buffer)
        _set_cursor(0)

        treemotion.run_motion_w()

        assert.same(0, _get_cursor_column())

        vim.api.nvim_buf_delete(buffer, { force = true })
    end)
end)

describe("motion commands", function()
    before_each(_initialize_buffer)
    after_each(_remove_buffer)

    it("runs #w through the :TreeMotion command", function()
        _set_cursor(0)

        vim.cmd([[TreeMotion motion w]])

        assert.same(3, _get_cursor_column())
    end)

    it("runs #w with --count through the :TreeMotion command", function()
        _set_cursor(0)

        vim.cmd([[TreeMotion motion w --count=3]])

        assert.same(7, _get_cursor_column())
    end)

    it("runs #W through the :TreeMotion command", function()
        _set_cursor(0)

        vim.cmd([[TreeMotion motion W]])

        assert.same(11, _get_cursor_column())
    end)

    it("runs #gE through the :TreeMotion command", function()
        _set_cursor(12)

        vim.cmd([[TreeMotion motion gE]])

        assert.same(9, _get_cursor_column())
    end)
end)
