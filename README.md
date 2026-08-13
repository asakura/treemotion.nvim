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

## Installation

### lazy.nvim

```lua
{
    "asakura/treemotion.nvim",
    dependencies = { "ColinKennedy/mega.cmdparse", "ColinKennedy/mega.logging" },
    version = "v1.*",
}
```

### Nix

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

#### With lazyvim-nix

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

## Motions

`treemotion` moves the cursor over treesitter nodes instead of Vim's character
classes -- no per-filetype configuration needed, since it walks whatever
parser is already attached to the buffer. It provides two families
of motions, `w`/`e`/`b`/`ge` and `W`/`E`/`B`/`gE`, both exposed as
`:TreeMotion motion {name} [--count=N]` and as `<Plug>` mappings (see `Keymaps`
below).

### `w` / `e` / `b` / `ge` (leaf motions)

Move one treesitter leaf at a time -- an identifier, a number, or a single
punctuation token like `.` or `,`.

Within a leaf, they also move one naming-convention sub-word at a time,
e.g. `fooBar-bazQux` is four stops: `foo`, `Bar`, `baz`, `Qux`.

#### Comments and prose

Comments (or any other span a language's treesitter query tags `@spell`)
are treated as prose instead of code: they first split into individual
words on whitespace, the way real Vim's `w` does in a text file, before
naming-convention splitting applies to each word.

A run of that language's comment-opener punctuation -- e.g. Python/Bash
`#`, C/Rust `/` (Rust's `///`), LaTeX `%`, Vim `"`, a treesitter query
file's `;`, or Lua's `-` (its `--` opener, or a `-----` separator) -- is one
stop by default, the same as a `-`/`_` inside an identifier. Set
`comment_marker_case = "skip"` to jump straight past it to the next real
word instead, independently of `kebab_case`/`snake_case` (which govern
`-`/`_` next to a real letter or digit, e.g. `hello-world`, and keep
governing even a bare `-`/`_` run in any language that hasn't listed that
character as a comment marker -- see below). See
`commands.motion.subword.code` / `.prose` under `Configuration` to control
`comment_marker_case` itself per context.

#### Backtick-enclosed identifiers

Within prose, a backtick-enclosed span that's exactly one Vim word --
`` `fooBar` ``, `` `foo-bar` `` -- is treated as a code identifier: `code`'s
`camel_case`/`pascal_case`/`kebab_case`/`snake_case`/`comment_marker_case`
rules apply to it instead of `prose`'s, and the backticks themselves are
never landing stops, the same way a `comment_marker_case = "skip"` run
already isn't. A backtick pair that isn't exactly one word (multiple words,
e.g. `` `foo bar` ``, or an empty pair with nothing between them) is left as
ordinary prose text, backticks included, with no behavior change.

This is on by default; set `commands.motion.subword.backtick_identifiers = false`.

#### Comment-marker characters

Which characters count as comment-marker punctuation -- `-`/`_` included,
exactly like every other character -- is configured per treesitter
language, via `commands.motion.subword.comment_markers` (see
`Configuration` below). A language with no entry has no comment-marker
characters at all, so `comment_marker_case` is a no-op there until you add
one. This is deliberate, not an oversight, since the same punctuation means
unrelated things in different grammars (`"` opens a comment in Vimscript
but closes a string everywhere else).

`:checkhealth treemotion` warns if a language _you_ added to
`comment_markers` has no treesitter parser installed (a likely typo, or a
parser you haven't installed yet) -- it stays silent about the shipped
defaults, since most setups won't have every one of those parsers installed
and that isn't a problem.

Beyond the shipped defaults and anything you configure yourself, 124
additional languages are supported automatically, with no configuration
needed, as soon as their treesitter parser is installed -- see
`_OPTIONAL_COMMENT_MARKERS` in `lua/treemotion/_core/configuration.lua`, or
the table below, for the full list.

#### Supported languages

The `w`/`e`/`b`/`ge`/`W`/`E`/`B`/`gE` motions themselves work with **any**
treesitter grammar Neovim can parse -- they only look at generic node shape
(leaf, blank-line gap, partial-coverage child) and generic leaf text, never
a language's specific node type names. The two columns below track the two
things that _are_ per-language:

- **Comment markers** -- whether `comment_marker_case` (see above) knows
  that language's comment-opener punctuation at all.
- **Prose (`@spell`)** -- whether comments additionally get full _prose_
  treatment (splitting into words on whitespace, governed by `prose.*`
  instead of `code.*` settings -- see `Comments and prose` above). This
  needs the grammar's own treesitter _highlight query_ to tag the comment
  `@spell`, which lives in a separate `queries/<lang>/highlights.scm` file,
  not the parser. `✓` here means Neovim itself ships that query, so it
  works with zero extra setup; a `-` still gets comment-marker recognition,
  just governed by `code.comment_marker_case` until you install a plugin
  (typically `nvim-treesitter`) that provides one for that language.

11 languages ship with comment-marker support built in, active regardless
of what other treesitter parsers you have installed:

| Language | Comment markers | Prose (`@spell`) |
| -------- | --------------- | ---------------- |
| `bash`   | `✓`             | -                |
| `c`      | `✓`             | `✓`              |
| `cpp`    | `✓`             | -                |
| `latex`  | `✓`             | -                |
| `lua`    | `✓`             | `✓`              |
| `python` | `✓`             | -                |
| `query`  | `✓`             | `✓`              |
| `rust`   | `✓`             | -                |
| `sh`     | `✓`             | -                |
| `tex`    | `✓`             | -                |
| `vim`    | `✓`             | `✓`              |

<details>
<summary>124 more languages, auto-detected once their treesitter parser is installed</summary>

| Language             | Comment markers | Prose (`@spell`) |
| -------------------- | --------------- | ---------------- |
| `ada`                | `✓`             | -                |
| `agda`               | `✓`             | -                |
| `arduino`            | `✓`             | -                |
| `asm`                | `✓`             | -                |
| `awk`                | `✓`             | -                |
| `beancount`          | `✓`             | -                |
| `c3`                 | `✓`             | -                |
| `c_sharp`            | `✓`             | -                |
| `caddy`              | `✓`             | -                |
| `cairo`              | `✓`             | -                |
| `clojure`            | `✓`             | -                |
| `cmake`              | `✓`             | -                |
| `commonlisp`         | `✓`             | -                |
| `cue`                | `✓`             | -                |
| `d`                  | `✓`             | -                |
| `dart`               | `✓`             | -                |
| `desktop`            | `✓`             | -                |
| `devicetree`         | `✓`             | -                |
| `dhall`              | `✓`             | -                |
| `dockerfile`         | `✓`             | -                |
| `editorconfig`       | `✓`             | -                |
| `elixir`             | `✓`             | -                |
| `elm`                | `✓`             | -                |
| `elvish`             | `✓`             | -                |
| `erlang`             | `✓`             | -                |
| `fennel`             | `✓`             | -                |
| `fish`               | `✓`             | -                |
| `fsharp`             | `✓`             | -                |
| `gdscript`           | `✓`             | -                |
| `gdshader`           | `✓`             | -                |
| `git_config`         | `✓`             | -                |
| `git_rebase`         | `✓`             | -                |
| `gitattributes`      | `✓`             | -                |
| `gitcommit`          | `✓`             | -                |
| `gitignore`          | `✓`             | -                |
| `gleam`              | `✓`             | -                |
| `glsl`               | `✓`             | -                |
| `go`                 | `✓`             | -                |
| `graphql`            | `✓`             | -                |
| `groovy`             | `✓`             | -                |
| `haskell`            | `✓`             | -                |
| `haskell_persistent` | `✓`             | -                |
| `hcl`                | `✓`             | -                |
| `hjson`              | `✓`             | -                |
| `hlsl`               | `✓`             | -                |
| `hyprlang`           | `✓`             | -                |
| `idris`              | `✓`             | -                |
| `ini`                | `✓`             | -                |
| `java`               | `✓`             | -                |
| `javascript`         | `✓`             | -                |
| `jq`                 | `✓`             | -                |
| `json5`              | `✓`             | -                |
| `jsonnet`            | `✓`             | -                |
| `julia`              | `✓`             | -                |
| `kconfig`            | `✓`             | -                |
| `kdl`                | `✓`             | -                |
| `kitty`              | `✓`             | -                |
| `kotlin`             | `✓`             | -                |
| `ledger`             | `✓`             | -                |
| `llvm`               | `✓`             | -                |
| `luau`               | `✓`             | -                |
| `make`               | `✓`             | -                |
| `matlab`             | `✓`             | -                |
| `meson`              | `✓`             | -                |
| `muttrc`             | `✓`             | -                |
| `nasm`               | `✓`             | -                |
| `nginx`              | `✓`             | -                |
| `nim`                | `✓`             | -                |
| `nix`                | `✓`             | -                |
| `objc`               | `✓`             | -                |
| `odin`               | `✓`             | -                |
| `pascal`             | `✓`             | -                |
| `perl`               | `✓`             | -                |
| `php`                | `✓`             | -                |
| `php_only`           | `✓`             | -                |
| `pkl`                | `✓`             | -                |
| `powershell`         | `✓`             | -                |
| `prolog`             | `✓`             | -                |
| `promql`             | `✓`             | -                |
| `properties`         | `✓`             | -                |
| `proto`              | `✓`             | -                |
| `prql`               | `✓`             | -                |
| `puppet`             | `✓`             | -                |
| `purescript`         | `✓`             | -                |
| `pymanifest`         | `✓`             | -                |
| `r`                  | `✓`             | -                |
| `racket`             | `✓`             | -                |
| `requirements`       | `✓`             | -                |
| `rescript`           | `✓`             | -                |
| `robots_txt`         | `✓`             | -                |
| `ron`                | `✓`             | -                |
| `ruby`               | `✓`             | -                |
| `scala`              | `✓`             | -                |
| `scheme`             | `✓`             | -                |
| `scss`               | `✓`             | -                |
| `snakemake`          | `✓`             | -                |
| `solidity`           | `✓`             | -                |
| `sparql`             | `✓`             | -                |
| `sql`                | `✓`             | -                |
| `ssh_config`         | `✓`             | -                |
| `starlark`           | `✓`             | -                |
| `swift`              | `✓`             | -                |
| `sxhkdrc`            | `✓`             | -                |
| `systemverilog`      | `✓`             | -                |
| `tcl`                | `✓`             | -                |
| `teal`               | `✓`             | -                |
| `terraform`          | `✓`             | -                |
| `thrift`             | `✓`             | -                |
| `tmux`               | `✓`             | -                |
| `toml`               | `✓`             | -                |
| `tsx`                | `✓`             | -                |
| `typescript`         | `✓`             | -                |
| `typespec`           | `✓`             | -                |
| `udev`               | `✓`             | -                |
| `unison`             | `✓`             | -                |
| `v`                  | `✓`             | -                |
| `vala`               | `✓`             | -                |
| `vhdl`               | `✓`             | -                |
| `wgsl`               | `✓`             | -                |
| `wgsl_bevy`          | `✓`             | -                |
| `yaml`               | `✓`             | -                |
| `zathurarc`          | `✓`             | -                |
| `zig`                | `✓`             | -                |
| `zsh`                | `✓`             | -                |

</details>

Markup/template languages with block-only or multi-character comment
delimiters (HTML, XML, JSON, Jinja/Twig/Liquid, Markdown, reStructuredText)
and dozens of very niche grammars are deliberately excluded from both
tables rather than guessed at; add them yourself via
`commands.motion.subword.comment_markers` if you need them (see
`Configuration` below).

### `W` / `E` / `B` / `gE` (WORD motions)

Move one contiguous _run_ of leaves at a time -- a run is a maximal
sequence of leaves with no whitespace between them, mirroring how Vim's
real `W` ignores punctuation inside a WORD while `w` stops on it. These
ignore sub-words entirely, the same way real `W` ignores punctuation.

## Configuration

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
            motion = {
                subword = {
                    -- Which single characters count as comment-marker
                    -- punctuation, per treesitter language. A language with
                    -- no entry has none at all -- add your own to extend this
                    -- list.
                    comment_markers = {
                        c = { "/" },
                        cpp = { "/" },
                        rust = { "/" },
                        python = { "#" },
                        bash = { "#" },
                        sh = { "#" },
                        latex = { "%" },
                        tex = { "%" },
                        vim = { '"' },
                        query = { ";" },
                        lua = { "-" },
                    },
                    -- Whether a backtick-enclosed single word within prose
                    -- (`` `fooBar` ``) is treated as a code identifier, with
                    -- the backticks themselves never landing stops.
                    backtick_identifiers = true,
                    -- Identifiers, string content, and similar: `-`/`_` divide
                    -- but are never landed on themselves.
                    code = {
                        camel_case = true,
                        pascal_case = true,
                        kebab_case = "skip",
                        snake_case = "skip",
                        comment_marker_case = "stop",
                    },
                    -- Comments, or any other `@spell`-tagged span: mirrors real
                    -- Vim's own `iskeyword` in a text file, where `-` is
                    -- punctuation (its own stop) but `_` is a keyword character
                    -- (doesn't split at all).
                    prose = {
                        camel_case = true,
                        pascal_case = true,
                        kebab_case = "stop",
                        snake_case = "none",
                        comment_marker_case = "stop",
                    },
                },
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

### Keymaps

Both families are exposed as `:TreeMotion motion {name} [--count=N]` and as
`<Plug>` mappings, `<Plug>(TreeMotionw)` through `<Plug>(TreeMotiongE)`,
case-sensitive to match Vim's own `w` vs `W`. Neither is bound to a key by
default, so pick your own:

#### Plain Neovim

```lua
for _, name in ipairs({ "w", "e", "b", "ge", "W", "E", "B", "gE" }) do
    vim.keymap.set({ "n", "x", "o" }, name, string.format("<Plug>(TreeMotion%s)", name))
end
```

#### lazy.nvim

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

## Commands

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

## Development

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

## Coverage

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

## Tracking Updates

See [doc/news.txt](doc/news.txt) for updates.

You can watch this plugin for changes by adding this URL to your RSS feed:

```
https://github.com/asakura/treemotion.nvim/commits/main/doc/news.txt.atom
```
