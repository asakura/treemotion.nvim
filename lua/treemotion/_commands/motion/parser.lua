--- The main parser for the `:TreeMotion motion` command.

local cmdparse = require("mega.cmdparse")

local M = {}

---@type string[] # Every `motion` subcommand name, `word` (lowercase) then `WORD` (uppercase).
local _NAMES = { "w", "e", "b", "ge", "W", "E", "B", "gE" }

---@return mega.cmdparse.ParameterParser # The main parser for the `:TreeMotion motion` command.
function M.make_parser()
    local parser = cmdparse.ParameterParser.new({ "motion", help = "Move the cursor by treesitter node." })

    local subparsers =
        parser:add_subparsers({ destination = "commands", help = "All motion commands.", required = true })

    for _, name in ipairs(_NAMES) do
        local subparser = subparsers:add_parser({ name, help = string.format('Move like Vim\'s "%s".', name) })

        subparser:add_parameter({
            names = { "--count", "-c" },
            type = "number",
            default = 1,
            help = "How many times to repeat the motion (default=1).",
        })

        subparser:set_execute(function(data)
            ---@cast data mega.cmdparse.NamespaceExecuteArguments
            local runner = require("treemotion._commands.motion.runner")

            runner["run_" .. name](data.namespace.count)
        end)
    end

    return parser
end

return M
