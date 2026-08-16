# `M.current_leaf` calls `parser:parse(true)` on every motion

Status: **resolved and shipped.** Attempts 3 and 4 (below) looked like a dead
end, but the actual root cause of their regression turned out to be a
separate, real correctness bug (see "The multi-region injection matching
bug"), not a limitation of lazy parsing itself. Fixing that bug
(`_merge_contiguous`, in `_commands.motion.leaf`) made the same
parse-as-you-walk mechanism viable, and it's now what `_current_leaf`/
`_injection_at` actually do -- see "Attempt 5" for the corrected benchmarks
and "Current state" for what shipped.

## The problem

`M.current_leaf` (`lua/treemotion/_commands/motion/leaf.lua:668`, a logging
wrapper around the private `_current_leaf` at `leaf.lua:562`) calls
`parser:parse(true)` at `leaf.lua:594` on every single invocation.
`M.current_leaf` is the entry point for every `w`/`e`/`b`/`ge`/`W`/`E`/`B`/`gE`
keystroke, so this runs once per motion, no exceptions.

`:help LanguageTree:parse()` documents `range = true` as "run a complete
parse of the source (Note: Can be slow!)". In practice this is not "a full
parse on every keystroke": Neovim caches parsed trees and only reparses what
an edit actually invalidated (see "Measured performance"). The real cost
lands on the first motion after a buffer edit, not on motions in general.

This was flagged by an automated code-review pass, which suggested parsing
only the cursor's own position instead of the whole buffer -- `range`
accepts a `Range`/`Range[]`, not just `true`/`false`, so this looked like a
clean, obvious fix. It isn't. Both attempts below were tried, both broke
real tests, and the module currently ships with the full `parse(true)` call
and a docstring explaining why.

## Measured performance

The per-region caching mechanics that determine whether `parse(true)` is
cheap or expensive live in Neovim's bundled `vim/treesitter/languagetree.lua`
runtime module (not part of this repo, and not documented at the field level
by `:help`), so this section is grounded in reading that source directly and
confirming the behavior empirically.

### The caching mechanism

`LanguageTree:_parse()` starts with:

```lua
if self:is_valid(nil, ...) then
  return self._trees, true   -- cached trees, no reparse at all
end
```

Every buffer edit goes through `_on_bytes` -> `_edit()`, which applies a
cheap tree-sitter incremental edit to each existing tree and then marks
**only the region(s) whose range intersects the edit** as invalid --
everything else keeps `valid = true`. Cursor motions never call `on_bytes`
(they don't edit the buffer), so a sequence of pure motions never
invalidates anything between calls.

One exception: the root tree's own region is always `{}` (empty, meaning
"the whole document"), and `_edit()`'s region-validation callback
unconditionally treats an empty region as invalidated by *any* edit,
anywhere in the buffer. So while injected-child regions are invalidated
precisely (only the region actually touched by the edit), the root is
invalidated by every single edit regardless of location. This is why the
post-edit cost below is location-independent, and why no amount of `range`
narrowing removes it: the root has no narrower scope to give.

### Benchmark 1: steady-state motions are free

Small case (Lua/Markdown, one buffer, `parser:parse(true)` measured
directly, no treemotion code involved):

| call | time |
|---|---|
| first `parse(true)` ever | 20.1 ms |
| 500x `parse(true)` with no edits between | avg **0.023 ms** |
| `parse(true)` right after a 1-char edit | 3.0 ms (only the touched region reparsed) |
| `parse(true)` again, no further edit | 0.006 ms |

### Benchmark 2: same test at realistic scale (3000-line Rust-heavy doc)

Generated a 2953-line Markdown document with 190 `` ```rust `` fenced code
blocks interspersed with prose -- large enough that the injection count
(190 `rust` + 572 `markdown_inline` = 762 child regions) stresses the
whole-buffer injection-query cost that `:help treesitter-language-injections`
warns about:

| scenario | `parse(true)` cost |
|---|---|
| first parse ever (cold) | 56.4 ms |
| 1000x repeat, no edits between | avg **0.003 ms** |
| right after *any* single-char edit (20 scattered locations) | median 8.6 ms, avg 11.1 ms, up to 30.8 ms |
| again, no further edit | 0.004 ms |

Steady-state holds at this scale too. The post-edit cost is
location-independent -- editing near line 2 costs as much as editing inside
a Rust fence at line 2900 -- because any edit invalidates the root's empty
region, forcing a root reparse, which resets `_processed_injection_region`
and forces the injection *query* to rescan the entire buffer before
per-child `is_valid()` gets a chance to skip the 761 still-valid children.

### Benchmark 3: lazy (range-scoped) parsing

Same 3000-line document, comparing `parser:parse(true)` against
`parser:parse({row, col, row, col + 1})` scoped to a point. Methodology
notes:

- Cold-buffer comparisons must use real scratch buffers (`nvim_create_buf` +
  `nvim_buf_set_lines`) per test, not repeated `:edit <same path>` calls --
  Neovim's `:edit` on an already-open path switches to the existing buffer
  instead of loading a fresh one, which silently reuses a warm parser and
  produces impossible "cold" numbers.
- Post-edit comparisons must alternate between two dedicated,
  once-warmed parsers (one eager-only, one lazy-only) fed the *same*
  sequence of edits, not a single shared parser reused for both modes in
  sequence -- reusing one parser lets an earlier mode's work contaminate the
  next measurement. An order-swap check (lazy measured before eager instead
  of after, same edit sequence) confirmed the reported gap isn't a
  cache-warmth/scheduling artifact of always running one mode first.

| scenario | eager `parse(true)` | lazy `parse({row,col,row,col+1})` |
|---|---|---|
| cold, first parse ever | 79.8 ms | 21.9 ms (cursor in prose) / 20.0 ms (cursor in a Rust fence) |
| 1000x repeat, same spot, no edits | -- | avg 0.028 ms |
| first touch of a *new* region, doc already warm | -- | **0.33 ms** |
| same new region again | -- | 0.08 ms |
| post-edit reparse, paired same-edit comparison (30 scattered edits) | avg 12.37 ms | avg 8.46 ms |
| same 30 edits, excluding the one outlier below | avg 11.78 ms | avg 8.50 ms |

Takeaways:

- Lazy parsing cuts cold-start by ~73% (80ms -> ~21ms) by skipping the
  eager parse of all 762 children. It's still 20+ ms, not free, because the
  root's own region is always the whole document -- narrowing `range` only
  controls which *children* get touched, never the root's own parse scope.
  That's a hard floor, not a tuning knob.
- Post-edit, lazy saves ~25-30%. The mechanism is narrower than it first
  looks, and worth getting right since it's easy to misattribute: markdown's
  own `queries/markdown/injections.scm` uses `#set! injection.combined` (for
  HTML blocks), which sets `has_combined_injections = true` on the *whole*
  query object (confirmed directly: `parser._injection_query.has_combined_injections
  == true` for both `markdown` and `markdown_inline`). Per
  `LanguageTree:_get_injections`, `full_scan = range == true or
  self._injection_query.has_combined_injections` -- so root's own
  injection-*discovery* scan is whole-buffer in *both* modes; narrowing
  `range` buys nothing there. The actual saving is one level down: `range ==
  true` (eager) propagates unchanged through every recursive `_parse()`
  call, so it also forces `full_scan = true` on every *child's* own
  injection query regardless of that child's own flag. Rust's
  `queries/rust/injections.scm` (comments, `Regex::new(...)`, macro
  invocations) has no combined-injection pattern of its own (confirmed:
  `has_combined_injections == nil`), so in lazy mode its query only runs
  over the narrow range, while in eager mode it re-scans the full text of
  all 190 Rust regions for injectable content every time `_processed_injection_region`
  gets reset by a reparse. Confirmed by instrumenting `_parse_regions`
  directly: both modes reparse the *same* number of regions per edit (2:
  root + the one touched child, for ordinary edits) -- the gap is in
  child-level injection-query cost, not in how much gets parsed.
- One of the 30 sampled edits is a concrete illustration of the risk
  Attempt 2 above already flagged, not a performance win: inserting a
  character into a `` ```rust `` fence-delimiter line changes the fenced
  block's own identity, and eager mode correctly reparsed 760 of the 762
  child regions to catch up (29.6ms), while lazy mode reparsed only 2
  (7.6ms) -- silently leaving roughly 758 regions stale instead of
  reflecting the structural change. Excluding this edit barely moves the
  average (12.37ms -> 11.78ms eager; 8.46ms -> 8.50ms lazy), so it isn't
  what's driving the overall gap -- the injection-query mechanism above is
  -- but it's a reminder that some of what narrow scoping "saves" is
  legitimately deferred/skipped work, not free performance.
- Lazy parsing wins big on warm navigation into never-before-visited
  territory: 0.33 ms to touch a new region once the doc has been parsed
  once, instead of paying anything close to a full reparse. This is the
  shape of cost a parse-as-you-walk redesign (see below) would have for
  `next_leaf`/`previous_leaf` stepping into a not-yet-touched region.

## What was tried, and why it didn't work

### Attempt 1: parse just the cursor's zero-width point

```lua
local row, column = M.cursor_position()
parser:parse({ row, column, row, column })
```

This alone caused 7 test failures, all in nested-injection cases. Traced it
to a genuine Neovim API quirk, reproduced directly:

```lua
-- buffer: ```lua / vim.cmd([[set number]]) / ```
-- the lua fence's injected region starts at exactly (row=1, col=0)
root:parse({ 1, 0, 1, 0 })  -- zero-width point at the region's own start
-- => lua child ltree exists, but ntrees() == 0 -- never actually parsed

root:parse({ 1, 10, 1, 10 })  -- zero-width point mid-region
-- => ntrees() == 1, parsed fine

root:parse({ 1, 0, 1, 1 })  -- one-column-wide range at the same start
-- => ntrees() == 1, parsed fine
```

`LanguageTree:parse()`'s own intersects-`{range}` check -- unlike
`node_for_range()`'s, which resolves a plain cursor position correctly using
the exact same zero-width `{row, col, row, col}` shape -- silently misses a
zero-width range sitting exactly on an injected region's *start* boundary.
Anywhere else (mid-region, or a range with real width), it works. A cursor
sitting on the very first character of an injected block is not a rare case
-- it's exactly where a user's cursor lands after `f`/`gg`/opening a file at
a specific line, or after any motion that lands on the first leaf of an
injection.

### Attempt 2: widen to a one-column range

```lua
parser:parse({ row, column, row, column + 1 })
```

This fixes the boundary quirk above (confirmed: `ntrees() == 1` at the exact
same boundary case). It did not fix the test suite -- 5 failures remained,
all in the nested-injection spec, none of them at a region-start boundary
this time (e.g. cursor at column 23, well past any boundary).

The real cause is architectural, not a boundary edge case:
**the private `_next_leaf`/`_previous_leaf` (`leaf.lua:883`, `:945` -- the
actual walk logic that `M.next_leaf`/`M.previous_leaf` wrap with logging)
never call `parser:parse()` themselves.** They assume every `LanguageTree` a
walk might touch is already parsed, because the *only* place parsing happens
is the one upfront call in `M.current_leaf`, before the walk starts. The
private `_run_start`/`_run_end` (`leaf.lua:1056`, `:1021`) call
`next_leaf`/`previous_leaf` once per leaf in a run, and a long `W`/`B` run
can climb out of the injected tree the
cursor started in and into a *different* injected tree elsewhere in the
buffer entirely (a different fenced block, a different embedded string) --
one that a narrow, cursor-only parse never touched. That tree's `TSTree`
list stays empty, so `_owning_ltree`/`_injection_at`/`_leaf_at` see nothing
there and the walk silently produces wrong results instead of erroring.

Confirmed directly: `root:parse(range)` at a single injected region's exact
column does *not* cascade into parsing that region's *own* nested children
(the grandchild level) unless the given range also happens to intersect
whatever the grandchild's region turns out to be -- which a plain "parse the
cursor" call has no way to guarantee for every tree a later, still-unplanned
walk might reach.

### Attempt 3: parse-as-you-walk via `_injection_at`, narrow range every call

This is the design "What a proper fix would look like" (below, as it read
before this attempt) recommended, and it was actually implemented and
benchmarked end-to-end this time, not just reasoned about.

Two changes: `M.current_leaf` narrows its upfront call to
`parser:parse({row, column, row, column + 1})` (root only, one-column wide,
same boundary-quirk fix as Attempt 2). `_injection_at` -- the single
function every leaf-walk entry point (`first_leaf`/`last_leaf`/`_leaf_at`)
already calls on every node it touches, specifically because an injection
can start at any depth (see this module's own docstring) -- gets a new first
step: `ltree:parse({row1, column1, row1, column1 + 1})` on `node`'s own
owning tree, at `node`'s own start, before checking `ltree:children()` for a
match. The reasoning: `_injection_at` is already the one choke point every
walk passes through before trusting a node's content, so it's the one place
that can discover-and-parse a not-yet-touched injection lazily, at exactly
the moment a walk is about to cross into it -- no separate "which trees
might this walk reach" bookkeeping needed anywhere else.

This is *correct* -- traced through `LanguageTree:_parse()`'s actual
recursion (not just its docstring): a `parse()` call on any tree
unconditionally recurses into every already-*discovered* child with the same
range, and region-granularity means a matched child's *entire* region parses
in that one call, not just the queried column -- so `_leaf_at`'s later query
at a piece's *end* (`_last_leaf_in_piece`) is already covered, and nested
injections resolve to arbitrary depth in one top-down call. All 1265 tests
passed, including the exact-boundary regression test.

But it's a severe *performance* regression, confirmed by benchmarking actual
`treemotion.run_motion_w`/`run_motion_W` calls (not raw `parse()` calls in
isolation, which is all Benchmark 3 above measured) against a synthetic
1900-line/190-rust-fence Markdown document, A/B'd directly against the
unmodified `parse(true)` baseline via `git stash`:

| scenario (190 fences, 762 total injected regions) | eager `parse(true)` | Attempt 3 (lazy) |
|---|---|---|
| cold, cursor at first rust fence's first column | 69.1 ms | 55.0-76.5 ms |
| cold, cursor in prose (no injection touched) | 37.4 ms | 14.8-21.6 ms |
| first touch of a never-visited fence, doc otherwise warm | 0.55 ms | 0.52-0.68 ms |
| **full top-to-bottom `W` walk, 570 motions, no edits** | **281.7 ms (0.49 ms/motion)** | **925-2178 ms (1.6-3.8 ms/motion)** |

Cold-start and fresh-territory numbers land roughly where Benchmark 3
predicted. The full-walk row is the problem: **3.3-7.7x slower**, on
exactly the "long `W`/`B` run in an injection-heavy buffer" scenario this
whole effort was supposed to help most. It's not a fluke of the extreme
190-fence case either -- a 10-fence/100-line document (a much more
realistic size) still showed a **3.3x** regression (1.00 ms/motion lazy vs.
0.31 ms/motion eager) with the cold-start advantage almost gone (43 ms vs.
47 ms). See "Why attempts 3 and 4 don't work" for the root cause and why a
smaller-scale document doesn't escape it.

### Attempt 4: same as Attempt 3, plus committing a language fully once entered

A refinement meant to fix Attempt 3's regression: keep the narrow
per-node discovery call, but once `_injection_at` finds an exact match,
call `child:parse(true)` on *that specific child* (not the root) instead of
leaving it with only the one matched region parsed. The idea: once
`_is_entirely_valid` becomes true for a child, Neovim's own
`LanguageTree:is_valid()` short-circuits to an O(1) check instead of
scanning every one of that child's regions -- so a language you actually
touch gets paid for once (parsing everything discovered for it, e.g. all 190
rust fences in one shot the first time any one of them is entered), and a
language you never touch (e.g. `markdown_inline` in a walk that stays inside
code fences) still costs nothing.

This measurably helped -- the 190-fence full walk dropped from 925-2178 ms
to 895-2058 ms -- but it's still a **1.9-7.3x regression** across repeated
runs, nowhere close to eager's 281.7 ms, and the 10-fence case was
*still* 0.585 ms/motion (1.9x eager's 0.307 ms/motion). Per-`_owning_ltree`
instrumentation on the full walk pinned the cost precisely: of 10258
`_injection_at` calls, **8916 landed on the root (`markdown`) tree at
~0.06-0.15 ms each** (vs. ~0.0015-0.003 ms once genuinely warm, confirmed in
isolation below) -- `markdown_inline`, once committed, *did* reach that fast
~0.0008-0.0016 ms/call floor. The root tree never did, across the entire
walk.

## The multi-region injection matching bug

Traced into `LanguageTree:is_valid()`/`_parse()` directly (not documented at
this level by `:help`) to find out why the root tree's own calls stayed slow
even after every child it has was individually committed to
`_is_entirely_valid`:

```lua
-- LanguageTree:is_valid, exclude_children defaults falsy, so this branch
-- always runs for a top-level LanguageTree:parse() call:
for _, child in pairs(self._children) do
  if not child:is_valid(exclude_children, range) then
    return false
  end
end
```

This recursion is *unconditional* -- it runs on every `parse()` call the
root tree ever receives, regardless of `range`, and regardless of whether
each child is individually fast to check. Isolated confirmation (a
throwaway script, not the real motion code) that the mechanism *can* be fast
once genuinely fully committed:

```
committed all children
10000x root:is_valid() narrow varying range: 17.295 ms total, 0.00173 ms/call
10000x root:parse() narrow varying range: 14.776 ms total, 0.00148 ms/call
```

So the mechanism itself isn't the problem -- something about how *this
module's* walk reaches it is. Debugging Attempt 4's stubbornly-slow root
calls surfaced the actual cause, and it's unrelated to laziness at all: for
this benchmark's synthetic Markdown fixture, `` ```rust ``'s `code_fence_content`
node does **not** correspond to one clean injected region matching that
node's own `:range()`. Direct inspection (`parser:children()` after an
honest, fully eager `parser:parse(true)` -- no laziness involved) showed:

```
child rust
  region 3 0 4 0
  region 4 0 5 0
  region 5 0 6 0
  region 6 0 7 0
```

Four separate one-line regions, not one `3,0`-`7,0` region matching
`code_fence_content:range()` -- tree-sitter-markdown's own line-oriented
block parsing, not an injection-combining artifact and not something either
attempt's `range` argument controls. `_injection_at`'s exact-range match
(`region[1]==row1 and region[2]==column1 and region[4]==row2 and
region[5]==column2`, comparing a *single* candidate region against `node`'s
*whole* bounding range) can never succeed against a region set shaped like
that -- so for this fixture, `_injection_at` never finds a match at the
`code_fence_content` level at all, `child:parse(true)` (Attempt 4's commit
step) never fires for `rust`, `rust` never reaches `_is_entirely_valid`, and
root's unconditional children-recursion above pays the full O(children'
region count) scan on every single call, for the entire walk. This is why a
10-fence document still regressed 3.3x: the region count driving the slow
path never dropped to zero, no matter how small the document.

**This also means Attempt 3/4's benchmark numbers measure a mechanism that
was silently failing to enter the fences at all for most of the walk** --
confirmed directly: `git stash`ing every change in this file's history (at
the time) and running `#w` from `fn` on a freestanding `` ```rust `` fence
inside a Markdown buffer landed on `fenced_code_block_delimiter` (the closing
`` ``` ``), not `example_1` -- the motion silently treated the entire
multi-line fence as one leaf and skipped over it, matching the "no
exact-range match" analysis above exactly. This was a **real, pre-existing
bug on unmodified `main`, unrelated to laziness** -- and, as the next section
covers, fixing it is also what made laziness actually work.

The deeper, more general point beyond this one fixture: `is_valid()`'s
`_is_entirely_valid` fast path requires a language's *entire* discovered
region set to be parsed before any check against it becomes cheap. Under
true per-node laziness, a large language (many discovered regions, e.g.
`rust` or `markdown_inline` on any real Markdown corpus with lots of fenced
code or lots of inline emphasis) may never reach that state during a normal
editing session -- and every `_injection_at` call anywhere in the document,
including calls that have nothing to do with that language, pays for
checking it anyway, because the root tree's children-recursion has no way to
skip a child it hasn't fully committed to. Attempt 4's "commit a language
fully once entered" was a real, working mitigation for *that* problem (see
`markdown_inline` reaching the fast path once genuinely committed, in the
Attempt 4 numbers above) -- but it couldn't fire at all for a language whose
injection is captured as multiple regions not matching `_injection_at`'s
single-region exact-match check, which turned out to be exactly the shape of
the primary real-world case (Markdown code fences) this rewrite was aimed at.

## The fix: `_merge_contiguous`

`_injection_at`'s exact-range match compared a *single* `included_regions()`
entry against a node's *whole* bounding range. That's wrong whenever a
grammar reports one logical injected span as several regions with no real
gap between them -- confirmed this is exactly what tree-sitter-markdown does
for `code_fence_content` (each region is one line; a 4-line fence is 4
regions, `3,0`-`4,0`, `4,0`-`5,0`, `5,0`-`6,0`, `6,0`-`7,0`, even though the
*host* `code_fence_content` node's own `:range()` is one clean `3,0`-`7,0`
span). This isn't specific to `rust` or to any particular language -- it
reproduces identically for a multi-line `` ```lua `` fence too (confirmed
directly), since it's tree-sitter-markdown's own line-oriented block parsing
producing the regions, not anything about the injected language.

The fix (`_merge_contiguous`, `leaf.lua`) merges regions within one
`included_regions()` group into maximal end-to-end runs before either
`_injection_at`'s exact-range match or `_piece_at`'s point-containment check
ever sees them -- regions that touch (one's end equals the next one's start)
collapse into a single piece; regions with a genuine gap (real host-language
text between them, e.g. a stitched Nix indented string's `${...}`
interpolations) are left separate, unchanged. This fixes two things at once:
`_injection_at` can now match a multi-line fence's `code_fence_content` node
against the *merged* `3,0`-`7,0` piece, and `_piece_at`/`_within_piece` no
longer mistake an artificial per-line split for a real piece boundary, which
was *also* forcing `next_leaf`/`previous_leaf` to climb back out to the host
grammar at every line break inside a fence even on the rare occasion a match
did succeed. Single-region groups (the overwhelming majority of injections)
skip the merge work entirely -- see the function's own docstring.

Confirmed against the exact `git stash` reproduction above: `#w` from `fn`
inside a multi-line fence now steps through every line of the fence's own
content instead of jumping straight to the closing delimiter. A hermetic
regression test (`spec/treemotion/motion_injection_spec.lua`, using a
bundled-`lua` fence so it runs without `treesitterAllGrammars`) covers this;
confirmed to fail against unmodified `main` and pass with the fix. All 1266
tests pass.

## Attempt 5: attempt 4's mechanism, replayed after the matching fix

With `_injection_at` now able to match multi-region languages, Attempt 4's
"parse lazily, commit a child language fully once any of its regions is
matched" mechanism was re-implemented (same shape as before: `M.current_leaf`
narrows to a one-column-wide range at the cursor; `_injection_at` calls
`ltree:parse(...)` at `node`'s own start before checking children, and
`child:parse(true)` once a match is found) and re-benchmarked end-to-end
against the same 190-fence/1900-line document, this time with `git stash`
ruled out as a confound.

This machine's background noise turned out to be large enough that a 3-sample
comparison of the full top-to-bottom `W` walk was unreliable -- identical
code measured anywhere from 0.94 to 1.61 ms/motion across repeated runs.
Widening to 5 interleaved eager/lazy pairs (alternating which ran first, to
rule out thermal drift) gave eager a mean of ~1.33 ms/motion and lazy ~1.38
ms/motion, with overlapping ranges -- **statistically indistinguishable, not
a regression and not a clear win.** This makes sense in retrospect: a full
top-to-bottom walk eventually touches every injected language in the buffer
either way, so the *total* parsing work done is roughly the same; only *when*
it happens differs.

Cold-start numbers, by contrast, gave a clean, repeatable signal across 4
interleaved trials each (eager first, then lazy, alternating):

| scenario | eager (`parse(true)`) | lazy (`_merge_contiguous` + Attempt 4 mechanism) |
|---|---|---|
| cold, cursor at first rust fence's first column | 61.1-65.8 ms | 57.1-58.3 ms |
| cold, cursor in prose (no rust ever touched) | 22.4-23.3 ms | 19.0-29.4 ms (3 of 4 runs 19-20 ms) |

Every single cold-fence trial favored lazy, by a consistent ~5-13% -- smaller
than the ~73% reduction the original isolated `parse()`-only Benchmark 3
predicted (narrowing the *root's* range doesn't skip its own full-buffer
injection-discovery scan, since Markdown's `has_combined_injections` forces
`full_scan = true` regardless of range -- see "Neovim documentation extracts"
below -- so the win here is specifically from not eagerly committing
`markdown_inline`'s ~570 regions when only `rust` gets touched, not from
skipping discovery). "First touch of a never-visited fence, doc otherwise
warm" -- the scenario Benchmark 3 predicted the biggest win for -- turned out
to measure noise, not signal: this benchmark's own warm-up phase (5 `W`
motions from the top) never actually reaches into a rust fence in either
mode, but *eager*'s very first motion (`parser:parse(true)`, `range = true`
propagating unconditionally through every child) already commits every
region in the whole buffer regardless of where the cursor is -- so by the
time a later motion reaches a "never-visited" fence, eager already paid for
it, coincidentally, on turn one. Lazy defers that cost to whichever motion
actually triggers the first match for that specific language, which is
cheap in isolation (~0.7-1.2 ms to commit all 190 already-discovered rust
regions at once) but doesn't look like a "free" fresh-territory touch in a
benchmark that already warmed the whole buffer via eager's own side effect.

Net effect: no regression anywhere it was measured (full-walk: a wash, not a
loss; cold-start: consistently better), and a real, if modest, architectural
win for the common case eager can't match at all -- a session that only ever
touches a fraction of a large buffer's language mix (edit prose, open one
code fence, never touch the other 189) pays only for what it touches, instead
of eager's unconditional "commit everything in the whole buffer on the very
first motion" behavior. Given that, and unlike Attempts 3/4, this is what
shipped.

## Current state

`_current_leaf` narrows its parse to a one-column-wide range at the cursor
(the same boundary-quirk-safe shape Attempt 2 established); `_injection_at`
parses lazily at each node it checks and commits a matched child language
fully (Attempt 4's mechanism); `_merge_contiguous` fixes the matching bug
that made this regress before. All 1266 tests pass (`busted .`), including
the exact-boundary regression test from Attempts 1/2 and the new multi-region
regression test from the matching-bug fix. See "Attempt 5" above for the
benchmark results this shipped on.

## What a proper fix would look like

This section is now historical -- see "Attempt 5" and "Current state" above
for what actually shipped. It's kept for the reasoning trail: before the
matching bug was found, the working hypothesis was that "parse-as-you-walk
via `LanguageTree:parse()` calls from `_injection_at`" was fundamentally
unworkable given `is_valid()`'s all-or-nothing `_is_entirely_valid` fast
path, and that a real fix would need an entirely separate, module-owned
cache bypassing Neovim's own `parse()`/`is_valid()` machinery altogether.
That turned out to be unnecessary -- the mechanism itself was fine; it just
never got a fair chance to reach the fast path because `_injection_at`
couldn't match a real, common grammar shape (Markdown's multi-region code
fences) at all.

## Is this worth fixing at all?

Yes, and it now has been -- see "Current state". For context on why this
wasn't obvious earlier: steady-state navigation with the *original* eager
`parse(true)` was already free in the common case (no edits between
motions), so the pressure to fix this was never about typical keystroke
latency -- it was the ~7-30ms tax on the first motion after an edit in a
large, injection-heavy buffer, plus (once discovered) the separate
correctness bug where multi-line Markdown code fences weren't being entered
by `w`/`e`/`b` at all. Attempts 3 and 4 looked like they'd made the
performance question worse while leaving the correctness bug alone; fixing
the correctness bug first, as this note's own earlier revision recommended,
turned out to resolve both at once.

## Neovim documentation extracts

Pulled via `nvim --headless -c "help <topic>" -c "%print" -c "qa!"` (see
`CLAUDE.md`'s mandatory rule -- `:help` is the source of truth here, not
guesswork about how the API behaves). Each extract is tied to the specific
claim above it substantiates. Where `:help` doesn't cover the mechanism at
the needed level of detail (the per-region validity bookkeeping behind
"Measured performance" above), the note says so explicitly and cites
Neovim's bundled `vim/treesitter/languagetree.lua` runtime source instead.

### `:help treesitter-language-injections` -- injection queries are already whole-buffer, independently of `parse()`'s range

> Injection queries are currently run over the entire buffer, which can be
> slow for large buffers. To disable injections for, e.g., `c`, just place
> an empty `queries/c/injections.scm` file in your 'runtimepath'.

This is a second, independent full-buffer cost sitting *underneath*
`parse()`'s own range argument -- gated by `LanguageTree:_get_injections`'s
`full_scan` check, which is `true` whenever `range == true` *or* the
query's own `has_combined_injections` flag is set. Per "Measured
performance" above, whether narrowing `range` actually avoids this cost
depends on which level of the tree you're asking about: for a query that
sets `#set! injection.combined` (markdown's own query does, for HTML
blocks), `full_scan` stays `true` regardless of `range`, so narrowing buys
nothing there. For a query without that pattern (Rust's own
`injections.scm` has none), narrowing `range` does avoid the scan -- but
only because `range == true` (eager) otherwise forces `full_scan = true` on
every level it propagates through, not because narrowing skips some single
buffer-wide scan that both modes would otherwise share.

### `:help LanguageTree:parse()` -- confirms the recursive, per-level intersects-`{range}` gating that explains the grandchild failure

> Recursively parse all regions in the language tree using
> |treesitter-parsers| for the corresponding languages and run injection
> queries on the parsed trees to determine whether child trees should be
> created and parsed.
>
> Any region with empty range (`{}`, typically only the root tree) is always
> parsed; otherwise (typically injections) only if it intersects {range} (or
> if {range} is `true`).
>
> Parameters: ~
>   • {range} (`boolean|Range|Range[]?`) Parse this range (or list of
>     ranges, sorted by starting point in ascending order) in the parser's
>     source. Set to `true` to run a complete parse of the source (Note: Can
>     be slow!) Set to `false|nil` to only parse regions with empty ranges
>     (typically only the root tree without injections).

"Any region with empty range... is always parsed" is the documented root of
both the grandchild failure in Attempt 2 *and* the root-reparse floor in
"Measured performance": the root tree's region is exactly this "empty
range" case, so it has no narrower scope for a `{range}` argument to shrink.
"Recursively parse all regions... run injection queries on the parsed trees
to determine whether child trees should be created" is exactly why Attempt 2
still failed one level down: each level's injection query only runs *after*
that level itself gets parsed, and each level only gets parsed if *its own*
region intersects `{range}` -- there's no way to know a grandchild's region
in advance (it doesn't exist yet), so there's no way to build a `{range}`
upfront that's guaranteed to intersect it.

### `:help LanguageTree:is_valid()` / `:help vim.treesitter.get_parser()` -- confirms parsing is cached, not rebuilt per call

> `LanguageTree:is_valid({exclude_children}, {range})`
> Returns whether this LanguageTree is valid, i.e., |LanguageTree:trees()|
> reflects the latest state of the source. If invalid, user should call
> |LanguageTree:parse()|.

> `get_parser({buf}, {lang}, {opts})`
> Returns the parser for a specific buffer and attaches it to the buffer.
> If needed, this will create the parser.

Together these say what "Measured performance" confirms empirically:
`get_parser()` returns the *same* attached parser on repeat calls rather
than rebuilding one, and `parse()` is expected to be a no-op check
(`is_valid()`) rather than a reparse when nothing has changed. Neither
`:help` entry documents the actual per-region bookkeeping (`_valid_regions`,
`_is_entirely_valid`) that makes this fast path work -- that part came from
reading `LanguageTree:_parse`/`_edit`/`is_valid` in the runtime source
directly.

### `:help LanguageTree:included_regions()` -- confirms a narrow parse doesn't just leave far-away trees unparsed, it drops their regions entirely

> Gets the set of included regions managed by this LanguageTree. This can be
> different from the regions set by injection query, because a partial
> |LanguageTree:parse()| drops the regions outside the requested range.

This is the mechanism behind "a `W`/`B` run can walk into a different
injected tree... and that tree's `TSTree` list stays empty" above: it's not
that the tree exists-but-stale, it's that a partial parse actively drops
whatever regions fall outside `{range}` from `included_regions()`, so
`_piece_at`/`_injection_at` (which iterate `included_regions()`) see nothing
there at all, same as if no injection existed in that spot.

### `:help LanguageTree:trees()` -- confirms the `#ltree:trees() == 0` reproduction was reading the right signal

> Returns all trees of the regions parsed by this parser. Does not include
> child languages. The result is list-like if
>   • this LanguageTree is the root, in which case the result is empty or a
>     singleton list; or
>   • the root LanguageTree is fully parsed.

Confirms `trees()` is only reliably list-like once the *root* has been fully
parsed -- exactly why the reproduction scripts above checked `#ltree:trees()`
after a narrow `root:parse(range)` and got `0` for an as-yet-unparsed child:
a partial parse of the root doesn't guarantee a child's own `trees()` is
populated or even list-shaped yet.

### `:help LanguageTree:node_for_range()` vs `:help LanguageTree:parse()` -- why `get_node()` itself was never the problem

> `LanguageTree:node_for_range({range}, {opts})`
> Gets the smallest node that contains {range}.

`:help` doesn't document the exact range shape `get_node()` builds
internally; confirmed by reading `vim/treesitter.lua`'s `M.get_node()`
directly: `local ts_range = { row, col, row, col }`, then (since
`_current_leaf` passes `include_anonymous = true`, see `leaf.lua:600`)
`root_lang_tree:node_for_range(ts_range, opts)`. That's the same zero-width
shape that broke `parse()` at a region's start boundary -- and
`node_for_range()` resolves it correctly regardless.
`node_for_range()`'s "contains" check and `parse()`'s "intersects" check are
different operations over the same shape of range, and only one of them
mishandles the zero-width/boundary case. This is why `M.current_leaf`'s own
`get_node()` call (`leaf.lua:600`) never needed adjusting -- only the
`parse()` call feeding it did.
