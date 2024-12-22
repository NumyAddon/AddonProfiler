local thisAddonName = ...

local s_trim = _G.string.trim
local t_insert = _G.table.insert
local t_removemulti = _G.table.removemulti
local t_wipe = _G.table.wipe

local NAP = {};
NAP.eventFrame = CreateFrame('Frame');

_G.NumyAddonProfiler = NAP;

-- the metrics that can be fake reset, since they're just incremental
local resettableMetrics = {
    [Enum.AddOnProfilerMetric.CountTimeOver1Ms] = 'CountTimeOver1Ms',
    [Enum.AddOnProfilerMetric.CountTimeOver5Ms] = 'CountTimeOver5Ms',
    [Enum.AddOnProfilerMetric.CountTimeOver10Ms] = 'CountTimeOver10Ms',
    [Enum.AddOnProfilerMetric.CountTimeOver50Ms] = 'CountTimeOver50Ms',
    [Enum.AddOnProfilerMetric.CountTimeOver100Ms] = 'CountTimeOver100Ms',
    [Enum.AddOnProfilerMetric.CountTimeOver500Ms] = 'CountTimeOver500Ms',
    [Enum.AddOnProfilerMetric.CountTimeOver1000Ms] = 'CountTimeOver1000Ms',
};
local HISTORY_RANGES = {0, 5, 15, 30, 60, 120, 300, 600} -- 5sec - 10min
NAP.curHistoryRange = 30;

--- @type table<string, table<string, number>> [addonName] = { [metricName] = value }
NAP.initialMetrics = {};
--- @type table<string, table<string, number>> [addonName] = { [metricName] = value }
NAP.resetBaselineMetrics = NAP.initialMetrics;

NAP.snapshots = {};
--- @type table<string, { title: string, notes: string, loaded: boolean, loadedBeforeProfiler: boolean }>
NAP.addons = {};

--- Note: NAP:Init() is called at the end of the script body, BEFORE the addon_loaded event
function NAP:Init()
    for i = 1, C_AddOns.GetNumAddOns() do
        local addonName, title, notes = C_AddOns.GetAddOnInfo(i);
        self.initialMetrics[addonName] = {};
        for metric, metricName in pairs(resettableMetrics) do
            self.initialMetrics[addonName][metricName] = C_AddOnProfiler.GetAddOnMetric(addonName, metric);
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
            loaded = isLoaded,
            loadedBeforeProfiler = isLoaded,
        };
    end
    self.currentMetrics = CopyTable(self.initialMetrics);

    self.eventFrame:SetScript('OnUpdate', function() self:OnUpdate() end);
    self.eventFrame:SetScript('OnEvent', function(_, event, ...)
        if self[event] then self[event](self, ...); end
    end);
    self.eventFrame:RegisterEvent('ADDON_LOADED');

    self:InitDataCollector();
    SLASH_NUMY_ADDON_PROFILER1 = '/nap';
    SLASH_NUMY_ADDON_PROFILER2 = '/addonprofile';
    SLASH_NUMY_ADDON_PROFILER3 = '/addonprofiler';
    SLASH_NUMY_ADDON_PROFILER4 = '/addoncpu';
    SlashCmdList['NUMY_ADDON_PROFILER'] = function()
        self:ToggleFrame();
    end;
end

function NAP:ADDON_LOADED(addonName)
    if addonName == thisAddonName then
        AddonProfilerDB = AddonProfilerDB or {};
        self.db = AddonProfilerDB;
        self:InitUI();
        self:InitMinimapButton();
    end
    if 'BlizzMove' == addonName then
        self:RegisterIntoBlizzMove();
    end
    if not self.addons[addonName] then return end

    self.addons[addonName].loadedBeforeProfiler = false;
    self.addons[addonName].loaded = true;
end

local TIMESTAMP_INDEX = 1
local DATA_INDEX = 2
function NAP:OnUpdate()
    if not self.collectData then return end
    local snapshot;

    for addonName in pairs(self.addons) do
        if self.addons[addonName].loaded then
            local metrics = self:GetMetrics(addonName);
            if metrics then
                if not snapshot then snapshot = {[TIMESTAMP_INDEX] = GetTime(), [DATA_INDEX] = {}} end
                snapshot[DATA_INDEX][addonName] = metrics;
            end
        end
    end
    if snapshot then
        table.insert(self.snapshots, snapshot);
    end
end

function NAP:GetMetrics(addonName)
    local metrics;
    for metric, metricName in pairs(resettableMetrics) do
        local value = C_AddOnProfiler.GetAddOnMetric(addonName, metric);
        local currentMetric = self.currentMetrics[addonName][metricName] or 0;
        local adjustedValue = value - currentMetric;

        if adjustedValue > 0 then
            if not metrics then metrics = {} end
            metrics[metric] = adjustedValue;
        end
        self.currentMetrics[addonName][metricName] = value;
    end

    return metrics;
end

function NAP:ResetMetrics()
    self.resetBaselineMetrics = CopyTable(self.currentMetrics);
end

function NAP:PurgeOldData()
    local timestamp = GetTime();
    local rawData = self.snapshots;
    local cutoff = timestamp - HISTORY_RANGES[#HISTORY_RANGES];

    local to;

    for i = 1, #rawData do
        if rawData[i][TIMESTAMP_INDEX] > cutoff and i > 1 then
            to = i - 1;

            break;
        end
    end

    if to then
        -- don't ever use standard table.remove
        t_removemulti(rawData, 1, to);
    end
end

function NAP:InitDataCollector()
    self.collectData = true;
    -- continiously purge older entires
    self.purgerTicker = C_Timer.NewTicker(5, function() self:PurgeOldData() end)

end

function NAP:InitUI()
    local rawData = self.snapshots;
    self.filteredData = {};
    local filteredData = self.filteredData;
    self.dataProvider = nil;

    local ORDER_ASC = 1;
    local ORDER_DESC = -1;

    local TIME_FORMAT = "|cfff8f8f2%.3f|r|cfff92672ms|r";
    local ROUND_TIME_FORMAT = "|cfff8f8f2%d|r|cfff92672ms|r";
    local COLUMN_INFO = {
        {
            title = "Addon Name",
            width = 384,
            order = ORDER_ASC,
            textFormat = "%s",
            textKey = "addonTitle",
            sortMethods = {
                ---@param a NAP_ElementData
                ---@param b NAP_ElementData
                [ORDER_ASC] = function(a, b)
                    return a.addonTitle > b.addonTitle
                        or a.addonTitle == b.addonTitle
                        and a.addonName > b.addonName;
                end,
                ---@param a NAP_ElementData
                ---@param b NAP_ElementData
                [ORDER_DESC] = function(a, b)
                    return a.addonTitle < b.addonTitle
                        or a.addonTitle == b.addonTitle
                        and a.addonName < b.addonName;
                end,
            }
        },
        {
            title = "Peak Time",
            width = 96,
            order = ORDER_ASC,
            textFormat = TIME_FORMAT,
            textKey = "peakTime",
            tooltip = "Biggest spike in ms since logging in. This is not reset by reloading.",
            sortMethods = {
                ---@param a NAP_ElementData
                ---@param b NAP_ElementData
                [ORDER_ASC] = function(a, b)
                    return a.peakTime < b.peakTime
                        or a.peakTime == b.peakTime
                        and a.addonName < b.addonName;
                end,
                ---@param a NAP_ElementData
                ---@param b NAP_ElementData
                [ORDER_DESC] = function(a, b)
                    return a.peakTime > b.peakTime
                        or a.peakTime == b.peakTime
                        and a.addonName < b.addonName;
                end,
            },
        },
        {
            title = "Boss Avg",
            width = 96,
            order = ORDER_ASC,
            textFormat = TIME_FORMAT,
            textKey = "encounterAvg",
            tooltip = "Average time spent per frame during a boss encounter.",
            sortMethods = {
                ---@param a NAP_ElementData
                ---@param b NAP_ElementData
                [ORDER_ASC] = function(a, b)
                    return a.encounterAvg < b.encounterAvg
                        or a.encounterAvg == b.encounterAvg
                        and a.addonName < b.addonName;
                end,
                ---@param a NAP_ElementData
                ---@param b NAP_ElementData
                [ORDER_DESC] = function(a, b)
                    return a.encounterAvg > b.encounterAvg
                        or a.encounterAvg == b.encounterAvg
                        and a.addonName < b.addonName;
                end,
            },
        },
        {
            title = "Recent Avg",
            width = 96,
            order = ORDER_ASC,
            textFormat = TIME_FORMAT,
            textKey = "recentAvg",
            tooltip = "Average time spent in the last 60 frames.",
            sortMethods = {
                ---@param a NAP_ElementData
                ---@param b NAP_ElementData
                [ORDER_ASC] = function(a, b)
                    return a.recentAvg < b.recentAvg
                        or a.recentAvg == b.recentAvg
                        and a.addonName < b.addonName;
                end,
                ---@param a NAP_ElementData
                ---@param b NAP_ElementData
                [ORDER_DESC] = function(a, b)
                    return a.recentAvg > b.recentAvg
                        or a.recentAvg == b.recentAvg
                        and a.addonName < b.addonName;
                end,
            },
        },
    }
    local msOptions = {1, 5, 10, 50, 100, 500, 1000};
    for _, ms in ipairs(msOptions) do
        t_insert(COLUMN_INFO, {
            title = "Over " .. ms .. "ms",
            width = 96,
            order = ORDER_ASC,
            textFormat = "|cfff8f8f2%d|r |cfff92672x|r",
            textKey = "over" .. ms .. "Ms",
            tooltip = "How many times the addon took longer than " .. ms .. "ms per frame.",
            sortMethods = {
                ---@param a NAP_ElementData
                ---@param b NAP_ElementData
                [ORDER_ASC] = function(a, b)
                    return a["over" .. ms .. "Ms"] < b["over" .. ms .. "Ms"]
                        or a["over" .. ms .. "Ms"] == b["over" .. ms .. "Ms"]
                        and a.addonName < b.addonName;
                end,
                ---@param a NAP_ElementData
                ---@param b NAP_ElementData
                [ORDER_DESC] = function(a, b)
                    return a["over" .. ms .. "Ms"] > b["over" .. ms .. "Ms"]
                        or a["over" .. ms .. "Ms"] == b["over" .. ms .. "Ms"]
                        and a.addonName < b.addonName;
                end,
            },
        });
    end
    t_insert(COLUMN_INFO, {
        title = "Spike Sum",
        width = 96,
        order = ORDER_ASC,
        textFormat = ROUND_TIME_FORMAT,
        textKey = "overMsSum",
        tooltip = "Sum of all the separate spikes.",
        sortMethods = {
            ---@param a NAP_ElementData
            ---@param b NAP_ElementData
            [ORDER_ASC] = function(a, b)
                return a.overMsSum < b.overMsSum
                    or a.overMsSum == b.overMsSum
                    and a.addonName < b.addonName;
            end,
            ---@param a NAP_ElementData
            ---@param b NAP_ElementData
            [ORDER_DESC] = function(a, b)
                return a.overMsSum > b.overMsSum
                    or a.overMsSum == b.overMsSum
                    and a.addonName < b.addonName;
            end,
        },
    });

    local activeSort, activeOrder = #COLUMN_INFO, ORDER_DESC

    local UPDATE_INTERVAL = 1
    local continuousUpdate = true
    local curMatch = ".+"

    ---@class NAP_ElementData
    ---@field addonName string
    ---@field addonTitle string
    ---@field peakTime number
    ---@field encounterAvg number
    ---@field recentAvg number
    ---@field over1Ms number
    ---@field over5Ms number
    ---@field over10Ms number
    ---@field over50Ms number
    ---@field over100Ms number
    ---@field over500Ms number
    ---@field over1000Ms number
    ---@field overMsSum number

    local function prepareFilteredData()
        -- idc about recycling here, just wipe it
        t_wipe(filteredData)
        self.dataProvider = nil

        if not self.collectData then return end

        local minTimestamp = GetTime() - self.curHistoryRange;

        for addonName, info in pairs(self.addons) do
            if info.title:lower():match(curMatch) then
                ---@type NAP_ElementData
                ---@diagnostic disable-next-line: missing-fields
                local data = {
                    addonName = addonName,
                    addonTitle = info.title,
                    peakTime = C_AddOnProfiler.GetAddOnMetric(addonName, Enum.AddOnProfilerMetric.PeakTime),
                    encounterAvg = C_AddOnProfiler.GetAddOnMetric(addonName, Enum.AddOnProfilerMetric.EncounterAverageTime),
                    recentAvg = C_AddOnProfiler.GetAddOnMetric(addonName, Enum.AddOnProfilerMetric.RecentAverageTime),
                };
                if 0 == self.curHistoryRange then
                    for _, ms in ipairs(msOptions) do
                        local currentMetric = self.currentMetrics[addonName]['CountTimeOver' .. ms .. 'Ms'] or 0;
                        local baselineMetric = self.resetBaselineMetrics[addonName]['CountTimeOver' .. ms .. 'Ms'] or 0;
                        local adjustedValue = currentMetric - baselineMetric;
                        data["over" .. ms .. "Ms"] = adjustedValue;
                    end
                else
                    for _, snapshot in ipairs(self.snapshots) do
                        if snapshot[TIMESTAMP_INDEX] > minTimestamp then
                            local metrics = snapshot[DATA_INDEX][addonName];
                            if metrics then
                                for _, ms in ipairs(msOptions) do
                                    local adjustedValue = metrics[Enum.AddOnProfilerMetric['CountTimeOver' .. ms .. 'Ms']] or 0;
                                    data["over" .. ms .. "Ms"] = (data["over" .. ms .. "Ms"] or 0) + adjustedValue;
                                end
                            end
                        end
                    end
                end
                data.overMsSum = 0;
                local previousGroupCount = 0;
                for _, ms in ipairs_reverse(msOptions) do
                    data["over" .. ms .. "Ms"] = data["over" .. ms .. "Ms"] or 0;
                    local count = data["over" .. ms .. "Ms"];
                    data.overMsSum = data.overMsSum + ((count - previousGroupCount) * ms);
                    previousGroupCount = count;
                end

                t_insert(filteredData, data);
            end
        end

        self.dataProvider = CreateDataProvider(filteredData)
    end

    local function sortFilteredData()
        if self.dataProvider then
            self.dataProvider:SetSortComparator(COLUMN_INFO[activeSort].sortMethods[activeOrder])
        end
    end

    -------------
    -- DISPLAY --
    -------------
    do
        local profilerFrameMixin = {}

        function profilerFrameMixin:OnUpdate(elapsed)
            self.elapsed = (self.elapsed or 0) + elapsed
            if self.elapsed >= UPDATE_INTERVAL then
                prepareFilteredData()
                sortFilteredData()

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
        local display = self.ProfilerFrame
        local width = 2;
        for _, info in pairs(COLUMN_INFO) do
            width = width + info.width
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

            prepareFilteredData();
            sortFilteredData();

            local perc = display.ScrollBox:GetScrollPercentage();
            display.ScrollBox:Flush();

            if self.dataProvider then
                display.ScrollBox:SetDataProvider(self.dataProvider);
                display.ScrollBox:SetScrollPercentage(perc);
            end
            display.Stats:Update();
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
            curMatch = text == "" and ".+" or text

            prepareFilteredData()
            sortFilteredData()

            local perc = display.ScrollBox:GetScrollPercentage()
            display.ScrollBox:Flush()

            if NAP.dataProvider then
                display.ScrollBox:SetDataProvider(NAP.dataProvider)
                display.ScrollBox:SetScrollPercentage(perc)
            end

            display.Stats:Update()
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
            activeSort = index

            COLUMN_INFO[index].order = COLUMN_INFO[index].order * -1
            activeOrder = COLUMN_INFO[index].order

            sortFilteredData()

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
                GameTooltip:SetOwner(self, "ANCHOR_NONE")
                GameTooltip:SetPoint("TOPLEFT", self, "TOPRIGHT", 26, 2)
                GameTooltip:AddLine(data.addonTitle)
                GameTooltip:AddLine(data.addonName, 1, 1, 1)
                local notes = NAP.addons[data.addonName] and NAP.addons[data.addonName].notes
                if notes and notes ~= "" then
                    GameTooltip:AddLine(notes, 1, 1, 1, true)
                end
                GameTooltip:AddDoubleLine("Peak Time (since game start):", TIME_FORMAT:format(data.peakTime), 1, 0.92, 0, 1, 1, 1)
                GameTooltip:AddDoubleLine("Encounter Avg:", TIME_FORMAT:format(data.encounterAvg), 1, 0.92, 0, 1, 1, 1)
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

        local view = CreateScrollBoxListLinearView(2, 0, 2, 2, 2)
        view:SetElementExtent(20)
        view:SetElementInitializer("Button", function(button, data)
            if not button.created then
                Mixin(button, buttonMixin)
                button:SetSize(1000, 20)
                button:SetHighlightTexture("Interface\\BUTTONS\\WHITE8X8")
                button:GetHighlightTexture():SetVertexColor(0.1, 0.1, 0.1, 0.5)
                button:SetScript("OnEnter", button.OnEnter)
                button:SetScript("OnLeave", button.OnLeave)

                local offSet = 0
                local padding = 2
                button.columns = {}

                for i, column in ipairs(COLUMN_INFO) do
                    local text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                    text:SetPoint("LEFT", offSet, 0)
                    text:SetSize(column.width - padding, 0)
                    text:SetJustifyH("LEFT")
                    text:SetWordWrap(false)
                    button.columns[i] = text
                    offSet = offSet + column.width
                end

                local bg = button:CreateTexture(nil, "BACKGROUND")
                bg:SetPoint("TOPLEFT")
                bg:SetPoint("BOTTOMRIGHT")
                button.BG = bg

                button.created = true
            end

            for i, column in ipairs(COLUMN_INFO) do
                button.columns[i]:SetText(column.textFormat:format(data[column.textKey]))
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
            prepareFilteredData()
            sortFilteredData()

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

        local STATS_FORMAT = "|cfff8f8f2%s |cff75715e-|r %d |cff75715e/ %d|r"

        local stats = display:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        stats:SetPoint("LEFT", updateButton, "RIGHT", 6, 0)
        stats:SetSize(300, 20)
        stats:SetJustifyH("LEFT")
        stats:SetWordWrap(false)
        display.Stats = stats

        function stats:Update()
            self:SetFormattedText(STATS_FORMAT, continuousUpdate and "Updating" or "Paused", #filteredData, #rawData)
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
        end)
    end
end

function NAP:IsLogging()
    return self.collectData
end

function NAP:EnableLogging()
    self.ToggleButton:SetText("Disable")
    DynamicResizeButton_Resize(self.ToggleButton)

    self.collectData = true

    if self.purgerTicker then
        self.purgerTicker:Cancel()
    end

    self.purgerTicker = C_Timer.NewTicker(5, function() self:PurgeOldData() end)

    self.ProfilerFrame.ScrollBox:Flush()
end

function NAP:DisableLogging()
    self.ToggleButton:SetText("Enable")
    DynamicResizeButton_Resize(self.ToggleButton)

    self.collectData = false

    if self.purgerTicker then
        self.purgerTicker:Cancel()
    end

    t_wipe(self.snapshots)
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
            OnClick = function(minimapButton, button)
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
            end,
        }
    );
    LibStub('LibDBIcon-1.0'):Register(name, dataObject, self.db.minimap);
end

NAP:Init();