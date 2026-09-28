--- Split a treesitter leaf's (`M.split`), or a whole run's (`M.split_run`),
--- text into case-convention-aware sub-word units.
---
--- `M.split` backs `w`/`e`/`b`/`ge` (see `_commands.motion.word`) with
--- `commands.motion.small`'s settings. `M.split_run` backs `W`/`E`/`B`/`gE`
--- (see `_commands.motion.bigword`) with `commands.motion.big`'s, and only
--- splits when `commands.motion.big.enabled` is `true`; otherwise it returns
--- one unit spanning the whole run, the way real Vim's `W` ignores
--- punctuation inside a WORD. Both take a `treemotion.SplitSettings` (see
--- `_commands.motion.settings.resolve`) rather than reading configuration.
---
--- This module only orchestrates: it narrows a leaf or run to the text that
--- is eligible to split, maps offsets back to buffer coordinates, and
--- delegates the rest. `_commands.motion.classify` decides prose vs. code
--- and insignificance; `_commands.motion.prose`, `.delimiters` and `.case`
--- are the pure string splitters.
---
--- Splitting composes up to three passes. Prose text is first divided into
--- words (`prose.words`); code text is one word. Each word is then divided
--- on delimiters (`delimiters.split`) and, unless a chunk looks like a hash
--- (`case.looks_like_hash`), on camelCase/PascalCase boundaries
--- (`case.split`), using the `.code` or `.prose` rules. A backtick-enclosed
--- identifier in prose uses the `.code` rules when `backtick_identifiers` is
--- on. Each `treemotion.SubwordUnit` is only a coordinate range, not a tree
--- node.

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
--- Some grammars fold a trailing newline into a token's own span (e.g.
--- tree-sitter-rust's `doc_comment` ends at `(next_row, 0)`), and a run can
--- end in one too. Rather than special-casing node types, callers check
--- whether the trimmed text still ends on `start_row`: if so the span is
--- really single-row. Text with real content on several rows stays
--- multi-row after trimming.
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
--- Grammars can split one run of marker punctuation across leaves: Lua's
--- comment opener is a fixed 2-character `--`, so a `---` doc comment's
--- third dash starts `comment_content`; Rust's `///` parses as `//`, a lone
--- `/`, then the text. Real Vim treats a same-class punctuation run as one
--- word, so `M.split` strips this many characters and the run's only stop
--- stays in the previous leaf. The result can be `#text` (Rust's lone `/`).
---
--- Any non-blank, non-alphanumeric character qualifies. Alphanumerics are
--- excluded because a word or number split across leaves may be two
--- genuinely separate tokens.
---
--- Counts whole characters (via `_commands.motion.codepoint`), so the
--- result is always a character boundary in `text`. A 1-byte `char` takes a
--- plain byte-comparison fast path.
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
--- Word, delimiter and chunk offsets compose into each unit's offset in
--- `text`, which `span.position_mapper` maps back to buffer coordinates
--- (including multi-row prose such as a wrapped Markdown paragraph).
---
--- Text with no words at all (e.g. an all-whitespace prose comment)
--- returns `fallback`. Text made up entirely of a dropped
--- (`comment_marker_case = "skip"`) marker run has words but yields no
--- units, and gets no fallback: the user asked for no stop there.
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
--- A multi-row `node` whose extra rows are only trailing blanks is trimmed
--- to one row (`_trim_span`); other multi-row code stays one whole-leaf
--- unit, while multi-row prose is split across its rows. Leading characters
--- that continue the previous leaf's punctuation run are skipped (see
--- `_leading_continuation_length`); if that is all of `node`, no units are
--- returned and `_commands.motion.word` moves on to the next leaf.
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
            -- Genuinely multi-row code: sub-word splitting only applies
            -- within a line. Multi-row prose falls through to `_split_text`,
            -- which is row-aware.
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
--- leaves that share the same `classify.is_prose` classification.
---
--- A run can put code and prose leaves side by side with no whitespace (Lua's
--- `foo"bar"` is an identifier followed by a string). Splitting each stretch
--- with its own rules keeps `.code` settings out of the string and vice
--- versa.
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
--- `pcall` guards `nvim_buf_get_text`: a leaf's `:end_()` can sit one row
--- past the buffer's last line (a root node covering the implicit trailing
--- newline), which isn't a readable range. A run has no single `TSNode` to
--- hand to `vim.treesitter.get_node_text`, which handles that case itself.
--- On failure the whole segment becomes one unit.
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
        -- Genuinely multi-row code; see `M.split`'s identical branch.
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
--- sub-word units, per `settings` (`commands.motion.big`'s): the
--- `W`/`E`/`B`/`gE` counterpart to `M.split`.
---
--- A run's leaves are contiguous (see `_commands.motion.run`), so the buffer
--- text from `start_node`'s start to `end_node`'s end is exactly the run's
--- text. The run is divided into same-classification stretches
--- (`_run_segments`), each trimmed and split like a single leaf.
---
--- When `settings.enabled` is `false` (the default), returns one whole-run
--- unit.
---
---@param start_node TSNode The run's first leaf (e.g. `run.run_start(node)`).
---@param end_node TSNode The run's last leaf (e.g. `run.run_end(node)`).
---@param settings treemotion.SplitSettings See `_commands.motion.settings.resolve`.
---@return treemotion.SubwordUnit[] # Empty when `enabled` is `true` and the whole run is a dropped
---    (`"skip"`) delimiter run with no other content -- same as `M.split`, see `_split_text`'s docstring;
---    otherwise the run's full (trimmed) span if nothing else splits it.
---
M.split_run = _logged("split_run", function(start_node, end_node, settings)
    local start_row, start_col = start_node:start()
    local end_row, end_col = end_node:end_()

    if not settings.enabled then
        -- No trimming here: the disabled path must land exactly on the
        -- run's raw bounds, so `W`/`E`/`B`/`gE` behave as plain WORD motions.
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
