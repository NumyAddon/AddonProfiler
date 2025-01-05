--- @meta _

---  11.1 will likely allow adding applicationPeakTime, applicationEncounterAvg, applicationRecentMs
--- @class NAP_ElementData
--- @field addonName string
--- @field addonTitle string
--- @field addonNotes string
--- @field peakTime number
--- @field overallPeakTime number
--- @field encounterAvg number
--- @field overallEncounterAvg number
--- @field recentMs number
--- @field overallRecentMs number
--- @field averageMs number
--- @field totalMs number
--- @field overallTotalMs number
--- @field applicationTotalMs number
--- @field numberOfTicks number
--- @field over1Ms number
--- @field over5Ms number
--- @field over10Ms number
--- @field over50Ms number
--- @field over100Ms number
--- @field over500Ms number
--- @field over1000Ms number
--- @field overMsSum number

--- @class NAP_AddonInfo
--- @field title string
--- @field notes string

--- @class NAP_Bucket
--- @field tickMap table<number, number> # tickIndex -> timestamp
--- @field lastTick table<string, table<number, number>> # addonName -> {tickIndex -> ms}
--- @field curTickIndex number

--- @class NAP_PartialSnapshot
--- @field startMetrics table<string, table<number, number>> # addonName -> {ms -> numberOfMsSpikes}
--- @field startTick number # 0 if in passive mode
--- @field startTime number
--- @field startTotal table<string, number> # addonName -> ms; empty table if in passive mode
--- @field bucketStartTick number # 0 if not in active mode
--- @field isComplete boolean # false until the snapshot is completed

--- @class NAP_Snapshot: NAP_PartialSnapshot
--- @field endMetrics table<string, table<number, number>> # addonName -> {ms -> numberOfMsSpikes}
--- @field endTick number # 0 if in passive mode
--- @field endTime number
--- @field startTotal nil
--- @field total nil|table<string, number> # addonName -> ms; nil if in passive mode
--- @field bossAvg table<string, number> # addonName -> ms
--- @field recentAvg table<string, number> # addonName -> ms
--- @field peakTime table<string, number> # addonName -> ms
--- @field bucket nil|NAP_Bucket # nil if not in active mode

--- @class NAP_CombatSnapshot
--- @field snapshot NAP_Snapshot|NAP_PartialSnapshot

--- @class NAP_EncounterSnapshot
--- @field snapshot NAP_Snapshot|NAP_PartialSnapshot
--- @field encounterID number
--- @field name string # encounter name
--- @field kill boolean
