--- Shared buffer setup for the cross-grammar motion specs. A fixture whose
--- parser isn't installed becomes a pending test instead of a failure.

-- luacheck: globals pending

local M = {}

---@param filetype string
---@param lines string[]
---@param comment_node string? See `M.wrap`'s `fixture.comment_node` docstring.
---@return integer buffer
---@return boolean available # `false` if `filetype` has no treesitter parser here.
function M.new_buffer(filetype, lines, comment_node)
    if comment_node then
        vim.treesitter.query.set(filetype, "highlights", string.format("(%s) @spell", comment_node))
    end

    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(buffer)

    local available = pcall(vim.treesitter.start, buffer, filetype)

    return buffer, available
end

---@param buffer integer?
function M.remove_buffer(buffer)
    if buffer and vim.api.nvim_buf_is_valid(buffer) then
        vim.api.nvim_buf_delete(buffer, { force = true })
    end
end

---@param row integer 0-indexed row.
---@param column integer 0-indexed column.
function M.set_cursor(row, column)
    vim.api.nvim_win_set_cursor(0, { row + 1, column })
end

---@return integer, integer # The cursor's current 0-indexed row and column.
function M.get_cursor()
    local cursor = vim.api.nvim_win_get_cursor(0)

    return cursor[1] - 1, cursor[2]
end

--- Wrap `body` as an `it` callback: set up `fixture`'s buffer, run `body`,
--- tear it down. Without a parser for the filetype, the test is pending.
---
--- Busted's `pending` only exists in `_spec.lua` chunks, not in required
--- modules, so callers pass theirs in.
---
---@param pending fun(reason: string) The calling spec's `pending`.
---@param fixture {filetype: string, lines: string[], comment_node: string?}
---    `comment_node` registers a `(comment_node) @spell` query, for grammars
---    whose highlight queries aren't installed.
---@param body fun(buffer: integer)
---@return fun()
function M.wrap(pending, fixture, body)
    return function()
        local buffer, available = M.new_buffer(fixture.filetype, fixture.lines, fixture.comment_node)

        if not available then
            M.remove_buffer(buffer)

            -- busted's type stubs only declare `pending(name, block)`.
            ---@diagnostic disable-next-line: missing-parameter
            pending(string.format('no "%s" treesitter parser installed', fixture.filetype))

            return
        end

        local ok, err = pcall(body, buffer)

        M.remove_buffer(buffer)

        if not ok then
            error(err, 0)
        end
    end
end

return M
