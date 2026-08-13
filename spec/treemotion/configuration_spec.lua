--- Make sure configuration health checks succeed or fail where they should.

local configuration_ = require("treemotion._core.configuration")
local health = require("treemotion.health")

local mock_vim = require("test_utilities.mock_vim")

--- Make sure `data`, whether undefined, defined, or partially defined, is broken.
---
---@param data treemotion.Configuration? The user customizations, if any.
---@param messages string[] All found, expected error messages.
---
local function _assert_bad(data, messages)
    data = configuration_.resolve_data(data)
    local issues = health.get_issues(data)

    if vim.tbl_isempty(issues) then
        error(string.format('Test did not fail. Configuration "%s is valid.', vim.inspect(data)))

        return
    end

    assert.same(messages, issues)
end

--- Make sure `data`, whether undefined, defined, or partially defined, works.
---
---@param data treemotion.Configuration? The user customizations, if any.
---
local function _assert_good(data)
    data = configuration_.resolve_data(data)
    local issues = health.get_issues(data)

    if vim.tbl_isempty(issues) then
        return
    end

    error(
        string.format(
            'Test did not succeed. Configuration "%s fails with "%s" issues.',
            vim.inspect(data),
            vim.inspect(issues)
        )
    )
end

describe("default", function()
    it("works with an #empty configuration", function()
        _assert_good({})
        _assert_good()
    end)

    it("works with a fully defined, custom configuration", function()
        _assert_good({
            commands = {
                goodnight_moon = {
                    read = { phrase = "The Origin of Consciousness in the Breakdown of the Bicameral Mind" },
                },
                hello_world = { say = { ["repeat"] = 12, style = "uppercase" } },
            },
        })
    end)

    it("works with the default configuration", function()
        _assert_good({
            commands = {
                goodnight_moon = { phrase = "A good book" },
                hello_world = { say = { ["repeat"] = 1, style = "lowercase" } },
            },
        })
    end)

    it("works with the partially-defined configuration", function()
        _assert_good({
            commands = {
                goodnight_moon = {},
                hello_world = {},
            },
        })
    end)

    it(
        "works with every #commands.motion.subword.kebab_case/snake_case/comment_marker_case mode, "
            .. "for both code and prose",
        function()
            for _, mode in ipairs({ "none", "skip", "stop" }) do
                _assert_good({
                    commands = {
                        motion = {
                            subword = {
                                code = { kebab_case = mode, snake_case = mode, comment_marker_case = mode },
                                prose = { kebab_case = mode, snake_case = mode, comment_marker_case = mode },
                            },
                        },
                    },
                })
            end
        end
    )

    it("works with a #commands.motion.subword.comment_markers table with several languages", function()
        _assert_good({
            commands = {
                motion = {
                    subword = {
                        comment_markers = { lua = { "#" }, python = { "#" }, vim = { '"' } },
                    },
                },
            },
        })
    end)

    it("works with an #commands.motion.subword.comment_markers table with an empty character list", function()
        _assert_good({ commands = { motion = { subword = { comment_markers = { lua = {} } } } } })
    end)
end)

describe("get_comment_markers", function()
    ---@type treemotion.ResolvedConfiguration
    local _snapshot

    before_each(function()
        _snapshot = vim.deepcopy(configuration_.DATA)

        -- `M.DATA` is one shared, process-wide table, and `motion_spec.lua`'s
        -- "subword configuration" describe block deliberately leaves `lua`'s
        -- `comment_markers` zeroed out to `{}` in its own `after_each` (see
        -- its comment) -- a leak into whichever spec file runs next in the
        -- same busted process. Force the real shipped default back before
        -- every test here so these assertions don't depend on file run order.
        configuration_.DATA.commands.motion.subword.comment_markers.lua = { "-" }
        configuration_.DATA.commands.motion.subword.comment_markers.toml = nil
    end)

    after_each(function()
        configuration_.DATA = _snapshot
    end)

    it("returns a shipped #_DEFAULTS entry unchanged", function()
        assert.same({ "-" }, configuration_.get_comment_markers("lua"))
    end)

    it(
        "prefers a user-configured #comment_markers override over both the shipped default "
            .. "and the _OPTIONAL_COMMENT_MARKERS table",
        function()
            configuration_.merge_data({
                commands = { motion = { subword = { comment_markers = { lua = { "@" }, toml = { "@" } } } } },
            })

            -- `lua` is a shipped default (`_DEFAULTS`' `"-"`); `toml` only exists
            -- in `_OPTIONAL_COMMENT_MARKERS` (`"#"`) -- the override wins in both cases.
            assert.same({ "@" }, configuration_.get_comment_markers("lua"))
            assert.same({ "@" }, configuration_.get_comment_markers("toml"))
        end
    )

    it("resolves an #_OPTIONAL_COMMENT_MARKERS entry when the language's treesitter parser is installed", function()
        -- `toml` isn't one of Neovim's bundled grammars, but the Nix-driven
        -- dev-shell/`nix run .#test` suite's `treesitterAllGrammars` (see
        -- `flake.nix`) makes it available there -- consistent with how
        -- `motion_leaf_spec.lua`/`motion_gap_spec.lua` already rely on
        -- grammars beyond the bundled set. `nix build '.#treemotion-nvim'`'s
        -- own `checkPhase`, though, only has Neovim's 6 bundled grammars, so
        -- guard this the same way `grammar_helpers.lua`'s cross-grammar
        -- fixtures do, rather than asserting a parser that may not exist here.
        if not vim.treesitter.language.add("toml") then
            ---@diagnostic disable-next-line: missing-parameter
            pending('no "toml" treesitter parser installed')

            return
        end

        assert.same({ "#" }, configuration_.get_comment_markers("toml"))
    end)

    it("returns nil for an #_OPTIONAL_COMMENT_MARKERS entry when the language's parser is not installed", function()
        -- The bundled busted/luassert LuaCATS stubs only declare `stub.new`'s
        -- return type, not the fluent `.returns(...)` builder method it
        -- actually has at runtime (same kind of stub-coverage gap as
        -- `pending(reason)` in `grammar_helpers.lua`).
        ---@diagnostic disable-next-line: undefined-field
        local add_stub = stub(vim.treesitter.language, "add").returns(false)

        assert.is_nil(configuration_.get_comment_markers("toml"))

        add_stub:revert()
    end)

    it("returns nil for a language absent from both #_DEFAULTS and #_OPTIONAL_COMMENT_MARKERS", function()
        assert.is_nil(configuration_.get_comment_markers("not_a_real_language"))
    end)
end)

---@diagnostic disable: assign-type-mismatch
---@diagnostic disable: missing-fields
describe("bad configuration - commands", function()
    it("happens with a bad type for #commands.goodnight_moon.phrase", function()
        _assert_bad(
            { commands = { goodnight_moon = { read = { phrase = 10 } } } },
            { "commands.goodnight_moon.read.phrase: expected string, got number" }
        )
    end)

    it("happens with a bad type for #commands.hello_world.say.repeat", function()
        _assert_bad(
            { commands = { hello_world = { say = { ["repeat"] = "foo" } } } },
            { "commands.hello_world.say.repeat: expected a number (value must be 1-or-more), got foo" }
        )
    end)

    it("happens with a bad value for #commands.hello_world.say.repeat", function()
        _assert_bad(
            { commands = { hello_world = { say = { ["repeat"] = -1 } } } },
            { "commands.hello_world.say.repeat: expected a number (value must be 1-or-more), got -1" }
        )
    end)

    it("happens with a bad type for #commands.hello_world.say.style", function()
        _assert_bad(
            { commands = { hello_world = { say = { style = 123 } } } },
            { 'commands.hello_world.say.style: expected "lowercase" or "uppercase", got 123' }
        )
    end)

    it("happens with a bad value for #commands.hello_world.say.style", function()
        _assert_bad(
            { commands = { hello_world = { say = { style = "bad_value" } } } },
            { 'commands.hello_world.say.style: expected "lowercase" or "uppercase", got bad_value' }
        )
    end)

    it("happens with a bad type for #commands.motion.subword.comment_markers", function()
        _assert_bad({ commands = { motion = { subword = { comment_markers = "aaa" } } } }, {
            "commands.motion.subword.comment_markers: expected a table<string, string[]> "
                .. "(treesitter language name -> comment-marker characters), got aaa",
        })
    end)

    it("happens with a bad shape for #commands.motion.subword.comment_markers", function()
        -- The bad value here is a *table*, so `vim.validate`'s "got <value>" suffix
        -- would print an unstable memory address (`table: 0x...`) instead of
        -- something a test can match exactly -- so this only checks the message's
        -- stable prefix, unlike the exact-match `_assert_bad` calls elsewhere.
        local issues = health.get_issues(configuration_.resolve_data({
            commands = { motion = { subword = { comment_markers = { lua = "aaa" } } } },
        }))

        assert.same(1, #issues)
        assert.is_true(
            vim.startswith(
                issues[1],
                "commands.motion.subword.comment_markers: expected a table<string, string[]> "
                    .. "(treesitter language name -> comment-marker characters), got "
            )
        )
    end)

    for _, context in ipairs({ "code", "prose" }) do
        it(string.format("happens with a bad type for #commands.motion.subword.%s.camel_case", context), function()
            _assert_bad(
                { commands = { motion = { subword = { [context] = { camel_case = "aaa" } } } } },
                { string.format("commands.motion.subword.%s.camel_case: expected a boolean, got aaa", context) }
            )
        end)

        it(string.format("happens with a bad type for #commands.motion.subword.%s.pascal_case", context), function()
            _assert_bad(
                { commands = { motion = { subword = { [context] = { pascal_case = "aaa" } } } } },
                { string.format("commands.motion.subword.%s.pascal_case: expected a boolean, got aaa", context) }
            )
        end)

        it(string.format("happens with a bad value for #commands.motion.subword.%s.kebab_case", context), function()
            _assert_bad({ commands = { motion = { subword = { [context] = { kebab_case = "aaa" } } } } }, {
                string.format(
                    'commands.motion.subword.%s.kebab_case: expected "none" or "skip" or "stop", got aaa',
                    context
                ),
            })
        end)

        it(string.format("happens with a bad value for #commands.motion.subword.%s.snake_case", context), function()
            _assert_bad({ commands = { motion = { subword = { [context] = { snake_case = "aaa" } } } } }, {
                string.format(
                    'commands.motion.subword.%s.snake_case: expected "none" or "skip" or "stop", got aaa',
                    context
                ),
            })
        end)

        it(
            string.format("happens with a bad value for #commands.motion.subword.%s.comment_marker_case", context),
            function()
                _assert_bad({ commands = { motion = { subword = { [context] = { comment_marker_case = "aaa" } } } } }, {
                    string.format(
                        'commands.motion.subword.%s.comment_marker_case: expected "none" or "skip" or "stop", got aaa',
                        context
                    ),
                })
            end
        )
    end
end)
---@diagnostic enable: assign-type-mismatch
---@diagnostic enable: missing-fields

---@diagnostic disable: assign-type-mismatch
describe("bad configuration - logging", function()
    it("happens with a bad value for #logging", function()
        _assert_bad({ logging = false }, { 'logging: expected a table. e.g. { level = "info", ... }, got false' })
    end)

    it("happens with a bad value for #logging.level", function()
        _assert_bad({ logging = { level = false } }, {
            "logging.level: expected an enum. "
                .. 'e.g. "trace" | "debug" | "info" | "warning" | "error" | "fatal", got false',
        })

        _assert_bad({ logging = { level = "does not exist" } }, {
            "logging.level: expected an enum. "
                .. 'e.g. "trace" | "debug" | "info" | "warning" | "error" | "fatal", got does not exist',
        })
    end)

    it("happens with a bad value for #logging.use_console", function()
        _assert_bad({ logging = { use_console = "aaa" } }, { "logging.use_console: expected a boolean, got aaa" })
    end)

    it("happens with a bad value for #logging.use_file", function()
        _assert_bad({ logging = { use_file = "aaa" } }, { "logging.use_file: expected a boolean, got aaa" })
    end)
end)
---@diagnostic enable: assign-type-mismatch

---@diagnostic disable: assign-type-mismatch
describe("health.check", function()
    before_each(function()
        mock_vim.mock_vim_health()
    end)
    after_each(mock_vim.reset_mocked_vim_health)

    it("works with an empty configuration", function()
        health.check({})
        health.check()

        assert.same({}, mock_vim.get_vim_health_errors())
    end)

    it("reports whether this Neovim can run `motion` at full fidelity", function()
        health.check({})

        local oks = mock_vim.get_vim_health_oks()
        local warnings = mock_vim.get_vim_health_warnings()

        if vim.fn.has("nvim-0.11") == 1 then
            assert.same(0, #warnings)
            assert.is_true(vim.tbl_contains(oks, function(message)
                return message:find("include_anonymous", 1, true) ~= nil
            end, { predicate = true }))
        else
            assert.is_true(vim.tbl_contains(warnings, function(message)
                return message:find("include_anonymous", 1, true) ~= nil
            end, { predicate = true }))
        end
    end)

    it("doesn't warn about the shipped #commands.motion.subword.comment_markers defaults", function()
        -- The defaults (`c`, `cpp`, `rust`, `python`, ...) cover languages most
        -- users won't have every parser for -- see `_check_comment_markers`'s
        -- docstring in `health.lua` for why warning about those would be noise.
        health.check({})
        health.check()

        assert.same({}, mock_vim.get_vim_health_warnings())
    end)

    it(
        "doesn't warn about a user #commands.motion.subword.comment_markers language with an installed parser",
        function()
            health.check({ commands = { motion = { subword = { comment_markers = { lua = { "#" } } } } } })

            assert.same({}, mock_vim.get_vim_health_warnings())
        end
    )

    it("warns about a user #commands.motion.subword.comment_markers language with no installed parser", function()
        health.check({
            commands = { motion = { subword = { comment_markers = { not_a_real_language = { "#" } } } } },
        })

        assert.same({
            'No treesitter parser named "not_a_real_language" is installed, '
                .. "so `comment_markers.not_a_real_language` has no effect until one is.",
        }, mock_vim.get_vim_health_warnings())
    end)

    it("shows all issues at once", function()
        health.check({
            commands = {
                goodnight_moon = { read = { phrase = 123 } },
                hello_world = { say = { ["repeat"] = "aaa", style = 789 } },
            },
            hints = "diagonal",
            logging = {
                level = false,
                use_console = "aaa",
                use_file = "fdas",
            },
        })

        local found = mock_vim.get_vim_health_errors()

        assert.same({
            "commands.goodnight_moon.read.phrase: expected string, got number",
            "commands.hello_world.say.repeat: expected a number (value must be 1-or-more), got aaa",
            'commands.hello_world.say.style: expected "lowercase" or "uppercase", got 789',
            'hints: expected "word_boundaries" or "motions" or "none", got diagonal',
            "logging.level: expected an enum. "
                .. 'e.g. "trace" | "debug" | "info" | "warning" | "error" | "fatal", got false',
            "logging.use_console: expected a boolean, got aaa",
            "logging.use_file: expected a boolean, got fdas",
        }, found)
    end)
end)
---@diagnostic enable: assign-type-mismatch
