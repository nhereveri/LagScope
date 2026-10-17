local ADDON_NAME = ...

local DEFAULTS = {
    spikeMs = 50,
    maxSpikes = 60,
    maxLatency = 400,
    enabled = true,
}

local frame = CreateFrame("Frame")
local baseline = {}
local prefixStats = {}
local errorStats = {}
local netPeak = { latency = 0, bandwidthOut = 0 }
local totalMessages = 0
local lastSpikeAt = 0
local addonNames = {}
local profilerOK = false

local function Say(msg)
    print("|cff66ccffLagScope|r: " .. msg)
end

local function Line(msg)
    print("  " .. msg)
end

local METRIC = (Enum and Enum.AddOnProfilerMetric) or {}

local function ReadMetric(addonName, key)
    local metric = METRIC[key]
    if not metric or not profilerOK then
        return nil
    end
    local ok, value = pcall(C_AddOnProfiler.GetAddOnMetric, addonName, metric)
    if ok and type(value) == "number" then
        return value
    end
    return nil
end

local function RefreshAddOnList()
    wipe(addonNames)
    local total = C_AddOns and C_AddOns.GetNumAddOns and C_AddOns.GetNumAddOns() or 0
    for i = 1, total do
        if C_AddOns.IsAddOnLoaded(i) then
            local name = C_AddOns.GetAddOnInfo(i)
            if name then
                addonNames[#addonNames + 1] = name
            end
        end
    end
end

local function ReadStutterCount(addonName)
    return ReadMetric(addonName, "CountTimeOver10Ms")
        or ReadMetric(addonName, "CountTimeOver5Ms")
        or 0
end

local function TakeBaseline()
    wipe(baseline)
    RefreshAddOnList()
    for i = 1, #addonNames do
        local name = addonNames[i]
        baseline[name] = ReadStutterCount(name)
    end
end

local function CurrentContext()
    if LagScopeDB and LagScopeDB.encounter then
        return LagScopeDB.encounter
    end
    if InCombatLockdown() then
        return "in combat"
    end
    return "out of combat"
end

local function TopOffendersNow(count)
    local list = {}
    for i = 1, #addonNames do
        local name = addonNames[i]
        local ms = ReadMetric(name, "LastTime")
        if ms and ms > 0 then
            list[#list + 1] = { name = name, ms = ms }
        end
    end
    table.sort(list, function(a, b) return a.ms > b.ms end)
    local top = {}
    for i = 1, math.min(count, #list) do
        top[i] = string.format("%s %.1fms", list[i].name, list[i].ms)
    end
    return top
end

local function RecordSpike(frameMs)
    local bandwidthIn, bandwidthOut, latencyHome, latencyWorld = GetNetStats()
    local entry = {
        at = date("%H:%M:%S"),
        frameMs = frameMs,
        latency = latencyWorld or 0,
        latencyHome = latencyHome or 0,
        up = bandwidthOut or 0,
        down = bandwidthIn or 0,
        msgs = totalMessages,
        context = CurrentContext(),
        top = TopOffendersNow(3),
    }
    local log = LagScopeDB.spikes
    if not log then
        return
    end
    log[#log + 1] = entry
    while #log > LagScopeDB.maxSpikes do
        table.remove(log, 1)
    end
end

frame:SetScript("OnUpdate", function(_, elapsed)
    if not LagScopeDB or not LagScopeDB.enabled then
        return
    end
    if elapsed * 1000 < LagScopeDB.spikeMs then
        return
    end
    local now = GetTime()
    if now - lastSpikeAt < 1 then
        return
    end
    lastSpikeAt = now
    RecordSpike(elapsed * 1000)
end)

local function CountMessage(prefix, message)
    if not prefix then
        return
    end
    local entry = prefixStats[prefix]
    if not entry then
        entry = { count = 0, bytes = 0 }
        prefixStats[prefix] = entry
    end
    entry.count = entry.count + 1
    entry.bytes = entry.bytes + #tostring(prefix) + (message and #tostring(message) or 0)
    totalMessages = totalMessages + 1
end

local function HookAddonMessages()
    if not C_ChatInfo then
        return
    end
    if type(C_ChatInfo.SendAddonMessage) == "function" then
        hooksecurefunc(C_ChatInfo, "SendAddonMessage", function(prefix, message)
            CountMessage(prefix, message)
        end)
    end
    if type(C_ChatInfo.SendAddonMessageLogged) == "function" then
        hooksecurefunc(C_ChatInfo, "SendAddonMessageLogged", function(prefix, message)
            CountMessage(prefix, message)
        end)
    end
end

local function CountError(err)
    local source = tostring(err):match("AddOns[\\/]([^\\/]+)[\\/]") or "unknown"
    errorStats[source] = (errorStats[source] or 0) + 1
end

local function HookErrorHandler()
    local previous = geterrorhandler()
    seterrorhandler(function(err)
        CountError(err)
        if previous then
            return previous(err)
        end
    end)
end

local function SampleNet()
    local bandwidthIn, bandwidthOut, latencyHome, latencyWorld = GetNetStats()
    if latencyWorld and latencyWorld > netPeak.latency then
        netPeak.latency = latencyWorld
    end
    if bandwidthOut and bandwidthOut > netPeak.bandwidthOut then
        netPeak.bandwidthOut = bandwidthOut
    end

    local log = LagScopeDB and LagScopeDB.latency
    if not log then
        return
    end
    local last = log[#log]
    if last and last.w == latencyWorld and last.h == latencyHome then
        return
    end
    log[#log + 1] = {
        at = date("%H:%M:%S"),
        w = latencyWorld or 0,
        h = latencyHome or 0,
        up = bandwidthOut or 0,
        down = bandwidthIn or 0,
        context = CurrentContext(),
        msgs = totalMessages,
    }
    while #log > (LagScopeDB.maxLatency or 400) do
        table.remove(log, 1)
    end
end

local function SortedStutter()
    local list = {}
    RefreshAddOnList()
    for i = 1, #addonNames do
        local name = addonNames[i]
        local now = ReadStutterCount(name)
        local delta = now - (baseline[name] or 0)
        local peak = ReadMetric(name, "PeakTime") or 0
        local avg = ReadMetric(name, "RecentAverageTime") or 0
        if delta > 0 or avg > 0.05 or peak > 5 then
            list[#list + 1] = { name = name, delta = delta, peak = peak, avg = avg }
        end
    end
    table.sort(list, function(a, b)
        if a.delta ~= b.delta then
            return a.delta > b.delta
        end
        return a.peak > b.peak
    end)
    return list
end

local function ReportCPU(limit)
    if not profilerOK then
        Say("this client does not expose C_AddOnProfiler, no CPU data available.")
        return
    end
    Say("CPU per addon (hitches = frames over 10 ms since last reset):")
    Line(string.format("%-26s %8s %9s %9s", "addon", "hitches", "peak ms", "avg ms"))
    local list = SortedStutter()
    if #list == 0 then
        Line("no addon has crossed the threshold yet.")
        return
    end
    for i = 1, math.min(limit or 10, #list) do
        local e = list[i]
        Line(string.format("%-26s %8d %9.1f %9.3f", e.name, e.delta, e.peak, e.avg))
    end
end

local function ReportSpikes(limit)
    local log = LagScopeDB.spikes
    Say(string.format("hitches recorded: %d (threshold %d ms)", #log, LagScopeDB.spikeMs))
    local from = math.max(1, #log - (limit or 8) + 1)
    for i = from, #log do
        local e = log[i]
        Line(string.format("%s  %.0f ms  lat %d ms  (%s)", e.at, e.frameMs, e.latency, e.context))
        if e.top and #e.top > 0 then
            Line("      " .. table.concat(e.top, " | "))
        end
    end
end

local function ReportNet()
    local bandwidthIn, bandwidthOut, latencyHome, latencyWorld = GetNetStats()
    Say(string.format("network: world %d ms, home %d ms, world peak %d ms | up %.2f KB/s (peak %.2f)",
        latencyWorld or 0, latencyHome or 0, netPeak.latency, bandwidthOut or 0, netPeak.bandwidthOut))
    Line(string.format("down %.2f KB/s", bandwidthIn or 0))
    local list = {}
    for prefix, entry in pairs(prefixStats) do
        list[#list + 1] = { prefix = prefix, count = entry.count, bytes = entry.bytes }
    end
    if #list == 0 then
        Line("no addon messages sent since the last reset.")
        return
    end
    table.sort(list, function(a, b) return a.bytes > b.bytes end)
    Line("addon messages sent (prefix / count / bytes):")
    for i = 1, math.min(8, #list) do
        Line(string.format("%-16s %6d  %8d B", list[i].prefix, list[i].count, list[i].bytes))
    end
end

local function ReportLatency(limit)
    local log = LagScopeDB.latency
    if not log or #log == 0 then
        Say("no latency samples yet (one is taken every 5 s).")
        return
    end
    Say("latency over time - world / home / upload / messages sent:")
    local from = math.max(1, #log - (limit or 12) + 1)
    for i = from, #log do
        local e = log[i]
        Line(string.format("%s  %5d / %5d ms  %5.2f KB/s  %6d msgs  (%s)",
            e.at, e.w or 0, e.h or 0, e.up or 0, e.msgs or 0, e.context or "?"))
    end
    Line("if world AND home climb together, the problem is the connection or")
    Line("the outgoing traffic, not an addon's CPU.")
end

local function ReportErrors()
    local list = {}
    for name, count in pairs(errorStats) do
        list[#list + 1] = { name = name, count = count }
    end
    if #list == 0 then
        Say("no Lua errors recorded this session.")
        return
    end
    table.sort(list, function(a, b) return a.count > b.count end)
    Say("Lua errors by addon:")
    for i = 1, math.min(10, #list) do
        Line(string.format("%-26s %5d", list[i].name, list[i].count))
    end
end

local function ReportAll()
    ReportCPU(8)
    ReportSpikes(5)
    ReportNet()
    ReportLatency(6)
    ReportErrors()
    Line("note: GetNetStats refreshes latency about every 30 s, so the latency")
    Line("shown per hitch is approximate. The hitch column is the reliable one.")
end

local function ResetStats()
    TakeBaseline()
    wipe(prefixStats)
    wipe(errorStats)
    wipe(LagScopeDB.spikes)
    wipe(LagScopeDB.latency)
    netPeak.latency = 0
    netPeak.bandwidthOut = 0
    totalMessages = 0
    Say("counters reset.")
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("ENCOUNTER_START")
frame:RegisterEvent("ENCOUNTER_END")

frame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            LagScopeDB = LagScopeDB or {}
            for key, value in pairs(DEFAULTS) do
                if LagScopeDB[key] == nil then
                    LagScopeDB[key] = value
                end
            end
            LagScopeDB.spikes = LagScopeDB.spikes or {}
            LagScopeDB.traffic = LagScopeDB.traffic or {}
            LagScopeDB.errors = LagScopeDB.errors or {}
            LagScopeDB.latency = LagScopeDB.latency or {}
            prefixStats = LagScopeDB.traffic
            errorStats = LagScopeDB.errors
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        profilerOK = C_AddOnProfiler ~= nil
            and type(C_AddOnProfiler.GetAddOnMetric) == "function"
            and METRIC.LastTime ~= nil
        LagScopeDB.encounter = nil
        TakeBaseline()
        HookAddonMessages()
        HookErrorHandler()
        C_Timer.NewTicker(5, SampleNet)
        Say("running. Use /lagscope after the fight to see the report.")
        if not profilerOK then
            Say("warning: without C_AddOnProfiler only network and error data will be collected.")
        end
        return
    end

    if event == "ENCOUNTER_START" then
        LagScopeDB.encounter = tostring(arg2 or arg1 or "encounter")
        return
    end

    if event == "ENCOUNTER_END" then
        LagScopeDB.encounter = nil
        return
    end
end)

SLASH_LAGSCOPE1 = "/lagscope"
SLASH_LAGSCOPE2 = "/lsc"
SlashCmdList["LAGSCOPE"] = function(msg)
    LagScopeDB = LagScopeDB or {}
    local cmd, rest = strsplit(" ", strlower(strtrim(msg or "")), 2)
    if cmd == "cpu" then
        ReportCPU(tonumber(rest) or 15)
    elseif cmd == "spikes" then
        ReportSpikes(tonumber(rest) or 15)
    elseif cmd == "net" then
        ReportNet()
    elseif cmd == "latency" then
        ReportLatency(tonumber(rest) or 20)
    elseif cmd == "errors" then
        ReportErrors()
    elseif cmd == "reset" then
        ResetStats()
    elseif cmd == "threshold" then
        local ms = tonumber(rest)
        if ms and ms >= 10 and ms <= 1000 then
            LagScopeDB.spikeMs = ms
            Say("hitch threshold set to " .. ms .. " ms.")
        else
            Say("usage: /lagscope threshold <10-1000>")
        end
    elseif cmd == "off" then
        LagScopeDB.enabled = false
        Say("hitch detection disabled.")
    elseif cmd == "on" then
        LagScopeDB.enabled = true
        Say("hitch detection enabled.")
    elseif cmd == "help" then
        Say("commands:")
        Line("/lagscope             full report")
        Line("/lagscope cpu [n]     addons ranked by hitches")
        Line("/lagscope spikes [n]  recent hitches with their culprits")
        Line("/lagscope latency [n] latency over time")
        Line("/lagscope net         latency and addon message traffic")
        Line("/lagscope errors      Lua errors per addon")
        Line("/lagscope reset       clears counters (do this before the pull)")
        Line("/lagscope threshold 50  hitch threshold in ms")
        Line("/lagscope off | on    stops or resumes hitch detection")
    else
        ReportAll()
    end
end
