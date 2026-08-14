--- Make sure `commands.motion.small.prose.comment_marker_case` behaves the
--- same way regardless of what a grammar's comment-opener punctuation looks
--- like, or whether that punctuation is its own leaf (Lua's `--`, split from
--- `comment_content`) or embedded in one larger leaf's text alongside the
--- comment body (C/Vim/query, whose `comment` node is a single leaf with no
--- children at all). This is the fix that motivated cross-grammar testing
--- in the first place: `M.split`'s old "no units -> fall back to the whole
--- leaf" rule silently re-added a stop that `comment_marker_case = "skip"`
--- was supposed to remove, but only for grammars/shapes where the marker
--- was its own leaf -- see `subword.lua`'s `M.split` docstring. See
--- `grammar_helpers.lua` for the shared plumbing.
---
--- `_FIXTURES` also aims for broad `comment_markers` language coverage --
--- both the remaining `_DEFAULTS` entries and a representative slice of
--- `_OPTIONAL_COMMENT_MARKERS` (see `configuration.lua`) -- not only the
--- four grammars that originally motivated cross-grammar testing above.
--- `grammar.wrap` turns a fixture for a filetype with no parser installed
--- into a `pending()` test, so adding fixtures here is safe in any
--- environment; the Nix-driven suite's `treesitterAllGrammars` (see
--- `flake.nix`) is what actually makes nearly all of their *parsers*
--- available.
---
--- Parser availability alone isn't enough, though: `comment_marker_case`
--- only fires on `@spell`-tagged ("prose") leaves (see `subword.lua`'s
--- `_is_prose`), and `@spell` comes from a language's own
--- `queries/<lang>/highlights.scm` -- which `treesitterAllGrammars`
--- deliberately does *not* vendor (only compiled `parser/<lang>.so` files;
--- see `flake.nix`'s comment on that binding). Concretely: without a real
--- highlight query, every fixture below other than `lua`/`c`/`vim`/`query`
--- (whose queries ship inside Neovim itself) would silently fall back to
--- "code" leaf handling instead of "prose", producing a *different* stop
--- pattern than these tests assert -- not a skipped/pending test, an
--- actively wrong one that happened to pass locally on a machine with a
--- personal, non-Nix nvim-treesitter install providing those queries by
--- coincidence (that's genuinely how the first version of this file's
--- broader fixture list was validated, and why it was wrong). So each
--- non-bundled fixture below sets `comment_node` to that language's
--- comment node type name (from its parse tree, e.g. `"comment"` or
--- `"line_comment"`), which `grammar.wrap` uses to register a synthetic
--- `(comment_node) @spell` query before starting the parser -- exercising
--- the plugin's real prose-detection code path deterministically, without
--- depending on any real highlight query being present in the environment.
---
--- `r`, `haskell`, and `matlab` are deliberately excluded from
--- `_OPTIONAL_COMMENT_MARKERS`'s slice tested here: even with a synthetic
--- `@spell` query, `r`'s parser doesn't produce a same-line stop before the
--- next line (its `# foo`/`# bar` two-line fixture collapses the first
--- line's stop away entirely), and `haskell`/`matlab` merge two
--- consecutive line-comments into a single parse-tree node instead of two,
--- breaking the row/column assumptions below regardless of `@spell`. None
--- of this reflects on `_OPTIONAL_COMMENT_MARKERS` itself (those three
--- languages' entries there are still correct and still tested via
--- `configuration_spec.lua`'s `get_comment_markers` tests) -- it's purely
--- that these three don't fit this file's generic two-line stop/skip
--- assertion shape.

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

    -- Remaining `_DEFAULTS` languages (`sh`/`tex` skipped -- their
    -- treesitter *language* is actually `bash`/`latex`, already covered
    -- below, since nvim-treesitter maps those filetypes onto the same
    -- parser; see this module's docstring).
    { filetype = "cpp", marker = "//", comment_node = "comment", lines = { "// foo", "// bar" } },
    { filetype = "rust", marker = "//", comment_node = "line_comment", lines = { "// foo", "// bar" } },
    { filetype = "python", marker = "#", comment_node = "comment", lines = { "# foo", "# bar" } },
    { filetype = "bash", marker = "#", comment_node = "comment", lines = { "# foo", "# bar" } },
    { filetype = "latex", marker = "%", comment_node = "line_comment", lines = { "% foo", "% bar" } },

    -- A representative slice of `_OPTIONAL_COMMENT_MARKERS`, grouped the
    -- same way as that table (`r`/`haskell`/`matlab` excluded -- see this
    -- module's docstring).
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
        -- `foo`'s column, on either line: right after the marker and the
        -- space following it. Varies by marker width (1 char for vim's `"`
        -- and query's `;`, 2 for lua's `--` and c's `//`), unlike the
        -- marker's own start (always 0) and the next line's marker (always
        -- row+1, column 0).
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
