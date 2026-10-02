--- `comment_marker_case` behaves the same whether the marker is its own leaf
--- (Lua's `--`) or part of a single comment leaf (C, Vim, query).
---
--- Fixtures cover the default languages and a slice of the optional ones;
--- a fixture whose parser is missing is pending. Highlight queries for
--- non-bundled grammars aren't installed, so those fixtures set
--- `comment_node`, and `grammar.wrap` adds a `(comment_node) @spell` query.
---
--- `r`, `haskell` and `matlab` don't fit the two-line shape (their parsers
--- merge or drop consecutive comments) and are left out.

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

---@type {filetype: string, marker: string, lines: string[], comment_node: string?}[]
local _FIXTURES = {
    -- Neovim's own bundled queries cover these, so no `comment_node` override.
    { filetype = "lua", marker = "--", lines = { "-- foo", "-- bar" } },
    { filetype = "c", marker = "//", lines = { "// foo", "// bar" } },
    { filetype = "vim", marker = '"', lines = { '" foo', '" bar' } },
    { filetype = "query", marker = ";", lines = { "; foo", "; bar" } },

    -- The remaining default languages. `sh`/`tex` use the `bash`/`latex` parsers.
    { filetype = "cpp", marker = "//", comment_node = "comment", lines = { "// foo", "// bar" } },
    { filetype = "rust", marker = "//", comment_node = "line_comment", lines = { "// foo", "// bar" } },
    { filetype = "python", marker = "#", comment_node = "comment", lines = { "# foo", "# bar" } },
    { filetype = "bash", marker = "#", comment_node = "comment", lines = { "# foo", "# bar" } },
    { filetype = "latex", marker = "%", comment_node = "line_comment", lines = { "% foo", "% bar" } },

    -- A slice of `_OPTIONAL_COMMENT_MARKERS`.
    -- "#"
    { filetype = "toml", marker = "#", comment_node = "comment", lines = { "# foo", "# bar" } },
    { filetype = "yaml", marker = "#", comment_node = "comment", lines = { "# foo", "# bar" } },
    { filetype = "ruby", marker = "#", comment_node = "comment", lines = { "# foo", "# bar" } },
    { filetype = "fish", marker = "#", comment_node = "comment", lines = { "# foo", "# bar" } },
    { filetype = "nim", marker = "#", comment_node = "comment", lines = { "# foo", "# bar" } },
    { filetype = "make", marker = "#", comment_node = "comment", lines = { "# foo", "# bar" } },
    { filetype = "cmake", marker = "#", comment_node = "line_comment", lines = { "# foo", "# bar" } },
    { filetype = "dockerfile", marker = "#", comment_node = "comment", lines = { "# foo", "# bar" } },
    { filetype = "julia", marker = "#", comment_node = "line_comment", lines = { "# foo", "# bar" } },
    { filetype = "perl", marker = "#", comment_node = "comment", lines = { "# foo", "# bar" } },
    { filetype = "nix", marker = "#", comment_node = "comment", lines = { "# foo", "# bar" } },
    { filetype = "zsh", marker = "#", comment_node = "comment", lines = { "# foo", "# bar" } },
    -- "#" + ";" (only ";" tested here)
    { filetype = "ini", marker = ";", comment_node = "comment", lines = { "; foo", "; bar" } },
    -- "#" + "!"
    { filetype = "properties", marker = "#", comment_node = "comment", lines = { "# foo", "# bar" } },
    -- "#" + "/" (only "#" tested here)
    { filetype = "hcl", marker = "#", comment_node = "comment", lines = { "# foo", "# bar" } },
    { filetype = "terraform", marker = "#", comment_node = "comment", lines = { "# foo", "# bar" } },
    -- "/" (matches "//")
    { filetype = "java", marker = "//", comment_node = "line_comment", lines = { "// foo", "// bar" } },
    { filetype = "javascript", marker = "//", comment_node = "comment", lines = { "// foo", "// bar" } },
    { filetype = "typescript", marker = "//", comment_node = "comment", lines = { "// foo", "// bar" } },
    { filetype = "go", marker = "//", comment_node = "comment", lines = { "// foo", "// bar" } },
    { filetype = "kotlin", marker = "//", comment_node = "line_comment", lines = { "// foo", "// bar" } },
    { filetype = "swift", marker = "//", comment_node = "comment", lines = { "// foo", "// bar" } },
    { filetype = "zig", marker = "//", comment_node = "comment", lines = { "// foo", "// bar" } },
    { filetype = "scss", marker = "//", comment_node = "single_line_comment", lines = { "// foo", "// bar" } },
    { filetype = "proto", marker = "//", comment_node = "comment", lines = { "// foo", "// bar" } },
    -- "-" (matches "--")
    { filetype = "elm", marker = "--", comment_node = "line_comment", lines = { "-- foo", "-- bar" } },
    { filetype = "sql", marker = "--", comment_node = "comment", lines = { "-- foo", "-- bar" } },
    { filetype = "luau", marker = "--", comment_node = "comment", lines = { "-- foo", "-- bar" } },
    -- ";"
    { filetype = "scheme", marker = ";", comment_node = "comment", lines = { "; foo", "; bar" } },
    { filetype = "commonlisp", marker = ";", comment_node = "comment", lines = { "; foo", "; bar" } },
    { filetype = "fennel", marker = ";", comment_node = "comment", lines = { "; foo", "; bar" } },
    { filetype = "asm", marker = ";", comment_node = "line_comment", lines = { "; foo", "; bar" } },
    -- "%"
    { filetype = "erlang", marker = "%", comment_node = "comment", lines = { "% foo", "% bar" } },
}

describe("motion API - comment_marker_case, across grammars", function()
    after_each(function()
        treemotion.setup({
            commands = { motion = { small = { prose = { comment_marker_case = "stop" } } } },
        })
    end)

    for _, fixture in ipairs(_FIXTURES) do
        -- `foo`'s column: after the marker and one space.
        local foo_column = #fixture.marker + 1

        _it_per_grammar(
            fixture,
            string.format('lands on `%s` as its own stop by default ("stop")', fixture.marker),
            function()
                grammar.set_cursor(0, 0)

                local expected = { { 0, foo_column }, { 1, 0 }, { 1, foo_column } }
                for _, position in ipairs(expected) do
                    treemotion.run_motion_w()
                    assert.same(position, { grammar.get_cursor() })
                end
            end
        )

        _it_per_grammar(
            fixture,
            string.format('jumps straight past `%s` on every line when "skip"', fixture.marker),
            function()
                treemotion.setup({
                    commands = { motion = { small = { prose = { comment_marker_case = "skip" } } } },
                })

                -- From `foo`, straight to `bar` on the next line -- never
                -- stopping on line 2's marker, matching the regression this
                -- whole file exists to generalize (see the module docstring).
                grammar.set_cursor(0, foo_column)
                treemotion.run_motion_w()
                assert.same({ 1, foo_column }, { grammar.get_cursor() })

                treemotion.run_motion_b()
                assert.same({ 0, foo_column }, { grammar.get_cursor() })
            end
        )
    end
end)
