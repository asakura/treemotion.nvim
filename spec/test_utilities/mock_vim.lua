--- Temporarily track when certain built-in Vim commands are called.

local M = {}

local _ERROR_MESSAGES = {}
local _OK_MESSAGES = {}
local _WARN_MESSAGES = {}
local _ORIGINAL_HEALTH_ERROR = vim.health.error
local _ORIGINAL_HEALTH_OK = vim.health.ok
local _ORIGINAL_HEALTH_WARN = vim.health.warn

---@return string[] # Get all saved vim.health.error calls.
function M.get_vim_health_errors()
    return _ERROR_MESSAGES
end

---@return string[] # Get all saved vim.health.ok calls.
function M.get_vim_health_oks()
    return _OK_MESSAGES
end

---@return string[] # Get all saved vim.health.warn calls.
function M.get_vim_health_warnings()
    return _WARN_MESSAGES
end

--- Temporarily track vim.health calls.
function M.mock_vim_health()
    local function _save_health_error_message(message)
        table.insert(_ERROR_MESSAGES, message)
    end

    local function _save_health_ok_message(message)
        table.insert(_OK_MESSAGES, message)
    end

    local function _save_health_warn_message(message)
        table.insert(_WARN_MESSAGES, message)
    end

    vim.health.error = _save_health_error_message
    vim.health.ok = _save_health_ok_message
    vim.health.warn = _save_health_warn_message
end

--- Restore the previous vim.health function.
function M.reset_mocked_vim_health()
    vim.health.error = _ORIGINAL_HEALTH_ERROR
    vim.health.ok = _ORIGINAL_HEALTH_OK
    vim.health.warn = _ORIGINAL_HEALTH_WARN
    _ERROR_MESSAGES = {}
    _OK_MESSAGES = {}
    _WARN_MESSAGES = {}
end

return M
