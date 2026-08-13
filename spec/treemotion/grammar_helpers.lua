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

--- Wrap `body` for use as an `it(...)` callback: sets up `fixture`'s buffer,
--- runs `body(buffer)`, then tears the buffer down -- or, if `fixture`'s
--- filetype has no parser available here, marks the test pending instead of
--- running `body` at all (see the module docstring).
---
--- Busted injects `describe`/`it`/`pending` as chunk-local globals into each
--- `_spec.lua` file it loads directly, not into modules reached via
--- `require` -- so this module cannot call `it`/`pending` itself. It also
--- can't just call the bare name `pending` from inside a closure defined
--- here and expect it to resolve at the *caller's* scope the way a dynamic
--- language's free variable lookup might: Lua resolves a global by the
--- chunk's own `_ENV` upvalue, fixed at load time for wherever the source
--- line lexically lives, not by walking the call stack -- and busted loads
--- `grammar_helpers.lua` as an ordinary `require`d module with the real
--- `_G`, not the extended per-`_spec.lua`-file environment `describe`/`it`/
--- `pending` live in. Concretely: `_G.pending` is `nil` here even while a
--- spec file's own bare `pending` resolves fine. This isn't hypothetical --
--- every fixture across this whole test suite happened to have its parser
--- available prior to `_OPTIONAL_COMMENT_MARKERS`'s cross-grammar fixtures
--- (see `motion_comment_marker_spec.lua`), so this branch had literally
--- never run before those were added, and `nix build '.#treemotion-nvim'`'s
--- `checkPhase` (only Neovim's 6 bundled grammars, no `treesitterAllGrammars`)
--- was what finally exercised it and surfaced the bug. The fix: each spec
--- file passes its own `pending` through explicitly instead of `M.wrap`
--- assuming it can reach one.
---
---@param pending fun(reason: string) The calling spec file's own `pending`
---    (busted injects it as a chunk-local in `_spec.lua` files -- pass the
---    bare name through from a context where it resolves).
---@param fixture {filetype: string, lines: string[], comment_node: string?}
---    `comment_node`, if given, registers a synthetic `(comment_node) @spell`
---    highlight query for `filetype` before starting the parser -- see
---    `motion_comment_marker_spec.lua`'s module docstring for why: real
---    `@spell` captures require a language's `queries/<lang>/highlights.scm`,
---    which `flake.nix`'s `treesitterAllGrammars` deliberately doesn't vendor
---    (only compiled `parser/<lang>.so` files) for any grammar beyond
---    Neovim's own bundled few. Fixtures for those bundled languages (lua,
---    c, vim, query) omit `comment_node` and rely on Neovim's real bundled
---    query instead, exercising the plugin against genuine highlight data
---    for at least that subset.
---@param body fun(buffer: integer)
---@return fun()
function M.wrap(pending, fixture, body)
    return function()
        local buffer, available = M.new_buffer(fixture.filetype, fixture.lines, fixture.comment_node)

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
