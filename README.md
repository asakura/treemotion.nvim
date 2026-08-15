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

Comments and string content (or any other span a language's treesitter
query tags `@spell` or `@string`) are treated as prose instead of code:
they first split into individual words on whitespace, the way real Vim's
`w` does in a text file, before naming-convention splitting applies to each
word. String content counts as prose because it just as often holds free
text -- a description, an error message, a URL -- as it does an
identifier-like slug, and most treesitter highlight queries only ever tag
comments (not strings) `@spell`.

A run of that language's comment-opener punctuation -- e.g. Python/Bash
`#`, C/Rust `/` (Rust's `///`), LaTeX `%`, Vim `"`, a treesitter query
file's `;`, or Lua's `-` (its `--` opener, or a `-----` separator) -- is one
stop by default, the same as a `-`/`_` inside an identifier. Set
`comment_marker_case = "skip"` to jump straight past it to the next real
word instead, independently of `kebab_case`/`snake_case` (which govern
`-`/`_` next to a real letter or digit, e.g. `hello-world`, and keep
governing even a bare `-`/`_` run in any language that hasn't listed that
character as a comment marker -- see below). See
`commands.motion.small.code` / `.prose` under `Configuration` to control
`comment_marker_case` itself per context.

#### Structured prose tokens

`:` and `/` never produce their own landing stop or block a word run within
prose -- `colon_case`/`slash_case` both default to `"skip"` there -- so a
reference like `github:NixOS/nixpkgs`, a URL (`https://host/path`), or a
filesystem path (`/a/b/c`, `./a/b/c`) stays readable as one structured token
instead of fragmenting at every `:`/`/`. (`code`'s `colon_case`/`slash_case`
default to `"none"` instead, since real identifiers essentially never
contain a literal `:`/`/` -- inert there by default.)

A run that looks like an opaque hash or digest -- a hex string, or a
base64-alphabet string with both an uppercase and a lowercase letter, at
least `opaque_token_min_length` characters long (default `20`, comfortably
under a 40-character sha1 hex digest or a 44-character base64 sha256
digest) -- is treated as one unit and never split internally on case, e.g.
`A8YgMXtKnd9nSsRClkfz8cUbKHIUTRN2vudge6EfSgU` stays whole instead of
fragmenting at every case transition. This is a pure charset-and-length
heuristic, not a list of known algorithms, so it also matches things that
merely look hash-shaped. A trailing `=` (base64 padding) is folded into the
same unit rather than becoming its own tiny stop.

**Known caveat:** `kebab_case` still governs `-`, and prose's default for it
is `"stop"` (deliberate, for ordinary hyphenated English compounds like
"well-known"). That means `github:NixOS/nixpkgs/nixos-unstable` splits into
`github`, `Nix`, `OS`, `nixpkgs`, `nixos`, `-`, `unstable` out of the box --
the `-` in `nixos-unstable` (and in a `sha256-...` prefix) still lands as
its own stop. Set `kebab_case = "skip"` for prose if you want hyphens
ignored the same way `:`/`/` already are.

#### Backtick-enclosed identifiers

Within prose, a backtick-enclosed span that's exactly one Vim word --
`` `fooBar` ``, `` `foo-bar` `` -- is treated as a code identifier: `code`'s
`camel_case`/`pascal_case`/`kebab_case`/`snake_case`/`comment_marker_case`
rules apply to it instead of `prose`'s, and the backticks themselves are
never landing stops, the same way a `comment_marker_case = "skip"` run
already isn't. A backtick pair that isn't exactly one word (multiple words,
e.g. `` `foo bar` ``, or an empty pair with nothing between them) is left as
ordinary prose text, backticks included, with no behavior change.

This is on by default; set `commands.motion.small.backtick_identifiers = false`.

#### Comment-marker characters

Which characters count as comment-marker punctuation -- `-`/`_` included,
exactly like every other character -- is configured per treesitter
language, via `commands.motion.comment_markers` (see
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

String content gets full prose treatment too, via `@string` rather than
`@spell` -- unlike `@spell`, virtually every language's highlight query
already tags strings this way, so it isn't tracked as a separate column
below.

11 languages ship with comment-marker support built in, active regardless
of what other treesitter parsers you have installed:

| Language | Comment markers | Prose (`@spell`) |
| -------- | --------------- | ---------------- |
| `bash` | `✓` | - |
| `c` | `✓` | `✓` |
| `cpp` | `✓` | - |
| `latex` | `✓` | - |
| `lua` | `✓` | `✓` |
| `python` | `✓` | - |
| `query` | `✓` | `✓` |
| `rust` | `✓` | - |
| `sh` | `✓` | - |
| `tex` | `✓` | - |
| `vim` | `✓` | `✓` |

<details>
<summary>124 more languages, auto-detected once their treesitter parser is installed</summary>

| Language | Comment markers | Prose (`@spell`) |
| -------------------- | --------------- | ---------------- |
| `ada` | `✓` | - |
| `agda` | `✓` | - |
| `arduino` | `✓` | - |
| `asm` | `✓` | - |
| `awk` | `✓` | - |
| `beancount` | `✓` | - |
| `c3` | `✓` | - |
| `c_sharp` | `✓` | - |
| `caddy` | `✓` | - |
| `cairo` | `✓` | - |
| `clojure` | `✓` | - |
| `cmake` | `✓` | - |
| `commonlisp` | `✓` | - |
| `cue` | `✓` | - |
| `d` | `✓` | - |
| `dart` | `✓` | - |
| `desktop` | `✓` | - |
| `devicetree` | `✓` | - |
| `dhall` | `✓` | - |
| `dockerfile` | `✓` | - |
| `editorconfig` | `✓` | - |
| `elixir` | `✓` | - |
| `elm` | `✓` | - |
| `elvish` | `✓` | - |
| `erlang` | `✓` | - |
| `fennel` | `✓` | - |
| `fish` | `✓` | - |
| `fsharp` | `✓` | - |
| `gdscript` | `✓` | - |
| `gdshader` | `✓` | - |
| `git_config` | `✓` | - |
| `git_rebase` | `✓` | - |
| `gitattributes` | `✓` | - |
| `gitcommit` | `✓` | - |
| `gitignore` | `✓` | - |
| `gleam` | `✓` | - |
| `glsl` | `✓` | - |
| `go` | `✓` | - |
| `graphql` | `✓` | - |
| `groovy` | `✓` | - |
| `haskell` | `✓` | - |
| `haskell_persistent` | `✓` | - |
| `hcl` | `✓` | - |
| `hjson` | `✓` | - |
| `hlsl` | `✓` | - |
| `hyprlang` | `✓` | - |
| `idris` | `✓` | - |
| `ini` | `✓` | - |
| `java` | `✓` | - |
| `javascript` | `✓` | - |
| `jq` | `✓` | - |
| `json5` | `✓` | - |
| `jsonnet` | `✓` | - |
| `julia` | `✓` | - |
| `kconfig` | `✓` | - |
| `kdl` | `✓` | - |
| `kitty` | `✓` | - |
| `kotlin` | `✓` | - |
| `ledger` | `✓` | - |
| `llvm` | `✓` | - |
| `luau` | `✓` | - |
| `make` | `✓` | - |
| `matlab` | `✓` | - |
| `meson` | `✓` | - |
| `muttrc` | `✓` | - |
| `nasm` | `✓` | - |
| `nginx` | `✓` | - |
| `nim` | `✓` | - |
| `nix` | `✓` | - |
| `objc` | `✓` | - |
| `odin` | `✓` | - |
| `pascal` | `✓` | - |
| `perl` | `✓` | - |
| `php` | `✓` | - |
| `php_only` | `✓` | - |
| `pkl` | `✓` | - |
| `powershell` | `✓` | - |
| `prolog` | `✓` | - |
| `promql` | `✓` | - |
| `properties` | `✓` | - |
| `proto` | `✓` | - |
| `prql` | `✓` | - |
| `puppet` | `✓` | - |
| `purescript` | `✓` | - |
| `pymanifest` | `✓` | - |
| `r` | `✓` | - |
| `racket` | `✓` | - |
| `requirements` | `✓` | - |
| `rescript` | `✓` | - |
| `robots_txt` | `✓` | - |
| `ron` | `✓` | - |
| `ruby` | `✓` | - |
| `scala` | `✓` | - |
| `scheme` | `✓` | - |
| `scss` | `✓` | - |
| `snakemake` | `✓` | - |
| `solidity` | `✓` | - |
| `sparql` | `✓` | - |
| `sql` | `✓` | - |
| `ssh_config` | `✓` | - |
| `starlark` | `✓` | - |
| `swift` | `✓` | - |
| `sxhkdrc` | `✓` | - |
| `systemverilog` | `✓` | - |
| `tcl` | `✓` | - |
| `teal` | `✓` | - |
| `terraform` | `✓` | - |
| `thrift` | `✓` | - |
| `tmux` | `✓` | - |
| `toml` | `✓` | - |
| `tsx` | `✓` | - |
| `typescript` | `✓` | - |
| `typespec` | `✓` | - |
| `udev` | `✓` | - |
| `unison` | `✓` | - |
| `v` | `✓` | - |
| `vala` | `✓` | - |
| `vhdl` | `✓` | - |
| `wgsl` | `✓` | - |
| `wgsl_bevy` | `✓` | - |
| `yaml` | `✓` | - |
| `zathurarc` | `✓` | - |
| `zig` | `✓` | - |
| `zsh` | `✓` | - |

</details>

Markup/template languages with block-only or multi-character comment
delimiters (HTML, XML, JSON, Jinja/Twig/Liquid, Markdown, reStructuredText)
and dozens of very niche grammars are deliberately excluded from both
tables rather than guessed at; add them yourself via
`commands.motion.comment_markers` if you need them (see
`Configuration` below).

#### Insignificant characters

Punctuation like `.`, `=`, `{`, `}`, `;`, `[`, `]` is usually its own leaf,
so `w`/`e`/`b`/`ge` stop on it just like any other leaf by default -- real
treesitter-driven motion, but noisier than skimming past it entirely.
`commands.motion.insignificant_characters`, keyed by treesitter language
name (same convention as `comment_markers`), lists leaf texts that should be
invisible to word motions instead:

```lua
commands = {
    motion = {
        insignificant_characters = {
            lua = { ";" },
        },
    },
},
```

With that set, `w`/`b` glide straight past a `;` leaf to the next/previous
real leaf, the same way a `comment_marker_case = "skip"` run already isn't a
landing stop. It's still real buffer text -- `x`, `dd`, highlighting, and
everything else are unaffected; only word-motion traversal ignores it. An
entry has to match a leaf's **entire** text exactly, not merely appear
inside it, so a multi-character token (`"->"`, `"::"`) works too, not just a
single character.

This applies to **code** leaves only -- a *named* leaf tagged `@spell`/`@string`
(prose, or string content) never has any of its characters treated as
insignificant, since prose already does its own punctuation-is-a-word
splitting (see `Comments and prose` above). A `;` inside a comment or string
still stops `w` as normal. An *unnamed* leaf -- a fixed grammar token, like a
string's own quote delimiters, rather than a rule that captures real text --
is fair game even when it's `@string`/`@spell`-tagged too: highlight queries
often paint a string's quotes the same color as its content for a uniform
look (`(string) @string` in Lua, `(string_expression "\"" @string)` in Nix),
but that's a coloring choice, not a claim that the quote itself is prose.

Unlike `comment_markers`, this ships with **no** defaults for almost every
language -- comment syntax is an objective fact about a grammar, but which
punctuation counts as "insignificant" is a personal taste call (some setups
want `w` to stop on `{`/`}` to jump between blocks), so it's opt-in only.
`:checkhealth treemotion` warns the same way `comment_markers` does if a
language you add here has no treesitter parser installed.

The one exception is a small, curated set of near-universal cases, resolved
the same way `comment_markers`' own auto-detected languages are (see above):
auto-detected once that language's treesitter parser is installed, with no
configuration needed.

| Language | `{` | `}` | `[` | `]` | `;` | `"` | `''` |
| -------- | --- | --- | --- | --- | --- | --- | ---- |
| `nix` | `✓` | `✓` | `✓` | `✓` | `✓` | `✓` | `✓` |

A user-configured `insignificant_characters` entry for a language normally
overrides this table entirely, same as `comment_markers`. To keep most of an
auto-detected (or shipped) list but drop just one character, map it to
`false` instead of writing out a full replacement list -- a plain Lua `nil`
can't survive as a table value (`:help vim.NIL`), so `false` is the
explicit "remove this one" marker:

```lua
commands = {
    motion = {
        insignificant_characters = {
            -- Keeps Nix's auto-detected `{`/`}`/`[`/`]`, drops only `;`.
            nix = { [";"] = false },
        },
    },
},
```

A `false` entry can be combined with ordinary string elements in the same
table, e.g. `nix = { ",", [";"] = false }` drops `;` and adds `,` on top of
the rest of the auto-detected list.

`W`/`E`/`B`/`gE` (below) respect the same setting too: an insignificant
leaf that would otherwise form its own isolated run (e.g. `foo ; bar`, with
whitespace on both sides of `;`) is no longer its own stop either. A run
that mixes an insignificant leaf with others and no whitespace (`foo;bar`)
is unaffected either way -- it was already one stop before this setting
existed, since `W`/`E`/`B`/`gE` never stopped on punctuation glued to its
neighbors in the first place.

### `W` / `E` / `B` / `gE` (WORD motions)

Move one contiguous _run_ of leaves at a time -- a run is a maximal
sequence of leaves with no whitespace between them, mirroring how Vim's
real `W` ignores punctuation inside a WORD while `w` stops on it. By
default these ignore sub-words entirely, the same way real `W` ignores
punctuation -- a whole run is always one stop.

Set `commands.motion.big.enabled = true` to opt in to real,
case/delimiter-aware sub-splitting within each run too, configured via
`commands.motion.big.code` / `.prose` -- the same shape as `commands.motion.small`'s
(see `Comments and prose`, `Structured prose tokens`, and
`Backtick-enclosed identifiers` above; everything documented there applies
here too, just scoped to a whole run of leaves instead of one leaf).
`enabled = false` (the default) is exactly today's behavior, byte-for-byte;
none of `commands.motion.big`'s other fields have any effect until you flip it.

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
                -- Which single characters count as comment-marker
                -- punctuation, per treesitter language. A language with
                -- no entry has none at all -- add your own to extend this
                -- list. Shared by both `small` and `big` below.
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
                -- Leaf-level tokens that are invisible to word motions
                -- entirely, per treesitter language, for code leaves only
                -- (prose is never affected). Ships empty -- opt-in only,
                -- unlike `comment_markers` above.
                insignificant_characters = {},
                -- `w`/`e`/`b`/`ge`: sub-word splitting within one leaf.
                small = {
                    -- Whether a backtick-enclosed single word within prose
                    -- (`` `fooBar` ``) is treated as a code identifier, with
                    -- the backticks themselves never landing stops.
                    backtick_identifiers = true,
                    -- Identifiers and similar: `-`/`_` divide but are never
                    -- landed on themselves; `:`/`/` essentially never appear
                    -- in real identifiers, so they're inert here by default.
                    code = {
                        camel_case = true,
                        pascal_case = true,
                        kebab_case = "skip",
                        snake_case = "skip",
                        colon_case = "none",
                        slash_case = "none",
                        comment_marker_case = "stop",
                        -- Minimum length (after stripping trailing `=`
                        -- padding) for a hex/base64-alphabet run to be
                        -- treated as an opaque hash/digest -- one unit,
                        -- never split on its internal case transitions.
                        opaque_token_min_length = 20,
                    },
                    -- Comments, string content, or any other `@spell`-/`@string`-
                    -- tagged span: mirrors real Vim's own `iskeyword` in a text
                    -- file, where `-` is punctuation (its own stop) but `_` is a
                    -- keyword character (doesn't split at all). `:`/`/` are
                    -- ignored entirely by default, so structured tokens like
                    -- `github:owner/repo`, a URL, or a filesystem path read as
                    -- one unit instead of fragmenting at every `:`/`/`.
                    prose = {
                        camel_case = true,
                        pascal_case = true,
                        kebab_case = "stop",
                        snake_case = "none",
                        colon_case = "skip",
                        slash_case = "skip",
                        comment_marker_case = "stop",
                        opaque_token_min_length = 20,
                    },
                },
                -- `W`/`E`/`B`/`gE`: sub-word splitting within a whole run of
                -- contiguous leaves. `enabled = false` (the default) is
                -- exactly today's behavior -- a run is always one stop,
                -- ignoring case/delimiters entirely; none of this group's
                -- other fields have any effect until you flip it to `true`.
                -- The `code`/`prose` shape is identical to `small`'s above.
                big = {
                    enabled = false,
                    backtick_identifiers = true,
                    code = {
                        camel_case = false,
                        pascal_case = false,
                        kebab_case = "none",
                        snake_case = "none",
                        colon_case = "none",
                        slash_case = "none",
                        comment_marker_case = "none",
                        opaque_token_min_length = 20,
                    },
                    prose = {
                        camel_case = false,
                        pascal_case = false,
                        kebab_case = "none",
                        snake_case = "none",
                        colon_case = "none",
                        slash_case = "none",
                        comment_marker_case = "none",
                        opaque_token_min_length = 20,
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
