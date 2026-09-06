-- Use every connected display unless this host explicitly overrides it.
local host = require("config.host")
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
for _, monitor in ipairs(host.monitors) do
    hl.monitor(monitor)
end
