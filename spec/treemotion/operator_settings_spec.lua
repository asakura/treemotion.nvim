--- Make sure `_commands.motion.settings.resolve_operator` reads the
--- configuration and the pending operator correctly.
---
--- `resolve_operator` checks the mode, `v:operator` and `'cpoptions'`, so
--- each test types an operator followed by a mapping that records what it
--- returns, rather than faking the editor state. The mapping doesn't move
--- the cursor, so the operator itself acts on nothing.

local configuration = require("treemotion._core.configuration")
local grammar_helpers = require("treemotion.grammar_helpers")
local settings = require("treemotion._commands.motion.settings")
local treemotion = require("treemotion")

--- The key that records `resolve_operator`'s result. `Q` is otherwise unused in these buffers.
local _KEY = "Q"

---@type integer?
local _BUFFER

--- Apply `operator_pending` on top of the defaults.
---
---@param operator_pending table
local function _configure(operator_pending)
    treemotion.setup({ commands = { motion = { operator_pending = operator_pending } } })
end

--- Type `keys` followed by the recording mapping, and return what `resolve_operator` gave it.
---
---@param keys string The operator (and any forced motion type), e.g. `"d"` or `"dv"`.
---@return treemotion.OperatorSettings?
local function _resolve_during(keys)
    _BUFFER = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(_BUFFER, 0, -1, false, { "foo bar" })
    vim.api.nvim_set_current_buf(_BUFFER)
    grammar_helpers.set_cursor(0, 0)

    local called = false
    ---@type treemotion.OperatorSettings?
    local result

    vim.keymap.set("o", _KEY, function()
        called = true
        result = settings.resolve_operator()
    end, { buffer = _BUFFER })

    vim.api.nvim_feedkeys(vim.keycode(keys .. _KEY), "xt", false)
    vim.cmd("stopinsert")

    assert.is_true(called, "the operator-pending mapping never ran")

    return result
end

describe("settings.resolve_operator", function()
    ---@type treemotion.ResolvedConfiguration
    local original

    before_each(function()
        original = configuration.resolve_data()
    end)

    after_each(function()
        -- Restore the snapshot, as `configuration_spec.lua` does: every
        -- change replaces `configuration.DATA` rather than editing it, so
        -- the saved table is still the original.
        configuration.DATA = original

        grammar_helpers.remove_buffer(_BUFFER)
        _BUFFER = nil
    end)

    it("is nil while disabled (the default)", function()
        assert.is_nil(_resolve_during("d"))
    end)

    it("is nil outside operator-pending mode", function()
        _configure({ enabled = true })

        assert.is_nil(settings.resolve_operator())
    end)

    it("is nil for a forced motion type", function()
        _configure({ enabled = true })

        assert.is_nil(_resolve_during("dv"))
        assert.is_nil(_resolve_during("dV"))
        assert.is_nil(_resolve_during("d<C-v>"))
    end)

    it("copies the configuration for #d", function()
        _configure({
            enabled = true,
            skipped_text = "keep",
            stop_at_line_end = false,
            inclusive = false,
            change_to_end = true,
        })

        assert.same({
            skipped_text = "keep",
            stop_at_line_end = false,
            inclusive = false,
            change = false,
            change_to_end = false,
        }, _resolve_during("d"))
    end)

    it("sets #change and #change_to_end for #c", function()
        _configure({ enabled = true, change_to_end = true })
        local cpoptions = vim.o.cpoptions
        vim.o.cpoptions = cpoptions:find("_", 1, true) and cpoptions or cpoptions .. "_"

        local ok, result = pcall(_resolve_during, "c")
        vim.o.cpoptions = cpoptions

        assert.is_true(ok, result)
        ---@cast result treemotion.OperatorSettings
        assert.is_true(result.change)
        assert.is_true(result.change_to_end)
    end)

    it("leaves #change_to_end off for #c without _ in 'cpoptions'", function()
        _configure({ enabled = true, change_to_end = true })
        local cpoptions = vim.o.cpoptions
        vim.o.cpoptions = cpoptions:gsub("_", "")

        local ok, result = pcall(_resolve_during, "c")
        vim.o.cpoptions = cpoptions

        assert.is_true(ok, result)
        ---@cast result treemotion.OperatorSettings
        assert.is_true(result.change)
        assert.is_false(result.change_to_end)
    end)

    it("leaves #change_to_end off for #c when it's disabled", function()
        _configure({ enabled = true, change_to_end = false })

        local result = _resolve_during("c")

        ---@cast result treemotion.OperatorSettings
        assert.is_true(result.change)
        assert.is_false(result.change_to_end)
    end)

    it("leaves #change off for #y", function()
        _configure({ enabled = true, change_to_end = true })

        local result = _resolve_during("y")

        ---@cast result treemotion.OperatorSettings
        assert.is_false(result.change)
        assert.is_false(result.change_to_end)
    end)
end)
