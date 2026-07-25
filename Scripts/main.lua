local MOD_NAME = "PalTransportTimingProbe"
local VERSION = "0.2.0"
local CONFIG_PATH =
    "ue4ss/Mods/PalTransportTimingProbe/Scripts/config.lua"

local TRANSPORT_ASSIGN =
    "/Script/Pal.PalBaseCampModuleTransportItemDirector:OnAssignWorkTransportItemTarget"
local TRANSPORT_UNASSIGN =
    "/Script/Pal.PalBaseCampModuleTransportItemDirector:OnUnassignWorkTransportItemTarget"
local REQUIREMENT_ASSIGN =
    "/Script/Pal.PalBaseCampModuleTransportItemDirector:OnAssignWorkRequirement"
local REQUIREMENT_UNASSIGN =
    "/Script/Pal.PalBaseCampModuleTransportItemDirector:OnUnassignWorkRequirement"
local ITEM_MOVE_SERVER_INTERNAL =
    "/Script/Pal.PalEventNotify_ItemContainer:OnItemOperationMove_ServerInternal"
local CONTAINER_UPDATE =
    "/Script/Pal.PalBaseCampModuleTransportItemDirector:OnUpdateMapObjectContainer"

local WORK_SUITABILITY_TRANSPORT = 12
local UEHelpers = require("UEHelpers")

local function log(message)
    print("[" .. MOD_NAME .. "] " .. tostring(message) .. "\n")
end

local function load_config()
    local ok, value = pcall(dofile, CONFIG_PATH)
    if ok and type(value) == "table" then return value end
    log("[ERROR] config.lua could not be loaded: " .. tostring(value))
    return nil
end

local Config = load_config()
if not Config or Config.Enabled == false then
    return
end

local INITIAL_DELAY_MS = math.max(0,
    math.floor(tonumber(Config.InitialDelayMs) or 5000))
local SETTINGS_POLL_INTERVAL_MS = math.max(0,
    math.floor(tonumber(Config.GameSettingsPollIntervalMs) or 10000))
local MAX_TRACKED_WORKERS = math.max(1,
    math.floor(tonumber(Config.MaxTrackedWorkers) or 512))
local MAX_MOVE_OPERATIONS = math.max(1,
    math.floor(tonumber(Config.MaxOperationsPerMoveEvent) or 16))
local CONTAINER_LOG_FIRST = math.max(0,
    math.floor(tonumber(Config.ContainerLogFirstEvents) or 200))
local CONTAINER_LOG_STRIDE = math.max(1,
    math.floor(tonumber(Config.ContainerLogStride) or 100))
local SUMMARY_INTERVAL = math.max(0,
    math.floor(tonumber(Config.SummaryIntervalEvents) or 100))

local LOG_SETTINGS = Config.LogGameSettings ~= false
local LOG_ASSIGNMENTS = Config.LogAssignments ~= false
local LOG_REQUIREMENTS = Config.LogRequirements ~= false
local LOG_ITEM_MOVES = Config.LogItemMoves ~= false
local LOG_UNMATCHED_MOVES = Config.LogUnmatchedItemMoves == true
local LOG_CONTAINER_UPDATES = Config.LogContainerUpdates ~= false
local LOG_UNASSIGNMENTS = Config.LogUnassignments ~= false

local logged_errors = {}
local gameplay_statics = nil
local tracked_workers = {}
local tracked_order = {}
local last_game_settings = nil
local settings_missing = false

local GAME_SETTING_NAMES = {
    "WorkerCollectResourceStackMaxNum",
    "WorkTransportingDelayTimeDropItem",
    "WorkTransportingSpeedRate",
    "WorkTransportingItemNumRateInShouldTeleportWorker",
    "BaseCampWorkerDistancePickableItem",
    "DropItemWaitInsertMaxNumPerTick",
    "MergeDropItemRange",
    "WorkSuitabilityMaxRank",
}

local counters = {
    assignments = 0,
    assignment_posts = 0,
    assignment_take_out = 0,
    assignment_put_in = 0,
    requirement_assignments = 0,
    requirement_assignment_posts = 0,
    requirement_take_out = 0,
    requirement_put_in = 0,
    item_move_events = 0,
    matched_item_moves = 0,
    container_updates = 0,
    unassignments = 0,
    requirement_unassignments = 0,
}

local function log_error_once(key, message)
    if logged_errors[key] then return end
    logged_errors[key] = true
    log("[ERROR] " .. tostring(message))
end

local function unwrap_hook(value)
    if value == nil then return nil end
    local ok, result = pcall(function() return value:get() end)
    if ok then return result end
    return value
end

local function is_valid(value)
    if value == nil then return false end
    local ok, result = pcall(function() return value:IsValid() end)
    return ok and result == true
end

local function full_name(value)
    if not is_valid(value) then return "<invalid>" end
    local ok, result = pcall(function() return value:GetFullName() end)
    if ok and result ~= nil then return tostring(result) end
    return "<name-unavailable>"
end

local function format_number(value)
    value = tonumber(value)
    if value == nil then return "n/a" end
    return ("%.6g"):format(value)
end

local function format_guid_key(guid)
    if guid == nil then return nil end
    local ok, a, b, c, d = pcall(function()
        return tonumber(guid.A), tonumber(guid.B),
            tonumber(guid.C), tonumber(guid.D)
    end)
    if not ok or a == nil or b == nil or c == nil or d == nil then
        return nil
    end
    return table.concat({
        tostring(a), tostring(b), tostring(c), tostring(d)
    }, ":")
end

local function individual_id_key(value)
    if value == nil then return nil end
    local ok, guid = pcall(function() return value.InstanceId end)
    if not ok or guid == nil then return nil end
    return format_guid_key(guid)
end

local function ensure_gameplay_statics()
    if is_valid(gameplay_statics) then return gameplay_statics end
    local ok, value = pcall(function()
        return StaticFindObject("/Script/Engine.Default__GameplayStatics")
    end)
    if ok and is_valid(value) then
        gameplay_statics = value
        return gameplay_statics
    end
    return nil
end

local function now_ms()
    local statics = ensure_gameplay_statics()
    if statics ~= nil then
        local ok, value = pcall(function()
            local world = UEHelpers.GetWorld()
            return statics:GetRealTimeSeconds(world) * 1000.0
        end)
        if ok and tonumber(value) ~= nil then return tonumber(value) end
    end
    return os.clock() * 1000.0
end

local function delta_text(now, then_value)
    if then_value == nil then return "n/a" end
    return format_number(now - then_value)
end

local function remove_worker_state(key)
    if key == nil then return nil end
    local state = tracked_workers[key]
    if state == nil then return nil end
    tracked_workers[key] = nil
    for index = #tracked_order, 1, -1 do
        if tracked_order[index] == key then
            table.remove(tracked_order, index)
            break
        end
    end
    return state
end

local function set_worker_state(key, state)
    if key == nil then return end
    if tracked_workers[key] == nil then
        tracked_order[#tracked_order + 1] = key
    end
    tracked_workers[key] = state
    while #tracked_order > MAX_TRACKED_WORKERS do
        local oldest = table.remove(tracked_order, 1)
        tracked_workers[oldest] = nil
    end
end

local function get_or_create_worker_state(key)
    if key == nil then return nil end
    local state = tracked_workers[key]
    if state ~= nil then return state end
    state = {
        move_count = 0,
        target_active = false,
        requirement_active = false,
    }
    set_worker_state(key, state)
    return state
end

local function remove_worker_state_if_inactive(key, state)
    if key == nil or state == nil then return end
    if state.target_active or state.requirement_active then return end
    remove_worker_state(key)
end

local function get_work_assign_info(work_assign)
    work_assign = unwrap_hook(work_assign)
    if not is_valid(work_assign) then return nil end

    local ok_id, individual_id = pcall(function()
        return work_assign:GetAssignedIndividualId()
    end)
    local key = ok_id and individual_id_key(individual_id) or nil

    local parameter = nil
    local ok_parameter, parameter_value = pcall(function()
        return work_assign:GetAssignedIndividualParameter()
    end)
    if ok_parameter and is_valid(parameter_value) then
        parameter = parameter_value
    end

    local rank = nil
    if parameter ~= nil then
        local ok_rank, rank_value = pcall(function()
            return parameter:GetWorkSuitabilityRankWithCharacterRank(
                WORK_SUITABILITY_TRANSPORT)
        end)
        if ok_rank then rank = tonumber(rank_value) end
    end

    local worker_name = parameter and full_name(parameter) or "<unknown>"
    local ok_component, component = pcall(function()
        return work_assign:GetAssignedCharacterParameterComponent()
    end)
    if ok_component and is_valid(component) then
        local ok_owner, owner = pcall(function() return component:GetOwner() end)
        if ok_owner and is_valid(owner) then worker_name = full_name(owner) end
    end

    return {
        key = key,
        rank = rank,
        worker_name = worker_name,
    }
end

local function read_property(object, property_name)
    if not is_valid(object) then return nil end
    local ok, value = pcall(function() return object[property_name] end)
    if ok then return value end
    return nil
end

local function get_transport_type(work)
    work = unwrap_hook(work)
    local raw_value = unwrap_hook(read_property(work, "TransportType"))
    local value = tonumber(raw_value)
    if value == 0 then return value, "TakeOut" end
    if value == 1 then return value, "PutIn" end

    local text = tostring(raw_value)
    if text:find("TakeOut", 1, true) then return 0, "TakeOut" end
    if text:find("PutIn", 1, true) then return 1, "PutIn" end
    return value, "Unknown"
end

local function update_transport_type_counters(prefix, value)
    if value == 0 then
        counters[prefix .. "_take_out"] =
            (counters[prefix .. "_take_out"] or 0) + 1
    elseif value == 1 then
        counters[prefix .. "_put_in"] =
            (counters[prefix .. "_put_in"] or 0) + 1
    end
end

local function find_game_setting()
    local ok, instances = pcall(function()
        return FindAllOf("PalGameInstance")
    end)
    if not ok or instances == nil then return nil end
    for _, instance in ipairs(instances) do
        if is_valid(instance) then
            local setting = read_property(instance, "GameSetting")
            if is_valid(setting) then return setting end
        end
    end
    return nil
end

local function sample_game_settings(source, force_log)
    if not LOG_SETTINGS then return true end
    local setting = find_game_setting()
    if not is_valid(setting) then
        if not settings_missing then
            settings_missing = true
            log(("[SETTINGS_MISSING] source=%s"):format(tostring(source)))
        end
        return false
    end

    local values = {}
    local parts = {}
    for _, name in ipairs(GAME_SETTING_NAMES) do
        values[name] = tonumber(read_property(setting, name))
        parts[#parts + 1] = name .. "=" .. format_number(values[name])
    end

    if settings_missing then
        settings_missing = false
        log(("[SETTINGS_RESTORED] source=%s object=%s")
            :format(tostring(source), full_name(setting)))
    end

    if force_log or last_game_settings == nil then
        log(("[SETTINGS] source=%s object=%s %s")
            :format(tostring(source), full_name(setting),
                table.concat(parts, " ")))
    else
        local changes = {}
        for _, name in ipairs(GAME_SETTING_NAMES) do
            local old_value = last_game_settings[name]
            local new_value = values[name]
            if old_value ~= new_value then
                changes[#changes + 1] = name .. "=" ..
                    format_number(old_value) .. "->" ..
                    format_number(new_value)
            end
        end
        if #changes > 0 then
            log(("[SETTINGS_CHANGED] source=%s object=%s %s")
                :format(tostring(source), full_name(setting),
                    table.concat(changes, " ")))
        end
    end

    last_game_settings = values
    return true
end

local function maybe_log_summary()
    if SUMMARY_INTERVAL <= 0 then return end
    if counters.assignments == 0
        or counters.assignments % SUMMARY_INTERVAL ~= 0 then
        return
    end
    log(("[SUMMARY] targetAssignments=%d targetAssignmentPosts=%d " ..
        "targetTakeOut=%d targetPutIn=%d requirementAssignments=%d " ..
        "requirementAssignmentPosts=%d requirementTakeOut=%d " ..
        "requirementPutIn=%d itemMoveEvents=%d matchedItemMoves=%d " ..
        "containerUpdates=%d targetUnassignments=%d " ..
        "requirementUnassignments=%d trackedWorkers=%d")
        :format(
            counters.assignments,
            counters.assignment_posts,
            counters.assignment_take_out,
            counters.assignment_put_in,
            counters.requirement_assignments,
            counters.requirement_assignment_posts,
            counters.requirement_take_out,
            counters.requirement_put_in,
            counters.item_move_events,
            counters.matched_item_moves,
            counters.container_updates,
            counters.unassignments,
            counters.requirement_unassignments,
            #tracked_order))
end

local function on_assign_pre(context_param, work_param, work_assign_param)
    local ok, message = pcall(function()
        counters.assignments = counters.assignments + 1
        local now = now_ms()
        local info = get_work_assign_info(work_assign_param)
        local work = unwrap_hook(work_param)
        local transport_type, transport_phase = get_transport_type(work)
        update_transport_type_counters("assignment", transport_type)
        if info == nil or info.key == nil then
            if LOG_ASSIGNMENTS then
                log(("[ASSIGN_PRE] tMs=%s worker=<unresolved> " ..
                    "transportType=%s transportPhase=%s work=%s")
                    :format(
                        format_number(now),
                        format_number(transport_type),
                        transport_phase,
                        full_name(work)))
            end
            return
        end

        local state = get_or_create_worker_state(info.key)
        state.target_assign_ms = now
        state.target_active = true
        state.target_transport_type = transport_type
        state.target_transport_phase = transport_phase
        state.move_ms = nil
        state.move_count = 0
        state.rank = info.rank
        state.worker_name = info.worker_name
        if LOG_ASSIGNMENTS then
            log(("[ASSIGN_PRE] tMs=%s worker=%s rank=%s " ..
                "transportType=%s transportPhase=%s character=%s work=%s")
                :format(
                    format_number(now),
                    tostring(info.key),
                    format_number(info.rank),
                    format_number(transport_type),
                    transport_phase,
                    tostring(info.worker_name),
                    full_name(work)))
        end
        maybe_log_summary()
    end)
    if not ok then
        log_error_once("assign-pre",
            "assignment pre-hook failed: " .. tostring(message))
    end
end

local function on_assign_post(context_param, work_param, work_assign_param)
    local ok, message = pcall(function()
        counters.assignment_posts = counters.assignment_posts + 1
        local info = get_work_assign_info(work_assign_param)
        if info == nil or info.key == nil then return end
        local now = now_ms()
        local state = tracked_workers[info.key]
        if LOG_ASSIGNMENTS then
            log(("[ASSIGN_POST] tMs=%s worker=%s transportType=%s " ..
                "transportPhase=%s nativeMs=%s")
                :format(
                    format_number(now),
                    tostring(info.key),
                    format_number(state and state.target_transport_type),
                    tostring(state and state.target_transport_phase
                        or "Unknown"),
                    delta_text(now, state and state.target_assign_ms)))
        end
    end)
    if not ok then
        log_error_once("assign-post",
            "assignment post-hook failed: " .. tostring(message))
    end
end

local function on_requirement_assign_pre(
        context_param, work_param, work_assign_param)
    local ok, message = pcall(function()
        counters.requirement_assignments =
            counters.requirement_assignments + 1
        local now = now_ms()
        local info = get_work_assign_info(work_assign_param)
        local work = unwrap_hook(work_param)
        local transport_type, transport_phase = get_transport_type(work)
        update_transport_type_counters("requirement", transport_type)
        if info == nil or info.key == nil then
            if LOG_REQUIREMENTS then
                log(("[REQUIREMENT_ASSIGN_PRE] tMs=%s " ..
                    "worker=<unresolved> transportType=%s " ..
                    "transportPhase=%s work=%s")
                    :format(
                        format_number(now),
                        format_number(transport_type),
                        transport_phase,
                        full_name(work)))
            end
            return
        end

        local state = get_or_create_worker_state(info.key)
        state.requirement_assign_ms = now
        state.requirement_active = true
        state.requirement_transport_type = transport_type
        state.requirement_transport_phase = transport_phase
        state.rank = info.rank
        state.worker_name = info.worker_name
        if LOG_REQUIREMENTS then
            log(("[REQUIREMENT_ASSIGN_PRE] tMs=%s worker=%s rank=%s " ..
                "transportType=%s transportPhase=%s character=%s work=%s")
                :format(
                    format_number(now),
                    tostring(info.key),
                    format_number(info.rank),
                    format_number(transport_type),
                    transport_phase,
                    tostring(info.worker_name),
                    full_name(work)))
        end
    end)
    if not ok then
        log_error_once("requirement-assign-pre",
            "requirement assignment pre-hook failed: " ..
            tostring(message))
    end
end

local function on_requirement_assign_post(
        context_param, work_param, work_assign_param)
    local ok, message = pcall(function()
        counters.requirement_assignment_posts =
            counters.requirement_assignment_posts + 1
        local info = get_work_assign_info(work_assign_param)
        if info == nil or info.key == nil then return end
        local now = now_ms()
        local state = tracked_workers[info.key]
        if LOG_REQUIREMENTS then
            log(("[REQUIREMENT_ASSIGN_POST] tMs=%s worker=%s " ..
                "transportType=%s transportPhase=%s nativeMs=%s")
                :format(
                    format_number(now),
                    tostring(info.key),
                    format_number(
                        state and state.requirement_transport_type),
                    tostring(state and state.requirement_transport_phase
                        or "Unknown"),
                    delta_text(
                        now, state and state.requirement_assign_ms)))
        end
    end)
    if not ok then
        log_error_once("requirement-assign-post",
            "requirement assignment post-hook failed: " ..
            tostring(message))
    end
end

local function get_array_length(value)
    local ok, length = pcall(function() return #value end)
    if ok and tonumber(length) ~= nil then return tonumber(length) end
    return 0
end

local function on_item_move(context_param, operations_param)
    local ok, message = pcall(function()
        counters.item_move_events = counters.item_move_events + 1
        local operations = unwrap_hook(operations_param)
        local length = get_array_length(operations)
        local limit = math.min(length, MAX_MOVE_OPERATIONS)
        local matched = 0
        local now = now_ms()

        for index = 1, limit do
            local ok_operation, operation = pcall(function()
                return operations[index]
            end)
            if ok_operation and operation ~= nil then
                local ok_id, individual_id = pcall(function()
                    return operation.ExecutorIndividualId
                end)
                local key = ok_id and
                    individual_id_key(individual_id) or nil
                local state = key and tracked_workers[key] or nil
                if state ~= nil then
                    matched = matched + 1
                    counters.matched_item_moves =
                        counters.matched_item_moves + 1
                    state.move_count = (state.move_count or 0) + 1
                    state.move_ms = now
                    if LOG_ITEM_MOVES then
                        log(("[ITEM_MOVE] tMs=%s worker=%s operation=%d/%d " ..
                            "targetType=%s targetPhase=%s " ..
                            "requirementType=%s requirementPhase=%s " ..
                            "sinceTargetAssignMs=%s " ..
                            "sinceRequirementAssignMs=%s moveCount=%d")
                            :format(
                                format_number(now),
                                tostring(key),
                                index,
                                length,
                                format_number(
                                    state.target_transport_type),
                                tostring(state.target_transport_phase
                                    or "Unknown"),
                                format_number(
                                    state.requirement_transport_type),
                                tostring(
                                    state.requirement_transport_phase
                                    or "Unknown"),
                                delta_text(
                                    now, state.target_assign_ms),
                                delta_text(
                                    now, state.requirement_assign_ms),
                                state.move_count))
                    end
                end
            end
        end

        if LOG_ITEM_MOVES and LOG_UNMATCHED_MOVES and matched == 0 then
            log(("[ITEM_MOVE_UNMATCHED] tMs=%s operations=%d inspected=%d")
                :format(format_number(now), length, limit))
        end
    end)
    if not ok then
        log_error_once("item-move",
            "item move hook failed: " .. tostring(message))
    end
end

local function should_log_container_event(count)
    return count <= CONTAINER_LOG_FIRST
        or count % CONTAINER_LOG_STRIDE == 0
end

local function on_container_update(context_param, module_param)
    local ok, message = pcall(function()
        counters.container_updates = counters.container_updates + 1
        if LOG_CONTAINER_UPDATES
            and should_log_container_event(counters.container_updates) then
            local module = unwrap_hook(module_param)
            log(("[CONTAINER_UPDATE] tMs=%s count=%d module=%s " ..
                "trackedWorkers=%d")
                :format(
                    format_number(now_ms()),
                    counters.container_updates,
                    full_name(module),
                    #tracked_order))
        end
    end)
    if not ok then
        log_error_once("container-update",
            "container update hook failed: " .. tostring(message))
    end
end

local function on_target_unassign(
        context_param, work_param, individual_id_param)
    local ok, message = pcall(function()
        counters.unassignments = counters.unassignments + 1
        local individual_id = unwrap_hook(individual_id_param)
        local key = individual_id_key(individual_id)
        local now = now_ms()
        local state = key and tracked_workers[key] or nil
        local work = unwrap_hook(work_param)
        local transport_type, transport_phase = get_transport_type(work)
        if transport_type == nil and state ~= nil then
            transport_type = state.target_transport_type
            transport_phase = state.target_transport_phase or "Unknown"
        end
        if LOG_UNASSIGNMENTS then
            log(("[UNASSIGN] tMs=%s worker=%s transportType=%s " ..
                "transportPhase=%s sinceAssignMs=%s sinceMoveMs=%s " ..
                "moveCount=%s work=%s")
                :format(
                    format_number(now),
                    tostring(key or "<unresolved>"),
                    format_number(transport_type),
                    tostring(transport_phase),
                    delta_text(now, state and state.target_assign_ms),
                    delta_text(now, state and state.move_ms),
                    tostring(state and state.move_count or 0),
                    full_name(work)))
        end
        if state ~= nil then
            state.target_active = false
            remove_worker_state_if_inactive(key, state)
        end
    end)
    if not ok then
        log_error_once("target-unassign",
            "target unassign hook failed: " .. tostring(message))
    end
end

local function on_requirement_unassign(
        context_param, work_param, individual_id_param)
    local ok, message = pcall(function()
        counters.requirement_unassignments =
            counters.requirement_unassignments + 1
        local individual_id = unwrap_hook(individual_id_param)
        local key = individual_id_key(individual_id)
        local now = now_ms()
        local state = key and tracked_workers[key] or nil
        local work = unwrap_hook(work_param)
        local transport_type, transport_phase = get_transport_type(work)
        if transport_type == nil and state ~= nil then
            transport_type = state.requirement_transport_type
            transport_phase =
                state.requirement_transport_phase or "Unknown"
        end
        if LOG_REQUIREMENTS then
            log(("[REQUIREMENT_UNASSIGN] tMs=%s worker=%s " ..
                "transportType=%s transportPhase=%s " ..
                "sinceRequirementAssignMs=%s sinceTargetAssignMs=%s " ..
                "sinceMoveMs=%s moveCount=%s work=%s")
                :format(
                    format_number(now),
                    tostring(key or "<unresolved>"),
                    format_number(transport_type),
                    tostring(transport_phase),
                    delta_text(
                        now, state and state.requirement_assign_ms),
                    delta_text(now, state and state.target_assign_ms),
                    delta_text(now, state and state.move_ms),
                    tostring(state and state.move_count or 0),
                    full_name(work)))
        end
        if state ~= nil then
            state.requirement_active = false
            remove_worker_state_if_inactive(key, state)
        end
    end)
    if not ok then
        log_error_once("requirement-unassign",
            "requirement unassign hook failed: " .. tostring(message))
    end
end

local function register_hook(path, pre_callback, post_callback)
    local ok, pre_id, post_id = pcall(function()
        if post_callback ~= nil then
            return RegisterHook(path, pre_callback, post_callback)
        end
        return RegisterHook(path, pre_callback)
    end)
    if not ok or pre_id == nil then
        log(("[HOOK_FAILED] path=%s error=%s")
            :format(path, tostring(pre_id)))
        return false
    end
    log(("[HOOK_OK] path=%s preId=%s postId=%s")
        :format(path, tostring(pre_id), tostring(post_id)))
    return true
end

local started = false
local function start()
    if started then return end
    started = true
    ExecuteInGameThread(function()
        local settings_ok = sample_game_settings("startup", true)
        if not settings_ok then
            ExecuteWithDelay(3000, function()
                ExecuteInGameThread(function()
                    sample_game_settings("startup-retry", true)
                end)
            end)
        end

        local hook_count = 0
        if register_hook(TRANSPORT_ASSIGN,
            on_assign_pre, on_assign_post) then
            hook_count = hook_count + 1
        end
        if register_hook(TRANSPORT_UNASSIGN,
            on_target_unassign) then
            hook_count = hook_count + 1
        end
        if register_hook(REQUIREMENT_ASSIGN,
            on_requirement_assign_pre,
            on_requirement_assign_post) then
            hook_count = hook_count + 1
        end
        if register_hook(REQUIREMENT_UNASSIGN,
            on_requirement_unassign) then
            hook_count = hook_count + 1
        end
        if register_hook(ITEM_MOVE_SERVER_INTERNAL,
            on_item_move) then
            hook_count = hook_count + 1
        end
        if register_hook(CONTAINER_UPDATE,
            on_container_update) then
            hook_count = hook_count + 1
        end

        log(("[STARTED] version=%s hooks=%d readOnly=true " ..
            "settingsPollMs=%d maxTrackedWorkers=%d " ..
            "maxMoveOperations=%d")
            :format(
                VERSION,
                hook_count,
                SETTINGS_POLL_INTERVAL_MS,
                MAX_TRACKED_WORKERS,
                MAX_MOVE_OPERATIONS))
    end)

    if LOG_SETTINGS and SETTINGS_POLL_INTERVAL_MS > 0 then
        LoopAsync(SETTINGS_POLL_INTERVAL_MS, function()
            ExecuteInGameThread(function()
                local ok, message = pcall(
                    sample_game_settings, "poll", false)
                if not ok then
                    log_error_once("settings-poll",
                        "settings poll failed: " .. tostring(message))
                end
            end)
            return false
        end)
    end
end

ExecuteAsync(function()
    ExecuteWithDelay(INITIAL_DELAY_MS, start)
end)

log(("[LOADED] version=%s waitingInitialDelayMs=%d readOnly=true")
    :format(VERSION, INITIAL_DELAY_MS))
