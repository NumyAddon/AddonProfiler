local thisAddonName = ...

local s_trim = string.trim
local t_insert = table.insert
local t_removemulti = table.removemulti
local t_remove = table.remove
local t_wipe = table.wipe
local pairs = pairs
local GetTime = GetTime

local C_AddOnProfiler_GetAddOnMetric = C_AddOnProfiler.GetAddOnMetric;
local C_AddOnProfiler_GetOverallMetric = C_AddOnProfiler.GetOverallMetric;
local Enum_AddOnProfilerMetric_LastTime = Enum.AddOnProfilerMetric.LastTime;
local Enum_AddOnProfilerMetric_EncounterAverageTime = Enum.AddOnProfilerMetric.EncounterAverageTime;

local NAP = {};
NAP.eventFrame = CreateFrame('Frame');

_G.NumyAddonProfiler = NAP;

local msOptions = {1, 5, 10, 50, 100, 500, 1000};

-- the metrics that can be fake reset, since they're just incremental
local resettableMetrics = {
    [Enum.AddOnProfilerMetric.CountTimeOver1Ms] = 1,
    [Enum.AddOnProfilerMetric.CountTimeOver5Ms] = 5,
    [Enum.AddOnProfilerMetric.CountTimeOver10Ms] = 10,
    [Enum.AddOnProfilerMetric.CountTimeOver50Ms] = 50,
    [Enum.AddOnProfilerMetric.CountTimeOver100Ms] = 100,
    [Enum.AddOnProfilerMetric.CountTimeOver500Ms] = 500,
    [Enum.AddOnProfilerMetric.CountTimeOver1000Ms] = 1000,
};
local msMetricMap = {
    [1] = Enum.AddOnProfilerMetric.CountTimeOver1Ms,
    [5] = Enum.AddOnProfilerMetric.CountTimeOver5Ms,
    [10] = Enum.AddOnProfilerMetric.CountTimeOver10Ms,
    [50] = Enum.AddOnProfilerMetric.CountTimeOver50Ms,
    [100] = Enum.AddOnProfilerMetric.CountTimeOver100Ms,
    [500] = Enum.AddOnProfilerMetric.CountTimeOver500Ms,
    [1000] = Enum.AddOnProfilerMetric.CountTimeOver1000Ms,
};
local msOptionFieldMap = {};
for ms in pairs(msMetricMap) do
    msOptionFieldMap[ms] = "over" .. ms .. "Ms";
end

local TOTAL_ADDON_METRICS_KEY = "\00total\00";

local INFINITE_HISTORY = 0;
local HISTORY_RANGES = {INFINITE_HISTORY, 5, 15, 30, 60, 120, 300, 600} -- 5sec - 10min
NAP.curHistoryRange = 30;

--- @type table<string, table<string, number>> [addonName] = { [metricName] = value }
NAP.resetBaselineMetrics = {};

NAP.totalMs = { [TOTAL_ADDON_METRICS_KEY] = 0 };
NAP.loadedAtTick = { [TOTAL_ADDON_METRICS_KEY] = 0 };
NAP.tickNumber = 0;
NAP.peakMs = { [TOTAL_ADDON_METRICS_KEY] = 0 };
NAP.snapshots = {
    --- @type NAP_Bucket[]
    buckets = {},
};
do
    --- @class NAP_Bucket
    local lastBucket = {
        --- @type table<number, number> # tickIndex -> timestamp
        tickMap = {},
        --- @type table<string, table<number, number>> # addonName -> tickIndex -> ms
        lastTick = {},
        curTickIndex = 0;
    };
    NAP.snapshots.buckets[1] = lastBucket;
    NAP.snapshots.lastBucket = lastBucket;
    for ms in pairs(msMetricMap) do
        lastBucket[ms] = {}
    end
end

--- collect all available data
local ACTIVE_MODE = 'active';
--- collect only total and peak data - disables history range
--- @todo mostly implemented, but no toggle yet
local PERFORMANCE_MODE = 'performance';
--- collect no data at all, just reset the spike ms counters on reset - disables history range, and maybe show different columns?
--- @todo not yet implemented
local PASSIVE_MODE = 'passive';

--- @todo: add some radio buttons and logic to toggle between modes
NAP.mode = nil;

--- @type table<string, { title: string, notes: string, loaded: boolean }>
NAP.addons = {};
--- @type table<string, boolean> # list of addon names
NAP.loadedAddons = {};

--- Note: NAP:Init() is called at the end of the script body, BEFORE the addon_loaded event
function NAP:Init()
    for i = 1, C_AddOns.GetNumAddOns() do
        local addonName, title, notes = C_AddOns.GetAddOnInfo(i);
        local isLoaded = C_AddOns.IsAddOnLoaded(addonName);
        if title == '' then
            title = addonName;
        end
        local version = C_AddOns.GetAddOnMetadata(addonName, 'Version');
        if version and version ~= '' then
            title = title .. ' |cff808080(' .. version .. ')|r';
        end
        self.addons[addonName] = {
            title = title,
            notes = notes,
        };
        if isLoaded and addonName ~= thisAddonName then
            self:ADDON_LOADED(addonName);
        end
    end

    self.eventFrame:SetScript('OnEvent', function(_, event, ...)
        if self[event] then self[event](self, ...); end
    end);
    self.eventFrame:RegisterEvent('ADDON_LOADED');

    self:StartPurgeTicker();
    SLASH_NUMY_ADDON_PROFILER1 = '/nap';
    SLASH_NUMY_ADDON_PROFILER2 = '/addonprofile';
    SLASH_NUMY_ADDON_PROFILER3 = '/addonprofiler';
    SLASH_NUMY_ADDON_PROFILER4 = '/addoncpu';
    SlashCmdList['NUMY_ADDON_PROFILER'] = function(message)
        if message == 'reset' then
            wipe(self.db.minimap);
            self.db.minimap.hide = false;

            local name = 'NumyAddonProfiler';
            LibStub('LibDBIcon-1.0'):Hide(name);
            LibStub('LibDBIcon-1.0'):Show(name);

            return;
        end
        self:ToggleFrame();
    end;
    RunNextFrame(function()
        if NumyProfiler then -- the irony of profiling the profiler (-:
            self.OnUpdateActiveMode = NumyProfiler:Wrap(thisAddonName, 'ProfilerCore', 'OnUpdateActiveMode', self.OnUpdateActiveMode);
            self.OnUpdatePerformanceMode = NumyProfiler:Wrap(thisAddonName, 'ProfilerCore', 'OnUpdatePerformanceMode', self.OnUpdatePerformanceMode);
            self.PurgeOldData = NumyProfiler:Wrap(thisAddonName, 'ProfilerCore', 'PurgeOldData', self.PurgeOldData);
        end

        self:SwitchMode(self.db.mode);
    end);
end

local HEADER_IDS = {
    addonTitle = "addonTitle",
    encounterAvgMs = "encounterAvgMs",
    peakTimeMs = "peakTimeMs",
    averageMs = "averageMs",
    totalMs = "totalMs",
    ["overCount-1"] = "overCount-1",
    ["overCount-5"] = "overCount-5",
    ["overCount-10"] = "overCount-10",
    ["overCount-50"] = "overCount-50",
    ["overCount-100"] = "overCount-100",
    ["overCount-500"] = "overCount-500",
    ["overCount-1000"] = "overCount-1000",
    spikeSumMs = "spikeSumMs",
}

function NAP:InitDB()
    if not AddonProfilerDB then
        AddonProfilerDB = {};
    end
    self.db = AddonProfilerDB;

    local defaultShownColumns = {
        [HEADER_IDS.addonTitle] = true,
        [HEADER_IDS.encounterAvgMs] = true,
        [HEADER_IDS.peakTimeMs] = true,
        [HEADER_IDS.averageMs] = true,
        [HEADER_IDS.totalMs] = true,
        [HEADER_IDS['overCount-1']] = true,
        [HEADER_IDS['overCount-5']] = true,
        [HEADER_IDS['overCount-10']] = true,
        [HEADER_IDS['overCount-50']] = true,
        [HEADER_IDS['overCount-100']] = true,
        [HEADER_IDS['overCount-500']] = true,
        [HEADER_IDS['overCount-1000']] = true,
        [HEADER_IDS.spikeSumMs] = true,
    };
    self.db.shownColumns = self.db.shownColumns or {};
    for columnID, shown in pairs(defaultShownColumns) do
        if self.db.shownColumns[columnID] == nil then
            self.db.shownColumns[columnID] = shown;
        end
    end

    self.db.mode = self.db.mode or ACTIVE_MODE;

    self.db.minimap = self.db.minimap or {};
    self.db.minimap.hide = self.db.minimap.hide or false;
end

function NAP:ADDON_LOADED(addonName)
    if thisAddonName == addonName then
        self:InitDB();
        AddonProfilerDB = AddonProfilerDB or {};
        self.db = AddonProfilerDB;
        self:InitUI();
        self:InitMinimapButton();
    end
    if 'BlizzMove' == addonName then
        self:RegisterIntoBlizzMove();
    end
    if not self.addons[addonName] then return end

    self.loadedAddons[addonName] = true;
    self.addons[addonName].loaded = true;
    self.totalMs[addonName] = 0;
    self.loadedAtTick[addonName] = self.tickNumber;
    self.peakMs[addonName] = 0;
    self.snapshots.lastBucket.lastTick[addonName] = {};
    for ms in pairs(msMetricMap) do
        self.snapshots.lastBucket[ms][addonName] = {};
    end
    self.resetBaselineMetrics[addonName] = self:GetCurrentMsSpikeMetrics(addonName);
end

function NAP:SwitchMode(newMode)
    if newMode == self.mode then
        return;
    end
    local historyDropdown = self.ProfilerFrame.HistoryDropdown;
    self.mode = newMode;
    if newMode == ACTIVE_MODE then
        self.eventFrame:SetScript('OnUpdate', function() self:OnUpdateActiveMode() end);
        historyDropdown:Show();
    elseif newMode == PERFORMANCE_MODE then
        self.eventFrame:SetScript('OnUpdate', function() self:OnUpdatePerformanceMode() end);
        historyDropdown:Hide();
    else
        self.eventFrame:SetScript('OnUpdate', nil);
        historyDropdown:Hide();
    end
    self:ResetMetrics();
end

function NAP:OnUpdateActiveMode()
    self.tickNumber = self.tickNumber + 1;

    local lastBucket = self.snapshots.lastBucket;

    local curTickIndex = lastBucket.curTickIndex + 1;
    lastBucket.curTickIndex = curTickIndex;
    lastBucket.tickMap[curTickIndex] = GetTime();

    local lastTick = lastBucket.lastTick;
    local totalMs = self.totalMs;
    local peakMs = self.peakMs;

    local overallLastTickMs = C_AddOnProfiler_GetOverallMetric(Enum_AddOnProfilerMetric_LastTime);
    if overallLastTickMs > 0 then
        totalMs[TOTAL_ADDON_METRICS_KEY] = totalMs[TOTAL_ADDON_METRICS_KEY] + overallLastTickMs;
        lastTick[TOTAL_ADDON_METRICS_KEY][curTickIndex] = overallLastTickMs;
        if overallLastTickMs > peakMs[TOTAL_ADDON_METRICS_KEY] then
            peakMs[TOTAL_ADDON_METRICS_KEY] = overallLastTickMs;
        end
    end

    for addonName in pairs(self.loadedAddons) do
        local lastTickMs = C_AddOnProfiler_GetAddOnMetric(addonName, Enum_AddOnProfilerMetric_LastTime);
        if lastTickMs > 0 then
            totalMs[addonName] = totalMs[addonName] + lastTickMs;
            lastTick[addonName][curTickIndex] = lastTickMs;
            if lastTickMs > peakMs[addonName] then
                peakMs[addonName] = lastTickMs;
            end
        end
    end
end

--- performance mode OnUpdate script
--- right now the only difference is that it doesn't store the lastTickMs
--- more differences might come up in the future
function NAP:OnUpdatePerformanceMode()
    self.tickNumber = self.tickNumber + 1;

    local totalMs = self.totalMs;
    local peakMs = self.peakMs;

    local overallLastTickMs = C_AddOnProfiler_GetOverallMetric(Enum_AddOnProfilerMetric_LastTime);
    if overallLastTickMs > 0 then
        totalMs[TOTAL_ADDON_METRICS_KEY] = totalMs[TOTAL_ADDON_METRICS_KEY] + overallLastTickMs;
        if overallLastTickMs > peakMs[TOTAL_ADDON_METRICS_KEY] then
            peakMs[TOTAL_ADDON_METRICS_KEY] = overallLastTickMs;
        end
    end

    for addonName in pairs(self.loadedAddons) do
        local lastTickMs = C_AddOnProfiler_GetAddOnMetric(addonName, Enum_AddOnProfilerMetric_LastTime);
        if lastTickMs > 0 then
            totalMs[addonName] = totalMs[addonName] + lastTickMs;
            if lastTickMs > peakMs[addonName] then
                peakMs[addonName] = lastTickMs;
            end
        end
    end
end

function NAP:InitNewBucket()
    local lastBucket = { curTickIndex = 0, tickMap = {}, lastTick = { [TOTAL_ADDON_METRICS_KEY] = {} } };
    for ms in pairs(msMetricMap) do
        lastBucket[ms] = {};
    end
    for addonName in pairs(self.loadedAddons) do
        lastBucket.lastTick[addonName] = {};
    end

    t_insert(self.snapshots.buckets, lastBucket);
    self.snapshots.lastBucket = lastBucket;

    return lastBucket;
end

local BUCKET_CUTOFF = 2000; -- rather arbitrary number, but interestingly, the lower your fps, the less often actual work will be performed to purge old data ^^
function NAP:PurgeOldData()
    if self.mode ~= ACTIVE_MODE then -- only active mode uses buckets
        return;
    end
    if self.snapshots.lastBucket.curTickIndex > BUCKET_CUTOFF then
        self:InitNewBucket();
    end

    local buckets = self.snapshots.buckets
    local firstBucket = buckets[1];
    if not buckets[2] or not firstBucket.tickMap[1] then
        return;
    end

    local timestamp = GetTime();
    local cutoff = timestamp - HISTORY_RANGES[#HISTORY_RANGES];

    if firstBucket.tickMap[1] > cutoff then
        return;
    end

    local to;
    for i, bucket in ipairs(buckets) do
        if bucket.tickMap[1] and bucket.tickMap[1] > cutoff then
            to = i - 1;
            break;
        end
    end

    if to and to > 1 then
        t_removemulti(buckets, 1, to);
    end
end

function NAP:StartPurgeTicker()
    if self.purgerTicker then
        self.purgerTicker:Cancel()
    end

    self.collectData = true;
    -- continiously purge older entires
    self.purgerTicker = C_Timer.NewTicker(5, function() self:PurgeOldData() end)
end

function NAP:ResetMetrics()
    self.resetBaselineMetrics = self:GetCurrentMsSpikeMetrics();
    self.tickNumber = 0;
    self.resetTime = GetTime();
    self.snapshots.buckets = {};
    self:InitNewBucket();
    for addonName in pairs(self.loadedAddons) do
        self.totalMs[addonName] = 0;
        self.peakMs[addonName] = 0;
        self.loadedAtTick[addonName] = 0;
    end
    self.totalMs[TOTAL_ADDON_METRICS_KEY] = 0;
    self.peakMs[TOTAL_ADDON_METRICS_KEY] = 0;
end

function NAP:GetCurrentMsSpikeMetrics(onlyForAddonName)
    local currentMetrics = {};
    if not onlyForAddonName then
        currentMetrics[TOTAL_ADDON_METRICS_KEY] = {};
        for metric, ms in pairs(resettableMetrics) do
            currentMetrics[TOTAL_ADDON_METRICS_KEY][ms] = C_AddOnProfiler_GetOverallMetric(metric);
        end
        for addonName in pairs(self.loadedAddons) do
            currentMetrics[addonName] = {};
            for metric, ms in pairs(resettableMetrics) do
                currentMetrics[addonName][ms] = C_AddOnProfiler_GetAddOnMetric(addonName, metric);
            end
        end
    else
        if TOTAL_ADDON_METRICS_KEY == onlyForAddonName then
            for metric, ms in pairs(resettableMetrics) do
                currentMetrics[ms] = C_AddOnProfiler_GetOverallMetric(metric);
            end
        else
            for metric, ms in pairs(resettableMetrics) do
                currentMetrics[ms] = C_AddOnProfiler_GetAddOnMetric(onlyForAddonName, metric);
            end
        end
    end

    return currentMetrics;
end

function NAP:GetActiveHistoryRange()
    return self.db.mode == ACTIVE_MODE and self.curHistoryRange or INFINITE_HISTORY;
end

---@class NAP_ElementData
---@field addonName string
---@field addonTitle string
---@field addonNotes string
---@field peakTime number
---@field encounterAvg number
---@field averageMs number
---@field totalMs number
---@field numberOfTicks number
---@field over1Ms number
---@field over5Ms number
---@field over10Ms number
---@field over50Ms number
---@field over100Ms number
---@field over500Ms number
---@field over1000Ms number
---@field overMsSum number

--- @param forceUpdate boolean
--- @return table<NAP_Bucket, number>? bucketsWithinHistory
function NAP:PrepareFilteredData(forceUpdate)
    local now = self.frozenAt or GetTime();

    local minTimestamp = now - self:GetActiveHistoryRange();

    local prevTimestamp = self.minTimeStamp;
    local prevMatch = self.prevMatch;

    if not forceUpdate and prevTimestamp == minTimestamp and prevMatch == self.curMatch then
        return nil;
    end

    t_wipe(self.filteredData);
    self.dataProvider = nil;
    self.minTimeStamp = minTimestamp;
    self.prevMatch = self.curMatch;

    local withinHistory = {};
    if INFINITE_HISTORY ~= self:GetActiveHistoryRange() then
        for _, bucket in ipairs(self.snapshots.buckets) do
            if bucket.tickMap and bucket.tickMap[bucket.curTickIndex] and bucket.tickMap[bucket.curTickIndex] > minTimestamp then
                for tickIndex, timestamp in pairs(bucket.tickMap) do
                    if timestamp > minTimestamp then
                        withinHistory[bucket] = tickIndex;
                        break;
                    end
                end
            end
        end
    end

    for addonName in pairs(self.loadedAddons) do
        local info = self.addons[addonName];
        if info.title:lower():match(self.curMatch) then
            t_insert(self.filteredData, self:GetElelementDataForAddon(addonName, info, withinHistory));
        end
    end

    self.dataProvider = CreateDataProvider(self.filteredData)
    if self.sortComparator then
        self.dataProvider:SetSortComparator(self.sortComparator)
    end

    return withinHistory;
end

---@param addonName string
---@param info { title: string, notes: string, loaded: boolean }
---@param bucketsWithinHistory table<NAP_Bucket, number>
---@return NAP_ElementData
function NAP:GetElelementDataForAddon(addonName, info, bucketsWithinHistory)
    ---@type NAP_ElementData
    ---@diagnostic disable-next-line: missing-fields
    local data = {
        addonName = addonName,
        addonTitle = info.title,
        addonNotes = info.notes,
        peakTime = 0,
        averageMs = 0,
        totalMs = 0,
        numberOfTicks = 0,
    };
    if TOTAL_ADDON_METRICS_KEY == addonName then
        data.encounterAvg = C_AddOnProfiler_GetOverallMetric(Enum_AddOnProfilerMetric_EncounterAverageTime);
    else
        data.encounterAvg = C_AddOnProfiler_GetAddOnMetric(addonName, Enum_AddOnProfilerMetric_EncounterAverageTime);
    end
    for _, ms in pairs(msOptions) do
        data[msOptionFieldMap[ms]] = 0;
    end
    if INFINITE_HISTORY == self:GetActiveHistoryRange() then
        local currentMetrics = self.frozenMetrics and self.frozenMetrics[addonName] or self:GetCurrentMsSpikeMetrics(addonName);
        for ms in pairs(msMetricMap) do
            local currentMetric = currentMetrics[ms] or 0;
            local baselineMetric = self.resetBaselineMetrics[addonName][ms] or 0;
            local adjustedValue = currentMetric - baselineMetric;
            data[msOptionFieldMap[ms]] = adjustedValue;
        end
        data.peakTime = self.peakMs[addonName];
        data.totalMs = self.totalMs[addonName];
        data.numberOfTicks = self.tickNumber - self.loadedAtTick[addonName];
    else
        for bucket, startingTickIndex in pairs(bucketsWithinHistory) do
            data.numberOfTicks = data.numberOfTicks + ((bucket.curTickIndex - startingTickIndex) + 1);
            for tickIndex = startingTickIndex, bucket.curTickIndex do
                local tickMs = bucket.lastTick[addonName] and bucket.lastTick[addonName][tickIndex];
                if tickMs and tickMs > 0 then
                    if tickMs > data.peakTime then
                        data.peakTime = tickMs;
                    end
                    data.totalMs = data.totalMs + tickMs;
                    -- hardcoded for performance
                    if tickMs > 1 then
                        data.over1Ms = data.over1Ms + 1;
                        if tickMs > 5 then
                            data.over5Ms = data.over5Ms + 1;
                            if tickMs > 10 then
                                data.over10Ms = data.over10Ms + 1;
                                if tickMs > 50 then
                                    data.over50Ms = data.over50Ms + 1;
                                    if tickMs > 100 then
                                        data.over100Ms = data.over100Ms + 1;
                                        if tickMs > 500 then
                                            data.over500Ms = data.over500Ms + 1;
                                            if tickMs > 1000 then
                                                data.over1000Ms = data.over1000Ms + 1;
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    data.averageMs = data.totalMs / data.numberOfTicks;

    data.overMsSum = 0;
    local previousGroupCount = 0;
    for _, ms in ipairs_reverse(msOptions) do
        data[msOptionFieldMap[ms]] = data[msOptionFieldMap[ms]] or 0;
        local count = data[msOptionFieldMap[ms]];
        data.overMsSum = data.overMsSum + ((count - previousGroupCount) * ms);
        previousGroupCount = count;
    end

    return data;
end

function NAP:InitUI()
    self.filteredData = {};
    self.dataProvider = nil;
    self.curMatch = ".+"

    local ORDER_ASC = 1;
    local ORDER_DESC = -1;

    local msText = "|cff808080ms|r";
    local xText = "|cff808080x|r";
    local greyColorFormat = "|cff808080%s|r";
    local whiteColorFormat = "|cfff8f8f2%s|r";

    local TIME_FORMAT = function(val) return (val > 0 and whiteColorFormat or greyColorFormat):format(("%.3f"):format(val)) .. msText; end;
    local ROUND_TIME_FORMAT = function(val) return (val > 0 and whiteColorFormat or greyColorFormat):format(val) .. msText; end;
    local COUNTER_FORMAT = function(val) return (val > 0 and whiteColorFormat or greyColorFormat):format(val) .. xText; end;
    local RAW_FORMAT = function(val) return val; end;

    local COLUMN_INFO = {};
    do
        local function makeSortMethods(key)
            return {
                ---@param a NAP_ElementData
                ---@param b NAP_ElementData
                [ORDER_ASC] = function(a, b)
                    return a[key] < b[key] or (a[key] == b[key] and a.addonName < b.addonName);
                end,
                ---@param a NAP_ElementData
                ---@param b NAP_ElementData
                [ORDER_DESC] = function(a, b)
                    return a[key] > b[key] or (a[key] == b[key] and a.addonName < b.addonName);
                end,
            };
        end
        local counter = CreateCounter();
        -- the IDs/keys should not be changed, they're persistent in SVs to remember whether they're toggled on or off
        COLUMN_INFO[HEADER_IDS.addonTitle] = {
            ID = HEADER_IDS.addonTitle,
            order = counter(),
            justifyLeft = true,
            title = "Addon Name",
            width = 300,
            textFormatter = RAW_FORMAT,
            textKey = "addonTitle",
            sortMethods = {
                ---@param a NAP_ElementData
                ---@param b NAP_ElementData
                [ORDER_ASC] = function(a, b)
                    return strcmputf8i(StripHyperlinks(a.addonTitle), StripHyperlinks(b.addonTitle)) > 0
                end,
                ---@param a NAP_ElementData
                ---@param b NAP_ElementData
                [ORDER_DESC] = function(a, b)
                    return strcmputf8i(StripHyperlinks(a.addonTitle), StripHyperlinks(b.addonTitle)) < 0
                end,
            },
        };
        COLUMN_INFO[HEADER_IDS.encounterAvgMs] = {
            ID = HEADER_IDS.encounterAvgMs,
            order = counter(),
            title = "Boss Avg",
            width = 96,
            textFormatter = TIME_FORMAT,
            textKey = "encounterAvg",
            tooltip = "Average CPU time spent per frame during a boss encounter. Ignores the History Range",
            sortMethods = makeSortMethods("encounterAvg"),
        };
        COLUMN_INFO[HEADER_IDS.peakTimeMs] = {
            ID = HEADER_IDS.peakTimeMs,
            order = counter(),
            title = "Peak Time",
            width = 96,
            textFormatter = TIME_FORMAT,
            textKey = "peakTime",
            tooltip = "Biggest spike in ms, within the History Range.",
            sortMethods = makeSortMethods("peakTime"),
        };
        COLUMN_INFO[HEADER_IDS.averageMs] = {
            ID = HEADER_IDS.averageMs,
            order = counter(),
            title = "Average",
            width = 96,
            textFormatter = TIME_FORMAT,
            textKey = "averageMs",
            tooltip = "Average CPU time spent per frame.",
            sortMethods = makeSortMethods("averageMs"),
        };
        COLUMN_INFO[HEADER_IDS.totalMs] = {
            ID = HEADER_IDS.totalMs,
            order = counter(),
            title = "Total",
            width = 108,
            textFormatter = TIME_FORMAT,
            textKey = "totalMs",
            tooltip = "Total CPU time spent, within the History Range.",
            sortMethods = makeSortMethods("totalMs"),
        };
        for _, ms in ipairs(msOptions) do
            COLUMN_INFO[HEADER_IDS["overCount-" .. ms]] = {
                ID = HEADER_IDS["overCount-" .. ms],
                order = counter(),
                title = "Over " .. ms .. "ms",
                width = 80 + (strlen(ms) * 5),
                textFormatter = COUNTER_FORMAT,
                textKey = msOptionFieldMap[ms],
                tooltip = "How many times the addon took longer than " .. ms .. "ms per frame.",
                sortMethods = makeSortMethods(msOptionFieldMap[ms]),
            };
        end
        COLUMN_INFO[HEADER_IDS.spikeSumMs] = {
            ID = HEADER_IDS.spikeSumMs,
            order = counter(),
            title = "Spike Sum",
            width = 96,
            textFormatter = ROUND_TIME_FORMAT,
            textKey = "overMsSum",
            tooltip = "Sum of all the separate spikes.",
            sortMethods = makeSortMethods("overMsSum"),
        };
    end

    local activeSort, activeOrder = HEADER_IDS.averageMs, ORDER_DESC

    local UPDATE_INTERVAL = 1
    local continuousUpdate = true

    local function updateSortComparator()
        self.sortComparator = COLUMN_INFO[activeSort].sortMethods[activeOrder]
        if self.dataProvider then
            self.dataProvider:SetSortComparator(self.sortComparator)
        end
    end
    updateSortComparator()

    -------------
    -- DISPLAY --
    -------------
    do
        local ROW_HEIGHT = 20

        self.ProfilerFrame = CreateFrame("Frame", "NumyAddonProfilerFrame", UIParent, "ButtonFrameTemplate")
        local display = self.ProfilerFrame
        do
            function display:OnUpdate(elapsed)
                self.elapsed = (self.elapsed or 0) + elapsed
                if self.elapsed >= UPDATE_INTERVAL then
                    self:DoUpdate()
                end
            end

            function display:DoUpdate(force)
                local bucketsWithinHistory = NAP:PrepareFilteredData(force)
                self.TotalRow:Update(bucketsWithinHistory)

                local perc = self.ScrollBox:GetScrollPercentage()
                self.ScrollBox:Flush()

                if NAP.dataProvider then
                    self.ScrollBox:SetDataProvider(NAP.dataProvider)
                    self.ScrollBox:SetScrollPercentage(perc)
                end

                self.Stats:Update()

                self.elapsed = 0
            end

            function display:OnShow()
                self.elapsed = UPDATE_INTERVAL

                if continuousUpdate then
                    self:SetScript("OnUpdate", self.OnUpdate)
                end
            end

            function display:OnHide()
                self:SetScript("OnUpdate", nil)
            end
            display.activeColumns = {}
            for ID, info in pairs(COLUMN_INFO) do
                if NAP.db.shownColumns[ID] then
                    t_insert(display.activeColumns, info)
                end
            end
            table.sort(display.activeColumns, function(a, b) return a.order < b.order end)

            t_insert(UISpecialFrames, self.ProfilerFrame:GetName())
            display:SetPoint("CENTER", 0, 0)
            display:SetMovable(true)
            display:EnableMouse(true)
            display:SetToplevel(true)
            display:SetScript("OnShow", display.OnShow)
            display:SetScript("OnHide", display.OnHide)
            display:Hide()

            function display:UpdateWidth()
                local width = 40;
                for _, info in pairs(self.activeColumns) do
                    width = width + (info.width - 2)
                end
                display:SetSize(width, 651)
            end
            display:UpdateWidth()

            ButtonFrameTemplate_HidePortrait(display)

            display:SetTitle("|cffe03d02Numy:|r Addon Profiler")

            display.Inset:SetPoint("TOPLEFT", 8, (-86) - ROW_HEIGHT)
            display.Inset:SetPoint("BOTTOMRIGHT", -4, 30)

            function display:HideHeader(headerID)
                if headerID == 'addonTitle' then
                    return
                end
                for index, column in pairs(self.activeColumns) do
                    if column.ID == headerID then
                        t_remove(self.activeColumns, index)
                        break
                    end
                end
                self:UpdateHeaders()
                self:DoUpdate(true)
            end

            function display:ShowHeader(headerID)
                local info
                for ID, column in pairs(COLUMN_INFO) do
                    if ID == headerID then
                        info = column
                        break
                    end
                end
                t_insert(self.activeColumns, info)
                table.sort(self.activeColumns, function(a, b) return a.order < b.order end)
                self:UpdateHeaders()
                self:DoUpdate(true)
            end

            function display:UpdateHeaders()
                self:UpdateWidth()

                local headers = self.Headers
                headers:LayoutColumns(self.activeColumns)

                local RightClickAtlasMarkup = CreateAtlasMarkup('NPE_RightClick', 18, 18);
                local LeftClickAtlasMarkup = CreateAtlasMarkup('NPE_LeftClick', 18, 18);

                --- @type FramePool<BUTTON,ColumnDisplayButtonTemplate>
                local headerPool = headers.columnHeaders
                for header in headerPool:EnumerateActive() do
                    if header.initialized then
                        return
                    end
                    local arrow = header:CreateTexture("OVERLAY")
                    arrow:SetAtlas("auctionhouse-ui-sortarrow", true)
                    arrow:SetPoint("LEFT", header:GetFontString(), "RIGHT", 0, 0)
                    arrow:Hide()
                    header.Arrow = arrow

                    header:SetScript("OnEnter", function(self)
                        local info = display.activeColumns[self:GetID()]
                        GameTooltip:SetOwner(self, "ANCHOR_TOP")
                        GameTooltip:AddLine(self:GetText())
                        if info.tooltip then
                            GameTooltip:AddLine(info.tooltip, 1, 1, 1, true)
                        end
                        GameTooltip_AddInstructionLine(GameTooltip, LeftClickAtlasMarkup .. " Click to sort")
                        GameTooltip_AddInstructionLine(GameTooltip, RightClickAtlasMarkup .. " Right-click to show / hide columns")

                        GameTooltip:Show()
                    end)
                    header:SetScript("OnLeave", function()
                        GameTooltip:Hide()
                    end)
                    header:SetScript("OnClick", function(self, button)
                        headers:OnHeaderClick(self:GetID(), button, self)
                    end)
                    header:RegisterForClicks("AnyUp", "AnyDown")
                end
            end
        end

        local titleBar = CreateFrame("Frame", nil, display, "PanelDragBarTemplate")
        display.TitleBar = titleBar
        do
            titleBar:SetPoint("TOPLEFT", 0, 0)
            titleBar:SetPoint("BOTTOMRIGHT", display, "TOPRIGHT", 0, -32)
            titleBar:Init(display)
        end

        local historyMenu = CreateFrame("DropdownButton", nil, display, "WowStyle1DropdownTemplate");
        display.HistoryDropdown = historyMenu
        do
            historyMenu:SetPoint("TOPRIGHT", -11, -32);
            historyMenu:SetWidth(150);
            historyMenu:SetFrameLevel(3);
            historyMenu:OverrideText("History Range");
            local historyOptions = {};
            for _, range in ipairs(HISTORY_RANGES) do
                local text = SecondsToTime(range, false, true);
                if range == 0 then
                    text = "Since Reset/Reload";
                end
                t_insert(historyOptions, {text, range});
            end
            local function isSelected(data)
                return data == self.curHistoryRange;
            end
            local function onSelection(data)
                self.curHistoryRange = data;

                display.elapsed = UPDATE_INTERVAL
            end
            MenuUtil.CreateRadioMenu(historyMenu, isSelected, onSelection, unpack(historyOptions));
        end

        local search = CreateFrame("EditBox", "$parentSearchBox", display, "SearchBoxTemplate")
        do
            search:SetFrameLevel(3)
            search:SetPoint("TOPLEFT", 16, -31)
            search:SetSize(288, 22)
            search:SetAutoFocus(false)
            search:SetHistoryLines(1)
            search:SetMaxBytes(64)
            search:HookScript("OnTextChanged", function(self)
            local text = s_trim(self:GetText()):lower()
            NAP.curMatch = text == "" and ".+" or text

            display.elapsed = 50
        end)
        end

        local headers = CreateFrame("Button", "$parentHeaders", display, "ColumnDisplayTemplate")
        display.Headers = headers
        do
            headers:SetPoint("BOTTOMLEFT", display.Inset, "TOPLEFT", 1, ROW_HEIGHT + 1)
            headers:SetPoint("BOTTOMRIGHT", display.Inset, "TOPRIGHT", 0, -1)

            function headers:UpdateArrow(index)
                --- @type FramePool<BUTTON,ColumnDisplayButtonTemplate>
                local headerPool = headers.columnHeaders
                for header in headerPool:EnumerateActive() do
                    if header:GetID() == index then
                        header.Arrow:Show()

                        if activeOrder == ORDER_ASC then
                            header.Arrow:SetTexCoord(0, 1, 1, 0)
                        else
                            header.Arrow:SetTexCoord(0, 1, 0, 1)
                        end
                    else
                        header.Arrow:Hide()
                    end
                end
            end

            function headers:OnHeaderClick(index, button, headerFrame)
                if button == "LeftButton" then
                    local columnID = display.activeColumns[index].ID
                    local columnChanged = activeSort ~= columnID
                    activeSort = columnID

                    if columnChanged then
                        activeOrder = ORDER_DESC
                    else
                        activeOrder = activeOrder == ORDER_DESC and ORDER_ASC or ORDER_DESC
                    end
                    updateSortComparator()

                    self:UpdateArrow(index)
                elseif button == "RightButton" then
                    local headerOptions = {}
                    for ID, info in pairs(COLUMN_INFO) do
                        if ID ~= "addonTitle" then
                            t_insert(headerOptions, {info.title, info})
                        end
                    end
                    table.sort(headerOptions, function(a, b) return a[2].order < b[2].order end)
                    local function isSelected(data)
                        return NAP.db.shownColumns[data.ID] or false
                    end
                    local function onSelection(data)
                        if NAP.db.shownColumns[data.ID] then
                            NAP.db.shownColumns[data.ID] = false
                            display:HideHeader(data.ID)
                        else
                            NAP.db.shownColumns[data.ID] = true
                            display:ShowHeader(data.ID)
                        end
                        return MenuResponse.Refresh
                    end
                    MenuUtil.CreateCheckboxContextMenu(nil, isSelected, onSelection, unpack(headerOptions))
                end
            end

            headers:UpdateArrow(activeSort)
            headers.Background:Hide()
            headers.TopTileStreaks:Hide()
            display:UpdateHeaders()
        end

        local scrollBox = CreateFrame("Frame", "$parentScrollBox", display, "WowScrollBoxList")
        display.ScrollBox = scrollBox
        do
            scrollBox:SetPoint("TOPLEFT", display.Inset, "TOPLEFT", 4, -3)
            scrollBox:SetPoint("BOTTOMRIGHT", display.Inset, "BOTTOMRIGHT", -22, 2)

            local function alternateBG()
                local index = scrollBox:GetDataIndexBegin()
                scrollBox:ForEachFrame(function(button)
                    if index % 2 == 0 then
                        button.BG:SetColorTexture(0.1, 0.1, 0.1, 1)
                    else
                        button.BG:SetColorTexture(0.14, 0.14, 0.14, 1)
                    end

                    index = index + 1
                end)
            end
            scrollBox:RegisterCallback("OnDataRangeChanged", alternateBG, display)
        end

        local scrollBar = CreateFrame("EventFrame", "$parentScrollBar", display, "MinimalScrollBar")
        do
            scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 4, -4)
            scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 4, 4)
            local thumb = scrollBar.Track.Thumb;
            local mouseDown = false
            thumb:HookScript("OnMouseDown", function(self, button)
                if button ~= "LeftButton" then return end
                mouseDown = true
                self:RegisterEvent("GLOBAL_MOUSE_UP")
            end)
            thumb:HookScript("OnEvent", function(self, event, ...)
            if event == "GLOBAL_MOUSE_UP" then
                local button = ...
                if button ~= "LeftButton" then return end
                if mouseDown then
                    scrollBar.onButtonMouseUp(self, button)
                end
                mouseDown = false
            end
        end)
        end

        --- @class NAP_RowMixin: BUTTON
        --- @field BG Texture?
        --- @field columnPool ObjectPool<FontString>
        --- @field initialized boolean
        --- @field GetElementData fun(self): NAP_ElementData
        local rowMixin = {}
        local initRow;
        do
            function rowMixin:OnEnter()
                local data = self:GetElementData()
                if data then
                    GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT", 5, 5)
                    GameTooltip:AddLine(data.addonTitle)
                    GameTooltip:AddLine(data.addonName, 1, 1, 1)
                    local notes = data.addonNotes
                    if notes and notes ~= "" then
                        GameTooltip:AddLine(notes, 1, 1, 1, true)
                    end
                    GameTooltip:AddLine(" ")
                    if data.addonName == thisAddonName then
                        GameTooltip:AddLine("|cnNORMAL_FONT_COLOR:Note:|r The profiler has to do a lot of work while showing the UI, the numbers displayed here are not representative of the passive background CPU usage.", 1, 1, 1, true)
                        GameTooltip:AddLine(" ")
                    end
                    GameTooltip:AddDoubleLine("Peak CPU time:", TIME_FORMAT(data.peakTime), 1, 0.92, 0, 1, 1, 1)
                    GameTooltip:AddDoubleLine("Average CPU time per frame:", TIME_FORMAT(data.averageMs), 1, 0.92, 0, 1, 1, 1)
                    GameTooltip:AddDoubleLine("Total CPU time:", TIME_FORMAT(data.totalMs), 1, 0.92, 0, 1, 1, 1)
                    GameTooltip:AddDoubleLine("Number of frames:", RAW_FORMAT(data.numberOfTicks), 1, 0.92, 0, 1, 1, 1)
                    GameTooltip:Show()
                end
            end

            function rowMixin:OnLeave()
                GameTooltip:Hide()
            end

            function rowMixin:UpdateColumns()
                local rowWidth = scrollBox:GetWidth() - 4
                local offSet = 2
                local padding = 4

                self:SetSize(rowWidth, ROW_HEIGHT)
                self.columnPool:ReleaseAll()

                for _, column in ipairs(display.activeColumns) do
                    local text = self.columnPool:Acquire()
                    text:Show()
                    text.column = column
                    if column.justifyLeft then
                        text:SetPoint("LEFT", offSet, 0)
                    else
                        text:SetPoint("RIGHT", (offSet + column.width - (padding * 2)) - rowWidth, 0)
                    end
                    text:SetSize(column.width - (padding * 2.5), 0)
                    text:SetJustifyH(column.justifyLeft and "LEFT" or "RIGHT")
                    text:SetWordWrap(false)
                    offSet = offSet + (column.width - (padding / 2))
                end
            end

            --- @param row BUTTON|NAP_RowMixin
            initRow = function(row)
                Mixin(row, rowMixin)
                row:SetHighlightTexture("Interface\\BUTTONS\\WHITE8X8")
                row:GetHighlightTexture():SetVertexColor(0.1, 0.1, 0.1, 0.75)
                row:SetScript("OnEnter", row.OnEnter)
                row:SetScript("OnLeave", row.OnLeave)

                local function init()
                    return row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                end
                local function reset(_, obj)
                    if not obj then return end
                    obj:ClearAllPoints()
                    obj:SetText("")
                    obj:Hide()
                end
                row.columnPool = CreateObjectPool(init, reset) --[[@as ObjectPool<FontString>]]

                local bg = row:CreateTexture(nil, "BACKGROUND")
                bg:SetPoint("TOPLEFT")
                bg:SetPoint("BOTTOMRIGHT")
                row.BG = bg
            end
        end
        --- @class NAP_TotalRow: NAP_RowMixin
        local totalRow = CreateFrame("Button", nil, display)
        display.TotalRow = totalRow
        do
            initRow(totalRow)
            totalRow:SetPoint("TOPLEFT", display.Headers, "BOTTOMLEFT", 5, -1)

            function totalRow:GetElementData()
                return self.data
            end

            function totalRow:Update(bucketsWithinHistory)
                if bucketsWithinHistory then
                    self.data = NAP:GetElelementDataForAddon(TOTAL_ADDON_METRICS_KEY, { title = "|cnNORMAL_FONT_COLOR:Addon Total|r", loaded = true, notes = "Stats for all addons combined" }, bucketsWithinHistory)
                end
                self:UpdateColumns()
                for columnText in self.columnPool:EnumerateActive() do
                    local column = columnText.column
                    columnText:SetText(column.textFormatter(self.data[column.textKey]))
                end
            end
        end

        local view = CreateScrollBoxListLinearView(2, 0, 2, 2, 2)
        do
            view:SetElementExtent(20)

            --- @param row BUTTON|NAP_RowMixin
            view:SetElementInitializer("BUTTON", function(row, data)
                if not row.initialized then
                    initRow(row)

                    row.initialized = true
                end

                row:UpdateColumns()
                for columnText in row.columnPool:EnumerateActive() do
                    local column = columnText.column
                    columnText:SetText(column.textFormatter(data[column.textKey]))
                end
            end)

            ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
        end

        local playButton = CreateFrame("Button", nil, display)
        display.PlayButton = playButton
        do
            playButton:SetPoint("BOTTOMLEFT", 4, 0)
            playButton:SetSize(32, 32)
            playButton:SetHitRectInsets(4, 4, 4, 4)
            playButton:SetNormalTexture("Interface\\Buttons\\UI-SquareButton-Up")
            playButton:SetPushedTexture("Interface\\Buttons\\UI-SquareButton-Down")
            playButton:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")

            local playIcon = playButton:CreateTexture("OVERLAY")
            playButton.Icon = playIcon
            do
                playIcon:SetSize(11, 15)
                playIcon:SetPoint("CENTER")
                playIcon:SetBlendMode("ADD")
                playIcon:SetTexCoord(10 / 32, 21 / 32, 9 / 32, 24 / 32)
            end

            playButton:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT", -6, -4)
                GameTooltip:AddLine(continuousUpdate and "Pause" or "Resume")
                GameTooltip:Show()
            end)

            playButton:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)

            playButton:SetScript("OnMouseDown", function(self)
                self.Icon:SetPoint("CENTER", -2, -2)
            end)

            playButton:SetScript("OnMouseUp", function(self)
                self.Icon:SetPoint("CENTER", 0, 0)
            end)

            playButton:SetScript("OnClick", function(self)
                continuousUpdate = not continuousUpdate
                if continuousUpdate then
                    self.Icon:SetTexture("Interface\\TimeManager\\PauseButton")
                    self.Icon:SetVertexColor(0.84, 0.81, 0.52)

                    display:SetScript("OnUpdate", display.OnUpdate)
                    display.UpdateButton:Disable()
                else
                    self.Icon:SetTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
                    self.Icon:SetVertexColor(1, 1, 1)

                    display:SetScript("OnUpdate", nil)
                    display.UpdateButton:Enable()
                end

                if GameTooltip:IsOwned(self) then
                    self:GetScript("OnEnter")(self)
                end

                display.Stats:Update()
            end)

            playButton:SetScript("OnShow", function(self)
                if continuousUpdate then
                    self.Icon:SetTexture("Interface\\TimeManager\\PauseButton")
                    self.Icon:SetVertexColor(0.84, 0.81, 0.52)
                else
                    self.Icon:SetTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
                    self.Icon:SetVertexColor(1, 1, 1)
                end

                self.Icon:SetPoint("CENTER")
            end)
        end

        local updateButton = CreateFrame("Button", nil, display)
        display.UpdateButton = updateButton
        do
            updateButton:SetPoint("LEFT", playButton, "RIGHT", -6, 0)
            updateButton:SetSize(32, 32)
            updateButton:SetHitRectInsets(4, 4, 4, 4)
            updateButton:SetNormalTexture("Interface\\Buttons\\UI-SquareButton-Up")
            updateButton:SetPushedTexture("Interface\\Buttons\\UI-SquareButton-Down")
            updateButton:SetDisabledTexture("Interface\\Buttons\\UI-SquareButton-Disabled")
            updateButton:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        end

        local updateIcon = updateButton:CreateTexture("OVERLAY")
        updateButton.Icon = updateIcon
        do
            updateIcon:SetSize(16, 16)
            updateIcon:SetPoint("CENTER", -1, -1)
            updateIcon:SetBlendMode("ADD")
            updateIcon:SetTexture("Interface\\Buttons\\UI-RefreshButton")

            updateButton:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT", -6, -4)
                GameTooltip:AddLine("Update")
                GameTooltip:Show()
            end)

            updateButton:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)

            updateButton:SetScript("OnMouseDown", function(self)
                if self:IsEnabled() then
                    self.Icon:SetPoint("CENTER", -3, -3)
                end
            end)

            updateButton:SetScript("OnMouseUp", function(self)
                if self:IsEnabled() then
                    self.Icon:SetPoint("CENTER", -1, -1)
                end
            end)

            updateButton:SetScript("OnClick", function()
                display:DoUpdate(true)
            end)

            updateButton:SetScript("OnDisable", function(self)
                self.Icon:SetDesaturated(true)
                self.Icon:SetVertexColor(0.6, 0.6, 0.6)
            end)

            updateButton:SetScript("OnEnable", function(self)
                self.Icon:SetDesaturated(false)
                self.Icon:SetVertexColor(1, 1, 1)
            end)

            updateButton:SetScript("OnShow", function(self)
                if continuousUpdate then
                    self:Disable()
                else
                    self:Enable()
                end

                self.Icon:SetPoint("CENTER", -1, -1)
            end)
        end

        local stats = display:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        display.Stats = stats
        do
            stats:SetPoint("LEFT", updateButton, "RIGHT", 6, 0)
            stats:SetSize(300, 20)
            stats:SetJustifyH("LEFT")
            stats:SetWordWrap(false)

            local STATS_FORMAT = "|cfff8f8f2%s|r"
            function stats:Update()
                self:SetFormattedText(STATS_FORMAT, NAP.collectData and (continuousUpdate and "Live Updating List" or "Paused") or "List is |cffff0000frozen|r")
            end
        end

        self.ToggleButton = CreateFrame("Button", "$parentToggle", display, "UIPanelButtonTemplate, UIButtonTemplate")
        local toggleButton = self.ToggleButton
        do
            toggleButton:SetPoint("BOTTOM", 0, 6)
            toggleButton:SetText(self:IsLogging() and "Disable" or "Enable")
            DynamicResizeButton_Resize(toggleButton)

            toggleButton:SetOnClickHandler(function()
                if self:IsLogging() then
                    self:DisableLogging()
                else
                    self:EnableLogging()
                end
                display.Stats:Update()
            end)
        end

        local resetButton = CreateFrame("Button", "$parentReset", display, "UIPanelButtonTemplate, UIButtonTemplate")
        do
            resetButton:SetPoint("RIGHT", toggleButton, "LEFT", -6, 0)
            resetButton:SetText("Reset")
            DynamicResizeButton_Resize(resetButton)

            resetButton:SetOnClickHandler(function()
                self:ResetMetrics()

                RunNextFrame(function()
                    display.elapsed = UPDATE_INTERVAL
                end)
            end)
        end
    end
end

function NAP:IsLogging()
    return self.collectData
end

function NAP:EnableLogging()
    self.frozenAt = nil
    self.frozenMetrics = nil
    self:ResetMetrics()
    t_wipe(self.filteredData)
    self.dataProvider = nil

    self.ToggleButton:SetText("Disable")
    DynamicResizeButton_Resize(self.ToggleButton)

    self.eventFrame:Show()
    self:StartPurgeTicker()

    self.ProfilerFrame.ScrollBox:Flush()
end

function NAP:DisableLogging()
    self.frozenAt = GetTime()
    self.frozenMetrics = self:GetCurrentMsSpikeMetrics()
    self.ToggleButton:SetText("Enable")
    DynamicResizeButton_Resize(self.ToggleButton)

    self.collectData = false

    self.eventFrame:Hide()
    if self.purgerTicker then
        self.purgerTicker:Cancel()
    end
end

function NAP:ToggleFrame()
    self.ProfilerFrame:SetShown(not self.ProfilerFrame:IsShown())
end

function NAP:RegisterIntoBlizzMove()
    ---@type BlizzMoveAPI?
    local BlizzMoveAPI = BlizzMoveAPI;
    if BlizzMoveAPI then
        BlizzMoveAPI:RegisterAddOnFrames(
            {
                [thisAddonName] = {
                    [self.ProfilerFrame:GetName()] = {
                        SubFrames = {
                            [self.ProfilerFrame:GetName() .. '.TitleBar'] = {},
                            [self.ProfilerFrame:GetName() .. '.Headers'] = {},
                        },
                    },
                },
            }
        )
    end
end

function NAP:InitMinimapButton()
    local name = 'NumyAddonProfiler';
    local function getIcon()
        return self:IsLogging()
            and 'interface/icons/spell_nature_timestop'
            or 'interface/icons/timelesscoin-bloody';
    end
    local dataObject;
    dataObject = LibStub('LibDataBroker-1.1'):NewDataObject(
        name,
        {
            type = 'launcher',
            text = 'Addon Profiler',
            icon = getIcon(),
            OnClick = function(_, button)
                if IsShiftKeyDown() then
                    self.db.minimap.hide = true;
                    LibStub('LibDBIcon-1.0'):Hide(name);
                    print('Minimap button hidden. Use |cffeda55f/nap reset|r to restore.');

                    return;
                end
                if button == 'LeftButton' then
                    self:ToggleFrame();
                else
                    if self:IsLogging() then
                        self:DisableLogging();
                    else
                        self:EnableLogging();
                    end
                    dataObject.icon = getIcon();
                end
            end,
            OnTooltipShow = function(tooltip)
                tooltip:AddLine('Addon Profiler ' .. (
                    self:IsLogging()
                        and GREEN_FONT_COLOR:WrapTextInColorCode("enabled")
                        or RED_FONT_COLOR:WrapTextInColorCode("disabled")
                ))
                tooltip:AddLine('|cffeda55fLeft-Click|r to toggle the frame')
                tooltip:AddLine('|cffeda55fRight-Click|r to toggle logging')
                tooltip:AddLine('|cffeda55fShift-Click|r to hide this button. (|cffeda55f/nap reset|r to restore)');
            end,
        }
    );
    LibStub('LibDBIcon-1.0'):Register(name, dataObject, self.db.minimap);
end

NAP:Init();
