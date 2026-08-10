--- All `treemotion` command definitions.

local cmdparse = require("mega.cmdparse")

local _PREFIX = "TreeMotion"

---@type mega.cmdparse.ParserCreator
local _SUBCOMMANDS = function()
    local arbitrary_thing = require("treemotion._commands.arbitrary_thing.parser")
    local copy_logs = require("treemotion._commands.copy_logs.parser")
    local goodnight_moon = require("treemotion._commands.goodnight_moon.parser")
    local hello_world = require("treemotion._commands.hello_world.parser")

    local parser = cmdparse.ParameterParser.new({ name = _PREFIX, help = "The root of all commands." })
    local subparsers = parser:add_subparsers({ "commands", help = "All runnable commands." })

    subparsers:add_parser(arbitrary_thing.make_parser())
    subparsers:add_parser(copy_logs.make_parser())
    subparsers:add_parser(goodnight_moon.make_parser())
    subparsers:add_parser(hello_world.make_parser())

    return parser
end

cmdparse.create_user_command(_SUBCOMMANDS, _PREFIX)

vim.keymap.set("n", "<Plug>(TreeMotionSayHi)", function()
    local configuration = require("treemotion._core.configuration")
    local treemotion = require("treemotion")

    configuration.initialize_data_if_needed()

    treemotion.run_hello_world_say_word("Hi!")
end, { desc = "Say hi to the user." })
