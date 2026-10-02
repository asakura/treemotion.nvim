--- `w`/`b`, `e`/`ge`, `W`/`B` and `E`/`gE` must be mirrors: `n` forward steps
--- from a position, then `n` backward steps, retrace the same stops in
--- reverse. Checked for every non-default rule value (one at a time), across
--- grammars, multi-row buffers and injections, from seeded random starts.
---
--- A `count` jump must land where `count` single steps would, and its mirror
--- with the same `count` must undo it.

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
    -- Plain code with several naming conventions.
    { filetype = "lua", lines = { "local fooBar = BazQux.quux_thing(1, 2, snake_case_arg)" } },
    { filetype = "c", lines = { "int fooBar = BazQux_quuxThing(1, 2, snake_case_arg);" } },
    { filetype = "vim", lines = { "call foo#BarBaz_quux(thing_one, thing_two, 3)" } },
    {
        filetype = "query",
        lines = { [[(call_expression function: (identifier) @fooBar_baz (#eq? @fooBar_baz "quuxThing"))]] },
    },
    { filetype = "vimdoc", lines = { "foo-bar_baz qux |tag-link_here| 'option-name' quux" } },

    -- Comments, for the `prose` rules and `comment_marker_case`. Each packs
    -- every convention, a backtick identifier, a backtick phrase, a label
    -- and a URL.
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

    -- Rows: a blank-line gap, and a leaf spanning three rows.
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

    -- Injections: Vim in Lua, and Vim in Lua in a Markdown fence.
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

--- `_DEFAULTS.commands.motion`, restated so each test can reset to it.
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

--- A configuration overriding one `family.section.field`. `big` overrides
--- also set `enabled`, since `big`'s rules are otherwise unused.
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

--- A seeded PRNG, independent of `math.random`, so failures reproduce.
---
---@param seed integer
---@return fun(n: integer): integer # A value in `[1, n]`.
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

--- `count` seeded random positions in `fixture` (column 0 on blank rows).
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

--- Assert `backward_fn` undoes a random-length walk of `forward_fn`.
---
--- The walk starts from the first forward stop after `row`/`column`, since a
--- random column may not be a boundary. Its length is at most the number of
--- steps available, so the forward leg is never cut short by the buffer end.
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

    --- Assert one `count` jump round-trips, skipping starts too close to the
    --- buffer end for the jump to complete.
    ---
    ---@param single_forward_fn fun()
    ---@param multi_forward_fn fun()
    ---@param multi_backward_fn fun()
    ---@param count integer
    ---@param row integer
    ---@param column integer
    local function _assert_count_round_trip(single_forward_fn, multi_forward_fn, multi_backward_fn, count, row, column)
        grammar.set_cursor(row, column)
        single_forward_fn()
        local anchor = { grammar.get_cursor() }

        local single_steps = _collect_forward(single_forward_fn)

        if count > #single_steps then
            -- Fewer than `count` units ahead, so the jump would stop short.
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

    -- `count` isn't rule-sensitive; `big.enabled` gets a pass of its own.
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
