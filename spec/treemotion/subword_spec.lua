--- Direct tests for `_commands.motion.subword`, called with explicit
--- `treemotion.SplitSettings` instead of going through the global
--- configuration.
---
--- The fixture text is `local fooBar_bazQux = 1`; its identifier leaf
--- `fooBar_bazQux` starts at 0-indexed column 6.

local configuration = require("treemotion._core.configuration")
local settings_ = require("treemotion._commands.motion.settings")
local subword = require("treemotion._commands.motion.subword")

---@type integer?
local _BUFFER

local function _initialize_buffer()
    _BUFFER = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(_BUFFER, 0, -1, false, { "local fooBar_bazQux = 1" })
    vim.api.nvim_set_current_buf(_BUFFER)
    vim.treesitter.start(_BUFFER, "lua")
end

local function _remove_buffer()
    if _BUFFER and vim.api.nvim_buf_is_valid(_BUFFER) then
        vim.api.nvim_buf_delete(_BUFFER, { force = true })
    end

    _BUFFER = nil
end

---@param column integer A 0-indexed column, on line 1.
---@return TSNode
local function _leaf_at(column)
    local root = vim.treesitter.get_parser(_BUFFER):parse()[1]:root()

    return assert(root:descendant_for_range(0, column, 0, column + 1))
end

--- Build subword rules with every option at its most permissive "off" value.
---
---@param overrides treemotion.ConfigurationMotionSubwordRules?
---@return treemotion.ConfigurationMotionSubwordRules
local function _rules(overrides)
    return vim.tbl_extend("force", {
        camel_case = false,
        pascal_case = false,
        kebab_case = "none",
        snake_case = "none",
        colon_case = "none",
        slash_case = "none",
        comment_marker_case = "none",
        opaque_token_min_length = 20,
    }, overrides or {})
end

--- Build explicit settings, without reading the configuration.
---
---@param overrides table?
---@return treemotion.SplitSettings
local function _settings(overrides)
    return vim.tbl_extend("force", {
        enabled = true,
        backtick_identifiers = true,
        code = _rules(),
        prose = _rules(),
        comment_marker_characters = {},
        insignificant_characters = nil,
    }, overrides or {})
end

--- Each unit's 0-indexed start column.
---
---@param units treemotion.SubwordUnit[]
---@return integer[]
local function _starts(units)
    return vim.tbl_map(function(unit)
        local _, column = unit:start()

        return column
    end, units)
end

describe("subword.split with explicit settings", function()
    before_each(_initialize_buffer)
    after_each(_remove_buffer)

    it("keeps the leaf whole when every rule is off", function()
        assert.same({ 6 }, _starts(subword.split(_leaf_at(6), _settings())))
    end)

    it("splits on camelCase and snake_case as the given rules say", function()
        local settings = _settings({ code = _rules({ camel_case = true, pascal_case = true, snake_case = "skip" }) })

        assert.same({ 6, 9, 13, 16 }, _starts(subword.split(_leaf_at(6), settings)))
    end)

    it("stops on the snake_case delimiter when told to", function()
        local settings = _settings({ code = _rules({ snake_case = "stop" }) })

        assert.same({ 6, 12, 13 }, _starts(subword.split(_leaf_at(6), settings)))
    end)

    it("drops a leaf listed in insignificant_characters", function()
        local settings = _settings({ insignificant_characters = { "=" } })

        assert.same({}, subword.split(_leaf_at(20), settings))
    end)

    it("does not change the global configuration", function()
        local before = vim.deepcopy(configuration.resolve_data())

        subword.split(_leaf_at(6), _settings({ code = _rules({ snake_case = "stop" }) }))

        assert.same(before, configuration.resolve_data())
    end)
end)

describe("subword.split_run with explicit settings", function()
    before_each(_initialize_buffer)
    after_each(_remove_buffer)

    it("returns the whole run when splitting is disabled", function()
        local node = _leaf_at(6)
        local settings = _settings({ enabled = false, code = _rules({ camel_case = true }) })

        assert.same({ 6 }, _starts(subword.split_run(node, node, settings)))
    end)

    it("splits the run with the given rules when enabled", function()
        local node = _leaf_at(6)
        local settings = _settings({ code = _rules({ camel_case = true, pascal_case = true }) })

        assert.same({ 6, 9, 16 }, _starts(subword.split_run(node, node, settings)))
    end)
end)

describe("settings.resolve", function()
    before_each(_initialize_buffer)
    after_each(_remove_buffer)

    it("reads the group's rules and the current language's comment markers", function()
        local small = assert(configuration.resolve_data().commands.motion.small)
        local resolved = settings_.resolve("small")

        assert.equal(small.code, resolved.code)
        assert.equal(small.prose, resolved.prose)
        assert.same({ ["-"] = true }, resolved.comment_marker_characters)
    end)

    it("reads big.enabled", function()
        assert.same(configuration.resolve_data().commands.motion.big.enabled, settings_.resolve("big").enabled)
    end)
end)
