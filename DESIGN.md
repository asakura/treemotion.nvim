# Design notes

Things about this plugin that the code can't show: grammar shapes the leaf walk
was built against, Neovim API quirks found by reproduction, optimizations that
were measured and rejected, and test-suite traps. The source comments say what
each function does. This file says why it has to be that way, so nobody has to
work it out again.

Module and function names match `lua/treemotion/_commands/motion/` as of this
writing. Numbers come from headless Neovim benchmarks on synthetic buffers
(timed with `vim.uv.hrtime()`). Read them as ratios, not absolutes.

The longer write-ups this file condenses, with raw `:help` extracts and every
benchmark run, are in git history: `git show 6df1730:notes/<file>` for
`injection-parse-performance.md`, `motion-traversal-hotspots.md` and
`motion-design-notes.md`, and the pre-trim docstrings in the same commit.

## Grammar shapes

The motions never look at node type names. These are the shapes that made the
generic rules necessary.

- **Partial-coverage nodes.** tree-sitter-rust's `// foo bar` is a
  `line_comment` whose only child is the anonymous `//` (`0,0-0,2`). The comment
  text has no node at all. If you descend into `//`, `w` jumps over the whole
  comment. A cursor past the `//` resolves to `line_comment` itself, which looks
  like a blank-line gap. So a node with non-blank text that no child covers is a
  leaf (`leaf.lua`'s `_has_uncovered_text`). Before resolving the cursor's leaf,
  `_settle` climbs to the outermost such ancestor. Other nodes with this shape:
  Rust `/* */`, `markdown_inline`'s `emphasis` (two `emphasis_delimiter`
  children with text between them, so `_leaf_at` settles inside injected trees
  too), and Lua's `"foo\nbar"`, whose `string_content` has only the
  `escape_sequence` as a child.
- **Wrapped Markdown paragraphs.** `markdown_inline` parses a whole paragraph
  as one `inline` node whose only children are markup delimiters. The words have
  no nodes. Multi-row code stays one unit, but `subword.split` has to divide
  multi-row *prose* across rows (`span.position_mapper`). Before that fix, one
  `w` from the start of a wrapped paragraph landed on the next paragraph.
- **Trailing newlines inside tokens.** Rust's `doc_comment` ends at
  `(next_row, 0)` and has `"\n"` at the end of its text. Spans are trimmed of
  trailing blanks before the splitter decides whether they really span several
  rows (`_trim_span`). A Lua long string keeps its embedded newline after
  trimming, so it really does span several rows. Some grammars also end a leaf
  at the next row's column 0, which is why `operator.lua`'s token end is capped
  at the line's end.
- **Punctuation runs split across leaves.** Rust's `///` parses as `//`, a lone
  `/` (`outer_doc_comment_marker`), then `doc_comment`. tree-sitter-lua's
  comment opener is a fixed 2-character `--`, so the third dash of `---` is the
  first character of `comment_content`. Vim treats a run of same-class
  punctuation as one word, so `_leading_continuation_length` strips the
  continuation and the run keeps its single stop in the previous leaf.
  Alphanumerics are excluded because two adjacent word leaves can really be
  separate tokens.
- **Code next to prose in one run.** Lua's `foo"bar"` is an identifier followed
  by a string with no blank between them. `split_run` divides a run into
  stretches with the same prose/code classification (`_run_segments`).
  Otherwise the identifier's camelCase rules leak through the quote into the
  string (`Baz"hello` as one unit).
- **Coarse grammars.** `vimdoc` tokenizes `foo-bar_baz qux` into just three
  `word` leaves, and every other stop comes from sub-word splitting. Grammars
  also disagree in surprising ways (`query`'s `(` is a one-character leaf). So
  the expected columns in `motion_leaf_spec.lua` were captured from the
  plugin's own output, not derived by hand.
- **Grammars that don't fit the two-line comment fixture.** `r` drops the first
  line's stop. `haskell` and `matlab` merge two consecutive line comments into
  one node. Their `_OPTIONAL_COMMENT_MARKERS` entries are still correct (see
  `configuration_spec.lua`). They're just left out of
  `motion_comment_marker_spec.lua`. The `sh` and `tex` filetypes use the `bash`
  and `latex` parsers.

## Neovim API facts found by reproduction

Most of these aren't in `:help`. They were confirmed against
`runtime/lua/vim/treesitter/languagetree.lua` and `vim/treesitter.lua`, or with
throwaway scripts.

- **`LanguageTree:parse()` with a zero-width range at an injected region's exact
  start doesn't parse that region.** For example, with a Lua fence whose region
  starts at `(1,0)`, `root:parse({1,0,1,0})` creates the child, but
  `ntrees() == 0`. `{1,10,1,10}` and `{1,0,1,1}` both work. `node_for_range()`
  handles the same zero-width shape correctly, so `get_node()` was never the
  problem. Hence the one-column range in `leaf.leaf_at` and
  `injection.injected_content`. A cursor on an injection's first character is
  common (`gg`, `f`, any motion that lands there), and there is a regression test
  for it in `motion_injection_spec.lua`.
- **A partial parse drops regions outside the range** (`:help LanguageTree:included_regions()`). A grandchild injection is only discovered
  after its parent is parsed, so you can't build an upfront range that covers
  every tree a walk might reach. Parsing only around the cursor is therefore
  unsafe unless the walk itself parses as it goes.
- **The root tree's region is empty, meaning the whole document, and any edit
  invalidates it.** `_edit()` invalidates only the injected regions an edit
  touches, but it always invalidates the root's. So the first parse after any
  edit reparses the root and reruns its injection query, no matter where the
  edit was. This is a floor that no `range` argument can lower.
- **`injection.combined` forces a full injection scan.** `_get_injections` uses
  `full_scan = range == true or query.has_combined_injections`. Markdown's
  query sets `combined` (for HTML blocks), so its scan always covers the whole
  buffer. Rust's query doesn't set it. `range == true` passes down unchanged to
  every child and forces full scans there too.
- **`is_valid()`'s fast path is all-or-nothing.** A child language becomes cheap
  to check only once every one of its regions is parsed. The root's
  `is_valid()` recurses into every child on every `parse()` call. That's why
  `injected_content` calls `child:parse(true)` the first time it enters a
  language.
- **tree-sitter-markdown reports a fence's content as one region per line.** A
  four-line ```` ```rust ```` fence has regions `3,0-4,0` through `6,0-7,0`, but the
  host `code_fence_content:range()` is `3,0-7,0`. This comes from Markdown's
  line-based block parsing, so it happens for every fence language.
  `_merge_contiguous` joins regions that touch end to end. Without it, the
  exact-range match never succeeds and the fence is skipped as one opaque leaf.
  Without it, walks would also climb out of the fence at every line. Regions
  separated by real host text (a Nix indented string split around `${...}`)
  stay separate.
- **`language_for_range()` assigns a host node to the injected language** when
  the node starts where its injection starts (Nix's `string_fragment` holding a
  `# bash` script). Owners are looked up by `TSTree` identity instead
  (`_owning_ltree`).
- **Identity is stable enough to use weak-keyed caches.**
  `root:child(0) == root:child(0)` is `true` (the same Lua object), and a
  reparse creates new objects. `included_regions()` returns its internal table,
  and both `set_included_regions()` and `_edit()` replace that table whenever
  the regions change. So caches keyed on nodes, `TSTree`s or region tables can
  never return a stale entry.
- **Regions of one `LanguageTree` never overlap**, so pieces from different
  `included_regions()` groups can be put in one sorted array and
  binary-searched (`_sorted_pieces`, `_floor_index`). Pieces from different
  groups can still share a start, so the search walks back over ties.
- **Highlight-only injections look exactly like real ones.**
  nvim-treesitter's `queries/c/injections.scm` injects every C comment as
  `comment`, covering the comment's whole span. Neovim's own bundled query
  injects only fragments. With the nvim-treesitter query active, resolving
  inside the injection broke a C block comment into single `/` tokens and split
  it word by word. No query flag tells the two kinds apart, so
  `_ANNOTATION_ONLY_LANGUAGES` lists `comment`, `printf`, `doxygen` and `re2c`
  by name. The leaf is also resolved in the host grammar first.
- **`injection.combined` stitches unrelated text into one tree.** In this
  repository's `flake.nix`, several separate `# bash` strings became one
  `LanguageTree`, so sibling navigation inside it can jump to a distant string.
  Every step inside an injected tree is checked against the piece the walk
  started in.
- **`get_node()`'s `include_anonymous` only exists on Neovim 0.11+**, and older
  versions silently ignore it. The plugin uses `descendant_for_range()`, which
  returns anonymous nodes on every supported version.
- **`get_parser()` returns `nil, message` on some versions and errors on
  others** (0.11), so it's wrapped in `pcall`.
- **A node's `:end_()` can sit one row past the last line** (a root node
  covering the implicit trailing newline). `nvim_buf_get_text` errors there, so
  reads that can reach it are wrapped in `pcall`.
- **`vim.g` returns a converted copy on every read.** So
  `let g:loaded_treemotion = 0` reaches Lua as `0`, which is truthy, and the
  load guard checks `~= nil` to match `exists()`. The configuration module keeps
  its "initialized" flag module-local because `g:` variables survive clearing
  `package.loaded`, which would leave a reloaded module with empty data.
- **A Lua table can't hold `nil`** (`{"foo", nil}` is `{"foo"}`), so
  `insignificant_characters` overrides remove a character with
  `[character] = false`.
- **`mega.logging` mishandles numeric log levels**, so only the string names
  are accepted.

## Operator-pending behavior

- A `<Plug>` motion in operator-pending mode only moves the cursor, so the
  operator gets an exclusive range to wherever the cursor lands. To get Vim's
  ranges, `operator.lua` computes them itself.
- `dge` must include the character the operator started from, which no cursor
  position can do. So the mapping is `<expr>` and forces the motion with `v`
  (`:help o_v`), just as `dvb` does. The keys can't depend on the cursor because
  `.` replays them unchanged. A forced motion that doesn't move would still act
  on the character under the cursor, so it cancels the operator instead (an
  empty `<Cmd>` error does that silently).
- `vim.fn.mode(true)` is exactly `"no"` for an unforced operator. `"nov"`,
  `"noV"` and `"no<C-v>"` (`dvw` and so on) mean the user chose the shape, so
  they get the plain motion.
- To give an exclusive end past a line's last character, the cursor is moved
  there with the window-local `'virtualedit'` briefly set to `onemore`. An unset
  local value (`""`) has to be restored as unset. Visual mode is never used, so
  `'<` and `'>` stay the user's.
- An exclusive end at a line's start gets pulled back onto the previous line
  (`:help exclusive`). So a range that would end before a bracket that starts a
  line ends after the last real character before it.
- A bracket counts only if it's an unnamed token, or if the whole range stays
  inside the named leaf that contains it. `dW` on the `"` of `")" .. x` mustn't
  stop at the `)`.
- Prose leaves hold whole sentences, so a token's end is also cut at the first
  blank. Otherwise `dw` on "and" in "and `code`" would take the backtick.
- The expected results for `dw` at a line's end and on an empty line, and for
  `cw` on whitespace, were taken from Neovim's built-in `dw` and `cw` on the
  same text.

## Splitting decisions

- **`@string` counts as prose, not just `@spell`.** tree-sitter-nix's highlight
  query captures `string_expression` as `@string` and never emits `@spell`, so
  free text in strings would otherwise split by code rules into a few huge
  chunks.
- **Unnamed prose leaves can be insignificant.** Nix captures
  `(string_expression "\"" @string)`, so the quote reports as prose. Only
  *named* prose leaves are exempt from `insignificant_characters`. Otherwise no
  configuration could hide a quote.
- **Comment markers are per language.** `"` opens a Vimscript comment but closes
  a string elsewhere, and `;` ends a comment in a query file but a statement in
  C. A run made only of `-` or `_` (Lua's `--`, a `-----` rule) falls under
  `comment_marker_case` only if the language's `comment_markers` lists that
  character. Next to letters it's `kebab_case` or `snake_case`.
- **`-`, `:` and `/` are in prose's "word" class**, even though Vim's default
  `'iskeyword'` excludes them. If `prose.words` split them off, `"none"` mode
  could never put them back together. Keeping them in also keeps
  `github:NixOS/nixpkgs` and URLs whole until `colon_case` and `slash_case`
  decide.
  Both default to `"skip"` for prose and `"none"` for code, because real
  identifiers almost never contain a literal `:` or `/`.
- **The hash heuristic requires a digit on the base64 branch.** Without that
  requirement, any mixed-case identifier of 20 or more characters
  (`handleSubmitButtonClick`) counted as a hash. Each base64 character is a
  digit with probability 10/64, so a real digest almost always has one. Trailing
  `=` padding is merged back into the word before it (`_merge_opaque_padding`)
  so a base64 digest stays one unit. The default minimum length of 20 sits well
  below a 40-character sha1 hex digest and a 44-character base64 sha256, and
  well above ordinary identifiers and words.
- **`camel_case` and `pascal_case` toggle independently** because the first
  letter alone decides which one applies to a word.
- **An acronym keeps a one-letter lowercase suffix.** The `XMLHttp` rule splits
  before an acronym's last capital when a lowercase letter follows it. On its
  own, that turns `CIDRv4` into `CID`, `Rv4` and `URLs` into `UR`, `Ls`. The
  rule therefore doesn't fire when the lowercase run is a single letter followed
  by the end of the text, a digit or a capital (`IPv4`, `URLs`, `IDsList`). The
  cost is that a one-letter word after a capital joins it (`IAmHere` gives
  `IAm`, `Here`), which is rarer in identifiers than plurals and versions.
- **The default `W` (`big.enabled = false`) returns the run's raw bounds
  untrimmed.** That keeps it byte-for-byte identical to the WORD spans from
  before runs could be sub-split.
- **A leaf with no words gets a whole-leaf fallback unit, but a leaf whose only
  content is a dropped `"skip"` run doesn't.** The old fallback ("no units, so
  use the whole leaf") brought back a stop that `comment_marker_case = "skip"`
  had removed, but only where the marker was its own leaf (Lua's `--`, but not
  the single `comment` leaf of C, Vim or query). Fixing that is why the motion
  specs run across grammars.
- **Optional comment markers and insignificant characters are resolved lazily,
  per language.** `vim.treesitter.language.add()` loads the parser, and doing
  that for about 120 candidates at startup would be wasteful. The optional
  insignificant list is kept small on purpose because this setting is mostly
  taste. `:checkhealth` warns only about languages the user typed, not about
  defaults or optional entries whose parser isn't installed.
- **`resolve_data()` without overrides returns `M.DATA` itself**, not a deep
  copy. This is safe only because every writer replaces `M.DATA` rather than
  editing it. Callers must not edit the returned table.

## Performance: measured, including what didn't pay off

Don't retry the rejected ideas without new evidence.

### Injection parsing (shipped: lazy, plus whole-language commit)

`leaf_at` parses the root one column wide at the cursor. `injected_content`
parses the host tree at each node it checks, then calls `child:parse(true)` the
first time a language is entered. How this was arrived at:

| Attempt | Result |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `parse(true)` every motion (original) | Correct. Free in steady state: 0.003 ms when nothing changed, on a 2953-line document with 190 Rust fences and 762 injected regions. 8.6 ms median and up to 31 ms after any edit (root reparse plus a full injection scan). Cold: 56 to 80 ms. |
| 1: parse the zero-width cursor point | 7 failures, all from the region-start quirk above. |
| 2: parse a one-column range at the cursor | 5 failures. A `W`/`B` walk reaches injected trees that were never parsed, and the regions dropped by a partial parse are invisible. |
| 3: parse as you walk in `injected_content` | All tests passed, but a full `W` walk was 3.3 to 7.7 times slower (925 to 2178 ms against 282 ms for 570 motions). Even a 10-fence document was 3.3 times slower. |
| 4: 3, plus `child:parse(true)` on a match | Still 1.9 to 7.3 times slower. Of 10,258 lookups, 8,916 landed on the root at 0.06 to 0.15 ms each, against about 0.002 ms when warm. |
| Root cause | Not laziness. Per-line fence regions meant the exact match never succeeded, so Rust never became "entirely valid". That was also a correctness bug in `main`: `w` skipped every multi-line fence. |
| 5: 4, after `_merge_contiguous` | Shipped. A full walk is the same as eager within noise (about 1.33 against 1.38 ms per motion over 5 interleaved pairs). Cold start in a fence is consistently 5 to 13% faster (57 to 58 against 61 to 66 ms). Languages that are never entered cost nothing (eager parses all 570 `markdown_inline` regions anyway). |

On its own, without the motion code around it, a narrow `parse()` looked much
better than the shipped result: a cold start fell from 80 to 21 ms, a first
visit to a new region took 0.33 ms, and a post-edit reparse fell from 12.4 to
8.5 ms. In the real motions most of that disappeared, because Markdown's
combined-injection flag still forces a full scan of the root.

**Known trade-off of lazy parsing.** Typing a character into a fence's
delimiter line changes the fence's structure. After that edit, eager parsing
reparsed 760 of the 762 regions (29.6 ms). Lazy parsing reparsed 2 (7.6 ms) and
left the rest stale until a walk reaches them and parses them on arrival. Part
of what lazy parsing "saves" is work it defers. If stale injected trees ever
cause wrong motions after structural edits, this is where to look.

How to reproduce the numbers: no benchmark harness is committed. Run a
throwaway `bench.lua` with
`nvim --headless -u NONE -U NONE -N -i NONE --cmd "set rtp+=<treesitterAllGrammars>" -l bench.lua`.
It should call the real `treemotion.run_motion_*`, `leaf.*` and `unit.*`
functions, not copies of them in isolation. The scenarios were:

- A synthetic Markdown document: prose lines with a ```` ```rust ```` fence (a small
  function) every 10 lines, using 190 fences (1900 lines) or 2000 fences.
- A single-line Lua `local t = { field_1 = 1, ... }` with N fields, walked with
  `leaf.first_leaf` on its `table_constructor` node.
- A full `parser:parse(true)` right after creating the buffer when measuring
  traversal rather than cold parsing.

Benchmarking traps:

- `:edit` on a path that's already open switches to the existing buffer, which
  reuses a warm parser. Use `nvim_create_buf` and `nvim_buf_set_lines` for
  cold-start numbers.
- Compare post-edit costs with two separately warmed parsers fed the same
  edits, alternating which one runs first. Otherwise one mode's work warms the
  other's measurement.
- Background noise on the benchmark machine made 3-sample full-walk comparisons
  useless (the same code measured anywhere from 0.94 to 1.61 ms per motion).
  Use 5 or more interleaved pairs.
- Eager's first motion parses every region in the buffer as a side effect, so
  any "first visit to a fence" measurement taken after warming with eager is
  already paid for.

### Traversal hot spots (300-step warm walks, 1900 lines, 190 fences)

| Candidate | Verdict |
| --------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `count` loops resolve again from the cursor each time instead of chaining | **Rejected.** A fresh `unit_at` costs the same as a chained `next_unit` (0.96 to 1.05 times). `get_node()`'s C-side lookup is as cheap as the Lua sibling climb. Chaining would complicate the handling of gaps for no gain. |
| `_has_uncovered_text` reads the buffer once per child on every visit | **Fixed with a weak-keyed cache.** `first_leaf` on a Lua table with N fields: 0.69 to 0.07 ms at N = 500, 5.35 to 0.30 ms at N = 3000, 32.2 to 3.0 ms at N = 15,000. |
| Region lookups scan every injected region of a language on each node | **Fixed with sorted pieces and binary search.** The same 300 steps near the top got slower as the rest of the document grew: 0.055 ms per step at 190 fences, 0.286 at 2000. After the fix: a flat 0.02 to 0.03 ms. (A full top-to-bottom walk hides this cost because it touches every region anyway.) |
| `resolve_data()` deep-copies the configuration on every call | **Fixed, since it's free.** The call itself is about 10 times faster (0.00049 to 0.000048 ms), but no difference shows in an end-to-end walk because the call accounted for about 5% of the time. |
| `is_prose` called twice per leaf split | **Rejected.** `get_captures_at_pos()` costs 0.000075 ms. About 1.5 calls per step works out to under 0.5% of a walk. |

## Test suite traps

- **Busted's `pending` doesn't exist in `require`d modules.** It's a chunk-local
  in each `_spec.lua` file. Lua resolves globals through the chunk's own `_ENV`,
  not through the caller's. So `grammar_helpers.wrap` takes `pending` as a
  parameter. Nobody noticed until a fixture's parser went missing for the first
  time.
- **`nix build .#treemotion-nvim`'s `checkPhase` has only the grammars bundled
  with Neovim** (`c`, `lua`, `markdown`, `markdown_inline`, `query`, `vim`,
  `vimdoc`). `nix run .#test` adds `treesitterAllGrammars`. Fixtures for any
  other grammar must turn into pending tests when the parser is missing.
- **`treesitterAllGrammars` ships compiled parsers but no `highlights.scm`.**
  Without a real query there are no `@spell` captures, so comment fixtures
  quietly fall back to code rules and assert different stops. One version of
  the cross-grammar comment fixtures passed locally only because a personal
  nvim-treesitter install supplied the queries. Fixtures for non-bundled
  grammars set `comment_node`, so a synthetic `(comment_node) @spell` query is
  registered for them.
- **`configuration.DATA` is shared across the whole busted process.** A test
  that changes it must restore the original table, or the change leaks into
  whichever spec file runs next. `setup()` deep-merges, so it can't remove keys.
  Snapshot and restore the table instead.
- **The mirror pairs are `w`/`b`, `e`/`ge`, `W`/`B` and `E`/`gE`.** `w` and
  `ge` aren't a mirror pair. A counted jump near the buffer's end stops early,
  as Vim's does. That's correct, so round-trip checks skip starting points that
  don't have `count` units ahead.
- **Messages that print a table include a memory address**, so tests match only
  the stable prefix.
- **A `nvim_buf_get_text` stub must forward `...`**, not a named `opts`. If the
  caller omitted `opts`, forwarding `nil` explicitly passes a sixth argument.
- **Initialization is tested in a child `nvim --clean --headless`** because the
  suite's own process has already loaded the plugin. `package.path` and
  `package.cpath` are passed along so the child can find the `mega.*`
  dependencies.

## CI

- busted has to run under `nvim -l`, because the plugin calls `vim.*` when it
  loads. `luarocks --prepare` installs only busted, not the `mega.*`
  dependencies. On Windows, `luarocks path` returns backslashes, which become
  escape sequences inside the generated `.busted` Lua string, so they're
  converted to `/`.
- `:checkhealth` has no "everything except X" form, and naming a check that
  doesn't exist is an error, so the checks are listed per version. On 0.10 the
  core check is `nvim` and each provider is a separate check. On 0.11+ it's
  `vim.health` with a single `vim.provider`, and `vim.pack` needs 0.12+. On
  nightly, the core check always reports "Graphics protocol: not supported"
  because a headless runner has no terminal to answer the kitty-graphics query.
  So that step is informational and doesn't block.
