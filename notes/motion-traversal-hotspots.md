# Profiling the remaining `_commands.motion.leaf`/`runner` hot spots

Status: **three fixed, two measured and rejected.** Follow-on to
`notes/injection-parse-performance.md`, which covered `parser:parse()`'s own
cost. This note covers five candidate hot spots identified by reading
`leaf.lua`/`word.lua`/`bigword.lua`/`subword.lua`/`runner.lua`/
`configuration.lua`: the `count`-loop shape in `runner.lua`,
`_has_uncovered_text`'s per-child buffer reads, `_injection_at`'s linear
region scan, `configuration.resolve_data()`'s unconditional deep-copy, and
`subword.lua`'s `_is_prose` being called twice per leaf split. All five were
profiled with a purpose-built benchmark (real `treemotion.run_motion_*`/
`leaf.*`/`word.*`/`configuration.*` calls against synthetic buffers, not
microbenchmarks of code in isolation) before touching any code, so the fixes
below are backed by measurement, not just the architectural reasoning that
first flagged them.

Benchmark harness: `nvim --headless -u NONE -U NONE -N -i NONE --cmd "set
rtp+=<treesitterAllGrammars store path>" -l bench.lua [a|b|c|d|e]` against a
throwaway `bench.lua` (not committed -- see "Reproducing this" below for the
buffer-construction details needed to rebuild it), same headless-Neovim
methodology `notes/injection-parse-performance.md` used. Full `nix run
.#test` (1266 tests) passes after all three fixes, plus `stylua`/`luacheck`/
`llscheck` clean.

## Hot spot 1: `runner.lua`'s `count`-loop re-resolves from the cursor every iteration -- measured, not a real cost

**Hypothesis going in:** every `_move_*` function in `runner.lua` (all
eight motion shapes) calls `word.current_unit`/`bigword.current_unit` fresh
on *every* iteration of its `for _ = 1, count do` loop, even after the first
iteration has already found a unit and only needs to step to the next one.
`current_unit`/`current_leaf` looks architecturally heavier than
`next_unit`/`next_leaf` -- `vim.treesitter.get_node()`, the
settle-upward-past-uncovered-text loop, `_injection_at` -- so `10w` looked
like it should pay 10 expensive resolutions instead of 1 expensive
resolution + 9 cheap steps.

**Measured:** false, in a fully warm buffer (the common case -- no edits
between motions). Walked 300 real steps forward with chained `next_unit()`,
then separately re-resolved `current_unit()` fresh from the cursor at each
of those same 300 positions (an apples-to-apples comparison against real
content, not "the same position asked twice in a row," which is trivially
cache-hot and gives a misleading result):

| | before this note's other fixes | after |
|---|---|---|
| 300 steps, chained `next_unit()` | 0.0507 ms/step | 0.0308 ms/step |
| 300 steps, fresh `current_unit()` each | 0.0489 ms/step | 0.0323 ms/step |
| ratio fresh/chained | **0.96x** | **1.05x** |

Statistically indistinguishable both before and after the other two fixes
below (the small across-run wobble is noise, not a directional signal --
fresh was *cheaper* than chained in the first run). `vim.treesitter.get_node()`
is apparently not the expensive linear operation the code-reading intuition
assumed -- Neovim's own C-level tree search resolves a point query in time
comparable to the Lua-level sibling-climb `next_leaf` does, at least at the
scale tested (a 1900-line, 190-fence document). **No change made** --
rewriting the `count` loops to chain through `next_unit`/`previous_unit`
instead of re-resolving would add real complexity (particularly around the
gap-substitution logic in `_is_cursor_inside`) for a measured improvement of
approximately zero. This is the point of measuring before fixing: the
architecturally-obvious "waste" here wasn't actually waste.

## Hot spot 2: `_has_uncovered_text` re-reads every child's buffer text on every visit to the same node -- real, fixed

**Where:** `leaf.lua`'s `_has_uncovered_text` (the function behind `_is_leaf`,
checked at every level of `M.first_leaf`/`M.last_leaf`'s recursive descent
and once by `_current_leaf`/`_leaf_at`'s settle-upward loop). For a
container node with `N` children, it was O(N) `nvim_buf_get_text` calls to
decide "is this node fully covered by its children" -- and, with no
memoization, that full O(N) scan repeated *every single time* a walk
re-entered the same node (`gg`/`G` repeatedly re-descending into the same
large table/array literal from outside; separate motions each landing near
one).

**Measured** (`M.first_leaf` called directly on a Lua `table_constructor`
node with `N` fields, 20 uncached calls in a row, averaged -- every call
paid the same cost, confirming there was no warm-up effect to begin with):

| fields | before | after | speedup |
|---|---|---|---|
| 50 | 0.0498 ms/call | 0.0189 ms/call | 2.6x |
| 500 | 0.691 ms/call | 0.0700 ms/call | 9.9x |
| 3,000 | 5.35 ms/call | 0.298 ms/call | 18x |
| 15,000 | 32.2 ms/call | 3.04 ms/call | 10.6x |

(The "after" numbers still include one genuine cache miss per 20-call batch,
since each batch starts on a fresh buffer -- that's why the speedup isn't
closer to 20x; a session that revisits the same node many times over its
actual lifetime, the scenario this exists for, would see closer to that.)
15,000 fields is an extreme case chosen to make the O(N) shape obvious, but
3,000 (a plausible size for a large generated config table, enum, or JSON-ish
data literal) already cost over 5ms per uncached visit before the fix --
well into user-perceptible territory if a motion or repeated `gg`/`G`
lands there more than once in a session.

**Fix:** memoize `_has_uncovered_text`'s result, weak-keyed on the `TSNode`
itself (`setmetatable({}, { __mode = "k" })`, the same pattern this file
already uses for `_tree_to_ltree`). Confirmed safe to key on node identity
directly, not `node:id()`: repeated queries for the same underlying
tree-sitter node return the *same* Lua object (`root:child(0) ==
root:child(0)` is `true`, not just `:equal()` -- checked directly against a
real parse), so a stale cache entry can never be observed -- a node whose
underlying tree was replaced by a reparse is a different, unreachable
object, garbage-collected away rather than answering for content that no
longer exists there.

## Hot spot 3: `_injection_at`'s linear region scan degrades with *unrelated* injection count elsewhere in the document -- real, fixed

**Where:** `leaf.lua`'s `_injection_at`, called on every node every
leaf-walk entry point touches. For each of `node`'s owning tree's children
(injected languages), it scanned every `included_regions()` group and every
piece within it looking for an exact-range match -- O(total regions in that
language), regardless of whether `node` is anywhere near an injection.

`notes/injection-parse-performance.md`'s own Attempt 5 benchmark measured
this as "a wash" against eager parsing, but that benchmark was a *full*
top-to-bottom walk of a 762-region document -- total work is dominated by
"every region gets touched once either way" in that shape, which hides an
O(n) per-step scan cost behind O(n) total unavoidable work. It doesn't
answer the question this note asked instead: does a *fixed-size, fixed-position*
walk get slower as the *rest* of the document grows, even though the walk
itself never touches any more content? It does:

| fences in document | 300-step warm walk near the top, before | after |
|---|---|---|
| 190 | 16.5 ms total (0.0550 ms/step) | 8.0 ms total (0.0268 ms/step) |
| 800 | 35.2 ms total (0.1174 ms/step) | 6.0 ms total (0.0200 ms/step) |
| 2,000 | 85.8 ms total (0.2860 ms/step) | 8.3 ms total (0.0275 ms/step) |

Before the fix, per-step cost scaled with total document injection count
(190 -> 2000 fences: **5.2x** slower per step) even though the walk covered
the same 300 steps near the top of the document every time. After the fix,
per-step cost is flat regardless of document size (0.0268/0.0200/0.0275
ms/step -- noise-level variation, no growth trend).

**Fix:** `_sorted_pieces(ltree)` flattens every `included_regions()` group
(each still merged via the existing `_merge_contiguous`) into one array
sorted by start position, cached weak-keyed on the `included_regions()`
table's own identity. That identity is safe to key on for the same reason
`_tree_to_ltree`/`_uncovered_text_cache` are: `LanguageTree:set_included_regions()`
and `LanguageTree:_edit()` (`vim/treesitter/languagetree.lua`, confirmed by
reading the source directly) both unconditionally reassign `self._regions`
to a brand-new table on every call that could possibly change what regions
mean, so a stale cache entry can never be read back -- it would have to be
keyed on a table that `included_regions()` no longer returns, which means
it's simply unreachable and garbage-collected. `_floor_index` binary-searches
that sorted array for the rightmost piece starting at-or-before a target
point (used directly by `_piece_at`'s point-containment query, and by
`_injection_at`'s exact-range match after confirming the found piece's start
is an exact hit, walking backward through any same-start ties to check their
ends). Both `_piece_at` and `_injection_at` now do O(log n + children) work
per call instead of O(n).

Flattening pieces from *every* group into one sorted array (not just
binary-searching within each group separately) is safe because regions
belonging to one `LanguageTree` never overlap each other -- each represents
a disjoint span of that language's one parse -- so pieces from different
combined-injection groups can be compared in the same sorted order without
risk of the floor search picking the wrong group's piece for a given point.

## Hot spot 4: `configuration.resolve_data()` deep-copies the whole config tree on every call -- real but small, fixed anyway

**Where:** `configuration.lua`'s `M.resolve_data()` called
`vim.tbl_deep_extend("force", M.DATA, data or {})` unconditionally, even
when `data` is `nil` -- the *only* way `_commands.motion.subword` ever calls
it (`_rules`, `_backtick_identifiers_enabled`, `_split_run`'s `.enabled`
check -- confirmed by grepping every call site: `health.lua`'s is the one
caller that ever passes a real override). Merging `M.DATA` with `{}` under
`"force"` produces a value equal to `M.DATA` itself, just a freshly (and,
for every nested `commands.motion.*` table, recursively) deep-copied one --
so every one of those calls was paying for a full config-tree copy to get
back data that was already sitting there.

**Measured** (20,000 direct `resolve_data()` calls, plus a real 300-step
`word.next_unit()` walk over the same 190-fence markdown document scenarios
A/C use):

| | before | after |
|---|---|---|
| 20,000 x `resolve_data()` | 0.000491 ms/call | 0.000048 ms/call (**10.2x**) |
| 300-step word walk | 0.0261 ms/step | 0.0248-0.0313 ms/step (noise) |

The direct per-call cost dropped a real, consistent ~10x. The end-to-end
word-walk number, though, didn't move outside its own run-to-run noise band
(three post-fix runs: 0.0285, 0.0248, 0.0313 ms/step, bracketing the
pre-fix 0.0261) -- `resolve_data()` is only called once or twice per leaf
*boundary crossing* (not every step; most subword steps are a cheap `_index`
bump with no config lookup at all), and even at the old, slower per-call
cost its total share of the walk was on the order of 5%, too small to
separate from noise at this sample size. **Fixed anyway**: the change is a
two-line, zero-risk correctness-preserving optimization (skip the copy,
return `M.DATA` directly, since every no-override caller only reads it --
see the docstring for why that's safe), it measurably eliminates real,
repeated allocation and GC pressure regardless of whether that shows up in
wall-clock noise at this buffer size, and there's no plausible scenario
where doing *less* work here could regress anything. Not the kind of fix
that would be worth the same risk/complexity tradeoff as hot spots 2/3 if it
required restructuring, but this one is strictly cheaper code, not more
complex code, so the small/unproven win is still worth taking.

## Hot spot 5: `subword._is_prose`'s duplicate call per leaf split -- measured, not a real cost

**Hypothesis going in:** `subword.lua`'s `_split(node)` calls
`_is_insignificant(node)` first (which itself calls `_is_prose(node)` for
any *named* leaf), then, further down, calls `_is_prose(node)` a *second*
time on the same node to pick `.code`/`.prose` rules -- an apparently
wasteful duplicate `vim.treesitter.get_captures_at_pos()` call on every
split of every named leaf, the same "redundant work on repeat visits" shape
that made hot spot 2 a real, measured win.

**Measured:** false. `get_captures_at_pos()` itself is cheap
(0.000075 ms/call, direct benchmark, 20,000 calls), and instrumenting the
real function during the same 300-step word walk used above shows it's only
actually invoked 439 times total (1.46 calls/step on average -- lower than
"2 per leaf split" because most steps don't cross a leaf boundary at all).
439 calls x 0.000075 ms is about 0.03 ms out of a ~7-9 ms walk -- under 0.5%
of total time. **No change made** -- unlike `_has_uncovered_text` (hot spot
2), whose uncached cost scaled with node width and reached tens of
milliseconds on a single call, `get_captures_at_pos()`'s cost never leaves
the noise floor at any realistic call volume this code path produces, so
there's nothing here for a cache to meaningfully save.

## Reproducing this

The benchmark buffers: Scenario A/C/D reuse
`notes/injection-parse-performance.md`'s synthetic-Markdown-with-Rust-fences
shape (prose lines interspersed with `` ```rust `` fences containing a small
function). Scenario B is a single-line `local t = { field_1 = 1, field_2 =
2, ... }` with `N` fields, walked via `leaf.first_leaf()` on the
`table_constructor` node found by a manual tree search. Scenario E reuses
scenario A/C's markdown document, querying `get_captures_at_pos` directly
at a fixed position and, separately, wrapping the real function to count
calls made during a real 300-step `word.next_unit()` walk. All scenarios
force a full `parser:parse(true)` immediately after buffer creation so the
measurement is traversal cost, not cold-parse cost (that's
`injection-parse-performance.md`'s question, not this one's). Timing via
`vim.uv.hrtime()`.
