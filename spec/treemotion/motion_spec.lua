--- Make sure the treesitter `w`/`e`/`b`/`ge`/`W`/`E`/`B`/`gE` motions work.
---
--- The fixture text is `foo.bar(1, 2)`, whose leaves are
--- `foo . bar ( 1 , 2 )` (0-indexed start columns 0, 3, 4, 7, 8, 9, 11, 12).
--- The space before `2` is the only gap, so it splits the leaves into
--- exactly two "WORD" runs: `foo.bar(1,` (columns 0-10) and `2)` (columns
--- 11-13) -- that boundary is what every `W`/`E`/`B`/`gE` test below exists
--- to exercise, since it's the one place `word` and `WORD` motions disagree.

local treemotion = require("treemotion")

---@type integer?
local _BUFFER

--- Make a scratch buffer with `foo.bar(1, 2)` in it and attach the Lua parser.
local function _initialize_buffer()
    _BUFFER = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(_BUFFER, 0, -1, false, { "foo.bar(1, 2)" })
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
local function _set_cursor(column)
    vim.api.nvim_win_set_cursor(0, { 1, column })
end

---@return integer # The cursor's current 0-indexed column, on line 1.
local function _get_cursor_column()
    return vim.api.nvim_win_get_cursor(0)[2]
end

describe("motion API - word (leaf) motions", function()
    before_each(_initialize_buffer)
    after_each(_remove_buffer)

    it("#w moves to the start of each next leaf", function()
        _set_cursor(0)

        local expected = { 3, 4, 7, 8, 9, 11, 12, 12 }

        for _, column in ipairs(expected) do
            treemotion.run_motion_w()
            assert.same(column, _get_cursor_column())
        end
    end)

    it("#w with a count moves over multiple leaves at once", function()
        _set_cursor(0)

        treemotion.run_motion_w(3)

        assert.same(7, _get_cursor_column())
    end)

    it("#b moves to the start of each previous leaf", function()
        _set_cursor(12)

        local expected = { 11, 9, 8, 7, 4, 3, 0, 0 }

        for _, column in ipairs(expected) do
            treemotion.run_motion_b()
            assert.same(column, _get_cursor_column())
        end
    end)

    it("#e moves to the end of the current, then each next, leaf", function()
        _set_cursor(0)

        local expected = { 2, 3, 6, 7, 8, 9, 11, 12 }

        for _, column in ipairs(expected) do
            treemotion.run_motion_e()
            assert.same(column, _get_cursor_column())
        end
    end)

    it("#ge moves to the end of each previous leaf", function()
        _set_cursor(12)

        local expected = { 11, 9, 8, 7, 6, 3, 2, 2 }

        for _, column in ipairs(expected) do
            treemotion.run_motion_ge()
            assert.same(column, _get_cursor_column())
        end
    end)
end)

describe("motion API - WORD (contiguous run) motions", function()
    before_each(_initialize_buffer)
    after_each(_remove_buffer)

    it("#W jumps over an entire run, not leaf-by-leaf", function()
        _set_cursor(0)

        treemotion.run_motion_W()
        assert.same(11, _get_cursor_column())

        treemotion.run_motion_W()
        assert.same(11, _get_cursor_column()) -- no run after the last one
    end)

    it("#b moves leaf-by-leaf where #B moves run-by-run", function()
        _set_cursor(12)

        treemotion.run_motion_B()
        assert.same(11, _get_cursor_column()) -- to the start of the current run

        treemotion.run_motion_B()
        assert.same(0, _get_cursor_column()) -- to the start of the previous run
    end)

    it("#E jumps to the end of the current, then next, run", function()
        _set_cursor(0)

        treemotion.run_motion_E()
        assert.same(9, _get_cursor_column())

        treemotion.run_motion_E()
        assert.same(12, _get_cursor_column())
    end)

    it("#gE jumps to the end of the previous run, skipping leaves inside it", function()
        _set_cursor(12)

        treemotion.run_motion_gE()
        assert.same(9, _get_cursor_column()) -- end of the previous run

        treemotion.run_motion_gE()
        assert.same(9, _get_cursor_column()) -- no run before the first one
    end)
end)

--- Make a scratch buffer with `local fooBar_bazQux = "kebab-word"` in it.
---
--- Its leaves are `local fooBar_bazQux = " kebab-word "` (the `"` are
--- separate leaves), whose sub-words -- with every `subword` option at its
--- default of `true` -- are `local`, `foo`, `Bar`, `baz`, `Qux`, `=`, `"`,
--- `kebab`, `word`, `"` (0-indexed start columns 0, 6, 9, 13, 16, 20, 22,
--- 23, 29, 33). The `_` (column 12) and `-` (column 28) are gaps: dropped
--- delimiters that no unit lands on.
local function _initialize_subword_buffer()
    _BUFFER = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(_BUFFER, 0, -1, false, { [[local fooBar_bazQux = "kebab-word"]] })
    vim.api.nvim_set_current_buf(_BUFFER)
    vim.treesitter.start(_BUFFER, "lua")
end

describe("motion API - subword (naming convention) motions", function()
    before_each(_initialize_subword_buffer)
    after_each(_remove_buffer)

    it("#w steps through camelCase/snake_case/kebab-case sub-words, skipping `_`/`-`", function()
        _set_cursor(0)

        local expected = { 6, 9, 13, 16, 20, 22, 23, 29, 33, 33 }

        for _, column in ipairs(expected) do
            treemotion.run_motion_w()
            assert.same(column, _get_cursor_column())
        end
    end)

    it("#b steps backward through the same sub-words", function()
        _set_cursor(33)

        local expected = { 29, 23, 22, 20, 16, 13, 9, 6, 0, 0 }

        for _, column in ipairs(expected) do
            treemotion.run_motion_b()
            assert.same(column, _get_cursor_column())
        end
    end)

    it("#e moves to the end of the current, then each next, sub-word", function()
        _set_cursor(0)

        local expected = { 4, 8, 11, 15, 18, 20, 22, 27, 32, 33 }

        for _, column in ipairs(expected) do
            treemotion.run_motion_e()
            assert.same(column, _get_cursor_column())
        end
    end)

    it("#ge moves to the end of each previous sub-word, unconditionally", function()
        _set_cursor(33)

        local expected = { 32, 27, 22, 20, 18, 15, 11, 8, 4, 4 }

        for _, column in ipairs(expected) do
            treemotion.run_motion_ge()
            assert.same(column, _get_cursor_column())
        end
    end)
end)

--- Make a scratch buffer with a Lua comment in it.
---
--- `-- fooBar hello-world snake_case done` parses as `comment`, split into
--- the `--` leaf and one `comment_content` leaf spanning everything after
--- it (`" fooBar hello-world snake_case done"`). The `(comment) @spell`
--- highlight query (`:help treesitter-highlight-spell`) matches the whole
--- `comment` node's range, so *both* leaves count as prose -- including
--- `--` itself, whose two `-` characters form one run and become a single
--- stop under prose's default `comment_marker_case = "stop"` (a bare `-`
--- run with no identifier beside it, so `comment_marker_case` governs it,
--- not `kebab_case` -- see `_split_delimiters`; a run of consecutive
--- same-mode delimiter characters is always one unit, however long, the
--- same way real Vim's `w` treats a run of same-class punctuation as one
--- word). `comment_content` then splits into words on whitespace --
--- `fooBar`, `hello-world`, `snake_case`, `done` -- and
--- `commands.motion.subword.prose`'s rules apply to each: `fooBar` still
--- splits into `foo`/`Bar` (camelCase is on), `hello-world` splits into
--- `hello`/`-`/`world` (`kebab_case = "stop"`, a lone `-` is still its own
--- one-character run), and `snake_case` stays whole (`snake_case` defaults
--- to `"none"` in prose, unlike code's `"skip"`). Sub-word start columns,
--- in order: `--`=0, `foo`=3, `Bar`=6, `hello`=10, `-`=15, `world`=16,
--- `snake_case`=22, `done`=33.
local function _initialize_prose_buffer()
    _BUFFER = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(_BUFFER, 0, -1, false, { "-- fooBar hello-world snake_case done" })
    vim.api.nvim_set_current_buf(_BUFFER)
    vim.treesitter.start(_BUFFER, "lua")
end

describe("motion API - subword (prose) motions", function()
    before_each(_initialize_prose_buffer)
    after_each(_remove_buffer)

    it("#e splits prose into words first, then layers camelCase/kebab_case/snake_case on each word", function()
        _set_cursor(0)

        -- Cursor starts at `-`(0-1)'s own land (0), so `e` treats it as
        -- already-there and the first press absorbs both `-` units at once.
        -- `-`, `foo`, `Bar`, `hello`, `-`, `world`, `snake_case`, `done`, `done` (no more leaves).
        local expected = { 1, 5, 8, 14, 15, 20, 31, 36, 36 }

        for _, column in ipairs(expected) do
            treemotion.run_motion_e()
            assert.same(column, _get_cursor_column())
        end
    end)

    it("#w steps forward through the same prose units", function()
        _set_cursor(0)

        -- `--`(start), `foo`, `Bar`, `hello`, `-`, `world`, `snake_case`, `done`, `done` (no more units).
        local expected = { 3, 6, 10, 15, 16, 22, 33, 33, 33 }

        for _, column in ipairs(expected) do
            treemotion.run_motion_w()
            assert.same(column, _get_cursor_column())
        end
    end)

    it("#b steps backward through the same prose units", function()
        _set_cursor(33) -- the start of `done`

        -- `snake_case`, `world`, `-`, `hello`, `Bar`, `foo`, `--`(start), `--`(start), `--`(start) (no more units).
        local expected = { 22, 16, 15, 10, 6, 3, 0, 0, 0 }

        for _, column in ipairs(expected) do
            treemotion.run_motion_b()
            assert.same(column, _get_cursor_column())
        end
    end)

    it("#E ignores prose splitting entirely, treating the whole comment as one WORD run", function()
        _set_cursor(0)

        treemotion.run_motion_E()
        assert.same(36, _get_cursor_column()) -- straight to the end of `done`, no internal stops
    end)

    it("#w lands once on a whole run of delimiters, however long, not once per character", function()
        -- `------` (0-6) is a run of six same-mode (`comment_marker_case =
        -- "stop"` -- a bare `-` run, no identifier beside it) delimiter
        -- characters -- one unit, not six, matching real Vim's `w` treating
        -- a run of same-class punctuation as a single word.
        vim.api.nvim_buf_set_lines(assert(_BUFFER), 0, -1, false, { "-- ------ hi" })

        _set_cursor(0)
        treemotion.run_motion_w()
        assert.same(3, _get_cursor_column()) -- `--` -> straight to `------`, not `-` x6

        treemotion.run_motion_w()
        assert.same(10, _get_cursor_column()) -- `------` -> `hi`, in one press
    end)

    it("#w doesn't stop on a delimiter run split across a leaf boundary", function()
        -- `---` parses as the `--` leaf (0-2) plus `comment_content` = `"-
        -- lua"` (2-...) -- tree-sitter-lua's comment opener is a fixed
        -- 2-character `--` literal no matter how many dashes follow, so the
        -- third dash ends up as `comment_content`'s leading character
        -- instead of staying part of the same `-` run as its two siblings.
        -- Without `_leading_continuation_length`'s fix, that stray dash
        -- would read as its own 1-character stop; real Vim's `w` would
        -- never produce that, since a run of same-class punctuation is one
        -- word no matter how a grammar happened to tokenize it.
        vim.api.nvim_buf_set_lines(assert(_BUFFER), 0, -1, false, { "--- lua comment" })

        _set_cursor(0)
        treemotion.run_motion_w()
        assert.same(4, _get_cursor_column()) -- `---` -> straight to `lua`, not the stray 3rd `-`

        treemotion.run_motion_w()
        assert.same(8, _get_cursor_column()) -- `lua` -> `comment`
    end)

    it("#b doesn't stop on a delimiter run split across a leaf boundary, mirrored", function()
        vim.api.nvim_buf_set_lines(assert(_BUFFER), 0, -1, false, { "--- lua comment" })

        _set_cursor(8) -- the start of `comment`
        treemotion.run_motion_b()
        assert.same(4, _get_cursor_column()) -- `comment` -> `lua`

        treemotion.run_motion_b()
        assert.same(0, _get_cursor_column()) -- `lua` -> straight to `---`(start), not the stray 3rd `-`
    end)
end)

describe("motion API - subword unit fallback", function()
    before_each(function()
        _BUFFER = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(_BUFFER)
        vim.treesitter.start(_BUFFER, "lua")
    end)
    after_each(_remove_buffer)

    it("treats a leaf that's entirely a dropped delimiter (`_`) as one whole unit, not zero units", function()
        -- `local` (0-5), `_` (6), `=` (8), `1` (10). `_` alone, with the
        -- default `code.snake_case = "skip"`, has nothing left after
        -- `_split_delimiters` drops it -- exercising `M.split`'s
        -- `#units == 0` fallback.
        vim.api.nvim_buf_set_lines(assert(_BUFFER), 0, -1, false, { "local _ = 1" })

        _set_cursor(6) -- the start of `_`
        treemotion.run_motion_w()
        assert.same(8, _get_cursor_column()) -- straight to `=`, not stuck or errored on `_`

        _set_cursor(8) -- the start of `=`
        treemotion.run_motion_b()
        assert.same(6, _get_cursor_column()) -- back to the start of `_`'s fallback unit, precisely
    end)

    it("treats an all-blank prose leaf as one whole unit spanning its full range", function()
        -- `--` (0-2), `comment_content` = `"   "`, three spaces (2-5), all
        -- blank -- `_split_prose_words` finds no words at all, exercising
        -- `M.split`'s `#units == 0` fallback for prose specifically.
        vim.api.nvim_buf_set_lines(assert(_BUFFER), 0, -1, false, { "--   " })

        _set_cursor(2) -- the start of the blank `comment_content`
        treemotion.run_motion_e()
        assert.same(4, _get_cursor_column()) -- the fallback spans all 3 spaces, not zero-width
    end)
end)

--- A blank line has no treesitter node of its own, so `get_node()` at
--- `(1, 0)` doesn't land on a leaf -- it lands on the whole-buffer `chunk`
--- (the smallest node whose range still covers the blank line), which has
--- children and no useful next/previous sibling of its own. Without
--- specifically handling that, every motion run from a blank line does
--- nothing at all, since the traversal has nowhere to climb to. Leaf
--- columns, both lines: `local`=0, `a`/`b`=6, `=`=8, `1`/`2`=10.
local function _initialize_blank_line_buffer()
    _BUFFER = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(_BUFFER, 0, -1, false, { "local a = 1", "", "local b = 2" })
    vim.api.nvim_set_current_buf(_BUFFER)
    vim.treesitter.start(_BUFFER, "lua")
end

---@param row integer 0-indexed row.
---@param column integer 0-indexed column.
local function _set_cursor_at(row, column)
    vim.api.nvim_win_set_cursor(0, { row + 1, column })
end

---@return integer, integer # The cursor's current 0-indexed row and column.
local function _get_cursor()
    local cursor = vim.api.nvim_win_get_cursor(0)

    return cursor[1] - 1, cursor[2]
end

describe("motion API - blank line gaps", function()
    before_each(_initialize_blank_line_buffer)
    after_each(_remove_buffer)

    it("#w advances past a blank line to the very next leaf, without overshooting past it", function()
        _set_cursor_at(1, 0)
        treemotion.run_motion_w()

        local row, column = _get_cursor()
        assert.same({ 2, 0 }, { row, column }) -- `local`, not `a` (an un-guarded unconditional step would overshoot)
    end)

    it("#W does the same at the run level", function()
        _set_cursor_at(1, 0)
        treemotion.run_motion_W()

        local row, column = _get_cursor()
        assert.same({ 2, 0 }, { row, column })
    end)

    it("#e advances past a blank line to the end of the nearest next leaf", function()
        _set_cursor_at(1, 0)
        treemotion.run_motion_e()

        local row, column = _get_cursor()
        assert.same({ 2, 4 }, { row, column }) -- the end of `local`
    end)

    it("#b retreats past a blank line to the start of the nearest previous leaf", function()
        _set_cursor_at(1, 0)
        treemotion.run_motion_b()

        local row, column = _get_cursor()
        assert.same({ 0, 10 }, { row, column }) -- the start of `1`
    end)

    it(
        "#ge retreats past a blank line to the end of the nearest previous leaf, without overshooting past it",
        function()
            _set_cursor_at(1, 0)
            treemotion.run_motion_ge()

            local row, column = _get_cursor()
            assert.same({ 0, 10 }, { row, column }) -- `1`, not `=` (an un-guarded unconditional step would overshoot)
        end
    )

    it("#w does nothing, without erroring, on a blank line with no leaf after it", function()
        vim.api.nvim_buf_set_lines(assert(_BUFFER), 0, -1, false, { "local a = 1", "" })
        _set_cursor_at(1, 0)
        treemotion.run_motion_w()

        local row, column = _get_cursor()
        assert.same({ 1, 0 }, { row, column })
    end)

    it("#b does nothing, without erroring, on a blank line with no leaf before it", function()
        vim.api.nvim_buf_set_lines(assert(_BUFFER), 0, -1, false, { "", "local a = 1" })
        _set_cursor_at(0, 0)
        treemotion.run_motion_b()

        local row, column = _get_cursor()
        assert.same({ 0, 0 }, { row, column })
    end)
end)

describe("motion API - genuinely multi-row leaves", function()
    before_each(function()
        -- `local`(0,0), `x`(0,6), `=`(0,8), `[[`(0,10), `string_content`
        -- (0,12 - 1,3, text `"foo\nbar"`), `]]`(1,3). `string_content` has
        -- no trailing blank characters to trim, so `subword`'s row-collapsing
        -- pass (added for tree-sitter-rust's `doc_comment`, see
        -- `_single_row_span`'s docstring) must leave it alone -- this is the
        -- "genuinely spans more than one row" branch of that same check,
        -- confirming it still falls back to one whole-leaf unit rather than
        -- being mishandled by the new collapsing logic.
        _BUFFER = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(_BUFFER, 0, -1, false, { "local x = [[foo", "bar]]" })
        vim.api.nvim_set_current_buf(_BUFFER)
        vim.treesitter.start(_BUFFER, "lua")
    end)
    after_each(_remove_buffer)

    it("#w lands on the whole multi-row leaf as a single stop, then the leaf after it", function()
        _set_cursor_at(0, 10) -- the start of `[[`

        treemotion.run_motion_w()
        local row, column = _get_cursor()
        assert.same({ 0, 12 }, { row, column }) -- `[[` -> `string_content`'s start, not split at the embedded newline

        treemotion.run_motion_w()
        row, column = _get_cursor()
        assert.same({ 1, 3 }, { row, column }) -- straight to `]]`, skipping over `string_content` in one step
    end)

    it("#b mirrors #w, landing on the multi-row leaf's start from its end", function()
        _set_cursor_at(1, 3) -- the start of `]]`

        treemotion.run_motion_b()
        local row, column = _get_cursor()
        assert.same({ 0, 12 }, { row, column }) -- back to `string_content`'s start, on the first row
    end)
end)

describe("motion API - subword configuration", function()
    before_each(_initialize_subword_buffer)

    after_each(function()
        _remove_buffer()
        treemotion.setup({
            commands = {
                motion = {
                    subword = {
                        code = {
                            camel_case = true,
                            pascal_case = true,
                            kebab_case = "skip",
                            snake_case = "skip",
                            comment_marker_case = "stop",
                        },
                        prose = {
                            camel_case = true,
                            pascal_case = true,
                            kebab_case = "stop",
                            snake_case = "none",
                            comment_marker_case = "stop",
                        },
                    },
                },
            },
        })
    end)

    it('stops splitting on `_` when #code.snake_case is "none", but keeps camelCase splits', function()
        treemotion.setup({ commands = { motion = { subword = { code = { snake_case = "none" } } } } })
        _set_cursor(6) -- the start of `fooBar_bazQux`

        -- `_` no longer splits, but `B`/`Q` still do: `foo`, `Bar_baz`, `Qux`.
        treemotion.run_motion_w()
        assert.same(9, _get_cursor_column())

        treemotion.run_motion_w()
        assert.same(16, _get_cursor_column())
    end)

    it('stops splitting on `-` when #code.kebab_case is "none"', function()
        treemotion.setup({ commands = { motion = { subword = { code = { kebab_case = "none" } } } } })
        _set_cursor(23) -- the start of `kebab-word`'s content

        treemotion.run_motion_e()
        assert.same(32, _get_cursor_column()) -- the whole `kebab-word` is one unit now
    end)

    it('lands on `-` as its own stop when #code.kebab_case is "stop"', function()
        treemotion.setup({ commands = { motion = { subword = { code = { kebab_case = "stop" } } } } })
        _set_cursor(23) -- the start of `kebab-word`'s content

        local expected = { 27, 28, 32 } -- `kebab`, `-`, `word`

        for _, column in ipairs(expected) do
            treemotion.run_motion_e()
            assert.same(column, _get_cursor_column())
        end
    end)

    it('lands on a `#`/`/`/`%` run as its own stop when #prose.comment_marker_case is "stop" (the default)', function()
        -- `--` (0), `comment_content` = `" ### heading text"` (2-...) --
        -- `###` (class "other", per `_char_class`) is its own
        -- `_split_prose_words` word, isolated by the surrounding blanks, so
        -- `comment_marker_case` alone decides whether it's a landing stop.
        vim.api.nvim_buf_set_lines(assert(_BUFFER), 0, -1, false, { "-- ### heading text" })

        _set_cursor(0)

        local expected = { 3, 7, 15, 15 } -- `--`, `###`, `heading`, `text`

        for _, column in ipairs(expected) do
            treemotion.run_motion_w()
            assert.same(column, _get_cursor_column())
        end
    end)

    it('jumps straight past a `#`/`/`/`%` run when #prose.comment_marker_case is "skip"', function()
        treemotion.setup({ commands = { motion = { subword = { prose = { comment_marker_case = "skip" } } } } })
        vim.api.nvim_buf_set_lines(assert(_BUFFER), 0, -1, false, { "-- ### heading text" })

        _set_cursor(0)

        local expected = { 7, 15, 15 } -- `--`, straight to `heading` (`###` is never a stop), `text`

        for _, column in ipairs(expected) do
            treemotion.run_motion_w()
            assert.same(column, _get_cursor_column())
        end
    end)

    it('leaves a `#`/`/`/`%` run merged into its word when #prose.comment_marker_case is "none"', function()
        treemotion.setup({ commands = { motion = { subword = { prose = { comment_marker_case = "none" } } } } })
        -- With no split at all, `###` stays embedded exactly where
        -- `_split_prose_words` already isolated it -- so this looks
        -- identical to `"stop"` here (a lone, whitespace-bounded run has
        -- nothing else to merge with); `"none"` only differs from `"stop"`
        -- for a run mixed into a larger word, e.g. `foo/bar`.
        vim.api.nvim_buf_set_lines(assert(_BUFFER), 0, -1, false, { "-- ### heading text" })

        _set_cursor(0)

        local expected = { 3, 7, 15, 15 } -- `--`, `###`, `heading`, `text`

        for _, column in ipairs(expected) do
            treemotion.run_motion_w()
            assert.same(column, _get_cursor_column())
        end
    end)

    it(
        "a bare `-` run (no identifier beside it) follows #comment_marker_case, " .. "independently of #kebab_case",
        function()
            -- `kebab_case = "skip"` would normally drop a `-` run entirely,
            -- but `--` here has no identifier content beside it, so
            -- `comment_marker_case` (still the default `"stop"`) governs it
            -- instead -- it stays a landing stop even though `kebab_case`
            -- says "skip".
            treemotion.setup({ commands = { motion = { subword = { prose = { kebab_case = "skip" } } } } })
            vim.api.nvim_buf_set_lines(assert(_BUFFER), 0, -1, false, { "-- hello-world" })

            _set_cursor(0)

            -- Cursor starts exactly on `--`(0)'s own stop, so the first
            -- press moves past it: `hello`, `world` (kebab_case="skip"
            -- still drops the embedded `-` itself as a landing spot).
            local expected = { 3, 9, 9 }

            for _, column in ipairs(expected) do
                treemotion.run_motion_w()
                assert.same(column, _get_cursor_column())
            end
        end
    )

    it(
        "a bare `-` run (no identifier beside it) skips under #comment_marker_case "
            .. '= "skip", even while #kebab_case stays "stop"',
        function()
            -- The reverse: `comment_marker_case = "skip"` drops the bare
            -- `--` run entirely, while `kebab_case` (still the default
            -- `"stop"`) keeps splitting `hello-world`'s embedded `-` as its
            -- own stop -- the two settings tune independently even though
            -- both apply to `-`.
            treemotion.setup({ commands = { motion = { subword = { prose = { comment_marker_case = "skip" } } } } })
            vim.api.nvim_buf_set_lines(assert(_BUFFER), 0, -1, false, { "-- hello-world" })

            _set_cursor(0)

            -- `--` is never a stop; `hello`, `-`, `world` (kebab_case="stop").
            local expected = { 3, 8, 9, 9 }

            for _, column in ipairs(expected) do
                treemotion.run_motion_w()
                assert.same(column, _get_cursor_column())
            end
        end
    )

    it("#camel_case and #pascal_case toggle independently by the identifier's leading case", function()
        vim.api.nvim_buf_set_lines(assert(_BUFFER), 0, -1, false, { "local FooBar = fooBar" })

        treemotion.setup({ commands = { motion = { subword = { code = { pascal_case = false } } } } })
        _set_cursor(6) -- the start of `FooBar` (leading uppercase)

        -- `pascal_case` is off, so `FooBar` doesn't split at all.
        treemotion.run_motion_e()
        assert.same(11, _get_cursor_column())

        _set_cursor(15) -- the start of `fooBar` (leading lowercase)

        -- `camel_case` is still on, so `fooBar` still splits into `foo`/`Bar`.
        treemotion.run_motion_e()
        assert.same(17, _get_cursor_column())
    end)

    it('#prose.snake_case can be reconfigured to "stop", landing on `_` inside a comment', function()
        _remove_buffer()
        _initialize_prose_buffer()
        treemotion.setup({ commands = { motion = { subword = { prose = { snake_case = "stop" } } } } })
        _set_cursor(22) -- the start of `snake_case`, inside the comment

        local expected = { 26, 27, 31 } -- `snake`, `_`, `case`

        for _, column in ipairs(expected) do
            treemotion.run_motion_e()
            assert.same(column, _get_cursor_column())
        end
    end)
end)

describe("motion API - no parser", function()
    it("does nothing instead of erroring when the buffer has no treesitter parser", function()
        local buffer = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "plain text" })
        vim.api.nvim_set_current_buf(buffer)
        _set_cursor(0)

        treemotion.run_motion_w()

        assert.same(0, _get_cursor_column())

        vim.api.nvim_buf_delete(buffer, { force = true })
    end)
end)

describe("motion commands", function()
    before_each(_initialize_buffer)
    after_each(_remove_buffer)

    it("runs #w through the :TreeMotion command", function()
        _set_cursor(0)

        vim.cmd([[TreeMotion motion w]])

        assert.same(3, _get_cursor_column())
    end)

    it("runs #w with --count through the :TreeMotion command", function()
        _set_cursor(0)

        vim.cmd([[TreeMotion motion w --count=3]])

        assert.same(7, _get_cursor_column())
    end)

    it("runs #W through the :TreeMotion command", function()
        _set_cursor(0)

        vim.cmd([[TreeMotion motion W]])

        assert.same(11, _get_cursor_column())
    end)

    it("runs #gE through the :TreeMotion command", function()
        _set_cursor(12)

        vim.cmd([[TreeMotion motion gE]])

        assert.same(9, _get_cursor_column())
    end)
end)
