# CLAUDE.md

treemotion.nvim makes Neovim's word motions (`w` `e` `b` `ge` `W` `E` `B`
`gE`) and their operator ranges (`dw`, `cw`, `de`, ...) follow treesitter
leaves and naming-convention sub-words. It works for any grammar. Read
`DESIGN.md` before changing the motion code. It records the grammar shapes,
Neovim API quirks and benchmark results the code depends on, and the
optimizations that were measured and rejected.

## Commands

Everything is pinned by `flake.nix`. Run tools inside `nix develop` or through
`nix run`:

```sh
nix run .#test        # busted . (runs under `nvim -l` with treesitterAllGrammars)
nix run .#stylua      # format lua/ plugin/ scripts/ spec/ in place
nix run .#luacheck
nix run .#llscheck    # LuaCATS type check against .luarc.json
nix run .#mdformat    # README.md, DESIGN.md, CLAUDE.md, markdown/manual/docs/index.md
nix flake check       # everything, including coverage (90% minimum) and the package build
busted spec/treemotion/operator_range_spec.lua   # one file, inside `nix develop`
```

Before pushing, run test, stylua, luacheck and llscheck, plus mdformat if
Markdown changed. CI also runs the suite on Neovim 0.11.0, 0.12.0, stable
and nightly on Linux, and on stable on macOS and Windows.

## Layout

- `lua/treemotion/init.lua`: the public API (`setup`, `run_motion_*`).
  Incompatible changes need a major version.
- `plugin/treemotion.lua`: `:TreeMotion` and the `<Plug>(TreeMotion*)`
  mappings. The mappings are `<expr>` so that `dge` can be forced with `v`.
- `lua/treemotion/_core/`: the configuration (defaults, optional per-language
  tables, merging) and `schema.lua`, which `:checkhealth` validates against.
  `configuration_spec.lua` keeps the schema and the defaults in sync.
- `lua/treemotion/_commands/motion/`, roughly top-down:
  - `runner`: maps a motion name to a shape and a unit family, or to
    `operator` when an operator is pending. Resolves `settings` once per
    motion.
  - `shape`: the four step shapes. Each is pure, taking a position and
    returning one.
  - `unit`: sub-word unit sources for `w` (one leaf) and `W` (a run of
    contiguous leaves).
  - `leaf` and `injection`: leaf walks across language injections.
  - `subword`: splits a leaf or run. It uses `classify` (prose, code or
    insignificant), the pure string splitters `prose`, `delimiters` and `case`,
    and the helpers `codepoint` (UTF-8, Vim's character classes) and `span`
    (offsets to buffer positions).
  - `operator`: operator-pending ranges.
  - Helpers: `position`, `settings`, `constant`, and `parser` (`:TreeMotion`
    arguments).
- `spec/treemotion/`: busted specs. `grammar_helpers.lua` is the shared
  scratch-buffer setup for cross-grammar specs.
- `doc/*.txt` is generated. CI regenerates it after merge from `README.md` and
  the LuaCATS docstrings (`nix run .#user-documentation`,
  `nix run .#api-documentation`). Don't edit it by hand.

## Rules for the motion code

- **Stay grammar-agnostic.** Never branch on node type names or language names.
  Use generic shapes instead: leaves, gaps, partial coverage, runs, highlight
  captures (`@spell`/`@string` mean prose), and leaf text. Per-language data
  belongs in the configuration tables (`comment_markers`,
  `insignificant_characters`), not in code.
- **Match real Vim.** When in doubt, compare with Neovim's built-in motion on
  the same text, and cite `:help` for the behavior. Get API behavior from
  `nvim --headless -c "help <topic>" -c "%print" -c "qa!"` or from Neovim's
  runtime source, not from memory.
- **Steps take a position and return a position.** Only the cursor-moving
  wrappers and `operator.apply` read or move the cursor.
- **Columns are byte offsets.** Step across characters with `codepoint`.
  Never use `column - 1`.
- **Don't edit the configuration in place.** `configuration.resolve_data()`
  returns `M.DATA` itself, so writers must replace the table.
- **Measure before optimizing.** Several "obvious" wins in this code were
  measured and found to be noise. `DESIGN.md` lists them, along with the
  benchmark recipe and its traps.

## Tests

- Prefer fixtures in Neovim's bundled grammars (`lua`, `c`, `vim`, `query`,
  `vimdoc`, `markdown`). `nix build .#treemotion-nvim` runs the suite with only
  those grammars. A fixture for any other grammar must go through
  `grammar_helpers.wrap`, which marks it pending when the parser is missing.
  Pass that file's own `pending` in, because `require`d modules can't see it.
- Grammars beyond the bundled ones come without highlight queries. A prose
  fixture for one needs `comment_node`, which registers a synthetic `@spell`
  query. Otherwise it silently runs with code rules.
- `configuration.DATA` is shared by the whole busted process. Snapshot it and
  restore it in `after_each`.
- Take expected columns from real behavior (the plugin, or built-in Vim
  motions), not from hand derivation, and put the leaf layout in a short
  comment above the fixture.
- Behavior changes need a regression test. Invariants that apply to every
  rule, such as forward and backward steps undoing each other, belong in
  `motion_mirror_spec.lua`.

## Style

- Lua is formatted by stylua (4 spaces). Every function gets LuaCATS
  annotations. Private module functions are `local function _name`.
- Comments are contracts: one line for what a function takes and returns,
  plus a short "why" only where the code can't show it. Don't put history,
  debugging logs or benchmark numbers in comments. Lasting findings go in
  `DESIGN.md`.
- Commits follow Conventional Commits (`committed.toml`) with a lowercase
  subject of at most 72 characters. The types are `feat`, `fix`, `docs`,
  `refactor`, `perf`, `test`, `build`, `ci`, `chore` and `style`, and scopes
  are things like `motion`. A `feat` or breaking change should update
  `doc/news.txt`.
