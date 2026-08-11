# treemotion.nvim

Treesitter-driven `w`/`e`/`b`/`ge` motions, per filetype.

| <!-- -->     | <!-- -->                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Build Status | [![test](https://img.shields.io/github/actions/workflow/status/asakura/treemotion.nvim/test.yml?branch=main&style=for-the-badge&label=Test)](https://github.com/asakura/treemotion.nvim/actions/workflows/test.yml) [![documentation](https://img.shields.io/github/actions/workflow/status/asakura/treemotion.nvim/documentation.yml?branch=main&style=for-the-badge&label=Documentation)](https://github.com/asakura/treemotion.nvim/actions/workflows/documentation.yml) [![lints](https://img.shields.io/github/actions/workflow/status/asakura/treemotion.nvim/lints.yml?branch=main&style=for-the-badge&label=Lints)](https://github.com/asakura/treemotion.nvim/actions/workflows/lints.yml) [![checkhealth](https://img.shields.io/github/actions/workflow/status/asakura/treemotion.nvim/checkhealth.yml?branch=main&style=for-the-badge&label=checkhealth)](https://github.com/asakura/treemotion.nvim/actions/workflows/checkhealth.yml) [![urlchecker](https://img.shields.io/github/actions/workflow/status/asakura/treemotion.nvim/urlchecker.yml?branch=main&style=for-the-badge&label=URLChecker)](https://github.com/asakura/treemotion.nvim/actions/workflows/urlchecker.yml) [![commitlint](https://img.shields.io/github/actions/workflow/status/asakura/treemotion.nvim/commitlint.yml?branch=main&style=for-the-badge&label=Commitlint)](https://github.com/asakura/treemotion.nvim/actions/workflows/commitlint.yml) |
| License      | [![License-MIT](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)](https://github.com/asakura/treemotion.nvim/blob/main/LICENSE)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| Social       | [![RSS](https://img.shields.io/badge/rss-F88900?style=for-the-badge&logo=rss&logoColor=white)](https://github.com/asakura/treemotion.nvim/commits/main/doc/news.txt.atom)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |

# Status

This plugin is not yet functional. It's a fork of
[ColinKennedy's "Best Practices" Neovim plugin template](https://github.com/nvim-neorocks/nvim-best-practices),
mid-rename from the template's `plugin_template` scaffolding to `treemotion.nvim`.

The `lua/treemotion/_commands/` tree (`hello_world`, `goodnight_moon`,
`arbitrary_thing`, `copy_logs`) is still the template's literal example
scaffolding, not real treesitter-motion functionality. It's kept around as a
structural reference for how a command is wired end-to-end (`:TreeMotion`
subcommand parser → `lua/treemotion/init.lua` API → runner) until it gets
replaced with the real `w`/`e`/`b`/`ge` motions. The `Commands` and
`Configuration` sections below describe that scaffolding, not the plugin's
eventual feature set.

# Installation

- [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
    "asakura/treemotion.nvim",
    dependencies = { "ColinKennedy/mega.cmdparse", "ColinKennedy/mega.logging" },
    version = "v1.*",
}
```

# Configuration

(These are default values, for the current template scaffolding)

```lua
{
    "asakura/treemotion.nvim",
    config = function()
        vim.g.treemotion_configuration = {
            commands = {
                goodnight_moon = { read = { phrase = "A good book" } },
                hello_world = {
                    say = { ["repeat"] = 1, style = "lowercase" },
                },
            },
            logging = {
                level = "info",
                use_console = false,
                use_file = false,
            },
        }
    end
}
```

# Commands

The `:TreeMotion` command tree currently only exposes the template's example
subcommands. See `plugin/treemotion.lua` for how they're wired up.

```vim
" A typical subcommand
:TreeMotion hello-world say phrase "Hello, World!" " How are you?"
:TreeMotion hello-world say phrase "Hello, World!" --repeat=2 --style=lowercase

" An example of a flag this repeatable and 3 flags, -a, -b, -c, as one dash
:TreeMotion arbitrary-thing -vvv -abc -f

" Separate commands with completely separate, flexible APIs
:TreeMotion goodnight-moon count-sheep 42
:TreeMotion goodnight-moon read "a book"
:TreeMotion goodnight-moon sleep -z -z -z
```

# Development

Enter the dev shell (provides Neovim, `mega.cmdparse`, `mega.logging`,
LuaCATS type stubs, and every lint/format/doc tool, all pinned by the flake):

```sh
nix develop
```

Run every check in one shot (sandboxed, offline):

```sh
nix flake check
```

Or run checks individually:

```sh
nix run .#test               # busted .
nix run .#stylua             # auto-formats lua/plugin/scripts/spec in place
nix run .#luacheck           # lints lua/plugin/scripts/spec
nix run .#llscheck           # type-checks against .luarc.json
nix run .#mdformat           # formats README.md + markdown/manual/docs/index.md
nix run .#coverage-html      # busted under luacov, writes luacov_html/
nix run .#api-documentation  # regenerates doc/treemotion_api.txt + doc/treemotion_types.txt
```

Run a single test file or tag (inside `nix develop`):

```sh
busted spec/treemotion/treemotion_spec.lua
busted . --tags=simple
```

# Coverage

`treemotion.nvim` can generate a per-line breakdown of exactly where your
code is lacking tests using [LuaCov](https://luarocks.org/modules/mpeterv/luacov).

```sh
nix run .#coverage-html
```

This generates a `luacov.stats.out` file and a `luacov_html/` directory
(`nix flake check`'s `coverage` check enforces an 80% minimum). View it with:

```sh
(cd luacov_html && python -m http.server)
```

Then open `http://0.0.0.0:8000` in a browser and navigate down into a `.lua`
file to see its line-by-line coverage.

# Tracking Updates

See [doc/news.txt](doc/news.txt) for updates.

You can watch this plugin for changes by adding this URL to your RSS feed:

```
https://github.com/asakura/treemotion.nvim/commits/main/doc/news.txt.atom
```
