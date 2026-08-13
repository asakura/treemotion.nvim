--- Shared scratch-buffer plumbing for cross-grammar motion specs.
---
--- `lua/treemotion/_commands/motion/` is meant to be grammar-agnostic: it
--- walks generic treesitter node shapes (leaf / gap / partial-coverage,
--- see `leaf.lua`) and generic leaf *text* (camelCase/kebab-case/comment-marker
--- splitting, see `subword.lua`), never a particular language's node type
--- names. `spec/treemotion/motion_*_spec.lua` prove that by running the same
--- motion assertions against fixtures in multiple filetypes. This module
--- holds the plumbing those files share: buffer setup/teardown, cursor
--- helpers, and a wrapper that turns a missing treesitter parser into a
--- pending (not failing) test -- so a fixture for a filetype whose parser
--- isn't installed in a given environment (e.g. an external grammar like
--- Python or Rust, added as a fixture before it's vendored into `flake.nix`)
--- degrades gracefully instead of breaking the whole suite.

-- luacheck: globals pending
-- `pending` is a busted global; luacheck only knows to expect it in files
-- matching `*_spec.lua`, which this shared helper deliberately isn't (see
-- the module docstring on why the `it(...)` call itself has to live in
-- each `*_spec.lua` file instead of here).

local M = {}

---@param filetype string
---@param lines string[]
---@return integer buffer
---@return boolean available # `false` if `filetype` has no treesitter parser here.
function M.new_buffer(filetype, lines)
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

--- Wrap `body` for use as an `it(...)` callback: sets up `fixture`'s buffer,
--- runs `body(buffer)`, then tears the buffer down -- or, if `fixture`'s
--- filetype has no parser available here, marks the test pending instead of
--- running `body` at all (see the module docstring).
---
--- Busted injects `describe`/`it`/`pending` as chunk-local globals into each
--- `_spec.lua` file it loads directly, not into modules reached via
--- `require` -- so this module cannot call `it`/`pending` itself. Each spec
--- file instead calls `it(description, grammar.wrap(fixture, body))`, from
--- a context where those globals genuinely exist.
---
---@param fixture {filetype: string, lines: string[]}
---@param body fun(buffer: integer)
---@return fun()
function M.wrap(fixture, body)
    return function()
        local buffer, available = M.new_buffer(fixture.filetype, fixture.lines)

        if not available then
            M.remove_buffer(buffer)

            -- The bundled busted LuaCATS stub only declares the 2-arg
            -- `pending(name, block)` form (a standalone always-skipped
            -- test); calling `pending(reason)` alone, from inside an
            -- already-running `it` body, to bail out and mark *that* test
            -- pending is equally real busted behavior, just not one the
            -- stub covers.
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
