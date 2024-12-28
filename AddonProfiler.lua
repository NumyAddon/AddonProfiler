local thisAddonName = ...

local s_trim = string.trim
local t_insert = table.insert
local t_removemulti = table.removemulti
local t_wipe = table.wipe
local pairs = pairs
local GetTime = GetTime

local C_AddOnProfiler_GetAddOnMetric = C_AddOnProfiler.GetAddOnMetric;
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

local HISTORY_RANGES = {0, 5, 15, 30, 60, 120, 300, 600} -- 5sec - 10min
NAP.curHistoryRange = 30;

--- @type table<string, table<string, number>> [addonName] = { [metricName] = value }
NAP.initialMetrics = {};
--- @type table<string, table<string, number>> [addonName] = { [metricName] = value }
NAP.resetBaselineMetrics = NAP.initialMetrics;

NAP.totalMs = {};
NAP.loadedAtTick = {};
NAP.tickNumber = 0;
NAP.peakMs = {};
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

--- @type table<string, { title: string, notes: string, loaded: boolean }>
NAP.addons = {};
--- @type table<string, boolean> # list of addon names
NAP.loadedAddons = {};

--- Note: NAP:Init() is called at the end of the script body, BEFORE the addon_loaded event
function NAP:Init()
    for i = 1, C_AddOns.GetNumAddOns() do
        local addonName, title, notes = C_AddOns.GetAddOnInfo(i);
        self.initialMetrics[addonName] = {};
        for metric, ms in pairs(resettableMetrics) do
            self.initialMetrics[addonName][ms] = C_AddOnProfiler_GetAddOnMetric(addonName, metric);
        end
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

    self.eventFrame:SetScript('OnUpdate', function() self:OnUpdate() end);
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
            self.OnUpdate = NumyProfiler:Wrap(thisAddonName, 'ProfilerCore', 'OnUpdate', self.OnUpdate);
            self.PurgeOldData = NumyProfiler:Wrap(thisAddonName, 'ProfilerCore', 'PurgeOldData', self.PurgeOldData);
        end
    end);
end

function NAP:ADDON_LOADED(addonName)
    if thisAddonName == addonName then
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
end

function NAP:InitNewBucket()
    local lastBucket = { curTickIndex = 0, tickMap = {}, lastTick = {} };
    for ms in pairs(msMetricMap) do
        lastBucket[ms] = {};
    end
    for addonName in pairs(self.loadedAddons) do
        lastBucket.lastTick[addonName] = {};
        for ms in pairs(msMetricMap) do
            lastBucket[ms][addonName] = {};
        end
    end

    t_insert(self.snapshots.buckets, lastBucket);
    self.snapshots.lastBucket = lastBucket;

    return lastBucket;
end

function NAP:OnUpdate()
    self.tickNumber = self.tickNumber + 1;

    local lastBucket = self.snapshots.lastBucket;

    local curTickIndex = lastBucket.curTickIndex + 1;
    lastBucket.curTickIndex = curTickIndex;
    lastBucket.tickMap[curTickIndex] = GetTime();

    local lastTick = lastBucket.lastTick;
    local totalMs = self.totalMs;
    local peakMs = self.peakMs;

    for addonName in pairs(self.loadedAddons) do
        local lastTickMs = C_AddOnProfiler_GetAddOnMetric(addonName, Enum_AddOnProfilerMetric_LastTime);
        if lastTickMs > 0 then
            lastTick[addonName][curTickIndex] = lastTickMs;
            totalMs[addonName] = totalMs[addonName] + lastTickMs;
            if lastTickMs > peakMs[addonName] then
                peakMs[addonName] = lastTickMs;
            end
        end
    end
end

function NAP:GetCurrentMsSpikeMetrics(onlyForAddonName)
    local currentMetrics = {};
    if not onlyForAddonName then
        for addonName in pairs(self.loadedAddons) do
            currentMetrics[addonName] = {};
            for metric, ms in pairs(resettableMetrics) do
                currentMetrics[addonName][ms] = C_AddOnProfiler_GetAddOnMetric(addonName, metric);
            end
        end
    else
        for metric, ms in pairs(resettableMetrics) do
            currentMetrics[ms] = C_AddOnProfiler_GetAddOnMetric(onlyForAddonName, metric);
        end
    end

    return currentMetrics;
end

function NAP:ResetMetrics()
    self.resetBaselineMetrics = self:GetCurrentMsSpikeMetrics();
    self.tickNumber = 0;
    self.snapshots.buckets = {};
    self:InitNewBucket();
    for addonName in pairs(self.loadedAddons) do
        self.totalMs[addonName] = 0;
        self.peakMs[addonName] = 0;
        self.loadedAtTick[addonName] = 0;
    end
end

local BUCKET_CUTOFF = 2000; -- rather arbitrary number, but interestingly, the lower your fps, the less often actual work will be performed to purge old data ^^
function NAP:PurgeOldData()
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

---@class NAP_ElementData
---@field addonName string
---@field addonTitle string
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

function NAP:PrepareFilteredData()
    -- idc about recycling here, just wipe it
    t_wipe(self.filteredData)
    self.dataProvider = nil

    if not self.collectData then return end

    local minTimestamp = GetTime() - self.curHistoryRange;

    local withinHistory = {};
    if 0 ~= self.curHistoryRange then
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
            ---@type NAP_ElementData
            ---@diagnostic disable-next-line: missing-fields
            local data = {
                addonName = addonName,
                addonTitle = info.title,
                peakTime = 0,
                encounterAvg = C_AddOnProfiler_GetAddOnMetric(addonName, Enum_AddOnProfilerMetric_EncounterAverageTime),
                averageMs = 0,
                totalMs = 0,
                numberOfTicks = 0,
            };
            for _, ms in pairs(msOptions) do
                data[msOptionFieldMap[ms]] = 0;
            end
            if 0 == self.curHistoryRange then
                local currentMetrics = self:GetCurrentMsSpikeMetrics(addonName);
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
                for bucket, startingTickIndex in pairs(withinHistory) do
                    data.numberOfTicks = data.numberOfTicks + ((bucket.curTickIndex - startingTickIndex) + 1);
                    for tickIndex = startingTickIndex, bucket.curTickIndex do
                        local tickMs = bucket.lastTick[addonName][tickIndex];
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

            t_insert(self.filteredData, data);
        end
    end

    self.dataProvider = CreateDataProvider(self.filteredData)
    if self.sortComparator then
        self.dataProvider:SetSortComparator(self.sortComparator)
    end
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
    local COLUMN_INFO = {
        {
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
            }
        },
        {
            title = "Boss Avg",
            width = 96,
            textFormatter = TIME_FORMAT,
            textKey = "encounterAvg",
            tooltip = "Average CPU time spent per frame during a boss encounter. Ignores the History Range",
            sortMethods = makeSortMethods("encounterAvg"),
        },
        {
            title = "Peak Time",
            width = 96,
            textFormatter = TIME_FORMAT,
            textKey = "peakTime",
            tooltip = "Biggest spike in ms, within the History Range.",
            sortMethods = makeSortMethods("peakTime"),
        },
        {
            title = "Average",
            width = 96,
            textFormatter = TIME_FORMAT,
            textKey = "averageMs",
            tooltip = "Average CPU time spent per frame.",
            sortMethods = makeSortMethods("averageMs"),
        },
        {
            title = "Total",
            width = 108,
            textFormatter = TIME_FORMAT,
            textKey = "totalMs",
            tooltip = "Total CPU time spent, within the History Range.",
            sortMethods = makeSortMethods("totalMs"),
        },
    };
    for _, ms in ipairs(msOptions) do
        t_insert(COLUMN_INFO, {
            title = "Over " .. ms .. "ms",
            width = 80 + (strlen(ms) * 5),
            textFormatter = COUNTER_FORMAT,
            textKey = msOptionFieldMap[ms],
            tooltip = "How many times the addon took longer than " .. ms .. "ms per frame.",
            sortMethods = makeSortMethods(msOptionFieldMap[ms]),
        });
    end
    t_insert(COLUMN_INFO, {
        title = "Spike Sum",
        width = 96,
        textFormatter = ROUND_TIME_FORMAT,
        textKey = "overMsSum",
        tooltip = "Sum of all the separate spikes.",
        sortMethods = makeSortMethods("overMsSum"),
    });

    local activeSort, activeOrder = 4, ORDER_DESC -- 4 = averageMs

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
        local profilerFrameMixin = {}

        function profilerFrameMixin:OnUpdate(elapsed)
            self.elapsed = (self.elapsed or 0) + elapsed
            if self.elapsed >= UPDATE_INTERVAL then
                NAP:PrepareFilteredData()

                local perc = self.ScrollBox:GetScrollPercentage()
                self.ScrollBox:Flush()

                if NAP.dataProvider then
                    self.ScrollBox:SetDataProvider(NAP.dataProvider)
                    self.ScrollBox:SetScrollPercentage(perc)
                end

                self.Stats:Update()

                self.elapsed = 0
            end
        end

        function profilerFrameMixin:OnShow()
            self.elapsed = UPDATE_INTERVAL

            if continuousUpdate then
                self:SetScript("OnUpdate", self.OnUpdate)
            end
        end

        function profilerFrameMixin:OnHide()
            self:SetScript("OnUpdate", nil)
        end

        self.ProfilerFrame = Mixin(CreateFrame("Frame", "NumyAddonProfilerFrame", UIParent, "ButtonFrameTemplate"), profilerFrameMixin)
        t_insert(UISpecialFrames, self.ProfilerFrame:GetName())
        local display = self.ProfilerFrame
        local width = 40;
        for _, info in pairs(COLUMN_INFO) do
            width = width + (info.width - 2)
        end
        display:SetSize(width, 651)
        display:SetPoint("CENTER", 0, 0)
        display:SetMovable(true)
        display:EnableMouse(true)
        display:SetToplevel(true)
        display:SetScript("OnShow", display.OnShow)
        display:SetScript("OnHide", display.OnHide)
        display:Hide()

        ButtonFrameTemplate_HidePortrait(display)

        display:SetTitle("|cffe03d02Numy:|r Addon Profiler")

        local titleBar = CreateFrame("Frame", nil, display, "PanelDragBarTemplate")
        titleBar:SetPoint("TOPLEFT", 0, 0)
        titleBar:SetPoint("BOTTOMRIGHT", display, "TOPRIGHT", 0, -32)
        titleBar:Init(display)
        display.TitleBar = titleBar

        display.Inset:SetPoint("TOPLEFT", 8, -86)
        display.Inset:SetPoint("BOTTOMRIGHT", -4, 30)

        local historyMenu = CreateFrame("DropdownButton", nil, display, "WowStyle1DropdownTemplate");
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
        display.HistoryDropdown = historyMenu

        local search = CreateFrame("EditBox", "$parentSearchBox", display, "SearchBoxTemplate")
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

        local headers = CreateFrame("Button", "$parentHeaders", display, "ColumnDisplayTemplate")
        display.Headers = headers
        headers:SetPoint("BOTTOMLEFT", display.Inset, "TOPLEFT", 1, -1)
        headers:SetPoint("BOTTOMRIGHT", display.Inset, "TOPRIGHT", 0, -1)
        headers:LayoutColumns(COLUMN_INFO)

        --- @type FramePool<BUTTON,ColumnDisplayButtonTemplate>
        local headerPool = headers.columnHeaders
        for header in headerPool:EnumerateActive() do
            local arrow = header:CreateTexture("OVERLAY")
            arrow:SetAtlas("auctionhouse-ui-sortarrow", true)
            arrow:SetPoint("LEFT", header:GetFontString(), "RIGHT", 0, 0)
            arrow:Hide()
            header.Arrow = arrow

            header:SetScript("OnEnter", function(self)
                local info = COLUMN_INFO[self:GetID()]
                if not info.tooltip then return end
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine(self:GetText())
                GameTooltip:AddLine(info.tooltip, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            header:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
        end

        function headers:UpdateArrow(index)
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

        function headers:OnClick(index)
            local columnChanged = activeSort ~= index
            activeSort = index

            if columnChanged then
                activeOrder = ORDER_DESC
            else
                activeOrder = activeOrder == ORDER_DESC and ORDER_ASC or ORDER_DESC
            end
            updateSortComparator()

            self:UpdateArrow(index)
        end

        headers:UpdateArrow(activeSort)
        headers.Background:Hide()
        headers.TopTileStreaks:Hide()

        local buttonMixin = {}

        function buttonMixin:OnEnter()
            ---@type NAP_ElementData
            local data = self:GetElementData()
            if data then
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT", 5, 5)
                GameTooltip:AddLine(data.addonTitle)
                GameTooltip:AddLine(data.addonName, 1, 1, 1)
                local notes = NAP.addons[data.addonName] and NAP.addons[data.addonName].notes
                if notes and notes ~= "" then
                    GameTooltip:AddLine(notes, 1, 1, 1, true)
                end
                GameTooltip:AddLine(" ")
                if data.addonName == thisAddonName then
                    GameTooltip:AddLine("Note: The profiler has to do a lot of work while showing the UI, the numbers displayed here are not representative of the passive background CPU usage.", 1, 1, 1, true)
                    GameTooltip:AddLine(" ")
                end
                GameTooltip:AddDoubleLine("Peak CPU time:", TIME_FORMAT(data.peakTime), 1, 0.92, 0, 1, 1, 1)
                GameTooltip:AddDoubleLine("Average CPU time per frame:", TIME_FORMAT(data.averageMs), 1, 0.92, 0, 1, 1, 1)
                GameTooltip:AddDoubleLine("Total CPU time:", TIME_FORMAT(data.totalMs), 1, 0.92, 0, 1, 1, 1)
                GameTooltip:AddDoubleLine("Number of frames:", RAW_FORMAT(data.numberOfTicks), 1, 0.92, 0, 1, 1, 1)
                GameTooltip:Show()
            end
        end

        function buttonMixin:OnLeave()
            GameTooltip:Hide()
        end

        local scrollBox = CreateFrame("Frame", "$parentScrollBox", display, "WowScrollBoxList")
        scrollBox:SetPoint("TOPLEFT", display.Inset, "TOPLEFT", 4, -3)
        scrollBox:SetPoint("BOTTOMRIGHT", display.Inset, "BOTTOMRIGHT", -22, 2)
        display.ScrollBox = scrollBox

        local scrollBar = CreateFrame("EventFrame", "$parentScrollBar", display, "MinimalScrollBar")
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

        local view = CreateScrollBoxListLinearView(2, 0, 2, 2, 2)
        view:SetElementExtent(20)
        local buttonWidth = scrollBox:GetWidth() - 4
        view:SetElementInitializer("Button", function(button, data)
            if not button.created then
                Mixin(button, buttonMixin)
                button:SetSize(buttonWidth, 20)
                button:SetHighlightTexture("Interface\\BUTTONS\\WHITE8X8")
                button:GetHighlightTexture():SetVertexColor(0.1, 0.1, 0.1, 0.5)
                button:SetScript("OnEnter", button.OnEnter)
                button:SetScript("OnLeave", button.OnLeave)

                local offSet = 2
                local padding = 4
                button.columns = {}

                for i, column in ipairs(COLUMN_INFO) do
                    local text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                    if column.justifyLeft then
                        text:SetPoint("LEFT", offSet, 0)
                    else
                        text:SetPoint("RIGHT", (offSet + column.width - (padding * 2)) - buttonWidth, 0)
                    end
                    text:SetSize(column.width - (padding * 2.5), 0)
                    text:SetJustifyH(column.justifyLeft and "LEFT" or "RIGHT")
                    text:SetWordWrap(false)
                    button.columns[i] = text
                    offSet = offSet + (column.width - (padding / 2))
                end

                local bg = button:CreateTexture(nil, "BACKGROUND")
                bg:SetPoint("TOPLEFT")
                bg:SetPoint("BOTTOMRIGHT")
                button.BG = bg

                button.created = true
            end

            for i, column in ipairs(COLUMN_INFO) do
                button.columns[i]:SetText(column.textFormatter(data[column.textKey]))
            end
        end)

        ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

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

        local playButton = CreateFrame("Button", nil, display)
        playButton:SetPoint("BOTTOMLEFT", 4, 0)
        playButton:SetSize(32, 32)
        playButton:SetHitRectInsets(4, 4, 4, 4)
        playButton:SetNormalTexture("Interface\\Buttons\\UI-SquareButton-Up")
        playButton:SetPushedTexture("Interface\\Buttons\\UI-SquareButton-Down")
        playButton:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        display.PlayButton = playButton

        local playIcon = playButton:CreateTexture("OVERLAY")
        playIcon:SetSize(11, 15)
        playIcon:SetPoint("CENTER")
        playIcon:SetBlendMode("ADD")
        playIcon:SetTexCoord(10 / 32, 21 / 32, 9 / 32, 24 / 32)
        playButton.Icon = playIcon

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

        local updateButton = CreateFrame("Button", nil, display)
        updateButton:SetPoint("LEFT", playButton, "RIGHT", -6, 0)
        updateButton:SetSize(32, 32)
        updateButton:SetHitRectInsets(4, 4, 4, 4)
        updateButton:SetNormalTexture("Interface\\Buttons\\UI-SquareButton-Up")
        updateButton:SetPushedTexture("Interface\\Buttons\\UI-SquareButton-Down")
        updateButton:SetDisabledTexture("Interface\\Buttons\\UI-SquareButton-Disabled")
        updateButton:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        display.UpdateButton = updateButton

        local updateIcon = updateButton:CreateTexture("OVERLAY")
        updateIcon:SetSize(16, 16)
        updateIcon:SetPoint("CENTER", -1, -1)
        updateIcon:SetBlendMode("ADD")
        updateIcon:SetTexture("Interface\\Buttons\\UI-RefreshButton")
        updateButton.Icon = updateIcon

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
            NAP:PrepareFilteredData()

            local perc = display.ScrollBox:GetScrollPercentage()
            display.ScrollBox:Flush()

            if NAP.dataProvider then
                display.ScrollBox:SetDataProvider(NAP.dataProvider)
                display.ScrollBox:SetScrollPercentage(perc)
            end

            display.Stats:Update()
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

        local stats = display:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        stats:SetPoint("LEFT", updateButton, "RIGHT", 6, 0)
        stats:SetSize(300, 20)
        stats:SetJustifyH("LEFT")
        stats:SetWordWrap(false)
        display.Stats = stats

        local STATS_FORMAT = "|cfff8f8f2%s|r"
        function stats:Update()
            self:SetFormattedText(STATS_FORMAT, continuousUpdate and "Live Updating List" or "Paused")
        end

        self.ToggleButton = CreateFrame("Button", "$parentToggle", display, "UIPanelButtonTemplate, UIButtonTemplate")
        local toggleButton = self.ToggleButton
        toggleButton:SetPoint("BOTTOM", 0, 6)
        toggleButton:SetText(self:IsLogging() and "Disable" or "Enable")
        DynamicResizeButton_Resize(toggleButton)

        toggleButton:SetOnClickHandler(function()
            if self:IsLogging() then
                self:DisableLogging()
            else
                self:EnableLogging()
            end
        end)

        local resetButton = CreateFrame("Button", "$parentReset", display, "UIPanelButtonTemplate, UIButtonTemplate")
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

function NAP:IsLogging()
    return self.collectData
end

function NAP:EnableLogging()
    self.ToggleButton:SetText("Disable")
    DynamicResizeButton_Resize(self.ToggleButton)

    self.eventFrame:Show()
    self:StartPurgeTicker()

    self.ProfilerFrame.ScrollBox:Flush()
end

function NAP:DisableLogging()
    self.ToggleButton:SetText("Enable")
    DynamicResizeButton_Resize(self.ToggleButton)

    self.collectData = false

    self.eventFrame:Hide()
    if self.purgerTicker then
        self.purgerTicker:Cancel()
    end

    self:ResetMetrics()
    t_wipe(self.filteredData)
    self.dataProvider = nil
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
    self.db.minimap = self.db.minimap or {};

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
