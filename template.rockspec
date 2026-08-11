-- A template rendered by .github/workflows/release-luarocks.yml (via nvim-neorocks/luarocks-tag-release)

local git_ref = "$git_ref"
local modrev = "$modrev"
local specrev = "$specrev"

local repo_url = "$repo_url"

rockspec_format = "3.0"
package = "treemotion.nvim"
version = modrev .. "-" .. specrev

local user = "asakura"

description = {
    homepage = "https://github.com/" .. user .. "/" .. package,
    labels = { "neovim", "neovim-plugin" },
    license = "MIT",
    summary = "Treesitter-driven w/e/b/ge motions, per filetype",
}

dependencies = {
    "mega.cmdparse >= 1.0.3, < 2.0",
    "mega.logging >= 1.1.4, < 2.0",
}

test_dependencies = {
    "busted >= 2.0, < 3.0",
    "lua >= 5.1, < 6.0",
}

test = { type = "busted" }

source = {
    url = repo_url .. "/archive/" .. git_ref .. ".zip",
    dir = "$repo_name-" .. "$archive_dir_suffix",
}

if modrev == "scm" or modrev == "dev" then
    source = {
        url = repo_url:gsub("https", "git"),
    }
end

build = {
    type = "builtin",
    copy_directories = $copy_directories,
}
