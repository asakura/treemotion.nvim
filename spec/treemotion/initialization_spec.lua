--- A fresh Neovim loads and initializes treemotion once, and honors
--- `g:loaded_treemotion`. A `g:` variable survives clearing
--- `package.loaded`; the configuration's own flag doesn't, so a reloaded
--- module initializes again.
---
--- The rest of the suite runs in one Neovim that has already loaded the
--- plugin, so each test here runs a scenario in a `nvim --clean --headless`
--- child with the same `package.path`.

--- Run `scenario` in a fresh Neovim and return its global `result` table.
---
--- The scenario starts in a Lua buffer holding `fooBar baz`, cursor at
--- column 0, with the plugin on 'runtimepath' but not sourced. It can call
--- `load_plugin()`, `press(name)` (runs `<Plug>(TreeMotion<name>)`, returns
--- the column) and `mapping(name)` (the mapping's callback, or `nil`).
---
---@param scenario string
---@return table
local function _run_in_fresh_neovim(scenario)
    local script = vim.fn.tempname() .. ".lua"
    local root = vim.fn.getcwd()

    local source = table.concat({
        "package.path = " .. string.format("%q", package.path),
        "package.cpath = " .. string.format("%q", package.cpath),
        "vim.opt.runtimepath:append(" .. string.format("%q", root) .. ")",
        "result = {}",
        "local function load_plugin() vim.cmd('runtime plugin/treemotion.lua') end",
        "local function press(name)",
        "    vim.api.nvim_feedkeys(vim.keycode('<Plug>(TreeMotion' .. name .. ')'), 'x', false)",
        "    return vim.api.nvim_win_get_cursor(0)[2]",
        "end",
        "local function mapping(name)",
        "    return vim.fn.maparg('<Plug>(TreeMotion' .. name .. ')', 'n', false, true).callback",
        "end",
        "local buffer = vim.api.nvim_create_buf(false, true)",
        "vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { 'fooBar baz' })",
        "vim.api.nvim_set_current_buf(buffer)",
        "vim.treesitter.start(buffer, 'lua')",
        "local ok, message = pcall(function()",
        scenario,
        "end)",
        "if not ok then result.error = tostring(message) end",
        "io.stdout:write(vim.json.encode(result))",
    }, "\n")

    -- `writefile()` turns a newline inside a list item into a NUL byte, so
    -- hand it one item per line.
    vim.fn.writefile(vim.split(source, "\n"), script)

    local completed = vim.system({ vim.v.progpath, "--clean", "--headless", "-l", script }, { text = true }):wait()

    vim.fn.delete(script)

    assert.equal(0, completed.code, completed.stderr)

    local result = vim.json.decode(completed.stdout)

    assert.is_nil(result.error)

    return result
end

describe("g:loaded_treemotion in a fresh Neovim", function()
    it("is set when the plugin loads, and the motions work", function()
        local result = _run_in_fresh_neovim([[
            result.before = vim.fn.exists("g:loaded_treemotion")
            load_plugin()
            result.after = vim.g.loaded_treemotion
            result.column = press("w")
        ]])

        assert.same({ before = 0, after = true, column = 3 }, result)
    end)

    it("makes sourcing #plugin/treemotion.lua a second time a no-op", function()
        local result = _run_in_fresh_neovim([[
            load_plugin()
            local callback = mapping("w")
            load_plugin()
            result.same_mapping = mapping("w") == callback
        ]])

        assert.same({ same_mapping = true }, result)
    end)

    -- `g:` values arrive in Lua as converted copies: `let g:x = 0` reads back
    -- as the number `0`, which Lua treats as true, and `v:false` as `false`.
    -- Each must still count as "set", the same as Vimscript's `exists()`.
    for _, value in ipairs({ "v:true", "1", "0", "v:false" }) do
        it(string.format("stops the plugin from loading when preset to %s (#opt-out)", value), function()
            local result = _run_in_fresh_neovim(string.format(
                [[
                vim.cmd("let g:loaded_treemotion = %s")
                local before = vim.fn.string(vim.g.loaded_treemotion)
                load_plugin()
                result.mapping_defined = mapping("w") ~= nil
                result.command_defined = vim.fn.exists(":TreeMotion") == 2
                result.unchanged = vim.fn.string(vim.g.loaded_treemotion) == before
                ]],
                value
            ))

            assert.same({ mapping_defined = false, command_defined = false, unchanged = true }, result)
        end)
    end
end)

describe("configuration initialization in a fresh Neovim", function()
    it("initializes only once, however many motions run", function()
        local result = _run_in_fresh_neovim([[
            load_plugin()
            local configuration = require("treemotion._core.configuration")

            press("w")
            local data = configuration.DATA

            -- The start-up configuration is only read by that one
            -- initialization, so changing it now must not matter.
            vim.g.treemotion_configuration = { commands = { motion = { small = { code = { camel_case = false } } } } }
            result.columns = { press("b"), press("w"), press("w") }
            result.same_data = configuration.DATA == data
        ]])

        assert.same({ columns = { 0, 3, 7 }, same_data = true }, result)
    end)

    it("initializes again after the Lua modules are #reloaded", function()
        local result = _run_in_fresh_neovim([[
            load_plugin()
            press("w")

            for name in pairs(package.loaded) do
                if name == "treemotion" or name:match("^treemotion%.") then
                    package.loaded[name] = nil
                end
            end

            vim.api.nvim_win_set_cursor(0, { 1, 0 })
            result.column = press("w")
            result.has_configuration = require("treemotion._core.configuration").DATA.commands ~= nil
            result.still_loaded = vim.g.loaded_treemotion
        ]])

        assert.same({ column = 3, has_configuration = true, still_loaded = true }, result)
    end)
end)
