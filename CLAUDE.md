# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## Mandatory rule

Always search Neovim's `:help` manual pages first. They are the source of truth
for Neovim itself, for Lua as used in Neovim, and for plugin development. Check
them before answering from general knowledge. To dump a help topic
non-interactively:

```sh
nvim --headless -c "help <topic>" -c "%print" -c "qa!"
```

Note that `%print` dumps the whole help file the tag lives in (for example
`map.txt`), not just that one section. Neovim has no built-in command that
prints a single entry. When `:help` doesn't cover a behavior at the level of
detail you need, read Neovim's runtime source (for example
`runtime/lua/vim/treesitter/languagetree.lua`) instead of guessing.

## Project

treemotion.nvim makes Neovim's word motions (`w` `e` `b` `ge` `W` `E` `B`
`gE`) and their operator ranges (`dw`, `cw`, `de`, ...) follow treesitter
leaves and naming-convention sub-words, with any grammar:

- `w`/`e`/`b`/`ge` step through the sub-words of one leaf at a time.
- `W`/`E`/`B`/`gE` step through runs of contiguous leaves.

They are exposed as `:TreeMotion motion {name} [--count=N]`, as
`<Plug>(TreeMotion{name})` and as `require("treemotion").run_motion_*`. The
repository started as a fork of ColinKennedy's
["Best Practices" Neovim plugin template](https://github.com/nvim-neorocks/nvim-best-practices).
The template's example commands are gone, and `motion` is the only subcommand.

**Read `DESIGN.md` before changing the motion code.** It records the grammar
shapes, the Neovim API quirks and the benchmark results the code depends on, and
the optimizations that were measured and rejected.

## Commands

The Nix flake provides every dependency: Neovim, `mega.cmdparse`,
`mega.logging`, the LuaCATS type stubs, and the lint, format and documentation
tools. There's no `luarocks install` or `git clone` step.

```sh
nix develop                  # a shell with everything on PATH, plus .luarc.json and .busted linked in
nix flake check              # every check below in one shot (sandboxed, offline)
```

You can also run each check on its own, either with `nix run` as below or with
`nix build .#checks.<system>.<name>`:

```sh
nix run .#test               # busted .
nix run .#stylua             # formats lua/ plugin/ scripts/ spec/ in place
nix run .#luacheck           # lints lua/ plugin/ scripts/ spec/
nix run .#llscheck           # type-checks against .luarc.json
nix run .#mdformat           # formats README.md, DESIGN.md, CLAUDE.md and markdown/manual/docs/index.md
nix run .#coverage-html      # busted under luacov, writes luacov_html/ (checks.coverage enforces a 90% minimum)
nix run .#coverage-serve     # serves luacov_html/ at http://127.0.0.1:8000
nix run .#api-documentation  # regenerates doc/treemotion_api.txt and doc/treemotion_types.txt from LuaCATS docstrings
nix run .#user-documentation # regenerates doc/treemotion.txt and doc/tags from README.md with panvimdoc
```

To run a single test file, do it inside `nix develop`:

```sh
busted spec/treemotion/operator_range_spec.lua
```

Before pushing, run test, stylua, luacheck and llscheck, plus mdformat if
Markdown changed. CI also runs the suite on Neovim 0.11.0, 0.12.0, stable and
nightly on Linux, and on stable on macOS and Windows. The `test-nix` job runs
`nix build .#treemotion-nvim` against nixos-unstable and nixos-26.05 (using
`--override-input nixpkgs`).

`.busted` runs the tests in headless Neovim itself:
`lua = "nvim -u NONE -U NONE -N -i NONE --cmd 'set rtp+=<treesitterAllGrammars>' -l"`.
`spec/minimal_init.lua`, busted's helper, only bootstraps Neovim: it sets up
`rtp`, runs `runtime plugin/treemotion.lua` and initializes the configuration.
Tests never touch the network.

## Architecture

- **`plugin/treemotion.lua`**: the entry point. Any value of
  `g:loaded_treemotion`, even `0`, disables the plugin. It builds a single
  `mega.cmdparse.ParameterParser` tree and mounts it under the `:TreeMotion`
  user command, so commands are never wired up with `nvim_create_user_command`
  directly. It also defines the `<Plug>(TreeMotion{name})` mappings. These
  are `<expr>` mappings, so that `dge` can be forced inclusive with `v`.
- **`lua/treemotion/init.lua`**: the public API. Each function is a thin
  wrapper around `_commands/motion/runner.lua`. Changing a signature here in an
  incompatible way needs a major version bump.
- **`lua/treemotion/_commands/motion/`**:
  - `parser.lua` builds the `mega.cmdparse` parser and wires its arguments to
    `runner.lua`. The CLI and the Lua API therefore reach a single
    implementation.
  - `runner.lua` maps a motion name to a shape and a unit family, or to
    `operator` when an operator is pending. It resolves `settings` once per
    motion.
  - `shape.lua` holds the four step shapes. Each one is pure: it takes a
    position and returns a position.
  - `unit.lua` provides the sub-word unit sources: one leaf for `w`, a run of
    contiguous leaves for `W`.
  - `leaf.lua` and `injection.lua` walk leaves across language injections.
  - `subword.lua` splits a leaf or a run. It uses `classify` (prose, code or
    insignificant), the pure string splitters `prose`, `delimiters` and `case`,
    `codepoint` (UTF-8 and Vim's character classes) and `span` (offsets to
    buffer positions).
  - `operator.lua` computes operator-pending ranges.
  - The helpers are `position`, `settings` and `constant`.
- **`lua/treemotion/_core/configuration.lua`**: the single source of truth for
  configuration. On first use it merges `_DEFAULTS` with
  `vim.g.treemotion_configuration`. It also holds the optional per-language
  tables (`_OPTIONAL_COMMENT_MARKERS` and `_OPTIONAL_INSIGNIFICANT_CHARACTERS`),
  which only apply when that language's parser is installed, and it configures
  `mega.logging`. A module-local flag makes initialization run only once. It
  isn't a `g:` variable, because `g:` survives a module reload.
- **`lua/treemotion/_core/schema.lua`** and **`health.lua`**: `:checkhealth`
  validates the configuration against the schema. `configuration_spec.lua`
  checks that the schema and `_DEFAULTS` declare the same keys.
- **`lua/treemotion/types.lua`**: LuaCATS annotations only, with no runtime
  code.
- **`doc/treemotion_api.txt`** and **`doc/treemotion_types.txt`**: generated
  from the `init.lua` and `types.lua` docstrings with `mega.vimdoc` (see
  `scripts/make_api_documentation/main.lua`). Don't edit them by hand.
- **`doc/treemotion.txt`**: generated from `README.md` with panvimdoc, taken
  from nixpkgs, which is a wrapper around `pandoc` and a Lua filter.
  `.github/workflows/documentation.yml` regenerates it on every push to `main`,
  so it lags one push behind `README.md`.

### Nix packaging of runtime dependencies

`mega.cmdparse` and `mega.logging` aren't in nixpkgs. `nix/mega-cmdparse.nix`
and `nix/mega-logging.nix` build them from their GitHub tags with
`vimUtils.buildVimPlugin`, the same way nixpkgs builds other Neovim plugins.
That keeps each plugin's normal `lua/` layout, so `.luarc.json`'s
`workspace.library` and `.busted`'s `lpath` just point at
`<store path>/lua`. There's no luarocks `share/lua/5.1` layout to bridge.

`flake.nix` renders `.luarc.json` and `.busted` with `pkgs.writeText`, with the
store paths baked in. `linkDependencies` links them into the working tree.
Neither file is committed: both are gitignored. The LuaCATS stubs for `busted`
and `luassert` have no rockspec, so they're fetched with `fetchFromGitHub` and
wrapped by `toLuaAnnotationModule`. `lustache` and `luacov-multiple` are used
only by the coverage tooling. They're plain Lua rocks
(`lua51.buildLuarocksPackage`, consumed via `pkgs.lua5_1.withPackages`).

`overlays.default` exports `vimPlugins.mega-logging`, `vimPlugins.mega-cmdparse`
and `vimPlugins.treemotion-nvim` (`nix/treemotion-nvim.nix`). Downstream
flakes can then use `pkgs.vimPlugins.treemotion-nvim` like any other plugin,
and the flake's own `pkgs` applies the same overlay. The package's
`checkPhase` runs the busted suite, so a successful
`nix build .#treemotion-nvim` is a passing test run.

`treesitterAllGrammars` is a `symlinkJoin` of every
`vimPlugins.nvim-treesitter-parsers.*` derivation, which merges each
`parser/<lang>.so` into one directory shaped like a plugin. It's deliberately
not part of the overlay. It only feeds `.busted`'s `--cmd 'set rtp+=...'`, so
`nix run .#test`, `checks.test` and the dev shell have every grammar nixpkgs
knows. Grammars are found on `runtimepath`, not on `lpath`. The package's
`checkPhase` has only the grammars bundled with Neovim: `c`, `lua`, `markdown`,
`markdown_inline`, `query`, `vim` and `vimdoc`.

## Rules for the motion code

- **Stay grammar-agnostic.** Never branch on node type names or language names.
  Use generic shapes instead: leaves, gaps, partial coverage, runs, highlight
  captures (`@spell` and `@string` mean prose), and leaf text. Per-language data
  belongs in the configuration tables (`comment_markers`,
  `insignificant_characters`), not in code.
- **Match real Vim.** When in doubt, compare with Neovim's built-in motion on
  the same text, and cite `:help` for the behavior.
- **Steps take a position and return a position.** Only the wrappers that move
  the cursor, and `operator.apply`, read or move it.
- **Columns are byte offsets.** Step across characters with `codepoint`, never
  with `column - 1`.
- **Never edit the configuration in place.** `configuration.resolve_data()`
  returns `M.DATA` itself, so anything that changes the configuration must
  replace the table.
- **Measure before optimizing.** Several "obvious" wins in this code were
  measured and turned out to be noise. `DESIGN.md` lists them, along with the
  benchmark recipe and its traps.

## Tests

- Prefer fixtures in the grammars bundled with Neovim, because the package's
  `checkPhase` has only those. A fixture in any other grammar must go through
  `grammar_helpers.wrap`, which marks the test pending when the parser is
  missing. Pass the spec file's own `pending` in, because modules loaded with
  `require` can't see it.
- `treesitterAllGrammars` has parsers but no highlight queries. A prose fixture
  in a non-bundled grammar therefore needs `comment_node`, which registers a
  synthetic `@spell` query. Without it, the fixture silently uses the code
  rules.
- `configuration.DATA` is shared across the whole busted process. Snapshot it
  and restore it in `after_each`.
- Take expected columns from real behavior (the plugin, or Vim's built-in
  motions), not from working them out by hand. Put the leaf layout in a short
  comment above the fixture.
- Every behavior change needs a regression test. Properties that must hold for
  every rule value, such as forward and backward steps undoing each other,
  belong in `motion_mirror_spec.lua`.

## Style

- stylua formats the Lua (4 spaces). Every function has LuaCATS annotations.
  Private module functions are `local function _name`.
- Comments are contracts: one line saying what a function takes and returns,
  plus a short "why" only where the code can't show it. Don't put history,
  debugging logs or benchmark numbers in comments. Findings worth keeping go in
  `DESIGN.md`.
- Commits follow Conventional Commits (`committed.toml`). The subject is
  lowercase and at most 72 characters. The allowed types are `feat`, `fix`,
  `docs`, `refactor`, `perf`, `test`, `build`, `ci`, `chore` and `style`, with
  scopes such as `motion`. A `feat` or a breaking change should update
  `doc/news.txt`.
