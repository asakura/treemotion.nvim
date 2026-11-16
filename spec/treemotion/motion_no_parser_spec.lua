--- Without a treesitter grammar there are no leaves, so every motion falls
--- back to Vim's built-in one (`:help word-motions`).

local treemotion = require("treemotion")

describe("buffer without a parser", function()
    local buffer

    before_each(function()
        buffer = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(buffer)
        vim.bo[buffer].filetype = "treemotion_no_grammar"
        vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "foo.bar baz", "qux" })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
    end)

    after_each(function()
        vim.api.nvim_buf_delete(buffer, { force = true })
    end)

    --- The cursor after the built-in motion, run on a fresh copy of the buffer.
    local function _builtin(keys)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.cmd.normal({ args = { keys }, bang = true })

        return vim.api.nvim_win_get_cursor(0)
    end

    for name, keys in pairs({ w = "w", W = "W", e = "e", E = "E" }) do
        it("moves like the built-in " .. name, function()
            local expected = _builtin("2" .. keys)

            vim.api.nvim_win_set_cursor(0, { 1, 0 })
            treemotion["run_motion_" .. name](2)

            assert.same(expected, vim.api.nvim_win_get_cursor(0))
        end)
    end

    it("moves backward like the built-in b and ge", function()
        vim.api.nvim_win_set_cursor(0, { 2, 2 })
        treemotion.run_motion_b(2)
        assert.same({ 1, 8 }, vim.api.nvim_win_get_cursor(0))

        vim.api.nvim_win_set_cursor(0, { 2, 2 })
        treemotion.run_motion_ge(1)
        assert.same({ 1, 10 }, vim.api.nvim_win_get_cursor(0))
    end)

    it("works under an operator", function()
        vim.keymap.set("o", "w", "<Plug>(TreeMotionw)", { buffer = buffer, remap = true })
        vim.cmd.normal({ args = { "dw" }, bang = false })

        assert.same({ ".bar baz", "qux" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
    end)
end)
