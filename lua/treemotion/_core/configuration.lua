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
            subword = {
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
                backtick_identifiers = true,
                code = {
                    camel_case = true,
                    pascal_case = true,
                    kebab_case = motion_constant.DelimiterMode.skip,
                    snake_case = motion_constant.DelimiterMode.skip,
                    comment_marker_case = motion_constant.DelimiterMode.stop,
                },
                prose = {
                    camel_case = true,
                    pascal_case = true,
                    kebab_case = motion_constant.DelimiterMode.stop,
                    snake_case = motion_constant.DelimiterMode.none,
                    comment_marker_case = motion_constant.DelimiterMode.stop,
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

    local shipped = M.DATA.commands.motion.subword.comment_markers[language]

    if shipped then
        return shipped
    end

    local optional = _OPTIONAL_COMMENT_MARKERS[language]

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
