# treemotion.nvim

Treesitter-driven `w`/`e`/`b`/`ge`/`W`/`E`/`B`/`gE` motions, per filetype.

[![test](https://img.shields.io/github/actions/workflow/status/asakura/treemotion.nvim/test.yml?branch=main&style=for-the-badge&label=Test)](https://github.com/asakura/treemotion.nvim/actions/workflows/test.yml)
[![documentation](https://img.shields.io/github/actions/workflow/status/asakura/treemotion.nvim/documentation.yml?branch=main&style=for-the-badge&label=Documentation)](https://github.com/asakura/treemotion.nvim/actions/workflows/documentation.yml)
[![lints](https://img.shields.io/github/actions/workflow/status/asakura/treemotion.nvim/lints.yml?branch=main&style=for-the-badge&label=Lints)](https://github.com/asakura/treemotion.nvim/actions/workflows/lints.yml)
[![checkhealth](https://img.shields.io/github/actions/workflow/status/asakura/treemotion.nvim/checkhealth.yml?branch=main&style=for-the-badge&label=checkhealth)](https://github.com/asakura/treemotion.nvim/actions/workflows/checkhealth.yml)
[![urlchecker](https://img.shields.io/github/actions/workflow/status/asakura/treemotion.nvim/urlchecker.yml?branch=main&style=for-the-badge&label=URLChecker)](https://github.com/asakura/treemotion.nvim/actions/workflows/urlchecker.yml)
[![commitlint](https://img.shields.io/github/actions/workflow/status/asakura/treemotion.nvim/commitlint.yml?branch=main&style=for-the-badge&label=Commitlint)](https://github.com/asakura/treemotion.nvim/actions/workflows/commitlint.yml)
[![License-MIT](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)](https://github.com/asakura/treemotion.nvim/blob/main/LICENSE)
[![RSS](https://img.shields.io/badge/rss-F88900?style=for-the-badge&logo=rss&logoColor=white)](https://github.com/asakura/treemotion.nvim/commits/main/doc/news.txt.atom)

# Installation

## lazy.nvim

```lua
{
    "asakura/treemotion.nvim",
    dependencies = { "ColinKennedy/mega.cmdparse", "ColinKennedy/mega.logging" },
    version = "v1.*",
}
```

## Nix

This flake exports `overlays.default`, which adds `treemotion.nvim` (plus its
`mega.cmdparse`/`mega.logging` dependencies) to `pkgs.vimPlugins` as ordinary
Neovim plugin derivations.

Add it as a flake input and overlay it onto your own `nixpkgs`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    treemotion-nvim.url = "github:asakura/treemotion.nvim";
  };

  outputs =
    { nixpkgs, treemotion-nvim, ... }:
    let
      pkgs = import nixpkgs {
        system = "x86_64-linux";
        overlays = [ treemotion-nvim.overlays.default ];
      };
    in
    {
      # `pkgs.vimPlugins.treemotion-nvim` is now available, e.g.:
      #
      # pkgs.neovim.override {
      #   configure.packages.myPlugins.start = [ pkgs.vimPlugins.treemotion-nvim ];
      # };
    };
}
```

Without adding a flake input (e.g. directly in a NixOS or home-manager
`nixpkgs.overlays` list), `builtins.getFlake` fetches it the same way:

```nix
nixpkgs.overlays = [
  (builtins.getFlake "github:asakura/treemotion.nvim").overlays.default
];
```

### With lazyvim-nix

[lazyvim-nix](https://github.com/pfassina/lazyvim-nix) drives lazy.nvim's
`plugins.<key>` option with plain Lua-spec strings, so a plugin sourced from
the Nix store (rather than fetched by lazy.nvim itself over the network)
just needs a `dir = "..."` field pointing at the derivation, the same way
lazyvim-nix's own bundled plugins are wired. Apply this flake's overlay to
get `pkgs.vimPlugins.treemotion-nvim` (plus `mega-cmdparse`/`mega-logging`),
then reference their store paths:

```nix
programs.lazyvim = {
  enable = true;

  plugins.treemotion = ''
    return {
      {
        "asakura/treemotion.nvim",
        dir = "${pkgs.vimPlugins.treemotion-nvim}",
        dependencies = {
          { "ColinKennedy/mega.cmdparse", dir = "${pkgs.vimPlugins.mega-cmdparse}" },
          { "ColinKennedy/mega.logging", dir = "${pkgs.vimPlugins.mega-logging}" },
        },
        opts = {},
      },
    }
  '';
};
```

# Motions

`treemotion` moves the cursor over treesitter nodes instead of Vim's
character classes -- no per-filetype configuration needed, since it walks
whatever parser is already attached to the buffer.

- `w` / `e` / `b` / `ge` move one treesitter leaf at a time (an identifier, a
  number, or a single punctuation token like `.` or `,`).
- `W` / `E` / `B` / `gE` move one contiguous _run_ of leaves at a time -- a
  run is a maximal sequence of leaves with no whitespace between them,
  mirroring how Vim's real `W` ignores punctuation inside a WORD while `w`
  stops on it.

Both families are exposed as `:TreeMotion motion {name} [--count=N]` and as
`<Plug>` mappings, `<Plug>(TreeMotionw)` through `<Plug>(TreeMotiongE)`,
case-sensitive to match Vim's own `w` vs `W`. Neither is bound to a key by
default, so pick your own:

## Plain Neovim

```lua
for _, name in ipairs({ "w", "e", "b", "ge", "W", "E", "B", "gE" }) do
    vim.keymap.set({ "n", "x", "o" }, name, string.format("<Plug>(TreeMotion%s)", name))
end
```

## lazy.nvim

```lua
{
    "asakura/treemotion.nvim",
    dependencies = { "ColinKennedy/mega.cmdparse", "ColinKennedy/mega.logging" },
    keys = {
        { "w", "<Plug>(TreeMotionw)", mode = { "n", "x", "o" }, desc = "Next treesitter leaf" },
        { "e", "<Plug>(TreeMotione)", mode = { "n", "x", "o" }, desc = "End of treesitter leaf" },
        { "b", "<Plug>(TreeMotionb)", mode = { "n", "x", "o" }, desc = "Previous treesitter leaf" },
        { "ge", "<Plug>(TreeMotionge)", mode = { "n", "x", "o" }, desc = "End of previous treesitter leaf" },
        { "W", "<Plug>(TreeMotionW)", mode = { "n", "x", "o" }, desc = "Next treesitter WORD" },
        { "E", "<Plug>(TreeMotionE)", mode = { "n", "x", "o" }, desc = "End of treesitter WORD" },
        { "B", "<Plug>(TreeMotionB)", mode = { "n", "x", "o" }, desc = "Previous treesitter WORD" },
        { "gE", "<Plug>(TreeMotiongE)", mode = { "n", "x", "o" }, desc = "End of previous treesitter WORD" },
    },
}
```

Binding through `keys` (rather than `opts`/`config`) lets lazy.nvim lazy-load
`treemotion.nvim` the first time one of these mappings is pressed, replaying
the key once the `<Plug>` mapping is actually defined.

Counts work as usual (e.g. `3w`, `2W`) -- the `<Plug>` mappings read
`v:count1`. `n`/`x`/`o` modes mean these also compose with operators for
free (`dw`, `cW`, ...) without a custom `'operatorfunc'`.

# Configuration

(These are default values, for the current template scaffolding)

`treemotion` exposes a `setup(opts)` function, so lazy.nvim's `opts` table
works as expected:

```lua
{
    "asakura/treemotion.nvim",
    opts = {
        hints = "none",
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
    },
}
```

Equivalently, you can set `vim.g.treemotion_configuration` directly (useful
outside of lazy.nvim, or if you need the values available before `treemotion`
loads):

```lua
{
    "asakura/treemotion.nvim",
    config = function()
        vim.g.treemotion_configuration = {
            hints = "none",
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

The `:TreeMotion` command tree exposes the real `motion` subcommand (see
`Motions` above) alongside the template's placeholder example subcommands
(see `Status`). See `plugin/treemotion.lua` for how they're all wired up.

```vim
" The real functionality
:TreeMotion motion w
:TreeMotion motion W --count=3

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
nix run .#user-documentation # regenerates doc/treemotion.txt + doc/tags from README.md via panvimdoc
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
(`nix flake check`'s `coverage` check enforces a 35.00% minimum). View it with:

```sh
nix run .#coverage-serve
```

Then open `http://127.0.0.1:8000` in a browser and navigate down into a `.lua`
file to see its line-by-line coverage.

# Tracking Updates

See [doc/news.txt](doc/news.txt) for updates.

You can watch this plugin for changes by adding this URL to your RSS feed:

```
https://github.com/asakura/treemotion.nvim/commits/main/doc/news.txt.atom
```
