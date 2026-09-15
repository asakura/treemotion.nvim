--- All `treemotion` command definitions.

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

for _, name in ipairs({ "w", "e", "b", "ge", "W", "E", "B", "gE" }) do
    vim.keymap.set({ "n", "x", "o" }, string.format("<Plug>(TreeMotion%s)", name), function()
        local configuration = require("treemotion._core.configuration")
        local treemotion = require("treemotion")

        configuration.initialize_data_if_needed()

        treemotion["run_motion_" .. name](vim.v.count1)
    end, { desc = string.format('Move like Vim\'s "%s", by treesitter node.', name) })
end
