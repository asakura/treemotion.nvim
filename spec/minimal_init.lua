--- Helper that runs before unittests. `mega.cmdparse`/`mega.logging` come from
--- `.busted`'s `lpath` (rendered by `flake.nix`, see `bustedConfig`).

vim.opt.rtp:append(".")

vim.cmd("runtime plugin/treemotion.lua")

require("treemotion._core.configuration").initialize_data_if_needed()
