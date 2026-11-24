-- Eqol Feature: Splitter & Belt Balancer Walk-Through + Compact 2/3 Height (+ Underground Belts)
-- 1. Neutralizes transient runtime FCharacterCollider entries in UCollisionEnv.Colliders and ignores
--    ECC_Pawn on splitter/belt balancer actors (NEVER mutating CDO/UMachineObject bColliderEnabled so
--    saves remain 100% vanilla and save-safe), leaving MachineBounds / building placement intact.
-- 2. Scales splitter, belt balancer, and underground belt meshes to 2/3 height (~0.67x Z), anchored at floor Z.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name       = "SplitterBalancerTweaks",
    Toggleable = false, -- Individual options (Walkthrough + CompactHeight) are registered as toggleable options
}

local FEAT_WALK   = "SplitterBalancerWalkthrough"
local FEAT_HEIGHT = "SplitterBalancerCompactHeight"

local HEIGHT_SCALE     = 2.0 / 3.0
local ECC_PAWN         = 2   -- ECollisionChannel::ECC_Pawn (WorldStatic=0, WorldDynamic=1, Pawn=2, Visibility=3)
local ECR_IGNORE       = 0   -- ECollisionResponse::ECR_Ignore
local ECR_BLOCK        = 2   -- ECollisionResponse::ECR_Block

local WALKTHROUGH_ACTOR_CLASSES = {
    "BP_Splitter_C",
    "BP_Splitter_2_C",
    "BP_Splitter_3_C",
    "BP_BeltBalancer_C",
    "BP_BeltBalancer_01_C",
    "BP_BeltBalancer_02_C",
    "BP_BeltBalancer_03_C",
}

local UNDERGROUND_ACTOR_CLASSES = {
    "BP_UndergroundBeltActor_C",
    "BP_UndergroundBeltActor_2_C",
    "BP_UndergroundBeltActor_3_C",
}

local WALKTHROUGH_SIM_CLASSES = {
    "BP_SplitterObject_C",
    "BP_SplitterObject_2_C",
    "BP_SplitterObject_3_C",
    "BPO_BeltBalancer_01_C",
    "BPO_BeltBalancer_02_C",
    "BPO_BeltBalancer_03_C",
}

local WALKTHROUGH_SIM_SET = {}
for _, clsName in ipairs(WALKTHROUGH_SIM_CLASSES) do
    WALKTHROUGH_SIM_SET[clsName] = true
end

local UNDERGROUND_SIM_SET = {
    BP_UndergroundBeltObject_C = true,
    BP_UndergroundBeltObject_2_C = true,
    BP_UndergroundBeltObject_3_C = true,
}

local ApplyDirectToMachineActors = nil

local OrigMeshState            = {} -- compAddr -> { ... }
local ProcessedHeightActors    = {} -- actorAddr -> true
local ProcessedCollisionActors = {} -- actorAddr -> true
local LoggedKeys               = {} -- key -> true
local NewObjHookRegistered     = false

local function SafeName(obj)
    if not Core.IsValidObj(obj) then return "nil" end
    local ok, n = pcall(function() return obj:GetFName():ToString() end)
    return (ok and type(n) == "string") and n or "?"
end

local function SafeClassName(obj)
    if not Core.IsValidObj(obj) then return "nil" end
    local ok, n = pcall(function() return obj:GetClass():GetFName():ToString() end)
    return (ok and type(n) == "string") and n or "?"
end

local function ExtractArray(tarr)
    local out = {}
    local count = 0
    if not tarr then return out, 0 end
    local okLen, len = pcall(function()
        return tarr.GetArrayNum and tarr:GetArrayNum() or #tarr
    end)
    if okLen and type(len) == "number" then
        for i = 1, len do
            local okE, elem = pcall(function() return tarr[i] end)
            if okE and elem ~= nil then
                local unwrapped = Core.UnwrapArrayElem(elem)
                if unwrapped then
                    count = i
                    out[i] = unwrapped
                end
            end
        end
        return out, count
    end
    pcall(function()
        tarr:ForEach(function(idx, elem)
            local unwrapped = Core.UnwrapArrayElem(elem)
            if unwrapped then
                if idx > count then count = idx end
                out[idx] = unwrapped
            end
        end)
    end)
    return out, count
end

local COLLIDER_DISABLE_MIN = 1000000000
local COLLIDER_DISABLE_MAX = -1000000000
local COLLIDER_STRIDE = 28

local WalkthroughSimIDs = {}
local TrackedSimFrames = {}
local TrackedEnvs = {}
local ProcessedEnvNums = {}
local NeedsEnvClean = false
local CachedAnchors = {}
local RegisteredSlotProps = {}
local RegisteredOffsetProps = {} -- persistent "clsPath:offset" -> { pMin, pMax, pCid }
local RegisteredOffsetPropCount = 0
local MAX_CUSTOM_SLOT_PROPS = 2048

local function GetObjectClassPath(obj)
    if not Core.IsValidObj(obj) then return nil end
    local ok, cls = pcall(function() return obj:GetClass() end)
    if not ok or not Core.IsValidObj(cls) then return nil end
    local okF, full = pcall(function() return cls:GetFullName() end)
    if not okF or type(full) ~= "string" then return nil end
    return full:match("^%S+ (.+)$") or full
end

local DISALLOWED_ANCHOR_CLASSES = {
    ["/Script/CoreUObject.Object"] = true,
    ["/Script/Engine.Actor"] = true,
    ["/Script/Engine.ActorComponent"] = true,
}

local function RecordAnchorCandidate(obj)
    if not Core.IsValidObj(obj) then return end
    local addr = obj:GetAddress()
    if type(addr) ~= "number" then return end
    if CachedAnchors[addr] then return end
    local clsPath = GetObjectClassPath(obj)
    if clsPath and not DISALLOWED_ANCHOR_CLASSES[clsPath] then
        CachedAnchors[addr] = { obj = obj, addr = addr, clsPath = clsPath }
    end
end

local function FindAnchorForRange(minAddr, maxAddr, preferredEnv)
    local function Fits(entry)
        if not entry or not Core.IsValidObj(entry.obj) then return false end
        local dMin = minAddr - entry.addr
        local dMax = maxAddr - entry.addr
        return dMin >= 0 and dMax >= 0 and dMax <= 0x7FFFFFFF
    end

    if Core.IsValidObj(preferredEnv) then
        RecordAnchorCandidate(preferredEnv)
        local pAddr = preferredEnv:GetAddress()
        if type(pAddr) == "number" and Fits(CachedAnchors[pAddr]) then
            return CachedAnchors[pAddr]
        end
    end

    for _, entry in pairs(CachedAnchors) do
        if Fits(entry) then return entry end
    end

    -- Never fall back to FindAllOf("Object") or FindAllOf("ActorComponent"): enumerating all engine
    -- UObjects freezes the game thread and risks polluting core engine UClasses with custom properties.
    -- Check fast early-allocated singletons first, then game-specific classes spread across the heap.
    for _, searchCls in ipairs({
        "GameInstance", "LocalPlayer", "GameViewportClient", "PlayerController",
        "World", "Level", "DMSObject", "StationObject", "MachineObject", "UserWidget",
    }) do
        local ok, list = pcall(FindAllOf, searchCls)
        if ok and list then
            for i = 1, #list do
                local obj = list[i]
                if Core.IsValidObj(obj) then
                    local addr = obj:GetAddress()
                    if type(addr) == "number" then
                        local dMin = minAddr - addr
                        local dMax = maxAddr - addr
                        if dMin >= 0 and dMax >= 0 and dMax <= 0x7FFFFFFF then
                            RecordAnchorCandidate(obj)
                            if CachedAnchors[addr] then
                                return CachedAnchors[addr]
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function EnsureSlotProps(elemAddr, preferredEnv)
    local existing = RegisteredSlotProps[elemAddr]
    if existing and Core.IsValidObj(existing.anchor.obj) then
        local d = elemAddr - existing.anchor.addr
        if d == existing.baseOffset then
            return existing
        end
    end

    if type(RegisterCustomProperty) ~= "function" or type(PropertyTypes) ~= "table" then
        return nil, "RegisterCustomProperty unavailable"
    end

    local anchor = FindAnchorForRange(elemAddr, elemAddr + 0x18, preferredEnv)
    if not anchor then
        return nil, string.format("no UObject anchor within +2GB below 0x%X", elemAddr)
    end

    local baseOffset = elemAddr - anchor.addr
    local offsetKey = anchor.clsPath .. ":" .. string.format("%X", baseOffset)
    local cachedNames = RegisteredOffsetProps[offsetKey]
    if cachedNames then
        local slot = {
            anchor = anchor,
            baseOffset = baseOffset,
            pMin = cachedNames.pMin,
            pMax = cachedNames.pMax,
            pCid = cachedNames.pCid,
        }
        RegisteredSlotProps[elemAddr] = slot
        return slot
    end

    if RegisteredOffsetPropCount >= MAX_CUSTOM_SLOT_PROPS then
        return nil, "custom property registration cap reached"
    end

    local tag = string.format("%X_%X", anchor.addr, baseOffset)
    local pMin = "EqolMinX_" .. tag
    local pMax = "EqolMaxX_" .. tag
    local pCid = "EqolCid_" .. tag

    local ok1, e1 = pcall(RegisterCustomProperty, {
        Name = pMin,
        Type = PropertyTypes.IntProperty,
        BelongsToClass = anchor.clsPath,
        OffsetInternal = baseOffset + 0x00,
    })
    local ok2, e2 = pcall(RegisterCustomProperty, {
        Name = pMax,
        Type = PropertyTypes.IntProperty,
        BelongsToClass = anchor.clsPath,
        OffsetInternal = baseOffset + 0x0C,
    })
    local ok3, e3 = pcall(RegisterCustomProperty, {
        Name = pCid,
        Type = PropertyTypes.IntProperty,
        BelongsToClass = anchor.clsPath,
        OffsetInternal = baseOffset + 0x18,
    })

    if not (ok1 and ok2 and ok3) then
        return nil, string.format("reg err min=(%s,%s) max=(%s,%s) cid=(%s,%s)",
            tostring(ok1), tostring(e1), tostring(ok2), tostring(e2), tostring(ok3), tostring(e3))
    end

    RegisteredOffsetProps[offsetKey] = { pMin = pMin, pMax = pMax, pCid = pCid }
    RegisteredOffsetPropCount = RegisteredOffsetPropCount + 1

    local slot = {
        anchor = anchor,
        baseOffset = baseOffset,
        pMin = pMin,
        pMax = pMax,
        pCid = pCid,
    }
    RegisteredSlotProps[elemAddr] = slot
    return slot
end

local LastWorldAddr = nil
local LoggedMultiplayerDisable = false

local function GetCurrentWorldAddr()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return nil end
    local okW, w = pcall(function() return pc:GetWorld() end)
    if okW and Core.IsValidObj(w) then
        return w:GetAddress()
    end
    return nil
end

-- Walk-through modifies transient local runtime collision envelopes.
-- Automatically disable walk-through in multiplayer (remote clients or host with >1 connected player)
-- to prevent client/server movement desync; visual 2/3 height scaling remains active.
-- NOTE: Main Sequence always runs solo saves as NM_ListenServer (GetNetMode() == 2, IsStandalone == false),
-- so we must check for remote client (IsServer == false / GetNetMode() == 3) or PlayerArray > 1.
local function IsMultiplayerSession()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then
        -- Controller not ready yet; treat as non-solo until valid so we never mutate early
        return true
    end

    local isMP = false

    -- 1. Remote client check via UKismetSystemLibrary:IsServer(WorldContext)
    local ksl = Core.GetCDO("/Script/Engine.Default__KismetSystemLibrary")
    if Core.IsValidObj(ksl) and ksl.IsServer then
        local okSrv, isServer = pcall(function() return ksl:IsServer(pc) end)
        if okSrv and isServer == false then
            isMP = true
        end
    end

    -- 2. Fallback remote client check via UWorld:GetNetMode() (3 = NM_Client) or pc:HasAuthority()
    if not isMP then
        local okW, w = pcall(function() return pc:GetWorld() end)
        if okW and Core.IsValidObj(w) and w.GetNetMode then
            local okNm, nm = pcall(function() return w:GetNetMode() end)
            if okNm and type(nm) == "number" and nm == 3 then
                isMP = true
            end
        end
        if not isMP and pc.HasAuthority then
            local okAuth, hasAuth = pcall(function() return pc:HasAuthority() end)
            if okAuth and hasAuth == false then
                isMP = true
            end
        end
    end

    -- 3. Active multiplayer check on host: GameState.PlayerArray > 1 connected player
    if not isMP then
        pcall(function()
            local w = pc:GetWorld()
            local gs = Core.IsValidObj(w) and w.GameState or nil
            if Core.IsValidObj(gs) and gs.PlayerArray then
                local len = gs.PlayerArray.GetArrayNum and gs.PlayerArray:GetArrayNum() or #gs.PlayerArray
                if type(len) == "number" and len > 1 then
                    isMP = true
                end
            end
        end)
    end

    return isMP
end

local function TrackSimEnv(simObj)
    local sAddr = simObj:GetAddress()
    if TrackedSimFrames[sAddr] then return end

    local gotID = false
    pcall(function()
        local id = simObj.ID
        if type(id) == "number" and id > 0 then
            gotID = true
            if not WalkthroughSimIDs[id] then
                WalkthroughSimIDs[id] = true
                NeedsEnvClean = true
            end
        end
    end)

    local gotEnv = false
    pcall(function()
        if not simObj.GetFrame then return end
        local frame = simObj:GetFrame()
        if not Core.IsValidObj(frame) or not frame.GetCollisionEnv then return end
        local env = frame:GetCollisionEnv()
        if Core.IsValidObj(env) then
            gotEnv = true
            local envAddr = env:GetAddress()
            if not TrackedEnvs[envAddr] then
                TrackedEnvs[envAddr] = env
                NeedsEnvClean = true
            end
        end
    end)

    if gotID and gotEnv then
        TrackedSimFrames[sAddr] = simObj
    end
end

local EnvCleanActive = false
local EnvCleanPending = false
local EnvCleanGen = 0

local function CleanTrackedEnvs()
    local anyID = next(WalkthroughSimIDs) ~= nil
    if not anyID then return end

    local dirty = NeedsEnvClean
    if not dirty then
        for envAddr, env in pairs(TrackedEnvs) do
            if Core.IsValidObj(env) and env.Colliders and env.Colliders.GetArrayNum then
                local curNum = tonumber(env.Colliders:GetArrayNum()) or -1
                if ProcessedEnvNums[envAddr] ~= curNum then
                    dirty = true
                    break
                end
            end
        end
    end
    if not dirty then return end

    if EnvCleanActive then
        EnvCleanPending = true
        return
    end
    EnvCleanActive = true
    EnvCleanPending = false
    NeedsEnvClean = false
    local myCleanGen = EnvCleanGen

    local envList = {}
    for envAddr, env in pairs(TrackedEnvs) do
        if not Core.IsValidObj(env) then
            TrackedEnvs[envAddr] = nil
            ProcessedEnvNums[envAddr] = nil
        else
            envList[#envList + 1] = { addr = envAddr, env = env }
        end
    end

    local eIdx = 1
    local curState = nil

    local function StepClean()
        if myCleanGen ~= EnvCleanGen then
            EnvCleanActive = false
            return
        end
        local tFrame0 = os.clock()
        local budgetEnd = tFrame0 + 0.0018

        if not curState then
            if eIdx > #envList then
                EnvCleanActive = false
                if EnvCleanPending and myCleanGen == EnvCleanGen then
                    EnvCleanPending = false
                    ExecuteInGameThreadAfterFrames(2, CleanTrackedEnvs)
                end
                return
            end
            local entry = envList[eIdx]
            eIdx = eIdx + 1
            local env = entry.env
            if not Core.IsValidObj(env) then
                TrackedEnvs[entry.addr] = nil
                ProcessedEnvNums[entry.addr] = nil
                ExecuteInGameThreadAfterFrames(2, StepClean)
                return
            end
            local cols, num, dataAddr = nil, 0, nil
            pcall(function()
                cols = env.Colliders
                if cols and cols.GetArrayNum then
                    num = tonumber(cols:GetArrayNum()) or 0
                    dataAddr = cols.GetArrayDataAddress and cols:GetArrayDataAddress() or nil
                end
            end)
            if not cols or num <= 0 or type(dataAddr) ~= "number" or dataAddr == 0 then
                if cols and num > 0 and not LoggedKeys["no_data_addr"] then
                    LoggedKeys["no_data_addr"] = true
                    Core.Log(string.format("[SplitterBalancerTweaks] Colliders:GetArrayDataAddress unavailable: type=%s val=%s",
                        type(dataAddr), tostring(dataAddr)))
                end
                ExecuteInGameThreadAfterFrames(2, StepClean)
                return
            end
            curState = {
                addr = entry.addr,
                env = env,
                cols = cols,
                num = num,
                dataAddr = dataAddr,
                i = 1,
                readErr = 0,
                firstErr = nil,
            }
        end

        local st = curState
        local ops = 0
        while st.i <= st.num and (ops < 4 or os.clock() < budgetEnd) and ops < 120 do
            local i = st.i
            st.i = i + 1
            ops = ops + 1
            local c = nil
            pcall(function() c = st.cols[i] end)
            if c then
                local okId, cid = pcall(function() return c.ColliderID end)
                if okId and type(cid) == "number" and WalkthroughSimIDs[cid] then
                    local elemAddr = st.dataAddr + (i - 1) * COLLIDER_STRIDE
                    local slot, slotErr = EnsureSlotProps(elemAddr, st.env)
                    if not slot then
                        st.readErr = st.readErr + 1
                        if not st.firstErr then st.firstErr = slotErr end
                        -- If no UObject anchor exists within +2GB below this TArray buffer, abort this env pass
                        -- immediately instead of repeating FindAllOf scans for every remaining collider!
                        if type(slotErr) == "string" and slotErr:find("no UObject anchor", 1, true) then
                            st.i = st.num + 1
                            break
                        end
                    else
                        local anchorObj = slot.anchor.obj
                        local okRead, gotCid, oldMin, oldMax = pcall(function()
                            return anchorObj[slot.pCid], anchorObj[slot.pMin], anchorObj[slot.pMax]
                        end)
                        if not okRead then
                            st.readErr = st.readErr + 1
                            if not st.firstErr then st.firstErr = tostring(gotCid) end
                        elseif gotCid ~= cid then
                            st.readErr = st.readErr + 1
                            if not st.firstErr then
                                st.firstErr = string.format("cid mismatch got=%s expected=%s at 0x%X",
                                    tostring(gotCid), tostring(cid), elemAddr)
                            end
                        elseif oldMin ~= COLLIDER_DISABLE_MIN or oldMax ~= COLLIDER_DISABLE_MAX then
                            local curDataAddr = nil
                            pcall(function() curDataAddr = st.cols.GetArrayDataAddress and st.cols:GetArrayDataAddress() or nil end)
                            if curDataAddr ~= st.dataAddr then
                                st.readErr = st.readErr + 1
                                if not st.firstErr then st.firstErr = "Colliders TArray reallocated mid-pass" end
                            else
                                local okWrite, errW = pcall(function()
                                    anchorObj[slot.pMin] = COLLIDER_DISABLE_MIN
                                    anchorObj[slot.pMax] = COLLIDER_DISABLE_MAX
                                end)
                                if not okWrite then
                                    st.readErr = st.readErr + 1
                                    if not st.firstErr then st.firstErr = tostring(errW) end
                                end
                            end
                        end
                    end
                end
            end
        end

        local elapsedMs = (os.clock() - tFrame0) * 1000.0
        if elapsedMs > 15.0 then
            Core.Log(string.format("[Perf] SplitterBalancerTweaks.CleanTrackedEnvs step took %.1fms (ops=%d/%d)", elapsedMs, ops, st.num))
        end

        if st.i <= st.num then
            ExecuteInGameThreadAfterFrames(2, StepClean)
        else
            ProcessedEnvNums[st.addr] = st.num
            if st.readErr > 0 and not LoggedKeys["env_err"] then
                LoggedKeys["env_err"] = true
                Core.Log(string.format("[SplitterBalancerTweaks] Env[%s] collider write err=%d (%s)",
                    tostring(st.addr), st.readErr, st.firstErr or "?"))
            end
            curState = nil
            ExecuteInGameThreadAfterFrames(2, StepClean)
        end
    end

    ExecuteInGameThreadAfterFrames(2, StepClean)
end

local function DisableSimCollider(simObj)
    if not Core.IsValidObj(simObj) then return end
    -- Save-safe: NEVER mutate CDO or simObj.bColliderEnabled (serialized into saves).
    -- Only track simObj.ID and its station's transient UCollisionEnv for runtime collider neutralization.
    TrackSimEnv(simObj)
end

local CachedPrimCls = nil
local CachedSmCls = nil
local ScanGeneration = 0

local function EnsureActorPawnIgnoreAndSimDisable(actor, simSeen, disabledCounts)
    local actorAddr = actor:GetAddress()
    local needCompScan = not ProcessedCollisionActors[actorAddr]

    -- Always check direct actor SimulationObject cheaply if available
    pcall(function()
        local s = actor.GetSimulationObject and actor:GetSimulationObject() or actor.SimulationObject
        if Core.IsValidObj(s) then
            local sAddr = s:GetAddress()
            if not simSeen[sAddr] then
                simSeen[sAddr] = true
                DisableSimCollider(s, disabledCounts)
            end
        end
    end)

    if not needCompScan then return end
    ProcessedCollisionActors[actorAddr] = true

    if not Core.IsValidObj(CachedPrimCls) then
        CachedPrimCls = Core.FindOrLoadClass("/Script/Engine.PrimitiveComponent")
    end
    local primCls = CachedPrimCls
    if not Core.IsValidObj(primCls) or not actor.K2_GetComponentsByClass then return end

    local comps, n = ExtractArray(actor:K2_GetComponentsByClass(primCls))
    for i = 1, n do
        local c = comps[i]
        if Core.IsValidObj(c) then
            pcall(function()
                if c.GetCollisionEnabled and c.GetCollisionResponseToChannel and c.SetCollisionResponseToChannel then
                    local colEn = tonumber(c:GetCollisionEnabled()) or 0
                    if colEn ~= 0 then
                        local resp = tonumber(c:GetCollisionResponseToChannel(ECC_PAWN))
                        if resp == ECR_BLOCK then
                            c:SetCollisionResponseToChannel(ECC_PAWN, ECR_IGNORE)
                        end
                    end
                end
                local s = c.GetSimulationObject and c:GetSimulationObject() or c.SimulationObject
                if Core.IsValidObj(s) then
                    local sAddr = s:GetAddress()
                    if not simSeen[sAddr] then
                        simSeen[sAddr] = true
                        DisableSimCollider(s, disabledCounts)
                    end
                end
            end)
        end
    end
end

local function ShouldScaleMeshComponent(comp)
    if not Core.IsValidObj(comp) then return false end
    local sm = nil
    pcall(function() sm = comp.StaticMesh end)
    if not Core.IsValidObj(sm) then return false end

    -- Skip hidden helper/trigger meshes (never call sm:GetFName(); UE4SS 0x18 crash trigger per learning.md §6)
    local hidden = false
    pcall(function() hidden = (comp.bHiddenInGame == true) end)
    if hidden then
        return false
    end
    return true
end

local function EnsureTargetHeight(actor)
    local actorAddr = actor:GetAddress()
    if ProcessedHeightActors[actorAddr] then return end
    ProcessedHeightActors[actorAddr] = true

    if not Core.IsValidObj(CachedSmCls) then
        CachedSmCls = Core.FindOrLoadClass("/Script/Engine.StaticMeshComponent")
    end
    local smCls = CachedSmCls
    if not Core.IsValidObj(smCls) or not actor.K2_GetComponentsByClass then return end

    local comps, n = ExtractArray(actor:K2_GetComponentsByClass(smCls))
    for i = 1, n do
        local c = comps[i]
        if ShouldScaleMeshComponent(c) then
            local cAddr = c:GetAddress()
            local st = OrigMeshState[cAddr]
            if not st then
                local rx, ry, rz = 0.0, 0.0, 0.0
                local sx, sy, sz = 1.0, 1.0, 1.0
                local oz, ez = 0.0, 0.0
                pcall(function()
                    -- Always read baseline transform from the unmodified archetype/template component
                    -- so scaling can never compound across restarts or cache refreshes.
                    local src = c.GetArchetype and c:GetArchetype() or nil
                    if not Core.IsValidObj(src) then src = c end

                    local rl = c.RelativeLocation or src.RelativeLocation
                    if rl then
                        rx = tonumber(rl.X) or 0.0
                        ry = tonumber(rl.Y) or 0.0
                        rz = tonumber(rl.Z) or 0.0
                    end
                    -- Use archetype Z only when live Z was already scaled, but NEVER overwrite live X/Y
                    -- (BP_UndergroundBeltActor_C moves S_Underground_Belt_02 to (-600, 0, 0) at runtime!)
                    local srcRl = src.RelativeLocation
                    if srcRl and type(srcRl.Z) == "number" then
                        rz = srcRl.Z
                    end
                    local rs = src.RelativeScale3D or c.RelativeScale3D
                    if rs then
                        sx = tonumber(rs.X) or 1.0
                        sy = tonumber(rs.Y) or 1.0
                        sz = tonumber(rs.Z) or 1.0
                    end
                    local sm = c.StaticMesh
                    if Core.IsValidObj(sm) and sm.ExtendedBounds then
                        local eb = sm.ExtendedBounds
                        if eb.Origin then oz = tonumber(eb.Origin.Z) or 0.0 end
                        if eb.BoxExtent then ez = tonumber(eb.BoxExtent.Z) or 0.0 end
                    end
                end)

                local targetSz = sz * HEIGHT_SCALE
                local targetLz = rz
                -- Only compensate RelativeLocation.Z if the mesh pivot is centered (not at floor Z=0)
                if ez > 15.0 and math.abs(oz - ez) > 2.0 then
                    local bottomZ = rz + (oz - ez) * sz
                    targetLz = bottomZ - (oz - ez) * targetSz
                end

                st = {
                    Comp = c,
                    OrigLocX = rx,
                    OrigLocY = ry,
                    OrigLocZ = rz,
                    OrigScaleX = sx,
                    OrigScaleY = sy,
                    OrigScaleZ = sz,
                    TargetScaleZ = targetSz,
                    TargetLocZ = targetLz,
                }
                OrigMeshState[cAddr] = st
            end

            pcall(function()
                if c.SetMobility and c.Mobility ~= 2 then
                    pcall(function() c:SetMobility(2) end) -- EComponentMobility::Movable
                end
                local curRs = c.RelativeScale3D
                local curSz = curRs and (tonumber(curRs.Z) or 1.0) or 1.0
                if math.abs(curSz - st.TargetScaleZ) > 0.005 then
                    c:SetRelativeScale3D({ X = st.OrigScaleX, Y = st.OrigScaleY, Z = st.TargetScaleZ })
                end
                local curRl = c.RelativeLocation
                local curLx = curRl and (tonumber(curRl.X) or st.OrigLocX) or st.OrigLocX
                local curLy = curRl and (tonumber(curRl.Y) or st.OrigLocY) or st.OrigLocY
                local curLz = curRl and (tonumber(curRl.Z) or 0.0) or 0.0
                if math.abs(curLz - st.TargetLocZ) > 0.05 then
                    c:K2_SetRelativeLocation({ X = curLx, Y = curLy, Z = st.TargetLocZ }, false, {}, false)
                end
            end)
        end
    end
end

local StaggeredScanActive = false
local StaggeredScanPending = false
local DebouncedScanScheduled = false
local DebouncedScanGen = 0

local function ResetWorldCaches()
    ScanGeneration = ScanGeneration + 1
    EnvCleanGen = EnvCleanGen + 1
    EnvCleanActive = false
    EnvCleanPending = false
    StaggeredScanActive = false
    StaggeredScanPending = false
    DebouncedScanScheduled = false
    DebouncedScanGen = DebouncedScanGen + 1
    OrigMeshState = {}
    ProcessedHeightActors = {}
    ProcessedCollisionActors = {}
    WalkthroughSimIDs = {}
    TrackedSimFrames = {}
    TrackedEnvs = {}
    ProcessedEnvNums = {}
    CachedAnchors = {}
    RegisteredSlotProps = {}
    CachedPrimCls = nil
    CachedSmCls = nil
    NeedsEnvClean = false
    LoggedMultiplayerDisable = false
end

local RegisteredActorClassHooks = {} -- clsPath -> true

local function RegisterDynamicActorHook(actor, isWalk)
    if not Core.IsValidObj(actor) then return end
    local clsPath = GetObjectClassPath(actor)
    if not clsPath or RegisteredActorClassHooks[clsPath] then return end
    RegisteredActorClassHooks[clsPath] = true
    pcall(NotifyOnNewObject, clsPath, function(newActor)
        if not Core.IsValidObj(newActor) then return end
        local allowWalk = isWalk and Core.IsFeatureEnabled(FEAT_WALK) and (not IsMultiplayerSession())
        local wantHeight = Core.IsFeatureEnabled(FEAT_HEIGHT)
        if not allowWalk and not wantHeight then return end
        local myGen = ScanGeneration
        ExecuteInGameThreadWithDelay(100, function()
            if myGen ~= ScanGeneration or not Core.IsValidObj(newActor) then return end
            if allowWalk then
                EnsureActorPawnIgnoreAndSimDisable(newActor, {}, {})
                pcall(CleanTrackedEnvs)
            end
            if wantHeight then
                EnsureTargetHeight(newActor)
            end
        end)
    end)
end

-- Exact 3 verified visual actor classes in Main Sequence (never scans 13+ guessed class names
-- or triggers FindAllOf("MachineObject") across distant empty stations).
local VERIFIED_ACTOR_SCAN_CLASSES = {
    { cls = "BP_Splitter_C",             isWalk = true  },
    { cls = "BP_BeltBalancer_01_C",      isWalk = true  },
    { cls = "BP_UndergroundBeltActor_C", isWalk = false },
}

local function RunStaggeredScan()
    if StaggeredScanActive then
        StaggeredScanPending = true
        return
    end
    StaggeredScanActive = true
    StaggeredScanPending = false
    local myGen = ScanGeneration

    local isMP = IsMultiplayerSession()
    local allowWalkthrough = Core.IsFeatureEnabled(FEAT_WALK) and (not isMP)
    local doHeight = Core.IsFeatureEnabled(FEAT_HEIGHT)
    if not allowWalkthrough and not doHeight then
        StaggeredScanActive = false
        return
    end
    if isMP and Core.IsFeatureEnabled(FEAT_WALK) then
        if not LoggedMultiplayerDisable then
            LoggedMultiplayerDisable = true
            Core.Log("[SplitterBalancerTweaks] Multiplayer session detected; walk-through automatically disabled (2/3 height remains active).")
        end
    end

    local simSeen = {}
    local disabledCounts = {}
    local clsIdx = 1
    local curActors = nil
    local actorIdx = 1
    local totalActorsSeen = 0

    local function Step()
        if myGen ~= ScanGeneration then
            StaggeredScanActive = false
            return
        end

        -- Fetch one verified actor class per tick (only 3 classes total, <0.5ms each)
        if not curActors then
            if clsIdx > #VERIFIED_ACTOR_SCAN_CLASSES then
                if allowWalkthrough then
                    pcall(CleanTrackedEnvs)
                end
                StaggeredScanActive = false
                if StaggeredScanPending and myGen == ScanGeneration then
                    StaggeredScanPending = false
                    ExecuteInGameThreadWithDelay(300, RunStaggeredScan)
                end
                return
            end
            local spec = VERIFIED_ACTOR_SCAN_CLASSES[clsIdx]
            local okF, list = pcall(FindAllOf, spec.cls)
            if okF and list and #list > 0 then
                curActors = list
                actorIdx = 1
                totalActorsSeen = totalActorsSeen + #list
            else
                clsIdx = clsIdx + 1
            end
            ExecuteInGameThreadAfterFrames(2, Step)
            return
        end

        local spec = VERIFIED_ACTOR_SCAN_CLASSES[clsIdx]
        local budgetEnd = os.clock() + 0.0018
        local ops = 0
        local total = #curActors
        while actorIdx <= total and (ops < 4 or os.clock() < budgetEnd) and ops < 24 do
            local actor = curActors[actorIdx]
            actorIdx = actorIdx + 1
            ops = ops + 1
            if Core.IsValidObj(actor) then
                RegisterDynamicActorHook(actor, spec.isWalk)
                local wantWalk = allowWalkthrough and spec.isWalk
                if wantWalk then
                    EnsureActorPawnIgnoreAndSimDisable(actor, simSeen, disabledCounts)
                end
                if doHeight then
                    EnsureTargetHeight(actor)
                end
            end
        end

        if actorIdx <= total then
            ExecuteInGameThreadAfterFrames(2, Step)
        else
            curActors = nil
            clsIdx = clsIdx + 1
            ExecuteInGameThreadAfterFrames(2, Step)
        end
    end

    ExecuteInGameThreadAfterFrames(2, Step)
end

local function ScheduleStaggeredScan(delayMs)
    if DebouncedScanScheduled then return end
    DebouncedScanScheduled = true
    DebouncedScanGen = DebouncedScanGen + 1
    local myDebGen = DebouncedScanGen
    local myGen = ScanGeneration
    ExecuteInGameThreadWithDelay(delayMs or 400, function()
        if myDebGen ~= DebouncedScanGen then return end
        DebouncedScanScheduled = false
        if myGen == ScanGeneration then
            RunStaggeredScan()
        end
    end)
end

ApplyDirectToMachineActors = function(obj, isWalk)
    if not Core.IsValidObj(obj) then return false end
    local foundActor = false
    local simSeen = {}
    local disabledCounts = {}

    local function handleActor(a)
        if not Core.IsValidObj(a) then return end
        foundActor = true
        if isWalk then
            EnsureActorPawnIgnoreAndSimDisable(a, simSeen, disabledCounts)
        end
        if Core.IsFeatureEnabled(FEAT_HEIGHT) then
            EnsureTargetHeight(a)
        end
    end

    pcall(function()
        local resolved = StationData.GetObjectActor and StationData.GetObjectActor(obj) or nil
        if Core.IsValidObj(resolved) then
            handleActor(resolved)
        end
        if Core.IsValidObj(obj.Actor) and (not Core.IsValidObj(resolved) or obj.Actor:GetAddress() ~= resolved:GetAddress()) then
            handleActor(obj.Actor)
        end
        if obj.Actors then
            local arr, n = ExtractArray(obj.Actors)
            for i = 1, n do
                handleActor(arr[i])
            end
        end
    end)
    return foundActor
end

local function RegisterMachineObjectHook()
    if NewObjHookRegistered then return end
    if not Core.IsFeatureEnabled(FEAT_WALK) and not Core.IsFeatureEnabled(FEAT_HEIGHT) then return end
    NewObjHookRegistered = true
    local function HandleNewTargetObj(obj, isWalk, isUg)
        if not Core.IsValidObj(obj) then return end
        local allowWalk = isWalk and Core.IsFeatureEnabled(FEAT_WALK) and (not IsMultiplayerSession())
        local wantHeight = Core.IsFeatureEnabled(FEAT_HEIGHT)
        if not allowWalk and not wantHeight then return end

        local myGen = ScanGeneration
        ExecuteInGameThreadWithDelay(150, function()
            if myGen ~= ScanGeneration or not Core.IsValidObj(obj) then return end
            if allowWalk then
                DisableSimCollider(obj)
                pcall(CleanTrackedEnvs)
            end
            if wantHeight or allowWalk then
                if not ApplyDirectToMachineActors(obj, allowWalk) or (allowWalk and not TrackedSimFrames[obj:GetAddress()]) then
                    ExecuteInGameThreadWithDelay(400, function()
                        if myGen ~= ScanGeneration or not Core.IsValidObj(obj) then return end
                        if allowWalk then
                            DisableSimCollider(obj)
                            pcall(CleanTrackedEnvs)
                        end
                        ApplyDirectToMachineActors(obj, allowWalk)
                    end)
                end
            end
        end)
    end
    -- Targeted NotifyOnNewObject ONLY on splitter / balancer / underground subclasses
    -- (never intercepts base MachineObject for every conveyor belt/machine spawned in the game!)
    for _, path in ipairs({
        "/Script/MainSequence.SplitterObject",
        "/Script/MainSequence.BeltBalancerObject",
        "/Game/Blueprints/Objects/Machines/Logistics/BP_SplitterObject.BP_SplitterObject_C",
        "/Game/Blueprints/Objects/Machines/Logistics/BPO_BeltBalancer_01.BPO_BeltBalancer_01_C",
    }) do
        pcall(NotifyOnNewObject, path, function(obj) HandleNewTargetObj(obj, true, false) end)
    end
    for _, path in ipairs({
        "/Script/MainSequence.UndergroundBeltObject",
        "/Game/Blueprints/Objects/Machines/Logistics/BP_UndergroundBeltObject.BP_UndergroundBeltObject_C",
    }) do
        pcall(NotifyOnNewObject, path, function(obj) HandleNewTargetObj(obj, false, true) end)
    end
end

local function RestoreOriginalHeights()
    for _, st in pairs(OrigMeshState) do
        if st and Core.IsValidObj(st.Comp) then
            pcall(function()
                st.Comp:SetRelativeScale3D({ X = st.OrigScaleX, Y = st.OrigScaleY, Z = st.OrigScaleZ })
                -- Preserve live X/Y (never move S_Underground_Belt_02 to archetype (0,0)!)
                local curRl = st.Comp.RelativeLocation
                local curLx = curRl and (tonumber(curRl.X) or st.OrigLocX) or st.OrigLocX
                local curLy = curRl and (tonumber(curRl.Y) or st.OrigLocY) or st.OrigLocY
                local curLz = curRl and (tonumber(curRl.Z) or st.OrigLocZ) or st.OrigLocZ
                if math.abs(curLz - st.OrigLocZ) > 0.05 then
                    st.Comp:K2_SetRelativeLocation({ X = curLx, Y = curLy, Z = st.OrigLocZ }, false, {}, false)
                end
            end)
        end
    end
    ProcessedHeightActors = {}
end

function Feature.Init()
    Core.RegisterToggleableOption({
        Name        = FEAT_WALK,
        DisplayName = "Splitter & Balancer Walk-Through (SP)",
        Description = "Allows walking through splitters and belt balancers in singleplayer (100% save-safe).",
        OnToggle    = function(enabled)
            if enabled then
                RegisterMachineObjectHook()
                ScheduleStaggeredScan(50)
            end
        end,
    })
    Core.RegisterToggleableOption({
        Name        = FEAT_HEIGHT,
        DisplayName = "Splitter, Balancer & Underground 2/3 Height",
        Description = "Scales splitters, belt balancers, and underground belts to 2/3 height.",
        OnToggle    = function(enabled)
            if enabled then
                RegisterMachineObjectHook()
                ProcessedHeightActors = {}
                ScheduleStaggeredScan(50)
            else
                RestoreOriginalHeights()
            end
        end,
    })

    LastWorldAddr = GetCurrentWorldAddr()
    if Core.IsFeatureEnabled(FEAT_WALK) or Core.IsFeatureEnabled(FEAT_HEIGHT) then
        RegisterMachineObjectHook()
        ScheduleStaggeredScan(1500)
    end
    Core.Log("[SplitterBalancerTweaks] Initialized.")
end

function Feature.OnClientRestart()
    local curWorld = GetCurrentWorldAddr()
    if curWorld == nil or curWorld ~= LastWorldAddr then
        LastWorldAddr = curWorld
        ResetWorldCaches()
    end
    if Core.IsFeatureEnabled(FEAT_WALK) or Core.IsFeatureEnabled(FEAT_HEIGHT) then
        RegisterMachineObjectHook()
        ScheduleStaggeredScan(1800)
    end
end

function Feature.OnMapLoad()
    LastWorldAddr = GetCurrentWorldAddr()
    ResetWorldCaches()
    if Core.IsFeatureEnabled(FEAT_WALK) or Core.IsFeatureEnabled(FEAT_HEIGHT) then
        RegisterMachineObjectHook()
        ScheduleStaggeredScan(2500)
    end
end

function Feature.PruneCaches()
    for addr, st in pairs(OrigMeshState) do
        if not st or not Core.IsValidObj(st.Comp) then
            OrigMeshState[addr] = nil
        end
    end
    for addr, entry in pairs(CachedAnchors) do
        if not entry or not Core.IsValidObj(entry.obj) then
            CachedAnchors[addr] = nil
        end
    end
    for addr, frame in pairs(TrackedSimFrames) do
        if not Core.IsValidObj(frame) then
            TrackedSimFrames[addr] = nil
        end
    end
    for addr, env in pairs(TrackedEnvs) do
        if not Core.IsValidObj(env) then
            TrackedEnvs[addr] = nil
            ProcessedEnvNums[addr] = nil
        end
    end
    for elemAddr, entry in pairs(RegisteredSlotProps) do
        if not entry or not entry.anchor or not Core.IsValidObj(entry.anchor.obj) then
            RegisteredSlotProps[elemAddr] = nil
        end
    end
end

return Feature
