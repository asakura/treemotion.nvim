--- Split a treesitter leaf's (`M.split`), or a whole run's (`M.split_run`),
--- text into case-convention-aware sub-word units.
---
--- `M.split` backs `w`/`e`/`b`/`ge` (see `_commands.motion.word`), given
--- `commands.motion.small`'s settings. `M.split_run` backs `W`/`E`/`B`/`gE`
--- (see `_commands.motion.bigword`), given `commands.motion.big`'s -- but
--- only splits once `commands.motion.big.enabled` is `true`; by default it
--- always returns one unit spanning the whole run, ignoring case entirely,
--- the same way real Vim's `W` ignores punctuation inside a WORD.
---
--- Neither reads the configuration itself: both take a
--- `treemotion.SplitSettings`, which `_commands.motion.settings.resolve`
--- builds once per motion.
---
--- This module only orchestrates: it narrows a leaf or run down to the
--- text that's eligible to split, turns offsets back into buffer
--- coordinates, and delegates everything else. No treesitter tree walking
--- happens here -- that's `_commands.motion.leaf`'s and
--- `_commands.motion.word`'s/`_commands.motion.bigword`'s job.
--- `_commands.motion.classify` decides whether a leaf is prose or code (its
--- highlight captures, `:help treesitter-highlight-spell`), whether it's
--- insignificant, and which characters are comment markers in the current
--- language; `_commands.motion.prose`, `.delimiters` and `.case` are the
--- pure string splitters.
---
--- `M.split`/`M.split_run` narrow their input down to eligible text, then
--- both hand off to the shared `_split_text`, which composes up to three
--- passes: `prose.words` runs first, but *only* for prose-tagged text -- it
--- divides prose into individual words the way real Vim's `w` divides a
--- text file (on whitespace and punctuation), since comment/string/run text
--- has no other word boundaries in it at all. Code text skips straight past
--- this pass, treating the whole thing as a single "word". Every resulting
--- word (one, for code) then goes through `delimiters.split` (dividing on
--- `_`/`-`/`:`/`/`) and, unless the chunk looks like an opaque hash/digest
--- (`case.looks_like_hash`), `case.split` (dividing on camelCase/PascalCase
--- boundaries) -- using `.code` or `.prose`'s rules, whichever matched.
--- Each produced `treemotion.SubwordUnit` is just a coordinate range, not a
--- real tree node -- there's no parent/child/sibling structure to a
--- sub-word slice, only a start and an end.
---
--- When `backtick_identifiers` is enabled (the default), prose word-splitting
--- gets one more wrinkle: a backtick-enclosed span that's exactly one Vim
--- word (`` `fooBar` ``, `` `foo-bar` ``, not `` `foo bar` `` or `` `` ``)
--- is pulled out and run through `.code`'s rules instead of `.prose`'s, and
--- the backticks themselves produce no unit at all -- invisible to
--- `w`/`b`/`e`/`ge`, the same way a `"skip"` comment-marker run already is.
--- See `prose.lua`'s `_split_backtick_identifiers`.

local logging = require("mega.logging")

local codepoint = require("treemotion._commands.motion.codepoint")
local case = require("treemotion._commands.motion.case")
local classify = require("treemotion._commands.motion.classify")
local delimiters = require("treemotion._commands.motion.delimiters")
local leaf = require("treemotion._commands.motion.leaf")
local prose = require("treemotion._commands.motion.prose")
local span = require("treemotion._commands.motion.span")

local _LOGGER = logging.get_logger("treemotion._commands.motion.subword")

local M = {}

--- Trim `text`'s trailing blank characters, and find where what's left ends.
---
--- Some grammars bake a trailing terminator into a token's own span instead
--- of stopping right after its real content: tree-sitter-rust's
--- `doc_comment` (everything after `///`) is produced by an external
--- scanner that folds the line's trailing newline into the token itself --
--- confirmed against the real grammar, its range ends at `(next_row, 0)`
--- and its text literally ends in `"\n"`, even though every real character
--- is still on the token's start row. That's not a Rust-only quirk: any
--- grammar whose scanner consumes trailing whitespace/newline(s) as part of
--- a token (commonly done so the scanner can disambiguate that token from
--- whatever follows) produces the same shape, the same way any grammar
--- can split a fixed-width comment-marker literal the way
--- `_leading_continuation_length` below handles. A run (`M.split_run`) can
--- end in one too. Rather than special-casing node types per grammar,
--- callers ask the one question that's actually true generically: after
--- trimming trailing blank characters, is everything that's left still on
--- one row -- i.e. is the returned end row still `start_row`? A span with
--- *real* content on more than one row (e.g. a Lua long string's
--- `string_content`, confirmed to keep its embedded newline even after
--- trimming) fails this check, and is treated as genuinely multi-row.
---
---@param text string The span's full text.
---@param start_row integer `text`'s row in the buffer (0-indexed).
---@param start_col integer `text`'s first column in the buffer (0-indexed).
---@return string, integer, integer # The trimmed text, and the row/column one past its last character.
---
local function _trim_span(text, start_row, start_col)
    local trimmed = text:gsub("%s+$", "")
    local end_row, end_col = span.end_position(start_row, start_col, trimmed)

    return trimmed, end_row, end_col
end

--- How many of `text`'s leading characters continue a punctuation run that
--- started in the character immediately before `node`, on the same line.
---
--- Tokenization is a grammar concern, not a textual one, and this isn't a
--- Lua-only quirk -- e.g. tree-sitter-lua's comment opener is a fixed
--- 2-character `--` literal no matter how many dashes actually follow, so a
--- `---` doc comment's third dash ends up as `comment_content`'s leading
--- character instead of staying part of the same `-` run as its two
--- siblings in the `--` leaf; tree-sitter-rust does the exact same thing
--- one level deeper for `///` outer doc comments, which parse as a `//`
--- leaf, then a *lone* `/` leaf (`outer_doc_comment_marker`), then the
--- `doc_comment` text -- confirmed against the real grammar, not just
--- Lua's. Left alone, that stray leading character would read as a fresh
--- 1-character word/chunk of its own once `M.split` runs on the sibling
--- leaf it landed in -- a landing stop real Vim's `w` would never produce,
--- since a run of same-class punctuation is always one word regardless of
--- how a particular grammar happened to tokenize it. `M.split` strips this
--- many characters off `text` before splitting, so the run's only landing
--- stop stays wherever it started -- in the previous leaf.
---
--- Not restricted to `-`/`_` (the two characters `kebab_case`/`snake_case`
--- know about) -- any non-blank, non-alphanumeric character qualifies,
--- since the same fixed-width-literal-token tokenization can split any
--- punctuation-based comment/doc-comment marker (`#`, `/`, `%`, ...) the
--- same way. Alphanumeric characters are deliberately excluded: an
--- identifier or number split across a leaf boundary is a different,
--- riskier kind of grammar quirk (e.g. a number literal's mantissa and
--- exponent as separate leaves) where blindly merging could swallow a
--- genuinely distinct token instead of a stray delimiter fragment.
---
--- Can return `#text` itself -- tree-sitter-rust's lone `/` leaf (the
--- `outer_doc_comment_marker` mentioned above) is *entirely* consumed this
--- way, not just a prefix of it. `M.split` handles that by producing no
--- units at all for `node` rather than falling back to its full span --
--- see `M.split`'s docstring.
---
--- Works in whole characters throughout, via `_commands.motion.codepoint`,
--- not raw bytes: `char` is `text`'s first full codepoint (not just its
--- first byte), `before` is read from `codepoint.last_character_column`'s
--- lead-byte column rather than a blind `start_col - 1` (which can itself
--- land mid-character, reading a bare continuation byte out of the buffer),
--- and the run-length walk below advances one whole character at a time. No
--- real grammar this plugin has been verified against actually produces a
--- multi-byte comment-marker character, but this keeps the guarantee exact
--- -- `text:sub(continuation + 1, ...)` in `M.split` always lands on a
--- character boundary -- rather than merely "safe in every case tested so far."
---
--- The run-length walk special-cases a 1-byte `char` (an ordinary ASCII
--- marker like `-`/`#`/`/`, the overwhelmingly common case) with a plain
--- byte comparison instead of calling `codepoint.char_width` per character:
--- a 1-byte `char` can only ever match another 1-byte character, so there's
--- no codepoint arithmetic to do, and a long ASCII divider comment
--- shouldn't pay a `vim.str_utf_end` call per dash.
---
---@param node TSNode The leaf `text` came from.
---@param text string `node`'s full text (see `M.split`).
---@return integer # 0 if `text`'s start doesn't continue a punctuation run.
---
local function _leading_continuation_length(node, text)
    if text == "" then
        return 0
    end

    local char_width = codepoint.char_width(text, 1)
    local char = text:sub(1, char_width)

    if char:match("%s") or char:match("%w") then
        return 0
    end

    local start_row, start_col = node:start()

    if start_col == 0 then
        return 0
    end

    local before_col = codepoint.last_character_column(start_row, start_col)
    local before = vim.api.nvim_buf_get_text(0, start_row, before_col, start_row, start_col, {})[1]

    if before ~= char then
        return 0
    end

    local length = 0

    if char_width == 1 then
        local byte = char:byte()

        while length < #text and text:byte(length + 1) == byte do
            length = length + 1
        end
    else
        while length < #text do
            local width = codepoint.char_width(text, length + 1)

            if text:sub(length + 1, length + width) ~= char then
                break
            end

            length = length + width
        end
    end

    return length
end

--- Shared tail of `M.split`/`M.split_run`: `text` -> words -> per-word
--- delimiter/case split -> `treemotion.SubwordUnit[]`.
---
--- For prose (`@spell`- or `@string`-tagged) text only, `prose.words` first
--- divides `text` into individual words; code text is treated as a single
--- word instead, since a normal token never contains embedded blanks. Every
--- word then goes through `delimiters.split` (dividing on `_`/`-`/`:`/`/`)
--- and, unless the resulting chunk looks like an opaque hash/digest (see
--- `case.looks_like_hash`), `case.split` (dividing on camelCase/PascalCase
--- boundaries). A chunk that *does* look like a hash skips `case.split`
--- entirely -- it's one unit no matter its internal case transitions. Two
--- running offsets -- `word.offset` from the outer pass, `delimited.offset`/
--- chunk length from the inner ones -- compose into each unit's offset in
--- `text`, which `span.position_mapper` turns back into buffer coordinates
--- (multi-row prose -- a hard/soft-wrapped markdown paragraph -- included).
---
--- If `text` produces no words at all (e.g. an all-whitespace prose
--- comment), this falls back to `fallback` -- nothing for any delimiter
--- setting to have acted on, so there's nothing to split. One more empty
--- case falls out of `delimiters.split` itself, though, and does *not* get
--- that fallback: text that's *entirely* a `comment_marker_case = "skip"`
--- run has real content -- unlike all-whitespace text -- but every bit of
--- it is a marker `delimiters.split` was told to drop, so `words` is
--- non-empty while the returned units end up empty anyway. That's `"skip"`
--- doing exactly what it says -- forcing a landing stop back in for it
--- would silently override the user's own setting.
---
---@param text string The text to split (already narrowed to what's eligible -- see `M.split`/`M.split_run`).
---@param fallback treemotion.SubwordUnit Starts where `text` does; returned as-is if `text` produces no words.
---@param is_prose boolean Whether to use `settings.prose` or `settings.code`.
---@param settings treemotion.SplitSettings
---@return treemotion.SubwordUnit[]
---
local function _split_text(text, fallback, is_prose, settings)
    local rules = is_prose and settings.prose or settings.code
    local words = is_prose and prose.words(text, settings.backtick_identifiers, rules.opaque_token_min_length)
        or { { text = text, offset = 1 } }

    if #words == 0 then
        return { fallback }
    end

    local start_row, start_col = fallback:start()
    local position = span.position_mapper(start_row, start_col, text)

    --- Build one unit spanning `length` bytes, starting at `offset` (1-indexed into `text`).
    ---
    ---@param offset integer
    ---@param length integer
    ---@return treemotion.SubwordUnit
    local function make_unit(offset, length)
        local unit_start_row, unit_start_col = position(offset)
        local unit_end_row, unit_end_col = position(offset + length)

        return span.new(unit_start_row, unit_start_col, unit_end_row, unit_end_col)
    end

    local units = {}

    for _, word in ipairs(words) do
        local word_rules = word.is_identifier and settings.code or rules

        for _, delimited in ipairs(delimiters.split(word.text, word_rules, settings.comment_marker_characters)) do
            local offset = word.offset + delimited.offset - 1

            if case.looks_like_hash(delimited.text, word_rules.opaque_token_min_length) then
                table.insert(units, make_unit(offset, #delimited.text))
            else
                for _, chunk in ipairs(case.split(delimited.text, word_rules.camel_case, word_rules.pascal_case)) do
                    table.insert(units, make_unit(offset, #chunk))
                    offset = offset + #chunk
                end
            end
        end
    end

    return units
end

--- Wrap `fn` so each call logs how many units it produced, at debug level.
---
---@generic F: function
---@param name string The public function's name, for the log message.
---@param fn F The function doing the actual work, returning `treemotion.SubwordUnit[]`.
---@param describe_args fun(...: any): string Render `fn`'s arguments for the log message.
---@return F # `fn`, plus logging.
---
local function _logged(name, fn, describe_args)
    return function(...)
        local units = fn(...)

        _LOGGER:fmt_debug("%s(%s) -> %s unit(s).", name, describe_args(...), #units)

        return units
    end
end

--- Split `node`'s text into sub-word units, per `settings` (`commands.motion.small`'s).
---
--- Two passes narrow `node` down to the text that's actually eligible to
--- split, before handing off to `_split_text`. `_trim_span` first
--- collapses a multi-row `node` down to one row when the only reason it
--- spans rows is a trailing run of blank characters (tree-sitter-rust's
--- `doc_comment`, see its docstring) -- genuinely multi-row code content (a
--- long string) is left alone and falls back to one whole-leaf unit, same as
--- always. Then `_leading_continuation_length` strips off (and shifts past)
--- any leading characters that are really the tail of the previous leaf's
--- delimiter run -- see its docstring. When that continuation consumes
--- `node` in its entirety (tree-sitter-rust's lone `/` `outer_doc_comment_marker`
--- leaf, for `///` doc comments), `node` has no content of its own left to
--- become a unit, so this returns an empty list instead of the usual
--- whole-leaf fallback -- `_commands.motion.word` treats that as "no stop
--- here", skipping straight to the next/previous leaf, the same way it
--- already skips punctuation runs collapsed into a single stop elsewhere.
---
---@param node TSNode Any leaf (see `_commands.motion.leaf`).
---@param settings treemotion.SplitSettings See `_commands.motion.settings.resolve`.
---@return treemotion.SubwordUnit[] # Empty when `node` is `classify.is_insignificant`,
---    entirely a punctuation-run continuation of the leaf before it, or
---    entirely a dropped (`"skip"`) delimiter run with no other content;
---    otherwise `node`'s full span if nothing else splits it.
---
M.split = _logged("split", function(node, settings)
    if classify.is_insignificant(node, settings.insignificant_characters) then
        return {}
    end

    local start_row, start_col = node:start()
    local end_row, end_col = node:end_()
    local text = vim.treesitter.get_node_text(node, 0)
    local is_prose = classify.is_prose(node)

    if start_row ~= end_row then
        local trimmed, trimmed_end_row, trimmed_end_col = _trim_span(text, start_row, start_col)

        if trimmed_end_row == start_row then
            text, end_row, end_col = trimmed, trimmed_end_row, trimmed_end_col
        elseif not is_prose then
            -- Genuinely multi-row, non-prose content; sub-word splitting
            -- only makes sense within a single line for code-shaped text,
            -- so no real-world code leaf (an identifier, a long string, a
            -- block comment, ...) needs it across lines. Multi-row *prose*
            -- (a hard/soft-wrapped markdown paragraph, e.g.) falls through
            -- to `_split_text` below instead, which is row/column-aware
            -- (see `span.position_mapper`) and splits it word-by-word across
            -- every line it spans, the same as a single-line paragraph
            -- already does.
            return { span.new(start_row, start_col, end_row, end_col) }
        end
    end

    local continuation = _leading_continuation_length(node, text)

    if continuation > 0 and continuation == #text then
        return {}
    end

    local text_start_col = start_col

    if continuation > 0 then
        text = text:sub(continuation + 1)
        text_start_col = start_col + continuation
    end

    return _split_text(text, span.new(start_row, text_start_col, end_row, end_col), is_prose, settings)
end, function(node)
    local row, column = node:start()

    return string.format("%s at %s:%s", node:type(), row, column)
end)

--- Break the run from `start_node` to `end_node` into maximal stretches of
--- leaves that all share the same `classify.is_prose` classification.
---
--- A contiguous run (see `_commands.motion.leaf`'s `is_contiguous`) can mix
--- a code leaf with a prose/string leaf right next to it with no whitespace
--- in between -- e.g. Lua's sugar call syntax `foo"bar"` parses as an
--- `identifier` leaf (code) immediately followed by a `"`/`string_content`/`"`
--- trio (all `@string`-tagged, i.e. prose per `classify.lua`'s `_is_prose_capture`). Splitting
--- the run's text as one undifferentiated blob would apply whichever leaf
--- happens to come first's rules to the whole thing, bleeding `.code`'s
--- `camel_case`/`opaque_token_min_length` (or `.prose`'s) into content that
--- should have used the other. Grouping by classification first, and
--- splitting each stretch with its own rules, keeps that boundary exact
--- while still treating same-classification leaves as one merged span the
--- way `M.split_run` always has.
---
---@param start_node TSNode The run's first leaf.
---@param end_node TSNode The run's last leaf.
---@return {is_prose: boolean, start_row: integer, start_col: integer, end_row: integer, end_col: integer}[]
---
local function _run_segments(start_node, end_node)
    local end_row, end_col = end_node:end_()
    local segments = {}
    local node = start_node

    while true do
        local is_prose = classify.is_prose(node)
        local segment_start_row, segment_start_col = node:start()
        local segment_end_row, segment_end_col = node:end_()

        while segment_end_row ~= end_row or segment_end_col ~= end_col do
            local next_node = assert(leaf.next_leaf(node))

            if classify.is_prose(next_node) ~= is_prose then
                node = next_node

                break
            end

            node = next_node
            segment_end_row, segment_end_col = node:end_()
        end

        table.insert(segments, {
            is_prose = is_prose,
            start_row = segment_start_row,
            start_col = segment_start_col,
            end_row = segment_end_row,
            end_col = segment_end_col,
        })

        if segment_end_row == end_row and segment_end_col == end_col then
            return segments
        end
    end
end

--- Split one `_run_segments` segment into sub-word units.
---
--- `pcall` guards `nvim_buf_get_text` the same way `_commands.motion.leaf`'s
--- `_has_non_blank_between` already guards its own identical call: a leaf's
--- `:end_()` can sit one row past the buffer's last line (a root node
--- covering an implicit trailing newline is the common case), which isn't a
--- valid range to read. `M.split` never hits this because it reads leaf text
--- via `vim.treesitter.get_node_text`, whose internal `buf_range_get_text`
--- special-cases `end_col == 0` before ever calling `nvim_buf_get_text` --
--- there's no equivalent to reach for here, since a run spans multiple
--- leaves and has no single `TSNode` of its own. Falling back to one
--- whole-segment unit on failure matches every other "can't split this"
--- fallback in this file (a genuinely multi-row span, a `text` with no words
--- in it, ...).
---
---@param segment {is_prose: boolean, start_row: integer, start_col: integer, end_row: integer, end_col: integer}
---@param settings treemotion.SplitSettings
---@return treemotion.SubwordUnit[]
---
local function _split_run_segment(segment, settings)
    local start_row, start_col = segment.start_row, segment.start_col
    local end_row, end_col = segment.end_row, segment.end_col

    local ok, lines = pcall(vim.api.nvim_buf_get_text, 0, start_row, start_col, end_row, end_col, {})

    if not ok then
        return { span.new(start_row, start_col, end_row, end_col) }
    end

    local trimmed, trimmed_end_row, trimmed_end_col = _trim_span(table.concat(lines, "\n"), start_row, start_col)

    if trimmed_end_row ~= start_row and not segment.is_prose then
        -- Genuinely multi-row, non-prose content; sub-word splitting
        -- only makes sense within a single line for code-shaped runs --
        -- see `M.split`'s identical branch for why multi-row *prose*
        -- runs fall through below instead.
        return { span.new(start_row, start_col, end_row, end_col) }
    end

    return _split_text(
        trimmed,
        span.new(start_row, start_col, trimmed_end_row, trimmed_end_col),
        segment.is_prose,
        settings
    )
end

--- Split the contiguous run from `start_node` to `end_node`'s text into
--- sub-word units, per `settings` (`commands.motion.big`'s) -- the `W`/`E`/`B`/`gE`
--- counterpart to `M.split`.
---
--- A run's leaves are contiguous by construction (see `_commands.motion.leaf`'s
--- `is_contiguous`), so the raw buffer text from `start_node`'s start to
--- `end_node`'s end is already exactly the run's text -- no leaf-boundary
--- artifact-stitching like `_leading_continuation_length` is needed the way
--- `M.split` needs it for a single leaf. `_run_segments` first divides the
--- run into same-classification (code vs. prose, see its docstring)
--- stretches; each stretch is then handled by `_split_run_segment`, which
--- trims trailing blank characters with `_trim_span`, the same way
--- `M.split` trims a leaf (a run can end in one, the same trailing-terminator
--- grammar quirk `_trim_span`'s docstring covers), falling back to one whole-segment
--- unit for genuinely multi-row content left after trimming, same as
--- `M.split` does for a multi-row leaf.
---
--- When `commands.motion.big.enabled` is `false` (the default), this always
--- returns one whole-run unit -- the exact behavior `W`/`E`/`B`/`gE`
--- had before this feature existed, ignoring case/delimiters entirely.
--- Setting it to `true` opts into real splitting, reading
--- `commands.motion.big.code`/`.prose` instead of `.small`'s.
---
---@param start_node TSNode The run's first leaf (e.g. `leaf.run_start(node)`).
---@param end_node TSNode The run's last leaf (e.g. `leaf.run_end(node)`).
---@param settings treemotion.SplitSettings See `_commands.motion.settings.resolve`.
---@return treemotion.SubwordUnit[] # Empty when `enabled` is `true` and the whole run is a dropped
---    (`"skip"`) delimiter run with no other content -- same as `M.split`, see `_split_text`'s docstring;
---    otherwise the run's full (trimmed) span if nothing else splits it.
---
M.split_run = _logged("split_run", function(start_node, end_node, settings)
    local start_row, start_col = start_node:start()
    local end_row, end_col = end_node:end_()

    if not settings.enabled then
        -- Deliberately skips `_run_segments`/trimming entirely: that
        -- machinery exists only to make real splitting land on sensible
        -- boundaries, and applying it here too would change `W`/`E`/`B`/`gE`'s
        -- landing column in the same rare trailing-terminator-grammar-quirk
        -- case `_trim_span` handles for `M.split` -- exactly the
        -- byte-for-byte parity with pre-`enabled` behavior this default is
        -- supposed to guarantee. So the disabled path returns the raw
        -- `start_node`/`end_node` span untouched, identical to what
        -- `_commands.motion.runner` used to compute directly from
        -- `leaf.run_start`/`leaf.run_end` before this function existed.
        return { span.new(start_row, start_col, end_row, end_col) }
    end

    local units = {}

    for _, segment in ipairs(_run_segments(start_node, end_node)) do
        vim.list_extend(units, _split_run_segment(segment, settings))
    end

    return units
end, function(start_node, end_node)
    local start_row, start_col = start_node:start()
    local end_row, end_col = end_node:end_()

    return string.format("%s at %s:%s -> %s:%s", start_node:type(), start_row, start_col, end_row, end_col)
end)

return M
