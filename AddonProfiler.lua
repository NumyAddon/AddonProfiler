local thisAddonName = ...

local s_trim = string.trim
local t_insert = table.insert
local t_removemulti = table.removemulti
local t_wipe = table.wipe
local pairs = pairs
local GetTime = GetTime

local C_AddOnProfiler_GetAddOnMetric = C_AddOnProfiler.GetAddOnMetric;
local C_AddOnProfiler_GetOverallMetric = C_AddOnProfiler.GetOverallMetric;
local Enum_AddOnProfilerMetric_LastTime = Enum.AddOnProfilerMetric.LastTime;
local Enum_AddOnProfilerMetric_RecentAverageTime = Enum.AddOnProfilerMetric.RecentAverageTime;
local Enum_AddOnProfilerMetric_EncounterAverageTime = Enum.AddOnProfilerMetric.EncounterAverageTime;
local Enum_AddOnProfilerMetric_PeakTime = Enum.AddOnProfilerMetric.PeakTime;

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

local HISTORY_TYPE_SINCE_RESET = 'sinceReset';
local HISTORY_TYPE_COMBAT = 'combat';
local HISTORY_TYPE_ENCOUNTER = 'encounter';
local HISTORY_TYPE_TIME_RANGE = 'timeRange';
local HISTORY_LATEST = -1;
local HISTORY_TIME_RANGES = {5, 15, 30, 60, 120, 300, 600} -- 5sec - 10min
NAP.currentHistorySelection = {
    type = HISTORY_TYPE_TIME_RANGE,
    timeRange = 30,
    encounterIndex = HISTORY_LATEST,
    combatIndex = HISTORY_LATEST,
};

--- @type table<string, table<string, number>> [addonName] = { [metricName] = value }
NAP.resetBaselineMetrics = {};

NAP.totalMs = { [TOTAL_ADDON_METRICS_KEY] = 0 };
NAP.loadedAtTick = { [TOTAL_ADDON_METRICS_KEY] = 0 };
NAP.tickNumber = 0;
NAP.peakMs = { [TOTAL_ADDON_METRICS_KEY] = 0 };
NAP.combatPeakMs = nil;
NAP.encounterPeakMs = nil;
NAP.snapshots = {
    --- @type NAP_Bucket[]
    buckets = {},
    --- @type NAP_Bucket # reference to the latest bucket
    lastBucket = nil,
};
do
    --- @type NAP_Bucket
    local lastBucket = {
        tickMap = {},
        lastTick = {},
        curTickIndex = 0;
    };
    NAP.snapshots.buckets[1] = lastBucket;
    NAP.snapshots.lastBucket = lastBucket;
end
--- @type NAP_EncounterSnapshot[]
NAP.encounterSnapshots = {};
--- @type NAP_CombatSnapshot[]
NAP.combatSnapshots = {};

--- collect all available data
local MODE_ACTIVE = 'active';
--- collect only total and peak data - disables history range
local MODE_PERFORMANCE = 'performance';
--- collect no data at all, just reset the spike ms counters on reset - disables history range, and maybe show different columns?
local MODE_PASSIVE = 'passive';

--- @type table<string, NAP_AddonInfo>
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

        local iconTexture = C_AddOns.GetAddOnMetadata(i, 'IconTexture');
        local iconAtlas = C_AddOns.GetAddOnMetadata(i, 'IconAtlas');
        if not iconTexture and not iconAtlas then
            iconTexture = '982414'; -- default to transparent icon
        end
        local iconMarkup;
        if iconTexture then
            iconMarkup = CreateSimpleTextureMarkup(iconTexture, 20, 20);
        elseif iconAtlas then
            iconMarkup = CreateAtlasMarkup(iconAtlas, 20, 20);
        end

        self.addons[addonName] = {
            title = title,
            notes = notes,
            iconMarkup = iconMarkup,
        };
        if isLoaded and addonName ~= thisAddonName then
            self:ADDON_LOADED(addonName);
        end
    end

    self.eventFrame:SetScript('OnEvent', function(_, event, ...)
        if self[event] then self[event](self, ...); end
    end);
    self.eventFrame:RegisterEvent('ADDON_LOADED');
    self.eventFrame:RegisterEvent('ENCOUNTER_START');
    self.eventFrame:RegisterEvent('ENCOUNTER_END');
    self.eventFrame:RegisterEvent('PLAYER_REGEN_DISABLED');
    self.eventFrame:RegisterEvent('PLAYER_REGEN_ENABLED');

    self.collectData = true;
    self:StartPurgeTicker();
    SLASH_NUMY_ADDON_PROFILER1 = '/nap';
    SLASH_NUMY_ADDON_PROFILER2 = '/addonprofile';
    SLASH_NUMY_ADDON_PROFILER3 = '/addonprofiler';
    SLASH_NUMY_ADDON_PROFILER4 = '/addoncpu';
    SlashCmdList['NUMY_ADDON_PROFILER'] = function(message)
        self:SlashCommand(message);
    end;
    RunNextFrame(function()
        if NumyProfiler then -- the irony of profiling the profiler (-:
            self.OnUpdateActiveMode = NumyProfiler:Wrap(thisAddonName, 'ProfilerCore', 'OnUpdateActiveMode', self.OnUpdateActiveMode);
            self.OnUpdatePerformanceMode = NumyProfiler:Wrap(thisAddonName, 'ProfilerCore', 'OnUpdatePerformanceMode', self.OnUpdatePerformanceMode);
            self.PurgeOldData = NumyProfiler:Wrap(thisAddonName, 'ProfilerCore', 'PurgeOldData', self.PurgeOldData);
            self.ENCOUNTER_START = NumyProfiler:Wrap(thisAddonName, 'ProfilerCore', 'ENCOUNTER_START', self.ENCOUNTER_START);
            self.ENCOUNTER_END = NumyProfiler:Wrap(thisAddonName, 'ProfilerCore', 'ENCOUNTER_END', self.ENCOUNTER_END);
            self.PLAYER_REGEN_DISABLED = NumyProfiler:Wrap(thisAddonName, 'ProfilerCore', 'PLAYER_REGEN_DISABLED', self.PLAYER_REGEN_DISABLED);
            self.PLAYER_REGEN_ENABLED = NumyProfiler:Wrap(thisAddonName, 'ProfilerCore', 'PLAYER_REGEN_ENABLED', self.PLAYER_REGEN_ENABLED);
        end

        self:SwitchMode(self.db.mode, true);
    end);

    if C_CVar.GetCVarBool('scriptProfile') then
        RunNextFrame(function()
            self:Print('Warning: scriptProfile is enabled, this can severely impact performance and is unnecessary for this addon to function. |cff71d5ff|Haddon:NumyAddonProfiler:scriptProfile|h[Reload]|h|r to disable it.');
        end);
        EventRegistry:RegisterCallback('SetItemRef', function(_, link)
            local linkType, addonName, linkData = strsplit(':', link);
            if linkType == 'addon' and addonName == 'NumyAddonProfiler' and linkData == 'scriptProfile' then
                C_CVar.SetCVar('scriptProfile', '0');
                ReloadUI();
            end
        end);
    end
end

function NAP:Print(...)
    print('|cff33ff99NumyAddonProfiler|r:', ...);
end

--- @param message string
function NAP:SlashCommand(message)
    message = message:trim():lower();
    if message == '' or message == 'ui' then
        self:ToggleFrame();
    elseif message == 'disable' then
        self:DisableLogging();
        self:Print('Logging has been disabled.')
    elseif message == 'enable' then
        self:EnableLogging();
        self:Print('Logging has been enabled.')
    elseif message == 'toggle' then
        if self:IsLogging() then
            self:DisableLogging();
            self:Print('Logging has been disabled.')
        else
            self:EnableLogging();
            self:Print('Logging has been enabled.')
        end
    elseif message == 'reset' then
        self:ResetMetrics();
        if self.ProfilerFrame then
            self.ProfilerFrame.elapsed = 60;
        end
        self:Print('All collected data has been reset.');
    elseif message == 'active' then
        self:SwitchMode(MODE_ACTIVE);
        self:Print('Switched to active mode.');
    elseif message == 'performance' then
        self:SwitchMode(MODE_PERFORMANCE);
        self:Print('Switched to performance mode.');
    elseif message == 'passive' then
        self:SwitchMode(MODE_PASSIVE);
        self:Print('Switched to passive mode.');
    elseif message == 'minimap' then
        wipe(self.db.minimap);
        self.db.minimap.hide = false;
        local name = 'NumyAddonProfiler';
        LibStub('LibDBIcon-1.0'):Hide(name);
        LibStub('LibDBIcon-1.0'):Show(name);

        self:Print('Minimap button has been restored.');
    else
        self:Print('Commands:');
        print('  help - show this help message');
        print('  ui (or nothing) - toggle the profiler frame');
        print('  disable - disable the profiler');
        print('  enable - enable the profiler');
        print('  toggle - disable / enable the profiler')
        print('  reset - reset all collected data');
        print('  active - switch to active mode');
        print('  performance - switch to performance mode');
        print('  passive - switch to passive mode');
        print('  minimap - reset the minimap button');
    end
end

local HEADER_IDS = {
    addonTitle = "addonTitle",
    encounterAvgMs = "encounterAvgMs",
    overallEncounterAvgPercent = "overallEncounterAvgPercent",
    peakTimeMs = "peakTimeMs",
    overallPeakTimePercent = "overallPeakTimePercent",
    recentMs = "recentMs",
    overallRecentPercent = "overallRecentPercent",
    averageMs = "averageMs",
    totalMs = "totalMs",
    overallTotalPercent = "overallTotalPercent",
    applicationTotalPercent = "applicationTotalPercent",
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
        [HEADER_IDS.overallEncounterAvgPercent] = false,
        [HEADER_IDS.peakTimeMs] = true,
        [HEADER_IDS.overallPeakTimePercent] = false,
        [HEADER_IDS.recentMs] = false,
        [HEADER_IDS.overallRecentPercent] = false,
        [HEADER_IDS.averageMs] = true,
        [HEADER_IDS.totalMs] = true,
        [HEADER_IDS.overallTotalPercent] = true,
        [HEADER_IDS.applicationTotalPercent] = true,
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

    self.db.mode = self.db.mode or MODE_ACTIVE;

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
    self.totalMs[addonName] = 0;
    self.loadedAtTick[addonName] = self.tickNumber;
    self.peakMs[addonName] = 0;
    self.snapshots.lastBucket.lastTick[addonName] = {};
    self.resetBaselineMetrics[addonName] = self:GetCurrentMsSpikeMetrics(addonName);
end

function NAP:SwitchMode(newMode, force)
    if newMode == self.db.mode and not force then
        return;
    end
    self.db.mode = newMode;
    if newMode == MODE_ACTIVE then
        self.eventFrame:SetScript('OnUpdate', function() self:OnUpdateActiveMode() end);
    elseif newMode == MODE_PERFORMANCE then
        self.eventFrame:SetScript('OnUpdate', function() self:OnUpdatePerformanceMode() end);
    elseif newMode == MODE_PASSIVE then
        self.eventFrame:SetScript('OnUpdate', nil);
    end
    self:ResetMetrics();
    self.ProfilerFrame:RefreshActiveColumns();
    self.ProfilerFrame:UpdateHeaders();
    RunNextFrame(function()
        self.ProfilerFrame.Headers:UpdateArrow();
        self.ProfilerFrame:UpdateSortComparator();
        if self.ProfilerFrame:IsShown() then
            self.ProfilerFrame:DoUpdate(true);
        end
    end);
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
    local combatPeakMs = self.combatPeakMs;
    local encounterPeakMs = self.encounterPeakMs;

    local overallLastTickMs = C_AddOnProfiler_GetOverallMetric(Enum_AddOnProfilerMetric_LastTime);
    if overallLastTickMs > 0 then
        totalMs[TOTAL_ADDON_METRICS_KEY] = totalMs[TOTAL_ADDON_METRICS_KEY] + overallLastTickMs;
        if overallLastTickMs > peakMs[TOTAL_ADDON_METRICS_KEY] then
            peakMs[TOTAL_ADDON_METRICS_KEY] = overallLastTickMs;
        end
        if combatPeakMs and overallLastTickMs > (combatPeakMs[TOTAL_ADDON_METRICS_KEY] or 0) then
            combatPeakMs[TOTAL_ADDON_METRICS_KEY] = overallLastTickMs;
        end
        if encounterPeakMs and overallLastTickMs > (encounterPeakMs[TOTAL_ADDON_METRICS_KEY] or 0) then
            encounterPeakMs[TOTAL_ADDON_METRICS_KEY] = overallLastTickMs;
        end
    end

    for addonName in pairs(self.loadedAddons) do
        local lastTickMs = C_AddOnProfiler_GetAddOnMetric(addonName, Enum_AddOnProfilerMetric_LastTime);
        if lastTickMs > 0 then
            totalMs[addonName] = totalMs[addonName] + lastTickMs;
            if lastTickMs > peakMs[addonName] then
                peakMs[addonName] = lastTickMs;
            end
            if combatPeakMs and lastTickMs > (combatPeakMs[addonName] or 0) then
                combatPeakMs[addonName] = lastTickMs;
            end
            if encounterPeakMs and lastTickMs > (encounterPeakMs[addonName] or 0) then
                encounterPeakMs[addonName] = lastTickMs;
            end
        end
    end
end

function NAP:InitNewBucket()
    local lastBucket = { curTickIndex = 0, tickMap = {}, lastTick = { [TOTAL_ADDON_METRICS_KEY] = {} } };
    for addonName in pairs(self.loadedAddons) do
        lastBucket.lastTick[addonName] = {};
    end

    t_insert(self.snapshots.buckets, lastBucket);
    self.snapshots.lastBucket = lastBucket;

    return lastBucket;
end

local BUCKET_CUTOFF = 2000; -- rather arbitrary number, but interestingly, the lower your fps, the less often actual work will be performed to purge old data ^^
function NAP:PurgeOldData()
    if self.db.mode ~= MODE_ACTIVE then -- only active mode uses buckets
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
    local cutoff = timestamp - HISTORY_TIME_RANGES[#HISTORY_TIME_RANGES];

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

function NAP:PLAYER_REGEN_DISABLED()
    self:StopPurgeTicker();

    if self.db.mode == MODE_PERFORMANCE then
        self.combatPeakMs = { [TOTAL_ADDON_METRICS_KEY] = 0 };
    end
    self.combatSnapshots = {
        { -- might add a list of combat snapshots in the future, for now it's just 1
            snapshot = self:InitNewSnapshot(self.combatPeakMs),
        },
    };
end

function NAP:PLAYER_REGEN_ENABLED()
    self:StartPurgeTicker();

    local snapshot = self.combatSnapshots[#self.combatSnapshots];
    if not snapshot then
        self:Print('Combat ended without matching combat start');
        return;
    end
    self:CloseSnapshot(snapshot.snapshot);
    self.combatPeakMs = nil
end

function NAP:ENCOUNTER_START(encounterID, encounterName, difficultyID, _)
    if (select(2, GetDifficultyInfo(difficultyID)) ~= 'raid') then return; end
    if self.db.mode == MODE_PERFORMANCE then
        self.encounterPeakMs = { [TOTAL_ADDON_METRICS_KEY] = 0 };
    end
    local snapshot = {
        encounterID = encounterID,
        name = encounterName,
        snapshot = self:InitNewSnapshot(self.encounterPeakMs),
    };
    t_insert(self.encounterSnapshots, snapshot);
end

function NAP:ENCOUNTER_END(encounterID, _, difficultyID, _, success)
    if (select(2, GetDifficultyInfo(difficultyID)) ~= 'raid') then return; end
    local snapshot = self.encounterSnapshots[#self.encounterSnapshots];
    if not snapshot or snapshot.encounterID ~= encounterID then
        self:Print('Encounter ended without matching encounter start');
        return;
    end
    snapshot.kill = success == 1;

    self:CloseSnapshot(snapshot.snapshot);
    self.encounterPeakMs = nil;
end

function NAP:StartPurgeTicker()
    if self.purgerTicker then
        self.purgerTicker:Cancel()
    end
    -- continiously purge older entires
    self.purgerTicker = C_Timer.NewTicker(5, function() self:PurgeOldData() end)
end

function NAP:StopPurgeTicker()
    if self.purgerTicker then
        self.purgerTicker:Cancel()
        self.purgerTicker = nil
    end
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

--- @param peakMsTable nil|table<string, number>
--- @return NAP_PartialSnapshot
function NAP:InitNewSnapshot(peakMsTable)
    return {
        startMetrics = self:GetCurrentMsSpikeMetrics(),
        startTime = GetTime(),
        startTick = self.tickNumber,
        startTotal = self.db.mode ~= MODE_PASSIVE and CopyTable(self.totalMs) or {},
        peakTime = peakMsTable,
        bucketStartTick = self.snapshots.lastBucket.curTickIndex,
        isComplete = false,
    };
end

--- @param snapshot NAP_PartialSnapshot
function NAP:CloseSnapshot(snapshot)
    --- @type NAP_Snapshot
    snapshot = snapshot; ---@diagnostic disable-line: assign-type-mismatch
    snapshot.endMetrics = self:GetCurrentMsSpikeMetrics();
    snapshot.endTime = GetTime();
    snapshot.endTick = self.tickNumber;

    snapshot.bossAvg = self:GetCurrentMetrics(Enum_AddOnProfilerMetric_EncounterAverageTime);
    snapshot.recentAvg = self:GetCurrentMetrics(Enum_AddOnProfilerMetric_RecentAverageTime);

    if self.db.mode ~= MODE_PASSIVE then
        snapshot.total = {};
        for addonName, endTotal in pairs(self.totalMs) do
            snapshot.total[addonName] = endTotal - (snapshot.startTotal[addonName] or 0);
        end
    end
    snapshot.startTotal = nil;

    if self.db.mode == MODE_ACTIVE then
        snapshot.peakTime = {};
        local bucket = {
            lastTick = {},
            tickMap = {},
            curTickIndex = 0,
        };
        local lastBucket = self.snapshots.lastBucket;
        for index = snapshot.bucketStartTick, lastBucket.curTickIndex do
            local tickIndex = bucket.curTickIndex + 1;
            bucket.curTickIndex = tickIndex;
            bucket.tickMap[tickIndex] = lastBucket.tickMap[index];
        end
        for addonName, lastTicks in pairs(lastBucket.lastTick) do
            snapshot.peakTime[addonName] = 0;
            local newTicks = {};
            local tickIndex = 0;
            for index = snapshot.bucketStartTick, lastBucket.curTickIndex do
                tickIndex = tickIndex + 1;
                local lastTick = lastTicks[index];
                if lastTick then
                    newTicks[tickIndex] = lastTicks[index];
                    if lastTicks[index] > snapshot.peakTime[addonName] then
                        snapshot.peakTime[addonName] = lastTicks[index];
                    end
                end
            end
            bucket.lastTick[addonName] = newTicks;
        end
        snapshot.bucket = bucket;
    else
        snapshot.peakTime = snapshot.peakTime or self:GetCurrentMetrics(Enum_AddOnProfilerMetric_PeakTime);
    end

    snapshot.isComplete = true;
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

--- @param metric any # Enum.AddOnProfilerMetric
--- @return table<string, number> # addonName -> metricValue
function NAP:GetCurrentMetrics(metric)
    local currentMetrics = {};
    currentMetrics[TOTAL_ADDON_METRICS_KEY] = C_AddOnProfiler_GetOverallMetric(metric);
    for addonName in pairs(self.loadedAddons) do
        currentMetrics[addonName] = C_AddOnProfiler_GetAddOnMetric(addonName, metric);
    end

    return currentMetrics;
end

--- @return string historyType
--- @return number|nil historyIndex # combatIndex, encounterIndex, or timeRange
function NAP:GetActiveHistoryRange()
    local type = self.currentHistorySelection.type;
    if HISTORY_TYPE_TIME_RANGE == type and self.db.mode ~= MODE_ACTIVE then
        type = HISTORY_TYPE_SINCE_RESET;
    end

    if HISTORY_TYPE_SINCE_RESET == type then
        return HISTORY_TYPE_SINCE_RESET, nil;
    elseif HISTORY_TYPE_COMBAT == type then
        return HISTORY_TYPE_COMBAT, self.currentHistorySelection.combatIndex;
    elseif HISTORY_TYPE_ENCOUNTER == type then
        return HISTORY_TYPE_ENCOUNTER, self.currentHistorySelection.encounterIndex;
    end

    -- if something went wrong, default to time range
    return HISTORY_TYPE_TIME_RANGE, self.currentHistorySelection.timeRange;
end

--- @param forceUpdate boolean
--- @return table<NAP_Bucket, number>? bucketsWithinHistory
function NAP:PrepareFilteredData(forceUpdate)
    local now = self.frozenAt or GetTime();

    local historyType, historyIndex = self:GetActiveHistoryRange();
    local timestampOffset = 0;
    if historyType == HISTORY_TYPE_TIME_RANGE and historyIndex then
        timestampOffset = historyIndex;
    end

    local minTimestamp = now - timestampOffset;

    local prevTimestamp = self.minTimeStamp;
    local prevMatch = self.prevMatch;
    local prevHistoryType = self.prevHistoryType;
    local prevHistoryIndex = self.prevHistoryIndex;

    if
        not forceUpdate
        and prevTimestamp == minTimestamp
        and prevMatch == self.curMatch
        and prevHistoryType == historyType
        and prevHistoryIndex == historyIndex
    then
        return nil;
    end

    t_wipe(self.filteredData);
    self.dataProvider = nil;
    self.minTimeStamp = minTimestamp;
    self.prevMatch = self.curMatch;
    self.prevHistoryType = historyType;
    self.prevHistoryIndex = historyIndex;

    local withinHistory = {};
    if HISTORY_TYPE_TIME_RANGE == historyType then
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
    local snapshot = nil;
    if HISTORY_TYPE_COMBAT == historyType then
        local index = historyIndex;
        if index == HISTORY_LATEST then
            index = #self.combatSnapshots;
        end
        snapshot = self.combatSnapshots[index] and self.combatSnapshots[index].snapshot;
    elseif HISTORY_TYPE_ENCOUNTER == historyType then
        local index = historyIndex;
        if index == HISTORY_LATEST then
            index = #self.encounterSnapshots;
        end
        snapshot = self.encounterSnapshots[index] and self.encounterSnapshots[index].snapshot;
    end
    if snapshot and not snapshot.isComplete then
        snapshot = nil;
    end
    if snapshot and snapshot.bucket then
        withinHistory[snapshot.bucket] = 1;
    end
    local overallSnapshotOverrides;
    if snapshot then
        overallSnapshotOverrides = {
            encounterAvg = snapshot.bossAvg[TOTAL_ADDON_METRICS_KEY] or 0,
            recentMs = snapshot.recentAvg[TOTAL_ADDON_METRICS_KEY] or 0,
            peakTime = snapshot.peakTime[TOTAL_ADDON_METRICS_KEY] or 0,
            totalMs = snapshot.total[TOTAL_ADDON_METRICS_KEY] or 0,
            numberOfTicks = snapshot.endTick - snapshot.startTick,
            applicationTotalMs = (snapshot.endTime - snapshot.startTime) * 1000,
            startMetrics = snapshot.startMetrics[TOTAL_ADDON_METRICS_KEY] or {},
            endMetrics = snapshot.endMetrics[TOTAL_ADDON_METRICS_KEY] or {},
        };
    end
    local overallStats = self:GetElelementDataForAddon(TOTAL_ADDON_METRICS_KEY, nil, withinHistory, nil, overallSnapshotOverrides);

    for addonName in pairs(self.loadedAddons) do
        local info = self.addons[addonName];
        if info.title:lower():match(self.curMatch) then
            local snapshotOverrides;
            if snapshot then
                snapshotOverrides = {
                    encounterAvg = snapshot.bossAvg[addonName] or 0,
                    recentMs = snapshot.recentAvg[addonName] or 0,
                    peakTime = snapshot.peakTime[addonName] or 0,
                    totalMs = snapshot.total[addonName] or 0,
                    numberOfTicks = overallSnapshotOverrides and overallSnapshotOverrides.numberOfTicks or 0,
                    applicationTotalMs = overallSnapshotOverrides and overallSnapshotOverrides.applicationTotalMs or 0,
                    startMetrics = snapshot.startMetrics[addonName] or {},
                    endMetrics = snapshot.endMetrics[addonName] or {},
                };
            end
            t_insert(self.filteredData, self:GetElelementDataForAddon(addonName, info, withinHistory, overallStats, snapshotOverrides));
        end
    end

    self.dataProvider = CreateDataProvider(self.filteredData)
    if self.sortComparator then
        self.dataProvider:SetSortComparator(self.sortComparator)
    end

    return withinHistory, overallSnapshotOverrides;
end

--- @param addonName string
--- @param info NAP_AddonInfo?
--- @param bucketsWithinHistory table<NAP_Bucket, number>
--- @param overallStats NAP_ElementData?
--- @param snapshotOverrides nil|{ encounterAvg: number, recentMs: number, peakTime: number, totalMs: number, numberOfTicks: number, applicationTotalMs: number, startMetrics: table<string, number>, endMetrics: table<string, number> }
--- @return NAP_ElementData
function NAP:GetElelementDataForAddon(addonName, info, bucketsWithinHistory, overallStats, snapshotOverrides)
    --- @type NAP_ElementData
    --- @diagnostic disable-next-line: missing-fields
    local data = {
        addonName = addonName,
        addonTitle = info and info.title or '',
        addonNotes = info and info.notes or '',
        addonIcon = info and info.iconMarkup or '',
        memoryUsage = GetAddOnMemoryUsage(addonName),
        peakTime = 0,
        averageMs = 0,
        totalMs = 0,
        numberOfTicks = 0,
        applicationTotalMs = 0,
    };
    if TOTAL_ADDON_METRICS_KEY == addonName then
        data.encounterAvg = snapshotOverrides and snapshotOverrides.encounterAvg or C_AddOnProfiler_GetOverallMetric(Enum_AddOnProfilerMetric_EncounterAverageTime);
        data.recentMs = snapshotOverrides and snapshotOverrides.recentMs or C_AddOnProfiler_GetOverallMetric(Enum_AddOnProfilerMetric_RecentAverageTime);
    else
        data.encounterAvg = snapshotOverrides and snapshotOverrides.encounterAvg or C_AddOnProfiler_GetAddOnMetric(addonName, Enum_AddOnProfilerMetric_EncounterAverageTime);
        data.recentMs = snapshotOverrides and snapshotOverrides.recentMs or C_AddOnProfiler_GetAddOnMetric(addonName, Enum_AddOnProfilerMetric_RecentAverageTime);
    end
    for _, ms in pairs(msOptions) do
        data[msOptionFieldMap[ms]] = 0;
    end
    local now = self.frozenAt or GetTime();
    local historyType = self:GetActiveHistoryRange();
    if
        HISTORY_TYPE_SINCE_RESET == historyType
        or HISTORY_TYPE_ENCOUNTER == historyType
        or HISTORY_TYPE_COMBAT == historyType
    then
        data.applicationTotalMs = (snapshotOverrides and snapshotOverrides.applicationTotalMs) or (now - self.resetTime) * 1000;
        local currentMetrics = (snapshotOverrides and snapshotOverrides.endMetrics) or (self.frozenMetrics and self.frozenMetrics[addonName]) or self:GetCurrentMsSpikeMetrics(addonName);
        local baselineMetrics = (snapshotOverrides and snapshotOverrides.startMetrics) or self.resetBaselineMetrics[addonName];
        for ms in pairs(msMetricMap) do
            local currentMetric = currentMetrics[ms] or 0;
            local baselineMetric = baselineMetrics[ms] or 0;
            local increase = currentMetric - baselineMetric;
            data[msOptionFieldMap[ms]] = increase;
        end
        data.peakTime = snapshotOverrides and snapshotOverrides.peakTime or self.peakMs[addonName];
        data.totalMs = (snapshotOverrides and snapshotOverrides.totalMs) or self.totalMs[addonName];
        data.numberOfTicks = (snapshotOverrides and snapshotOverrides.numberOfTicks) or (self.tickNumber - self.loadedAtTick[addonName]);
    else
        local firstTickTime = now;
        local lastTickTime = 0;
        for bucket, startingTickIndex in pairs(bucketsWithinHistory) do
            data.numberOfTicks = data.numberOfTicks + ((bucket.curTickIndex - startingTickIndex) + 1);
            if bucket.tickMap[startingTickIndex] < firstTickTime then
                firstTickTime = bucket.tickMap[startingTickIndex];
            end
            if bucket.tickMap[bucket.curTickIndex] > lastTickTime then
                lastTickTime = bucket.tickMap[bucket.curTickIndex];
            end
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

        data.applicationTotalMs = (lastTickTime - firstTickTime) * 1000;
    end
    data.averageMs = data.numberOfTicks > 0 and (data.totalMs / data.numberOfTicks) or 0; -- let's not divide by 0 :)

    if self.db.mode == MODE_PASSIVE then
        if TOTAL_ADDON_METRICS_KEY == addonName then
            data.peakTime = (snapshotOverrides and snapshotOverrides.peakTime) or C_AddOnProfiler_GetOverallMetric(Enum_AddOnProfilerMetric_PeakTime);
        else
            data.peakTime = (snapshotOverrides and snapshotOverrides.peakTime) or C_AddOnProfiler_GetAddOnMetric(addonName, Enum_AddOnProfilerMetric_PeakTime);
        end
    end

    data.overMsSum = 0;
    local previousGroupCount = 0;
    for _, ms in ipairs_reverse(msOptions) do
        data[msOptionFieldMap[ms]] = data[msOptionFieldMap[ms]] or 0;
        local count = data[msOptionFieldMap[ms]];
        data.overMsSum = data.overMsSum + ((count - previousGroupCount) * ms);
        previousGroupCount = count;
    end

    if TOTAL_ADDON_METRICS_KEY == addonName then
        data.overallPeakTime = data.peakTime;
        data.overallEncounterAvg = data.encounterAvg;
        data.overallRecentMs = data.recentMs;
        data.overallTotalMs = data.totalMs;
    elseif overallStats then
        data.overallPeakTime = overallStats.peakTime;
        data.overallEncounterAvg = overallStats.encounterAvg;
        data.overallRecentMs = overallStats.recentMs;
        data.overallTotalMs = overallStats.totalMs;
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
    local kbText = "|cff808080KB|r";
    local mbText = "|cff808080MB|r";
    local greyColorFormat = "|cff808080%s|r";
    local whiteColorFormat = "|cfff8f8f2%s|r";

    local MEMORY_FORMAT = function(val)
        if ( val > 1000 ) then
            val = val / 1000;

            return ('%.2f %s'):format(val, mbText);
        end
        return ('%.0f %s'):format(val, kbText);
    end
    local TIME_FORMAT = function(val) return (val > 0.0005 and whiteColorFormat or greyColorFormat):format(("%.3f"):format(val)) .. msText; end;
    local ROUND_TIME_FORMAT = function(val) return (val > 0.0005 and whiteColorFormat or greyColorFormat):format(val) .. msText; end;
    local COUNTER_FORMAT = function(val) return (val > 0.0005 and whiteColorFormat or greyColorFormat):format(val) .. xText; end;
    local RAW_FORMAT = function(val) return val; end;
    local PERCENT_FORMAT = function(val)
        local color = val > 0.00005 and whiteColorFormat or greyColorFormat;

        return val >= 1 and color:format("100.00%") or color:format(("%.2f%%"):format(val * 100));
    end;

    local COLUMN_INFO = {};
    do
        local totalAddonsText = NORMAL_FONT_COLOR:WrapTextInColorCode("Total Addons");
        local applicationText = NORMAL_FONT_COLOR:WrapTextInColorCode("Application");
        local applicationShortText = NORMAL_FONT_COLOR:WrapTextInColorCode("App");

        local Inf = math.huge
        local function makeSortMethods(key)
            return {
                --- @param a NAP_ElementData
                --- @param b NAP_ElementData
                [ORDER_ASC] = function(a, b)
                    return (a[key] ~= Inf and a[key] < b[key]) or (a[key] == b[key] and a.addonName < b.addonName);
                end,
                --- @param a NAP_ElementData
                --- @param b NAP_ElementData
                [ORDER_DESC] = function(a, b)
                    return (a[key] ~= Inf and a[key] > b[key]) or (a[key] == b[key] and a.addonName < b.addonName);
                end,
            };
        end
        local counter = CreateCounter();
        -- the IDs/keys should not be changed, they're persistent in SVs to remember whether they're toggled on or off
        COLUMN_INFO[HEADER_IDS.addonTitle] = {
            ID = HEADER_IDS.addonTitle,
            order = counter(),
            availableInPassiveMode = true,
            justifyLeft = true,
            title = "Addon",
            width = 300,
            textFormatter = RAW_FORMAT,
            --- @param data NAP_ElementData
            textFunc = function(data)
                return data.addonIcon .. ' ' .. data.addonTitle;
            end,
            sortMethods = {
                --- @param a NAP_ElementData
                --- @param b NAP_ElementData
                [ORDER_ASC] = function(a, b)
                    return strcmputf8i(StripHyperlinks(a.addonTitle), StripHyperlinks(b.addonTitle)) > 0
                end,
                --- @param a NAP_ElementData
                --- @param b NAP_ElementData
                [ORDER_DESC] = function(a, b)
                    return strcmputf8i(StripHyperlinks(a.addonTitle), StripHyperlinks(b.addonTitle)) < 0
                end,
            },
        };
        COLUMN_INFO[HEADER_IDS.encounterAvgMs] = {
            ID = HEADER_IDS.encounterAvgMs,
            order = counter(),
            availableInPassiveMode = true,
            title = "Boss Avg",
            width = 96,
            textFormatter = TIME_FORMAT,
            textKey = "encounterAvg",
            tooltip = "Average CPU time spent per frame during a boss encounter. Time based History Ranges will display the current values.",
            sortMethods = makeSortMethods("encounterAvg"),
        };
        COLUMN_INFO[HEADER_IDS.overallEncounterAvgPercent] = {
            ID = HEADER_IDS.overallEncounterAvgPercent,
            order = counter(),
            availableInPassiveMode = true,
            title = "Boss Avg %",
            width = 96,
            textFormatter = PERCENT_FORMAT,
            --- @param data NAP_ElementData
            textFunc = function(data)
                return data.overallEncounterAvg > 0 and (data.encounterAvg / data.overallEncounterAvg) or 0;
            end,
            tooltip = "Percentage of " .. totalAddonsText .. " CPU time spent per frame during a boss encounter. Time based History Ranges will display the current values.",
            sortMethods = makeSortMethods("encounterAvg"),
        };
        COLUMN_INFO[HEADER_IDS.peakTimeMs] = {
            ID = HEADER_IDS.peakTimeMs,
            order = counter(),
            availableInPassiveMode = true,
            title = "Peak Time",
            width = 96,
            textFormatter = TIME_FORMAT,
            textKey = "peakTime",
            tooltip = "Biggest spike in ms, within the History Range.",
            sortMethods = makeSortMethods("peakTime"),
        };
        COLUMN_INFO[HEADER_IDS.overallPeakTimePercent] = {
            ID = HEADER_IDS.overallPeakTimePercent,
            order = counter(),
            availableInPassiveMode = true,
            title = "Peak %",
            width = 96,
            textFormatter = PERCENT_FORMAT,
            --- @param data NAP_ElementData
            textFunc = function(data)
                return data.overallPeakTime > 0 and (data.peakTime / data.overallPeakTime) or 0;
            end,
            tooltip = "Percentage of " .. totalAddonsText .. " biggest spike in ms, within the History Range.",
            sortMethods = makeSortMethods("peakTime"),
        };
        COLUMN_INFO[HEADER_IDS.recentMs] = {
            ID = HEADER_IDS.recentMs,
            order = counter(),
            availableInPassiveMode = true,
            title = "Recent Ms",
            width = 96,
            textFormatter = TIME_FORMAT,
            textKey = "recentMs",
            tooltip = "Average CPU time spent in the last 60 frames. Ignores the History Range",
            sortMethods = makeSortMethods("recentMs"),
        };
        COLUMN_INFO[HEADER_IDS.overallRecentPercent] = {
            ID = HEADER_IDS.overallRecentPercent,
            order = counter(),
            availableInPassiveMode = true,
            title = "Recent %",
            width = 96,
            textFormatter = PERCENT_FORMAT,
            --- @param data NAP_ElementData
            textFunc = function(data)
                return data.overallRecentMs > 0 and (data.recentMs / data.overallRecentMs) or 0;
            end,
            tooltip = "Percentage of " .. totalAddonsText .. " CPU time spent in the last 60 frames. Ignores the History Range.",
            sortMethods = makeSortMethods("recentMs"),
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
            width = 120,
            textFormatter = TIME_FORMAT,
            textKey = "totalMs",
            tooltip = "Total CPU time spent, within the History Range.",
            sortMethods = makeSortMethods("totalMs"),
        };
        COLUMN_INFO[HEADER_IDS.overallTotalPercent] = {
            ID = HEADER_IDS.overallTotalPercent,
            order = counter(),
            title = "Total %",
            width = 96,
            textFormatter = PERCENT_FORMAT,
            --- @param data NAP_ElementData
            textFunc = function(data)
                return data.overallTotalMs > 0 and (data.totalMs / data.overallTotalMs) or 0;
            end,
            tooltip = "Percentage of " .. totalAddonsText .. " CPU time spent, within the History Range.",
            sortMethods = makeSortMethods("totalMs"),
        };
        COLUMN_INFO[HEADER_IDS.applicationTotalPercent] = {
            ID = HEADER_IDS.applicationTotalPercent,
            order = counter(),
            title = "Total % of " .. applicationShortText,
            width = 96,
            textFormatter = PERCENT_FORMAT,
            --- @param data NAP_ElementData
            textFunc = function(data)
                return data.applicationTotalMs > 0 and (data.totalMs / data.applicationTotalMs) or 0;
            end,
            tooltip = "CPU time spent, as a percentage of the total " .. applicationText .. " CPU time. This includes default UI, graphics, etc.",
            sortMethods = makeSortMethods("totalMs"),
        };
        for _, ms in ipairs(msOptions) do
            COLUMN_INFO[HEADER_IDS["overCount-" .. ms]] = {
                ID = HEADER_IDS["overCount-" .. ms],
                order = counter(),
                availableInPassiveMode = true,
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
            availableInPassiveMode = true,
            title = "Spike Sum",
            width = 96,
            textFormatter = ROUND_TIME_FORMAT,
            textKey = "overMsSum",
            tooltip = "Sum of all the separate spikes.",
            sortMethods = makeSortMethods("overMsSum"),
        };
    end

    -------------
    -- DISPLAY --
    -------------
    do
        local ROW_HEIGHT = 20
        local UPDATE_INTERVAL = 1
        local continuousUpdate = true

        --- @class NAP_Display: Frame, ButtonFrameTemplate
        local display = CreateFrame("Frame", "NumyAddonProfilerFrame", UIParent, "ButtonFrameTemplate")
        self.ProfilerFrame = display
        do
            do
                local activeSort, activeOrder = HEADER_IDS.averageMs, ORDER_DESC
                function display:SetActiveSort(sort, order)
                    activeSort, activeOrder = sort, order
                    self:UpdateSortComparator()
                end
                function display:GetActiveSort()
                    local sort, order = activeSort, activeOrder
                    if NAP.db.mode == MODE_PASSIVE and not COLUMN_INFO[sort].availableInPassiveMode then
                        sort = HEADER_IDS.spikeSumMs
                    end

                    return sort, order
                end
            end

            function display:UpdateSortComparator()
                local sort, order = self:GetActiveSort()
                NAP.sortComparator = COLUMN_INFO[sort].sortMethods[order]
                if NAP.dataProvider then
                    NAP.dataProvider:SetSortComparator(NAP.sortComparator)
                end
            end
            display:UpdateSortComparator()

            function display:OnUpdate(elapsed)
                self.elapsed = (self.elapsed or 0) + elapsed
                if self.elapsed >= UPDATE_INTERVAL then
                    self:DoUpdate()
                end
            end

            function display:DoUpdate(force)
                local bucketsWithinHistory, overallSnapshotOverrides = NAP:PrepareFilteredData(force)
                self.TotalRow:Update(bucketsWithinHistory, overallSnapshotOverrides)

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
                UpdateAddOnMemoryUsage()
                self:DoUpdate()

                if continuousUpdate then
                    self:SetScript("OnUpdate", self.OnUpdate)
                end
            end

            function display:OnHide()
                self:SetScript("OnUpdate", nil)
            end

            function display:RefreshActiveColumns()
                display.activeColumns = {}
                for ID, info in pairs(COLUMN_INFO) do
                    if NAP.db.shownColumns[ID] and (NAP.db.mode ~= MODE_PASSIVE or info.availableInPassiveMode) then
                        t_insert(display.activeColumns, info)
                    end
                end
                table.sort(display.activeColumns, function(a, b) return a.order < b.order end)
            end
            display:RefreshActiveColumns()

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

            function display:UpdateHeaders()
                self:UpdateWidth()

                local headers = self.Headers
                headers:LayoutColumns(self.activeColumns)

                local RightClickAtlasMarkup = CreateAtlasMarkup('NPE_RightClick', 18, 18);
                local LeftClickAtlasMarkup = CreateAtlasMarkup('NPE_LeftClick', 18, 18);

                --- @type FramePool<BUTTON,ColumnDisplayButtonTemplate>
                local headerPool = headers.columnHeaders
                for header in headerPool:EnumerateActive() do
                    if not header.initialized then
                        header.initialized = true
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
                        header:RegisterForClicks("AnyDown")
                    end
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
        display.HistoryDropdown = historyMenu;
        do
            historyMenu:SetPoint("TOPRIGHT", -11, -32);
            historyMenu:SetWidth(150);
            historyMenu:SetFrameLevel(3);
            historyMenu:OverrideText("History Range");

            local function onAfterSelection()
                display.elapsed = UPDATE_INTERVAL
            end
            local function isTypeSelected(data)
                return data == NAP:GetActiveHistoryRange();
            end
            local function selectType(data)
                NAP.currentHistorySelection.type = data;
                onAfterSelection();

                return MenuResponse.Refresh;
            end
            local function isTimeRangeSelected(data)
                return NAP.currentHistorySelection.timeRange == data;
            end
            local function selectTimeRange(data)
                NAP.currentHistorySelection.type = HISTORY_TYPE_TIME_RANGE;
                NAP.currentHistorySelection.timeRange = data;
                onAfterSelection();

                return MenuResponse.Refresh;
            end
            local function isEncounterSelected(data)
                local selectedIndex = NAP.currentHistorySelection.encounterIndex;

                return data.index == selectedIndex or (selectedIndex == HISTORY_LATEST and data.isLatest or false);
            end
            local function selectEncounter(data)
                NAP.currentHistorySelection.type = HISTORY_TYPE_ENCOUNTER;
                NAP.currentHistorySelection.encounterIndex = data.index;
                onAfterSelection();

                return MenuResponse.Refresh;
            end

            --- @param rootDescription RootMenuDescriptionProxy
            historyMenu:SetupMenu(function(_, rootDescription)
                rootDescription:CreateTitle("Select History Range");

                local sinceReset = rootDescription:CreateRadio("Since Reset", isTypeSelected, selectType, HISTORY_TYPE_SINCE_RESET);
                sinceReset:SetTitleAndTextTooltip("Since Reset/Reload", "Show all information since the last reset.");

                local timeRangeTypeAllowed = NAP.db.mode == MODE_ACTIVE;
                local timeRange = rootDescription:CreateRadio("Last X Seconds", isTypeSelected, selectType, HISTORY_TYPE_TIME_RANGE);
                timeRange:SetEnabled(timeRangeTypeAllowed);
                if timeRangeTypeAllowed then
                    timeRange:SetTitleAndTextTooltip("Last X Seconds", "Only available in Active Mode");
                end
                for _, range in ipairs(HISTORY_TIME_RANGES) do
                    local option = timeRange:CreateRadio(SecondsToTime(range, false, true), isTimeRangeSelected, selectTimeRange, range);
                    option:SetEnabled(timeRangeTypeAllowed);
                end

                local encounter = rootDescription:CreateRadio("Raid Encounters", isTypeSelected, selectType, HISTORY_TYPE_ENCOUNTER);
                encounter:SetTitleAndTextTooltip("Raid Encounters", "Show addon performance during a raid fight.");
                local latestIndex = #NAP.encounterSnapshots;
                if NAP.encounterSnapshots[latestIndex] and not NAP.encounterSnapshots[latestIndex].snapshot.isComplete then -- encounter is still in progress
                    latestIndex = latestIndex - 1;
                end
                encounter:CreateRadio("Last Encounter", isEncounterSelected, selectEncounter, { index = HISTORY_LATEST, isLatest = true });
                for index, encounterData in ipairs(NAP.encounterSnapshots) do
                    if encounterData.snapshot.isComplete then
                        local text = string.format("%d - %s (%s)", index, encounterData.name, encounterData.kill and "Kill" or "Wipe");
                        encounter:CreateRadio(text, isEncounterSelected, selectEncounter, { index = index, isLatest = index == latestIndex });
                    end
                end

                rootDescription:CreateRadio("Last Combat", isTypeSelected, selectType, HISTORY_TYPE_COMBAT);
            end)
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

        local modeMenu = CreateFrame("DropdownButton", nil, display, "WowStyle1DropdownTemplate");
        display.ModeDropdown = modeMenu
        do
            modeMenu:SetPoint("LEFT", search, "RIGHT", 4, 0);
            modeMenu:SetWidth(150);
            modeMenu:SetFrameLevel(3);
            --- @param rootDescription RootMenuDescriptionProxy
            modeMenu:SetupMenu(function(_, rootDescription)
                local function isSelected(data) return NAP.db.mode == data end
                local function onSelection(data)
                    NAP:SwitchMode(data)
                    return MenuResponse.Refresh
                end

                rootDescription:CreateTitle("Mode")
                local active = rootDescription:CreateRadio("Active Mode", isSelected, onSelection, MODE_ACTIVE)
                local performance = rootDescription:CreateRadio("Performance Mode", isSelected, onSelection, MODE_PERFORMANCE)
                local passive = rootDescription:CreateRadio("Passive Mode", isSelected, onSelection, MODE_PASSIVE)

                active:SetTitleAndTextTooltip("Active Mode", "Provides the most amount of information, and allows you to select a History Range to filter by.")
                performance:SetTitleAndTextTooltip("Performance Mode", "Performs slightly less work in the background, but does not allow you to select a History Range.")
                passive:SetTitleAndTextTooltip("Passive Mode", "No information is collected in the background, which limits the columns that can be displayed. But 0 work is performed in the background while the UI is closed.")
            end)
        end

        local headers = CreateFrame("Button", "$parentHeaders", display, "ColumnDisplayTemplate")
        display.Headers = headers
        do
            headers:SetPoint("BOTTOMLEFT", display.Inset, "TOPLEFT", 1, ROW_HEIGHT + 1)
            headers:SetPoint("BOTTOMRIGHT", display.Inset, "TOPRIGHT", 0, -1)

            function headers:UpdateArrow()
                local sort, order = display:GetActiveSort()
                --- @type FramePool<BUTTON,ColumnDisplayButtonTemplate>
                local headerPool = headers.columnHeaders
                for header in headerPool:EnumerateActive() do
                    local index = header:GetID()
                    local columnID = display.activeColumns[index].ID
                    if sort == columnID then
                        header.Arrow:Show()

                        if order == ORDER_ASC then
                            header.Arrow:SetTexCoord(0, 1, 1, 0)
                        else
                            header.Arrow:SetTexCoord(0, 1, 0, 1)
                        end
                    else
                        header.Arrow:Hide()
                    end
                end
            end

            function headers:OnHeaderClick(index, button)
                if button == "LeftButton" then
                    local sort, order = display:GetActiveSort()
                    local columnID = display.activeColumns[index].ID
                    local columnChanged = sort ~= columnID
                    local newSort, newOrder = columnID, ORDER_DESC

                    if not columnChanged then
                        newOrder = order == ORDER_DESC and ORDER_ASC or ORDER_DESC
                    end
                    display:SetActiveSort(newSort, newOrder)
                    display:UpdateSortComparator()

                    self:UpdateArrow()
                elseif button == "RightButton" then
                    local headerOptions = {}
                    for ID, info in pairs(COLUMN_INFO) do
                        if ID ~= "addonTitle" and (NAP.db.mode ~= MODE_PASSIVE or info.availableInPassiveMode) then
                            t_insert(headerOptions, { info.title, info })
                        end
                    end
                    table.sort(headerOptions, function(a, b) return a[2].order < b[2].order end)
                    local function isSelected(data)
                        return NAP.db.shownColumns[data.ID] or false
                    end
                    local function onSelection(data)
                        if NAP.db.shownColumns[data.ID] then
                            NAP.db.shownColumns[data.ID] = false
                        else
                            NAP.db.shownColumns[data.ID] = true
                        end
                        display:RefreshActiveColumns()
                        display:UpdateHeaders()
                        display:DoUpdate(true)
                        return MenuResponse.Refresh
                    end
                    MenuUtil.CreateCheckboxContextMenu(nil, isSelected, onSelection, unpack(headerOptions))
                end
            end

            headers:UpdateArrow()
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
                    GameTooltip:AddDoubleLine("Memory Usage:", MEMORY_FORMAT(data.memoryUsage), 1, 0.92, 0, 1, 1, 1)
                    GameTooltip:AddLine("|cnNORMAL_FONT_COLOR:Note:|r Memory usage is updated only when opening the UI.", 1, 1, 1, true)
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

            function totalRow:Update(bucketsWithinHistory, overallSnapshotOverrides)
                if bucketsWithinHistory then
                    self.data = NAP:GetElelementDataForAddon(TOTAL_ADDON_METRICS_KEY, { title = "|cnNORMAL_FONT_COLOR:Addon Total|r", notes = "Stats for all addons combined" }, bucketsWithinHistory, nil, overallSnapshotOverrides)
                end
                self:UpdateColumns()
                for columnText in self.columnPool:EnumerateActive() do
                    local column = columnText.column
                    local value = column.textFunc and column.textFunc(self.data) or self.data[column.textKey]
                    columnText:SetText(column.textFormatter(value))
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
                    local value = column.textFunc and column.textFunc(data) or data[column.textKey]
                    columnText:SetText(column.textFormatter(value))
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
    self.collectData = true;
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
    --- @type BlizzMoveAPI?
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
                    self:Print('Minimap button hidden. Use |cffeda55f/nap minimap|r to restore.');

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
