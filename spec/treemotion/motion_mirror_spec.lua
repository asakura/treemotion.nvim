--- Make sure `w`/`b`, `e`/`ge`, `W`/`B`, and `E`/`gE` are true mirrors of each
--- other -- stepping forward through a sentence and then stepping backward
--- the same number of times always retraces the exact same stops, in
--- reverse -- for every `commands.motion.small`/`commands.motion.big` rule
--- value, from randomly chosen cursor starting points, and across grammars
--- (including a couple of `:help treesitter-language-injections` fixtures).
---
--- Rather than hand-deriving expected columns per fixture/config pair (what
--- `motion_leaf_spec.lua`/`motion_comment_marker_spec.lua` do, and still the
--- right choice for pinning down one specific documented behavior), this
--- file checks one *generic* invariant that has to hold no matter what
--- `subword.split()` actually produces for a given rule combination: calling
--- the forward motion `n` times from a start position `p0` visits some
--- sequence `F[1..n]`; moving the cursor to `F[n]` and calling the mirror
--- motion `n` times must then visit `F[n-1], F[n-2], ..., F[1], p0` -- the
--- exact same stops, undone. This is what a "mirror" pair means at all, and
--- it holds by construction whenever `word.next_unit`/`word.previous_unit`
--- (`bigword`'s equivalents for `W`/`B`/`E`/`gE`) are genuine inverses of
--- each other, which is precisely the property most at risk of a subtle,
--- one-directional bug -- e.g. an off-by-one only visible walking backward,
--- or a rule that changes forward splitting without symmetrically updating
--- backward.
---
--- `w`/`b` and `e`/`ge` are the real mirror pairs (both "start of word"; both
--- "end of word" -- see `runner.lua`'s module docstring), not `w`/`ge` --
--- confirmed against `motion_spec.lua`'s existing hand-derived subword
--- fixture before writing the generic version here.
---
--- Config coverage: every `treemotion.SubwordDelimiterMode` field
--- (`kebab_case`/`snake_case`/`colon_case`/`slash_case`/`comment_marker_case`)
--- is exercised at its two non-default values (the third value is already
--- covered by the "defaults" baseline below, since `small`/`big` and
--- `code`/`prose` don't all share the same default for the same field), each
--- `boolean` field (`camel_case`/`pascal_case`/`backtick_identifiers`) at its
--- one non-default value, one at a time -- not the full cross product, which
--- is combinatorially infeasible (and, since every field is independently
--- read by `subword.lua`, not meaningfully more likely to catch a bug than
--- one-at-a-time coverage plus the defaults baseline). `opaque_token_min_length`
--- is excluded: it's an unbounded integer threshold, not a finite-domain
--- option, so "every possible value" doesn't apply to it the way it does to
--- the enum/boolean fields above.
---
--- Since `commands.motion.big`'s rules are only consulted once
--- `enabled = true` (see `types.lua`), and `commands.motion.small`'s rules
--- never affect `W`/`E`/`B`/`gE` at all (`runner.lua`: the two families are
--- "symmetric, one level apart", each reading its own group only), a
--- `small.*` config only bothers re-checking `w`/`b`/`e`/`ge`, and a `big.*`
--- config only re-checks `W`/`B`/`E`/`gE` -- the other family's behavior is
--- unaffected and already covered by the "defaults" baseline, which checks
--- all four pairs.
---
--- Grammar coverage: `_FIXTURES` reuses the plain-code lines from
--- `motion_leaf_spec.lua`'s bundled-grammar fixtures (lua/c/vim/query/vimdoc)
--- plus a comment-shaped line per grammar (bundled grammars, whose real
--- `@spell` highlight query ships inside Neovim, plus a representative slice
--- of `_OPTIONAL_COMMENT_MARKERS` languages via a synthetic `@spell` query --
--- same reasoning and `comment_node` mechanism as
--- `motion_comment_marker_spec.lua`, see its module docstring) so both
--- "code" and "prose" rule-sets get exercised. Each comment line packs
--- camelCase, snake_case, kebab-case, a backtick-enclosed identifier, and a
--- `colon_case`/`slash_case`-shaped URL into one span, so every rule this
--- file varies has *something* in the fixture for it to actually affect.
--- A handful of fixtures are multi-line instead, drawn from
--- `motion_gap_spec.lua`'s blank-line-gap and genuinely-multi-row-leaf
--- shapes, so the round-trip invariant gets checked crossing a row
--- boundary too, not just within one line. Two more are drawn from
--- `motion_injection_spec.lua`'s `:help treesitter-language-injections`
--- fixtures -- `vim.cmd([[...]])` (lua host, vim injected) and the same
--- text again inside a ```lua``` markdown fence (markdown host, lua
--- injected, vim injected inside *that* -- three stacked `LanguageTree`s)
--- -- so the generic round-trip invariant, not just
--- `motion_injection_spec.lua`'s own hand-derived columns, gets checked
--- crossing an injection boundary too.
---
--- Start positions and walk length: rather than exhaustively enumerating
--- every row's edges plus a couple of pseudo-random columns (what this file
--- used to do -- combinatorially wasteful now that `_FIXTURES` also
--- includes multi-row and multi-language-tree buffers), `_random_positions`
--- draws `_N_RANDOM_WALKS` deterministically "random" `{row, column}`
--- starting points per fixture via the same seeded `_rng` used everywhere
--- else in this file (so a failure is still reproducible from the
--- fixture's own text). From each start, `_assert_round_trip` also picks a
--- random walk *length* -- not always the longest possible forward run --
--- bounded by how many single steps are actually available from the
--- snapped anchor, so a short walk gets checked just as often as a long
--- one, without ever picking a length the forward leg can't actually
--- complete (the same boundary-truncation trap `_assert_count_round_trip`
--- avoids below, for the same reason).
---
--- `--count`: a separate describe block below checks that a `count`-sized
--- jump (`treemotion.run_motion_w(3)`, ...) is itself invertible by its
--- mirror motion with the same `count` -- not via the same forward/backward
--- call-count bookkeeping as the walk-based checks above (which would
--- wrongly flag a jump `count` couldn't fully complete near a boundary --
--- "undershooting" there is correct, real-Vim-matching behavior, not a bug
--- to catch), but by cross-checking against the single-step sequence
--- directly: a `count`-jump must land exactly where `count` single steps
--- would, and its mirror must undo that in one call. See
--- `_assert_count_round_trip`'s docstring.

local grammar = require("treemotion.grammar_helpers")
local treemotion = require("treemotion")

--- See `grammar_helpers.lua`'s `M.wrap` docstring for why this thin
--- `it(...)` call has to live here instead of in the shared module.
---
---@param fixture {filetype: string, lines: string[], comment_node: string?}
---@param description string
---@param body fun(buffer: integer)
local function _it_per_grammar(fixture, description, body)
    it(string.format("[%s] %s", fixture.filetype, description), grammar.wrap(pending, fixture, body))
end

---@type {filetype: string, comment_node: string?, lines: string[]}[]
local _FIXTURES = {
    -- Plain code, no prose leaves at all -- nested calls, indexing, and a
    -- spread of naming conventions (camelCase, PascalCase, snake_case) in
    -- one line, so splitting rules have more than a single bare identifier
    -- to bite into.
    { filetype = "lua", lines = { "local fooBar = BazQux.quux_thing(1, 2, snake_case_arg)" } },
    { filetype = "c", lines = { "int fooBar = BazQux_quuxThing(1, 2, snake_case_arg);" } },
    { filetype = "vim", lines = { "call foo#BarBaz_quux(thing_one, thing_two, 3)" } },
    {
        filetype = "query",
        lines = { [[(call_expression function: (identifier) @fooBar_baz (#eq? @fooBar_baz "quuxThing"))]] },
    },
    { filetype = "vimdoc", lines = { "foo-bar_baz qux |tag-link_here| 'option-name' quux" } },

    -- Comment-shaped lines, exercising `prose` (and, via the marker itself,
    -- `comment_marker_case`). Neovim's own bundled queries cover these four,
    -- so no `comment_node` override. Each line packs camelCase, PascalCase,
    -- snake_case, kebab-case, a backtick-enclosed identifier, a
    -- backtick-enclosed *multi-word* phrase (should stay plain prose, not
    -- get `code` treatment), a `colon_case`-shaped label, and a
    -- `slash_case`-shaped URL/path, all in one span.
    {
        filetype = "lua",
        lines = {
            [[-- fooBar_baz-qux `fooBar` note: http://example.com/a/b-c also `not code` and ./local/path-thing done]],
        },
    },
    {
        filetype = "c",
        lines = {
            [[// fooBar_baz-qux `fooBar` note: http://example.com/a/b-c also `not code` and ./local/path-thing done]],
        },
    },
    {
        filetype = "vim",
        lines = {
            [["fooBar_baz-qux `fooBar` note: http://example.com/a/b-c also `not code` and ./local/path-thing done]],
        },
    },
    {
        filetype = "query",
        lines = {
            [[; fooBar_baz-qux `fooBar` note: http://example.com/a/b-c also `not code` and ./local/path-thing done]],
        },
    },

    -- A representative slice of `_OPTIONAL_COMMENT_MARKERS`, covering marker
    -- groups the four bundled grammars above don't ("#" and "%").
    {
        filetype = "python",
        comment_node = "comment",
        lines = {
            [[# fooBar_baz-qux `fooBar` note: http://example.com/a/b-c also `not code` and ./local/path-thing done]],
        },
    },
    {
        filetype = "erlang",
        comment_node = "comment",
        lines = {
            [[% fooBar_baz-qux `fooBar` note: http://example.com/a/b-c also `not code` and ./local/path-thing done]],
        },
    },

    -- Row-crossing shapes -- a small multi-statement function whose body
    -- has a blank-line gap (no leaf at all on that row), and a leaf that's
    -- itself split across three rows (a run's *inside*, not a gap between
    -- runs) -- see `motion_gap_spec.lua` for the shapes these are drawn
    -- from. `_random_positions` can land a start on any row, including the
    -- blank gap row itself and a row boundary inside the multi-row leaf,
    -- and the function bodies' indentation gives every non-first row its
    -- own leading gap to land in too.
    {
        filetype = "lua",
        lines = {
            "local function fooBar_baz()",
            "    local quxDone = 1",
            "",
            "    return quxDone + snake_case_val",
            "end",
        },
    },
    {
        filetype = "c",
        lines = {
            "int fooBar_baz(void) {",
            "    int quxDone = 1;",
            "",
            "    return quxDone + snake_case_val;",
            "}",
        },
    },
    { filetype = "lua", lines = { "local x = [[fooBar_baz-qux", "middle-row_here", "hello-world]]" } },
    { filetype = "c", lines = { "int x = 1; /* fooBar_baz-qux", "middle_row-here", "hello-world */ int y = 2;" } },

    -- `:help treesitter-language-injections` boundaries -- flat (lua host,
    -- vim injected, two statements spread across a multi-row Lua long
    -- string) and the same text nested one level deeper inside a ```lua```
    -- markdown fence (markdown host, lua injected, vim injected inside
    -- *that* -- three stacked `LanguageTree`s), extended from
    -- `motion_injection_spec.lua`'s single-statement/single-row shape so
    -- the generic round-trip invariant also gets checked crossing an
    -- injection boundary that itself spans several rows.
    { filetype = "lua", lines = { "vim.cmd([[", "  set number", "  set relativenumber", "]])" } },
    {
        filetype = "markdown",
        lines = { "```lua", "vim.cmd([[", "  set number", "  set relativenumber", "]])", "```" },
    },
}

---@type treemotion.ConfigurationMotionSubwordRules
local _DEFAULT_CODE_RULES = {
    camel_case = true,
    pascal_case = true,
    kebab_case = "skip",
    snake_case = "skip",
    colon_case = "none",
    slash_case = "none",
    comment_marker_case = "stop",
    opaque_token_min_length = 20,
}

---@type treemotion.ConfigurationMotionSubwordRules
local _DEFAULT_PROSE_RULES = {
    camel_case = true,
    pascal_case = true,
    kebab_case = "stop",
    snake_case = "none",
    colon_case = "skip",
    slash_case = "skip",
    comment_marker_case = "stop",
    opaque_token_min_length = 20,
}

--- Mirrors `configuration.lua`'s `_DEFAULTS.commands.motion`, restated here
--- (rather than reached into via `require("treemotion._core.configuration")`,
--- whose `_DEFAULTS` is a local, not exported) so every test in this file can
--- reset to a known-good baseline regardless of what an earlier test -- in
--- this file or an earlier-run spec file sharing the same process-wide
--- `configuration.M.DATA` -- last left active.
---@type treemotion.ConfigurationMotion
local _DEFAULT_MOTION_RULES = {
    small = {
        backtick_identifiers = true,
        code = vim.deepcopy(_DEFAULT_CODE_RULES),
        prose = vim.deepcopy(_DEFAULT_PROSE_RULES),
    },
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
}

local function _reset_configuration()
    treemotion.setup(vim.deepcopy({ commands = { motion = _DEFAULT_MOTION_RULES } }))
end

---@param overrides treemotion.Configuration?
local function _apply_configuration(overrides)
    _reset_configuration()

    if overrides and next(overrides) then
        treemotion.setup(overrides)
    end
end

--- Build one config override touching a single `family.section.field`.
---
--- `family` ("small"/"big") also decides which motion pairs a config built
--- from it needs to re-check -- see `_add_rule_configs`. For `family == "big"`,
--- `enabled` is always forced `true` alongside the override, since
--- `big`'s rules are otherwise dormant (see this file's module docstring).
---
---@param family "small"|"big"
---@param section ("code"|"prose")?
---@param field string
---@param value boolean|string
---@return treemotion.Configuration
local function _override(family, section, field, value)
    local group = { [field] = value }
    local motion = {}

    if section then
        motion[family] = { [section] = group }
    else
        motion[family] = group
    end

    if family == "big" then
        motion.big.enabled = true
    end

    return { commands = { motion = motion } }
end

local _DELIM_FIELDS = { "kebab_case", "snake_case", "colon_case", "slash_case", "comment_marker_case" }
local _DELIM_MODES = { "none", "skip", "stop" }
local _BOOL_FIELDS = { "camel_case", "pascal_case" }

---@param configs {name: string, overrides: treemotion.Configuration, families: string[]}[]
---@param family "small"|"big"
local function _add_rule_configs(configs, family)
    for _, section in ipairs({ "code", "prose" }) do
        local defaults = assert(_DEFAULT_MOTION_RULES[family][section])

        for _, field in ipairs(_DELIM_FIELDS) do
            for _, mode in ipairs(_DELIM_MODES) do
                -- `field` is a plain `string`, not a literal union, so
                -- lua-language-server can't narrow `defaults[field]`'s type
                -- down from the class's declared-optional fields -- every
                -- field in `_DEFAULT_MOTION_RULES` is always concretely
                -- filled in, though, so this is never actually `nil`.
                ---@diagnostic disable-next-line: need-check-nil
                if mode ~= defaults[field] then
                    table.insert(configs, {
                        name = string.format("%s.%s.%s=%s", family, section, field, mode),
                        overrides = _override(family, section, field, mode),
                        families = { family },
                    })
                end
            end
        end

        for _, field in ipairs(_BOOL_FIELDS) do
            -- Same dynamic-key limitation as the `_DELIM_FIELDS` loop above.
            ---@diagnostic disable-next-line: need-check-nil
            local flipped = not defaults[field]

            table.insert(configs, {
                name = string.format("%s.%s.%s=%s", family, section, field, tostring(flipped)),
                overrides = _override(family, section, field, flipped),
                families = { family },
            })
        end
    end

    for _, value in ipairs({ true, false }) do
        if value ~= _DEFAULT_MOTION_RULES[family].backtick_identifiers then
            table.insert(configs, {
                name = string.format("%s.backtick_identifiers=%s", family, tostring(value)),
                overrides = _override(family, nil, "backtick_identifiers", value),
                families = { family },
            })
        end
    end
end

---@type {name: string, overrides: treemotion.Configuration, families: string[]}[]
local _CONFIGS = {
    { name = "defaults", overrides = {}, families = { "small", "big" } },
    {
        name = "big.enabled=true (rules at default)",
        overrides = { commands = { motion = { big = { enabled = true } } } },
        families = { "small", "big" },
    },
}

_add_rule_configs(_CONFIGS, "small")
_add_rule_configs(_CONFIGS, "big")

--- A tiny, self-contained deterministic PRNG (rather than `math.random`, to
--- stay independent of whatever else in the same busted process has already
--- called `math.randomseed`) for picking "random" cursor columns -- the same
--- `text` always yields the same columns, so a failure is reproducible.
---
---@param seed integer
---@return fun(n: integer): integer # Returns a 1-indexed value in `[1, n]` each call.
local function _rng(seed)
    local state = seed

    return function(n)
        state = (state * 1103515245 + 12345) % 2147483648

        return (state % n) + 1
    end
end

---@param text string
---@return integer
local function _seed_from(text)
    local seed = 0

    for index = 1, #text do
        seed = (seed * 31 + text:byte(index)) % 2147483647
    end

    return seed + 1
end

--- Pick `count` deterministically "random" cursor start positions anywhere
--- in `fixture`'s buffer -- a uniformly random row, then a uniformly random
--- column on that row (`0` for a blank row, e.g. the gap row in a
--- blank-line-gap fixture, which has no columns to pick one from at all --
--- `_rng`'s `n % 0` would be a division by zero). Seeded from the fixture's
--- own text, like every other random draw in this file, so a failure is
--- reproducible.
---
---@param fixture {lines: string[]}
---@param count integer
---@return integer[][] # 0-indexed `{row, column}` pairs.
local function _random_positions(fixture, count)
    local next_random = _rng(_seed_from(table.concat(fixture.lines, "\n")))
    local positions = {}

    for _ = 1, count do
        local row = next_random(#fixture.lines) - 1
        local line = fixture.lines[row + 1]
        local column = #line > 0 and (next_random(#line) - 1) or 0

        table.insert(positions, { row, column })
    end

    return positions
end

---@param a integer[]
---@param b integer[]
---@return boolean
local function _positions_equal(a, b)
    return a[1] == b[1] and a[2] == b[2]
end

--- Call `motion_fn` forward until the cursor stops moving (or `500` calls,
--- as a safety cap against an infinite-loop bug), returning every position
--- actually visited (not counting the final, unmoved repeat).
---
---@param motion_fn fun()
---@return integer[][]
local function _collect_forward(motion_fn)
    local positions = {}
    local previous = { grammar.get_cursor() }

    for _ = 1, 500 do
        motion_fn()
        local current = { grammar.get_cursor() }

        if _positions_equal(current, previous) then
            break
        end

        table.insert(positions, current)
        previous = current
    end

    return positions
end

---@param motion_fn fun()
---@param count integer
---@return integer[][]
local function _run_n(motion_fn, count)
    local positions = {}

    for _ = 1, count do
        motion_fn()
        table.insert(positions, { grammar.get_cursor() })
    end

    return positions
end

--- Assert that `backward_fn` exactly undoes a randomly sized walk of
--- `forward_fn` calls, starting from `row`/`column` -- see this file's
--- module docstring for the invariant.
---
--- `row`/`column` is only where the *search* for an anchor starts, not the
--- anchor itself: a raw column -- especially a "random" one -- may land in a
--- gap no unit covers at all (e.g. whitespace between two prose words), and
--- no motion, forward or backward, can ever land back on a non-boundary
--- column. Real Vim has the exact same property -- starting `w`/`b` from
--- the middle of a run of blanks doesn't round-trip to that exact column
--- either, only to the nearest real word boundary -- so this isn't a
--- plugin-specific wrinkle to work around, just what "boundary" means. One
--- `forward_fn()` call always lands on a genuine boundary (that's what it's
--- for, unconditionally for `w`/`W`, at-or-past the cursor for `e`/`E`), so
--- that lands this round-trip's actual anchor.
---
--- The walk length itself is random too, via `next_random` -- picked in
--- `[1, available]`, where `available` is how many single steps
--- `forward_fn` can actually take before stalling from the anchor. Bounding
--- it by `available` (rather than, say, always walking the full stalled
--- sequence) sidesteps the same boundary-truncation trap
--- `_assert_count_round_trip` documents: a length longer than what's
--- actually there would make the forward leg fall short of what the
--- backward leg -- with room to spare -- would retrace.
---
---@param forward_fn fun()
---@param backward_fn fun()
---@param row integer
---@param column integer
---@param next_random fun(n: integer): integer
local function _assert_round_trip(forward_fn, backward_fn, row, column, next_random)
    grammar.set_cursor(row, column)
    forward_fn()
    local start = { grammar.get_cursor() }

    local forward_positions = _collect_forward(forward_fn)
    local available = #forward_positions

    if available == 0 then
        -- Nothing to move over from this start (e.g. the last unit in the
        -- buffer) -- no mirror to check.
        return
    end

    local n = next_random(available)
    local last = forward_positions[n]
    grammar.set_cursor(last[1], last[2])

    local backward_positions = _run_n(backward_fn, n)

    local expected = {}
    for index = n - 1, 1, -1 do
        table.insert(expected, forward_positions[index])
    end
    table.insert(expected, start)

    assert.same(expected, backward_positions)
end

local _N_RANDOM_WALKS = 5

describe("motion API - w/b, e/ge, W/B, E/gE mirror round-trips, across configurations and grammars #slow", function()
    after_each(_reset_configuration)

    for _, fixture in ipairs(_FIXTURES) do
        local positions = _random_positions(fixture, _N_RANDOM_WALKS)

        for _, config in ipairs(_CONFIGS) do
            _it_per_grammar(fixture, string.format("round-trips under %s", config.name), function()
                _apply_configuration(config.overrides)

                -- Seeded per (fixture, config) rather than shared globally,
                -- so different configs don't all pick the exact same walk
                -- lengths -- still fully deterministic/reproducible.
                local next_random = _rng(_seed_from(config.name))

                for _, position in ipairs(positions) do
                    if vim.tbl_contains(config.families, "small") then
                        _assert_round_trip(
                            treemotion.run_motion_w,
                            treemotion.run_motion_b,
                            position[1],
                            position[2],
                            next_random
                        )
                        _assert_round_trip(
                            treemotion.run_motion_e,
                            treemotion.run_motion_ge,
                            position[1],
                            position[2],
                            next_random
                        )
                    end

                    if vim.tbl_contains(config.families, "big") then
                        _assert_round_trip(
                            treemotion.run_motion_W,
                            treemotion.run_motion_B,
                            position[1],
                            position[2],
                            next_random
                        )
                        _assert_round_trip(
                            treemotion.run_motion_E,
                            treemotion.run_motion_gE,
                            position[1],
                            position[2],
                            next_random
                        )
                    end
                end
            end)
        end
    end
end)

describe("motion API - w/b, e/ge, W/B, E/gE mirror round-trips with #count, across grammars #slow", function()
    after_each(_reset_configuration)

    --- Verify one `count`-sized jump round-trips, without ever picking a
    --- `count`/position combination close enough to a boundary that the
    --- forward jump would run out of units partway through (a "truncated"
    --- jump) -- see this block's module-level comment for why that case is
    --- deliberately out of scope.
    ---
    ---@param single_forward_fn fun() The un-counted forward motion (e.g. `treemotion.run_motion_w`).
    ---@param multi_forward_fn fun() `single_forward_fn`'s motion, called with a fixed `count`.
    ---@param multi_backward_fn fun() The mirror motion, called with that same `count`.
    ---@param count integer
    ---@param row integer
    ---@param column integer
    local function _assert_count_round_trip(single_forward_fn, multi_forward_fn, multi_backward_fn, count, row, column)
        grammar.set_cursor(row, column)
        single_forward_fn()
        local anchor = { grammar.get_cursor() }

        local single_steps = _collect_forward(single_forward_fn)

        if count > #single_steps then
            -- Fewer than `count` units remain ahead of `anchor` -- a
            -- `count`-jump from here would run out partway through (the
            -- same way real Vim's own counted motions just go as far as
            -- they can near a buffer boundary, rather than failing), so
            -- there's no clean single-jump round-trip to assert here.
            return
        end

        grammar.set_cursor(anchor[1], anchor[2])
        multi_forward_fn()
        assert.same(single_steps[count], { grammar.get_cursor() })

        multi_backward_fn()
        assert.same(anchor, { grammar.get_cursor() })
    end

    ---@param count integer
    ---@param row integer
    ---@param column integer
    local function _run_count_checks(count, row, column)
        _assert_count_round_trip(treemotion.run_motion_w, function()
            treemotion.run_motion_w(count)
        end, function()
            treemotion.run_motion_b(count)
        end, count, row, column)

        _assert_count_round_trip(treemotion.run_motion_e, function()
            treemotion.run_motion_e(count)
        end, function()
            treemotion.run_motion_ge(count)
        end, count, row, column)

        _assert_count_round_trip(treemotion.run_motion_W, function()
            treemotion.run_motion_W(count)
        end, function()
            treemotion.run_motion_B(count)
        end, count, row, column)

        _assert_count_round_trip(treemotion.run_motion_E, function()
            treemotion.run_motion_E(count)
        end, function()
            treemotion.run_motion_gE(count)
        end, count, row, column)
    end

    -- Only two configs -- `count`'s own looping logic (`runner.lua`'s
    -- `_move_*` functions each just call their single-step body `count`
    -- times) isn't rule-sensitive, so it doesn't need the full
    -- `_CONFIGS` matrix the way splitting behavior itself does (already
    -- covered above); `big.enabled = true` is still worth its own pass, so a
    -- multi-step `W`/`E`/`B`/`gE` jump gets exercised while it's actually
    -- sub-splitting runs, not just skipping whole ones.
    local _COUNT_CONFIGS = {
        { name = "defaults", overrides = {} },
        {
            name = "big.enabled=true (rules at default)",
            overrides = { commands = { motion = { big = { enabled = true } } } },
        },
    }
    local _COUNTS = { 2, 3 }

    for _, fixture in ipairs(_FIXTURES) do
        local positions = _random_positions(fixture, _N_RANDOM_WALKS)

        for _, config in ipairs(_COUNT_CONFIGS) do
            for _, count in ipairs(_COUNTS) do
                _it_per_grammar(
                    fixture,
                    string.format("round-trips with --count=%d under %s", count, config.name),
                    function()
                        _apply_configuration(config.overrides)

                        for _, position in ipairs(positions) do
                            _run_count_checks(count, position[1], position[2])
                        end
                    end
                )
            end
        end
    end
end)
