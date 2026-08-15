--- All functions and data to help customize `treemotion` for this user.

local hints_constant = require("treemotion._core.hints")
local motion_constant = require("treemotion._commands.motion.constant")
local say_constant = require("treemotion._commands.hello_world.say.constant")

local logging = require("mega.logging")

local _LOGGER = logging.get_logger("treemotion._core.configuration")

local M = {}

vim.g.loaded_treemotion = false

-- NOTE: `M.DATA` starts empty and is always filled out by
-- `M.initialize_data_if_needed()` before any other function in this module
-- reads it, so the "missing `logging`" warning below is a false positive.
---@type treemotion.ResolvedConfiguration
---@diagnostic disable-next-line: missing-fields
M.DATA = {}

---@type treemotion.ResolvedConfiguration
local _DEFAULTS = {
    hints = hints_constant.Kind.none,
    logging = { level = "info", use_console = false, use_file = false },
    commands = {
        goodnight_moon = { read = { phrase = "A good book" } },
        hello_world = {
            say = { ["repeat"] = 1, style = say_constant.Keyword.style.lowercase },
        },
        motion = {
            comment_markers = {
                c = { "/" },
                cpp = { "/" },
                rust = { "/" },
                python = { "#" },
                bash = { "#" },
                sh = { "#" },
                latex = { "%" },
                tex = { "%" },
                vim = { '"' },
                query = { ";" },
                lua = { "-" },
            },
            insignificant_characters = {},
            small = {
                backtick_identifiers = true,
                code = {
                    camel_case = true,
                    pascal_case = true,
                    kebab_case = motion_constant.DelimiterMode.skip,
                    snake_case = motion_constant.DelimiterMode.skip,
                    colon_case = motion_constant.DelimiterMode.none,
                    slash_case = motion_constant.DelimiterMode.none,
                    comment_marker_case = motion_constant.DelimiterMode.stop,
                    opaque_token_min_length = 20,
                },
                prose = {
                    camel_case = true,
                    pascal_case = true,
                    kebab_case = motion_constant.DelimiterMode.stop,
                    snake_case = motion_constant.DelimiterMode.none,
                    colon_case = motion_constant.DelimiterMode.skip,
                    slash_case = motion_constant.DelimiterMode.skip,
                    comment_marker_case = motion_constant.DelimiterMode.stop,
                    opaque_token_min_length = 20,
                },
            },
            big = {
                enabled = false,
                backtick_identifiers = true,
                code = {
                    camel_case = false,
                    pascal_case = false,
                    kebab_case = motion_constant.DelimiterMode.none,
                    snake_case = motion_constant.DelimiterMode.none,
                    colon_case = motion_constant.DelimiterMode.none,
                    slash_case = motion_constant.DelimiterMode.none,
                    comment_marker_case = motion_constant.DelimiterMode.none,
                    opaque_token_min_length = 20,
                },
                prose = {
                    camel_case = false,
                    pascal_case = false,
                    kebab_case = motion_constant.DelimiterMode.none,
                    snake_case = motion_constant.DelimiterMode.none,
                    colon_case = motion_constant.DelimiterMode.none,
                    slash_case = motion_constant.DelimiterMode.none,
                    comment_marker_case = motion_constant.DelimiterMode.none,
                    opaque_token_min_length = 20,
                },
            },
        },
    },
}

--- Additional treesitter language -> comment-marker-character entries beyond
--- `_DEFAULTS`, activated automatically (see `M.get_comment_markers`) only
--- when that language's parser is actually installed. Grouped by marker
--- character for readability, mirroring `_DEFAULTS`' own 11 entries.
---
--- Deliberately a curated, high-confidence list, not a guess at every
--- nixpkgs treesitter grammar: markup/template languages with block-only or
--- multi-character comment delimiters (HTML, XML, JSON, Jinja/Twig/Liquid,
--- Markdown, reStructuredText) and dozens of very niche grammars are
--- excluded rather than guessed at.
---
---@type table<string, string[]>
local _OPTIONAL_COMMENT_MARKERS = {
    -- "#"
    awk = { "#" },
    cmake = { "#" },
    dockerfile = { "#" },
    fish = { "#" },
    gitattributes = { "#" },
    gitcommit = { "#" },
    git_rebase = { "#" },
    gitignore = { "#" },
    graphql = { "#" },
    jq = { "#" },
    julia = { "#" },
    kconfig = { "#" },
    make = { "#" },
    meson = { "#" },
    muttrc = { "#" },
    nginx = { "#" },
    nim = { "#" },
    nix = { "#" },
    elixir = { "#" },
    perl = { "#" },
    powershell = { "#" },
    prql = { "#" },
    puppet = { "#" },
    r = { "#" },
    requirements = { "#" },
    robots_txt = { "#" },
    ruby = { "#" },
    snakemake = { "#" },
    sparql = { "#" },
    ssh_config = { "#" },
    starlark = { "#" },
    sxhkdrc = { "#" },
    tcl = { "#" },
    toml = { "#" },
    yaml = { "#" },
    zsh = { "#" },
    caddy = { "#" },
    desktop = { "#" },
    hyprlang = { "#" },
    kitty = { "#" },
    promql = { "#" },
    pymanifest = { "#" },
    tmux = { "#" },
    udev = { "#" },
    zathurarc = { "#" },
    gdscript = { "#" },
    elvish = { "#" },
    -- "#" + ";"
    ini = { "#", ";" },
    editorconfig = { "#", ";" },
    git_config = { "#", ";" },
    -- "#" + "!"
    properties = { "#", "!" },
    -- "#" + "/" (both accepted)
    hcl = { "#", "/" },
    terraform = { "#", "/" },
    hjson = { "#", "/" },

    -- "/" (matches "//")
    c_sharp = { "/" },
    java = { "/" },
    javascript = { "/" },
    typescript = { "/" },
    tsx = { "/" },
    go = { "/" },
    kotlin = { "/" },
    scala = { "/" },
    swift = { "/" },
    dart = { "/" },
    groovy = { "/" },
    zig = { "/" },
    glsl = { "/" },
    hlsl = { "/" },
    jsonnet = { "/" },
    proto = { "/" },
    thrift = { "/" },
    solidity = { "/" },
    typespec = { "/" },
    gdshader = { "/" },
    d = { "/" },
    objc = { "/" },
    odin = { "/" },
    v = { "/" },
    pkl = { "/" },
    systemverilog = { "/" },
    php = { "/" },
    php_only = { "/" },
    scss = { "/" },
    cue = { "/" },
    kdl = { "/" },
    ron = { "/" },
    gleam = { "/" },
    fsharp = { "/" },
    vala = { "/" },
    rescript = { "/" },
    cairo = { "/" },
    wgsl = { "/" },
    wgsl_bevy = { "/" },
    pascal = { "/" },
    arduino = { "/" },
    c3 = { "/" },
    devicetree = { "/" },
    json5 = { "/" },

    -- "-" (matches "--")
    haskell = { "-" },
    haskell_persistent = { "-" },
    elm = { "-" },
    purescript = { "-" },
    sql = { "-" },
    ada = { "-" },
    vhdl = { "-" },
    agda = { "-" },
    dhall = { "-" },
    idris = { "-" },
    unison = { "-" },
    teal = { "-" },
    luau = { "-" },

    -- ";"
    scheme = { ";" },
    racket = { ";" },
    commonlisp = { ";" },
    clojure = { ";" },
    fennel = { ";" },
    asm = { ";" },
    nasm = { ";" },
    llvm = { ";" },
    ledger = { ";" },
    beancount = { ";" },

    -- "%"
    erlang = { "%" },
    prolog = { "%" },
    matlab = { "%" },
}

--- Additional treesitter language -> insignificant-leaf-text entries beyond
--- `_DEFAULTS` (which ships empty), activated automatically (see
--- `M.get_insignificant_characters`) only when that language's parser is
--- actually installed. Mirrors `_OPTIONAL_COMMENT_MARKERS` in shape and
--- resolution order, but deliberately much smaller: unlike comment syntax,
--- which punctuation counts as "insignificant" is a personal taste call, not
--- an objective fact about a grammar (see `M.get_insignificant_characters`'s
--- docstring), so entries only belong here once they're a near-universal
--- call for that language, not a guess. In Nix, `;` only ever terminates a
--- `let`/attribute-set binding, never starts an expression, and `{`/`}`/`[`/`]`
--- are pure structural delimiters with no meaning of their own -- all four
--- are noise at every occurrence, the same reasoning README's own
--- `insignificant_characters` example gives for Lua's `;`. `"`/`''` (Nix's
--- plain and indented string delimiters) belong here for the same reason:
--- `subword.lua`'s `_is_prose` only counts *named* nodes as prose, and both
--- delimiters parse as unnamed leaves distinct from the named
--- `string_fragment` they wrap (`tree-sitter-nix`'s `queries/highlights.scm`
--- paints all three `@string` for uniform coloring, but only the fragment is
--- real text) -- so, unlike a language whose string quotes are the only
--- node covering their span, these are ordinary code leaves as far as this
--- feature is concerned, free of any of the actual string content's prose
--- rules.
---
---@type table<string, string[]>
local _OPTIONAL_INSIGNIFICANT_CHARACTERS = {
    nix = { "{", "}", "[", "]", ";", '"', "''" },
}

--- Setup `treemotion` for the first time, if needed.
function M.initialize_data_if_needed()
    if vim.g.loaded_treemotion then
        return
    end

    M.DATA = vim.tbl_deep_extend("force", _DEFAULTS, vim.g.treemotion_configuration or {})

    vim.g.loaded_treemotion = true

    local configuration = M.DATA.logging

    -- NOTE: `treemotion.LoggingConfiguration` and `mega.logging.SparseLoggerOptions`
    -- are separately-declared classes with no inheritance relationship, so
    -- lua-language-server won't treat this cast as valid on nominal-type
    -- grounds alone, even though every field the two types share matches
    -- exactly.
    ---@diagnostic disable-next-line: cast-type-mismatch
    ---@cast configuration mega.logging.SparseLoggerOptions
    logging.set_configuration("treemotion", configuration)

    _LOGGER:fmt_debug("Initialized treemotion's configuration.")
end

--- Merge `data` with the user's current configuration.
---
---@param data treemotion.Configuration? All extra customizations for this plugin.
---@return treemotion.ResolvedConfiguration # The configuration with 100% filled out values.
---
function M.resolve_data(data)
    M.initialize_data_if_needed()

    return vim.tbl_deep_extend("force", M.DATA, data or {})
end

--- Look up `language`'s comment-marker characters, whether shipped/user-configured
--- or auto-detected from `_OPTIONAL_COMMENT_MARKERS`.
---
--- The `_OPTIONAL_COMMENT_MARKERS` fallback is deliberately resolved here, lazily,
--- per call -- not merged into `M.DATA` up front in `initialize_data_if_needed()`.
--- `vim.treesitter.language.add()` (see `health.lua`'s identical use) loads the
--- parser it checks for, which is a real cost across ~120 candidate languages;
--- doing that for every one of them at plugin load, on every Neovim startup,
--- regardless of which languages actually get edited that session, would be
--- wasteful. Checking lazily for just the buffer's current language costs
--- nothing extra: by the time this is called, that language's parser is already
--- loaded (see `_current_language()`'s use of `vim.treesitter.get_parser()`).
---
---@param language string A treesitter language name.
---@return string[]?
---
function M.get_comment_markers(language)
    M.initialize_data_if_needed()

    local shipped = M.DATA.commands.motion.comment_markers[language]

    if shipped then
        return shipped
    end

    local optional = _OPTIONAL_COMMENT_MARKERS[language]

    if optional and vim.treesitter.language.add(language) then
        return optional
    end

    return nil
end

--- Whether `list` (a raw `commands.motion.insignificant_characters[language]`
--- override) negates at least one character rather than being a plain
--- `string[]` full replacement.
---
--- A Lua table literal can't hold a real `nil` value (`:help vim.NIL`
--- explains why: `{"foo", nil}` collapses to `{"foo"}`, indistinguishable
--- from never having the key at all), so there's no way for a user to write
--- "drop just this one character from `_OPTIONAL_INSIGNIFICANT_CHARACTERS`
--- (or a shipped default), keep the rest" as a real `nil`. `false` is the
--- sentinel instead: an ordinary, assignable Lua value that survives fine as
--- a table entry, e.g. `nix = { [";"] = false }` keeps `{`/`}`/`[`/`]` but
--- drops `;`. `list[character] == false` (rather than merely falsy) is
--- checked deliberately, so an absent key (`nil`, i.e. "no opinion") never
--- gets confused with an explicit negation.
---
---@param list treemotion.InsignificantCharacterList
---@return boolean
---
local function _has_negation(list)
    for key, value in pairs(list) do
        if type(key) == "string" and value == false then
            return true
        end
    end

    return false
end

--- Apply `patch` (a hybrid table -- see `_has_negation`) on top of `base` (an
--- `_OPTIONAL_INSIGNIFICANT_CHARACTERS` entry, or `{}` if `language` has
--- none): every character in `base` survives unless `patch` explicitly
--- negates it (`[character] = false`), and every plain string `patch` lists
--- in its own array part (`ipairs`-visible, same as any other
--- `insignificant_characters` entry) is added on top, whether or not it was
--- already in `base`.
---
---@param base string[]
---@param patch treemotion.InsignificantCharacterList
---@return string[]
---
local function _apply_negations(base, patch)
    local result = {}

    for _, character in ipairs(base) do
        if patch[character] ~= false then
            table.insert(result, character)
        end
    end

    for _, character in ipairs(patch) do
        if not vim.tbl_contains(result, character) then
            table.insert(result, character)
        end
    end

    return result
end

--- Look up `language`'s insignificant leaf texts -- leaf-level tokens (e.g.
--- `";"`, `"{"`, `"}"`) that `w`/`e`/`b`/`ge`/`W`/`E`/`B`/`gE` treat as
--- invisible for **code** leaves (see `_commands.motion.subword`'s
--- `_is_insignificant` for why prose is exempt).
---
--- Which punctuation counts as "insignificant" is mostly a personal taste
--- call, not an objective fact about a grammar the way comment syntax is
--- (see `_OPTIONAL_INSIGNIFICANT_CHARACTERS`'s docstring), so this stays
--- opt-in via `commands.motion.insignificant_characters` for the vast
--- majority of languages. `_OPTIONAL_INSIGNIFICANT_CHARACTERS` is the
--- narrow, curated exception: entries there resolve the same way
--- `M.get_comment_markers`'s `_OPTIONAL_COMMENT_MARKERS` fallback does, only
--- once `vim.treesitter.language.add(language)` confirms the parser is
--- actually installed -- unless the user's own override negates one of its
--- characters (see `_has_negation`/`_apply_negations`), in which case the
--- override is treated as a patch on top of it instead of a full
--- replacement, and applies regardless of whether the parser check would
--- have passed (the user typed the language name themselves, so there's no
--- "auto-detected" ambiguity to gate on).
---
---@param language string A treesitter language name.
---@return string[]?
---
function M.get_insignificant_characters(language)
    M.initialize_data_if_needed()

    local user = M.DATA.commands.motion.insignificant_characters[language]

    if user and _has_negation(user) then
        return _apply_negations(_OPTIONAL_INSIGNIFICANT_CHARACTERS[language] or {}, user)
    end

    if user then
        return user
    end

    local optional = _OPTIONAL_INSIGNIFICANT_CHARACTERS[language]

    if optional and vim.treesitter.language.add(language) then
        return optional
    end

    return nil
end

--- Merge `data` into the current configuration, in-place.
---
--- Unlike `M.resolve_data()`, this permanently updates `M.DATA` rather than
--- returning a one-off merged copy. Use this to apply configuration after
--- `M.initialize_data_if_needed()` has already run and latched (e.g. from a
--- plugin manager's `opts` table, which is applied after `require()` has
--- already triggered initialization).
---
---@param data treemotion.Configuration? Extra customizations to apply now.
---
function M.merge_data(data)
    M.initialize_data_if_needed()

    M.DATA = vim.tbl_deep_extend("force", M.DATA, data or {})
end

--- Turn `kind` on, replacing whichever hint kind (if any) was previously active.
---
---@param kind treemotion.HintKind Which hints to show. e.g. `"word_boundaries"`.
---
function M.set_hints(kind)
    M.initialize_data_if_needed()

    M.DATA.hints = kind
end

--- Turn `kind` on if it isn't already active, otherwise turn all hints off.
---
--- Because `M.DATA.hints` holds a single value, enabling `kind` always
--- implicitly disables whichever other kind was previously active.
---
---@param kind treemotion.HintKind Which hints to toggle. e.g. `"word_boundaries"`.
---
function M.toggle_hints(kind)
    M.initialize_data_if_needed()

    if M.DATA.hints == kind then
        M.DATA.hints = hints_constant.Kind.none
    else
        M.DATA.hints = kind
    end
end

return M
