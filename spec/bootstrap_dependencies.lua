--- Fetch `mega.cmdparse`/`mega.logging` from GitHub for `nvim` invocations
--- that skip Nix entirely (e.g. the `:checkhealth` CI workflow, see
--- `spec/checkhealth_init.lua`). Busted-driven runs never need this: they
--- already have both on `package.path` via `.busted`'s `lpath` (rendered by
--- `flake.nix`, see `bustedConfig`), which is why `spec/minimal_init.lua`
--- doesn't call this itself.

local _PLUGINS = {
    ["https://github.com/ColinKennedy/mega.cmdparse"] = {
        module = "mega.cmdparse",
        directory = os.getenv("MEGA_CMDPARSE_DIR") or "/tmp/mega.cmdparse",
    },
    ["https://github.com/ColinKennedy/mega.logging"] = {
        module = "mega.logging",
        directory = os.getenv("MEGA_LOGGING_DIR") or "/tmp/mega.logging",
    },
}

for url, plugin in pairs(_PLUGINS) do
    if not pcall(require, plugin.module) then
        if vim.fn.isdirectory(plugin.directory) ~= 1 then
            print(string.format('Cloning "%s" plug-in to "%s" path.', url, plugin.directory))

            vim.fn.system({ "git", "clone", url, plugin.directory })
        end

        vim.opt.rtp:append(plugin.directory)
    end
end
