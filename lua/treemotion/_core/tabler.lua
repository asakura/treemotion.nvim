--- Make dealing with Lua tables a bit easier.

local M = {}

--- Access the attribute(s) within `data` from `items`.
---
---@param data any Some nested data to query. e.g. `{a={b={c=true}}}`.
---@param items string[] Some attributes to query. e.g. `{"a", "b", "c"}`.
---@return any? # The found value, if any.
---
function M.get_value(data, items)
    local current = data
    local found = {}
    local count = #items

    for index = 1, count do
        local item = items[index]
        current = current[item]

        if current == nil then
            return nil
        end

        table.insert(found, item)

        local type_ = type(current)

        if index < count and type_ ~= "table" then
            error(string.format("%s: expected table, got %s", vim.fn.join(found, "."), type_), 0)
        end
    end

    return current
end

return M
