# Motion module design notes

Background moved out of the `_commands.motion.*` docstrings (28-09-2026) so
the source comments can stay focused on what each function takes, returns
and guarantees. Names below refer to public APIs unless marked otherwise;
private helpers may since have been renamed.

For parse-cost history see `notes/injection-parse-performance.md`; for the
profiling of walk hot spots see `notes/motion-traversal-hotspots.md`.

## Grammar shapes the leaf walk was verified against

- **tree-sitter-rust `//` and `/* */` comments.** `// foo bar` parses as
  `line_comment` with exactly one child, an anonymous `//` at `0,0-0,2`.
  The comment text has no node. Descending into `//` as the leaf made `w`
  jump over the rest of the comment, and a cursor past `//` resolved to
  `line_comment` itself, which looked like a blank-line gap. This is why
  `leaf_shape.has_uncovered_text` exists and why `leaf_shape.settle` runs
  before resolving the cursor's leaf.
- **tree-sitter-rust `///` doc comments.** These parse as `//`, a lone `/`
  (`outer_doc_comment_marker`), then `doc_comment`. The lone `/` is entirely
  a continuation of the `//` run, so `subword.split` returns no units for it
  and `word` skips it. `doc_comment`'s range ends at `(next_row, 0)` with a
  trailing `"\n"` in its text, which is why multi-row spans are trimmed of
  trailing blanks before deciding whether they are really multi-row.
- **tree-sitter-lua `---` doc comments.** The comment opener is a fixed
  2-character `--`, so the third dash starts `comment_content`. Same
  continuation handling as Rust's lone `/`. A Lua long string's
  `string_content` keeps its embedded newline after trimming and is treated
  as genuinely multi-row.
- **`markdown_inline` emphasis.** `emphasis` has two `emphasis_delimiter`
  children with uncovered text between them, the same partial-coverage shape
  as Rust's comments, one injection boundary deeper. `_leaf_at` (private to
  `leaf.lua`) therefore settles upward too.
- **Nested injections.** A Markdown fence tagged `lua` whose content calls
  `vim.cmd([[...]])` is three `LanguageTree`s deep, so leaf resolution
  recurses into injected content until it reaches the innermost language.

## Injection handling

- **Why resolve in the host grammar first.** nvim-treesitter's
  `queries/c/injections.scm` injects every comment as the `comment`
  language. With `get_node({ ignore_injections = false })`, a cursor in
  `int x; /* foo\nbar */` resolved to a single `/` token inside that
  pseudo-language instead of the whole comment leaf. `leaf.current_leaf`
  resolves in the host grammar and then asks `injection.injected_content`.
- **Why an annotation-only denylist.** Neovim's own bundled C query only
  injects small fragments, but nvim-treesitter's (which most users have)
  injects a comment's entire span, so an exact-range match alone can't tell
  it from a real embedded language. Running the test suite with that query
  active split a C block comment word by word. `printf`, `doxygen` and
  `re2c` have the same shape.
- **Combined injections.** This repository's own `flake.nix` showed a
  coarse query combining several unrelated `# bash` strings into one
  `LanguageTree`, which is why every step inside an injected tree is
  bounds-checked against a single piece.
- **Owner lookup by tree identity.** The owner of a node was originally found
  with `LanguageTree:language_for_range()`. For a host node such as Nix's
  `string_fragment`, which starts where its injected tree's first token
  starts, that reported the injected language (confirmed against
  `flake.nix`'s `# bash` strings). Matching by `TSTree` identity has no such
  ambiguity.
- **Merging contiguous regions.** A 4-line `` ```rust `` fence reports
  `code_fence_content:range()` as one `3,0-7,0` span on the host side, but
  the injected child's `included_regions()` splits it into `3,0-4,0`,
  `4,0-5,0`, `5,0-6,0` and `6,0-7,0`. Without merging, the exact-range match
  never succeeded and walks climbed out of the fence at every line.
- **Binary search over sorted pieces.** Before `_sorted_pieces`/
  `_floor_index` (private to `injection.lua`), every node a walk touched
  scanned every region of every child language. A fixed 300-step walk took
  0.055 ms/step with 190 fences in the document and 0.286 ms/step with
  2000, even though the walk itself never changed.
- **`child:parse(true)` on first match.** Neovim's `LanguageTree` only takes
  its O(1) "entirely valid" path once every region of a language has been
  parsed. That same lazy mechanism regressed badly in Attempts 3/4 of
  `notes/injection-parse-performance.md`, because the unmerged-region bug
  above meant a match never succeeded and the full parse never ran. With
  matching fixed it measures level with or ahead of the eager baseline.

## Leaf classification

- **`@string` counts as prose.** tree-sitter-nix's `queries/highlights.scm`
  captures `string_expression` as `@string` and never emits `@spell`, so
  free text in strings (`description = "..."`, error messages) would
  otherwise be split by code rules into a few huge chunks.
- **Unnamed prose leaves can be insignificant.** tree-sitter-nix captures
  `(string_expression "\"" @string)`, so the quote delimiter reports as
  prose. Before `classify.is_insignificant` limited its prose exemption to
  named nodes, no configuration could hide a quote delimiter.
- **Comment markers are per language.** `"` opens a Vimscript comment but
  closes a string elsewhere; `;` ends a comment in a query file but a
  statement in C. A global marker set would make `"skip"` eat unrelated
  tokens in other languages.

## Performance of `leaf_shape.has_uncovered_text`

Uncached, the check reads the buffer once per child on every call. A first
`leaf.first_leaf` descent into a 15000-field Lua `table_constructor` cost
about 32 ms, unchanged across repeated calls. The result is now cached per
node. Neovim returns the same Lua object for repeated lookups of one
tree-sitter node (`root:child(0) == root:child(0)` is `true`), so a
weak-keyed table is safe.

## `W`/`E`/`B`/`gE` with `commands.motion.big.enabled = false`

`subword.split_run` returns the raw run bounds untouched on this path, with
no trimming. That keeps the default behavior byte-for-byte identical to how
`_commands.motion.runner` computed WORD spans from `run.run_start`/
`run.run_end` before sub-word splitting of runs existed.
