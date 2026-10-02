--- All `treemotion` command definitions.

-- `g:loaded_treemotion` follows Vim's plugin convention (`:help
-- lua-plugin-filetype`, `usr_41.txt` "NOT LOADING"): if it exists at all,
-- this file does nothing. That lets users opt out of the plugin from Lua or
-- Vimscript, and makes sourcing this file a second time a no-op.
--
-- `g:` lives in Nvim's own variable store, not in Lua: `vim.g` hands back a
-- converted copy on every read, so `let g:loaded_treemotion = 0` arrives
-- here as the number `0`, which Lua treats as true. Check `~= nil`, which
-- matches Vimscript's `exists("g:loaded_treemotion")`, rather than
-- truthiness, so every value opts out, `0` and `v:false` included.
if vim.g.loaded_treemotion ~= nil then
    return
end

vim.g.loaded_treemotion = true

local cmdparse = require("mega.cmdparse")

local _PREFIX = "TreeMotion"

---@type mega.cmdparse.ParserCreator
local _SUBCOMMANDS = function()
    local motion = require("treemotion._commands.motion.parser")

    local parser = cmdparse.ParameterParser.new({ name = _PREFIX, help = "The root of all commands." })
    local subparsers = parser:add_subparsers({ "commands", help = "All runnable commands." })

    subparsers:add_parser(motion.make_parser())

    return parser
end

cmdparse.create_user_command(_SUBCOMMANDS, _PREFIX)

local constant = require("treemotion._commands.motion.constant")

for _, name in ipairs(constant.MOTION_NAMES) do
    local plug = string.format("<Plug>(TreeMotion%s)", name)
    local description = string.format('Move like Vim\'s "%s", by treesitter node.', name)

    vim.keymap.set({ "n", "x" }, plug, function()
        local configuration = require("treemotion._core.configuration")
        local treemotion = require("treemotion")

        configuration.initialize_data_if_needed()

        treemotion["run_motion_" .. name](vim.v.count1)
    end, { desc = description })

    -- An `<expr>` mapping, so `dge` can be forced inclusive with `v` (see
    -- `_commands.motion.runner.force`). The `<Cmd>` is what `.` repeats.
    vim.keymap.set("o", plug, function()
        local configuration = require("treemotion._core.configuration")
        local runner = require("treemotion._commands.motion.runner")

        configuration.initialize_data_if_needed()

        return runner.force(name, vim.v.count1)
            .. string.format('<Cmd>lua require("treemotion").run_motion_%s(vim.v.count1)<CR>', name)
    end, { desc = description, expr = true })
end
