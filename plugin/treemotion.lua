--- All `treemotion` command definitions.

-- Any value of `g:loaded_treemotion`, even `0`, disables the plugin, as
-- `exists()` would.
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

    -- `<expr>`, so `dge` can be forced inclusive with `v`.
    vim.keymap.set("o", plug, function()
        local configuration = require("treemotion._core.configuration")
        local runner = require("treemotion._commands.motion.runner")

        configuration.initialize_data_if_needed()

        return runner.operator_keys(name)
    end, { desc = description, expr = true })
end
