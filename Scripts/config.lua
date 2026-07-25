-- PalTransportTimingProbe settings.
-- Restart the dedicated server after changing these values.

return {
    Enabled = true,
    InitialDelayMs = 5000,
    -- Reacquire UPalGameSetting and compare scalar values every 10 seconds.
    -- Use 0 to keep only the startup sample.
    GameSettingsPollIntervalMs = 10000,

    LogGameSettings = true,
    LogAssignments = true,
    LogRequirements = true,
    LogItemMoves = true,
    LogUnmatchedItemMoves = false,
    LogContainerUpdates = true,
    LogUnassignments = true,

    MaxTrackedWorkers = 512,
    MaxOperationsPerMoveEvent = 16,
    ContainerLogFirstEvents = 200,
    ContainerLogStride = 100,
    SummaryIntervalEvents = 100,
}
