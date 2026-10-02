--- The user's configuration and the defaults it is merged over.

local motion_constant = require("treemotion._commands.motion.constant")

local logging = require("mega.logging")

local _LOGGER = logging.get_logger("treemotion._core.configuration")

local M = {}

--- Filled in by `M.initialize_data_if_needed()` before any read.
---@type treemotion.ResolvedConfiguration
---@diagnostic disable-next-line: missing-fields
M.DATA = {}

-- Module-local, not a `g:` variable, so reloading the module resets it.
local _initialized = false

---@type treemotion.ResolvedConfiguration
local _DEFAULTS = {
    logging = { level = "info", use_console = false, use_file = false },
    commands = {
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
            operator_pending = {
                enabled = false,
                skipped_text = motion_constant.SkippedText.keep_between_tokens,
                stop_at_line_end = true,
                change_to_end = true,
                inclusive = true,
            },
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

--- Comment markers for more languages, used only when the language's parser
--- is installed (see `M.get_comment_markers`). Languages with block-only or
--- multi-character comment syntax are left out.
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

--- Insignificant characters used when the language's parser is installed.
--- Kept to near-universal choices, since this is mostly taste.
---
---@type table<string, string[]>
local _OPTIONAL_INSIGNIFICANT_CHARACTERS = {
    nix = { "{", "}", "[", "]", ";", '"', "''", "=", "." },
}

--- Build `M.DATA` from the defaults and `g:treemotion_configuration`, once.
---
function M.initialize_data_if_needed()
    if _initialized then
        return
    end

    M.DATA = vim.tbl_deep_extend("force", _DEFAULTS, vim.g.treemotion_configuration or {})

    _initialized = true

    local configuration = M.DATA.logging

    -- The two classes have the same fields but are declared separately.
    ---@diagnostic disable-next-line: cast-type-mismatch
    ---@cast configuration mega.logging.SparseLoggerOptions
    logging.set_configuration("treemotion", configuration)

    _LOGGER:fmt_debug("Initialized treemotion's configuration.")
end

--- The configuration, with `data` merged in if given. Without `data` this is
--- `M.DATA` itself, not a copy, so don't edit it. Writers replace `M.DATA`
--- instead of editing it.
---
---@param data treemotion.Configuration?
---@return treemotion.ResolvedConfiguration
---
function M.resolve_data(data)
    M.initialize_data_if_needed()

    if not data or next(data) == nil then
        return M.DATA
    end

    return vim.tbl_deep_extend("force", M.DATA, data)
end

--- `language`'s comment markers. Optional entries are checked lazily,
--- because `vim.treesitter.language.add()` loads the parser.
---
---@param language string
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

--- Whether `list` removes a character with `[character] = false`. A table
--- can't hold `nil`, so `false` marks the removal.
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

--- `base` without the characters `patch` sets to `false`, plus `patch`'s
--- own listed characters.
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

--- `language`'s insignificant characters: the user's list, the user's
--- removals applied to the optional list, or the optional list when its
--- parser is installed.
---
---@param language string
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

--- Merge `data` into `M.DATA` permanently (used by `setup()`).
---
---@param data treemotion.Configuration?
---
function M.merge_data(data)
    M.initialize_data_if_needed()

    M.DATA = vim.tbl_deep_extend("force", M.DATA, data or {})
end

return M
