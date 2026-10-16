local ref = cloneref or function(value)
    return value
end

local Players = ref(game:GetService("Players"))
local ReplicatedStorage = ref(game:GetService("ReplicatedStorage"))
local TweenService = ref(game:GetService("TweenService"))
local RunService = ref(game:GetService("RunService"))
local UserInputService = ref(game:GetService("UserInputService"))
local Workspace = ref(game:GetService("Workspace"))
local Debris = ref(game:GetService("Debris"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Camera = Workspace.CurrentCamera
local AimMouse = LocalPlayer:GetMouse()

local ENV = (getgenv and getgenv()) or _G
if type(ENV.__ALEXK_UNLOAD) == "function" then
    pcall(ENV.__ALEXK_UNLOAD)
elseif type(ENV.__HARD_STICKY_HRP_UNLOAD) == "function" then
    -- Cleanly replace an older build of this script if it is still injected.
    pcall(ENV.__HARD_STICKY_HRP_UNLOAD)
end

local Config = {
    Aimview_Notifier = true,
    Mod_Detection = "Notify", -- "None", "Notify", "Kick"

    Aimbot = {
        Enabled = true,
        ActivationKey = Enum.KeyCode.C,
        KeyMode = "toggle",
        TargetPart = "HumanoidRootPart",
        Strength = 1.000, -- max mouse-lock smoothness/response
        Radius = 120,
        MaxDistance = math.huge, -- infinite lock distance
        Mode = "SilentMouse", -- video-style mouse hit lock; camera/crosshair stay free

        Prediction = {
            Enabled = true,
            XDivision = 16,
            YDivision = 20,
        },

        StickyAim = true,
        RequireFovWhileSticky = false,
        TeamCheck = false,
        WallCheck = false, -- requested: lock can acquire through walls
        VisibleCheck = false,
        DeadCheck = true,
        KOCheck = true,

        DrawFOV = false,
        FOVTransparency = 0.5,
        FOVThickness = 2,
    },

    ESP = {
        Enabled = false,
        ActivationKey = Enum.KeyCode.G,
        ShowName = true,
        ShowHealth = true,
        ShowDistance = true,
        ShowHealthBar = true,
        ShowOffscreen = true,
        HighlightTarget = true,
        Color = Color3.fromRGB(209, 179, 182), -- match the GUI accent
        UpdateRate = 10, -- performance: normal ESP refresh stays low; health changes can force an immediate lightweight refresh
        HealthDirty = false,
        HUDHealthDirty = false,
    },
}

local Unloaded = false
local Connections = {}
local BlacklistedUserIds = {}
local PresentBlacklistedTargets = false
local ESPEntries = {}
local ThumbnailCache = {}
local NotifIndex = 0
local RENDER_BIND_NAME = "alex.ftn_Render"
local OriginalMouseIndex = nil
local SilentMouseInstalled = false

local Aim = {
    Active = false,
    Toggled = false,
    CurrentTarget = nil,
    SmoothedVelocity = Vector3.zero,
    LockedUserId = nil,
}

-- AllIn1 is an E-key action that uses ONLY the current C-locked target.
-- It never changes normal C acquisition or adds a visibility requirement to C.
local AllIn1 = {
    Busy = false,
    Firing = false,
    FiringUntil = 0,
    Token = 0,
    -- Combat hook radius. 1 stud was close enough for the weapon muzzle/handle
    -- to overlap the target body on some guns, which can consume ammo while the
    -- server rejects the hit. Keep the HRP 1.5 studs out and orbit moderately.
    OrbitRadius = 1.5,
    OrbitAngularSpeed = 3.60, -- radians/sec (~206 deg/sec): clear moderate orbit during the fixed 0.10s hold
    PreFireOrbitTime = 0.10, -- fixed pre-fire orbit hold for all target speeds
    FinalOriginSettleTime = 0.018, -- one short replication slice after the orbit freezes before fire
    MinMuzzleTargetDistance = 0.65,
    MaxMuzzleTargetDistance = 6.00,
    NormalOriginConfirmFrames = 2,
    MaxDuration = 1.25,
    FastTargetSpeed = 200,
    FastTargetVerticalSpeed = 100,
    ExtremeTargetSpeed = 280,
    ExtremeTargetVerticalSpeed = 150,

    -- 200+ stud/s targets need fresher replication samples, not long stale waits.
    -- The fire gate below remains intact; these only tune how quickly fast motion
    -- can earn READY and how much network lead the aim path may use.
    FastAimLeadTime = 0.046,
    ExtremeAimLeadTime = 0.056,
    FastAimLeadCap = 8.5,
    ExtremeAimLeadCap = 12.5,

    -- E/H shot safety: inspect replicated HRP motion before committing to the
    -- teleport, settle on the latest HRP, then send ONE deliberate fire input and
    -- wait for damage/KO confirmation before retrying. This avoids stacking
    -- Tool:Activate + firesignal + mouse input on the same frame.
    -- Deliberately slower readiness timings. E/H now SCAN -> DETECT -> READY -> FIRE
    -- instead of reaching the fire input as soon as only a couple frames look good.
    PrecheckTime = 0.055,
    FastPreTeleportWait = 0.020,
    ExtremePreTeleportWait = 0.024,
    NormalSettleTime = 0.050,
    FastSettleTime = 0.018,
    ExtremeSettleTime = 0.024,

    -- ARRIVAL CHECK happens after the teleport/hook. The local HRP is hard-followed
    -- at the configured 1.5-stud orbit radius while we sample again.
    -- A shot is not allowed until the arrival samples are stable + unobstructed.
    NormalArrivalMinTime = 0.055,
    FastArrivalMinTime = 0.018,
    ExtremeArrivalMinTime = 0.024,
    NormalArrivalTimeout = 0.18,
    FastArrivalTimeout = 0.085,
    ExtremeArrivalTimeout = 0.10,
    NormalArrivalStableFrames = 2,
    FastArrivalStableFrames = 1,
    ExtremeArrivalStableFrames = 1,

    -- Damage replication can arrive after the local magazine decrement.  Give the
    -- server enough time to reflect a real hit before calling it a miss; this does
    -- not delay the shot itself, only the verification result.
    NormalShotVerifyTime = 0.30,
    FastShotVerifyTime = 0.40,
    ExtremeShotVerifyTime = 0.48,
    ShotRetryGap = 0.045,
    NormalStableFrames = 2,
    FastStableFrames = 1,
    ExtremeStableFrames = 1,
    NormalClearFrames = 1,
    FastClearFrames = 1,
    ExtremeClearFrames = 1,
    NormalReadyTimeout = 0.18,
    FastReadyTimeout = 0.070,
    ExtremeReadyTimeout = 0.085,
    MaxSafeShotAttempts = 2,
    -- The actual gun aim point is updated only from the live locked HRP. Keeping
    -- it on AllIn1 avoids adding more main-chunk locals near Luau's local limit.
    ShotAimPosition = nil,
    ShotTargetPart = nil,
    LastShotRayDetail = "not sampled",
    ShotGeometryReady = false,
    AttackAnchoredRoot = nil,

    -- Auto reload state. Capacities are intentionally fixed to the user's
    -- requested gun sizes so no other weapon behavior is changed.
    Reloading = false,
    ReloadToken = 0,
    ReloadTool = nil,
    ReloadHeartbeatAt = 0, -- watchdog timestamp so an errored reload task can never leave Reloading stuck forever
    ReloadInterval = 0.060, -- fast but leaves enough time for shell/mag state to replicate between pulses
    ReloadUnknownPulseLimit = 28,
    ShotCounts = setmetatable({}, { __mode = "k" }),
    LastShotSignal = setmetatable({}, { __mode = "k" }),
    ReloadHooked = setmetatable({}, { __mode = "k" }),

    -- Fake Pos tool/origin reliability. Keep this state on AllIn1 so the main
    -- Luau chunk does not spend additional top-level locals near the register limit.
    -- This does NOT bypass the game's origin validation: it only stops stale fire
    -- inputs, reacquires the live equipped Tool, and makes one bounded re-equip
    -- attempt if the server/game moved the exact Tool back into Backpack.
    LastEquippedTool = nil,
    LastEquippedToolName = nil,
    LastEquippedSeenAt = 0,
    ToolRecoveryBusy = false,
    ToolRecoveryToken = 0,
    ToolRecoveryNextAt = 0,
    ToolRecoveryDelay = 0.08,
    ToolRecoveryCooldown = 0.70,
    ToolRecoveryScanNextAt = 0,
    ToolRecoveryScanInterval = 0.08,
    OriginScanNextAt = 0,
    OriginScanInterval = 0.25,
    OriginTextCache = setmetatable({}, { __mode = "k" }),
    OriginTextCacheReady = false,
    OriginTextCacheGui = nil,
    OriginErrorLatched = false,
    OriginBlockedUntil = 0,

    -- Stomp never returns just because a timer expired. It stays on the exact
    -- target until a real post-stomp/dead/respawn state is observed or the
    -- whole action is explicitly cancelled/unloaded. One stomp pulse is sent
    -- every Heartbeat so target count/load can never degrade it to ~30 Hz.
    Stomping = false,
    StompToken = 0,
    StompInterval = 0,
    LastShotAttempts = 0,

    -- Fast-target replication/QOL. While E/H is physically following a moving
    -- target, mirror a capped copy of that HRP velocity so the local shot origin
    -- does not look stationary to replication while the target is flintlocking.
    MatchVelocityCap = 900, -- base only; high-speed matching scales dynamically up to ObservedMotionCap

    -- CFrame/fly tracking. AssemblyLinearVelocity can stay near zero while a
    -- character is being moved by direct CFrame writes, so E/H also derive a
    -- short-lived observed velocity from replicated HRP position deltas. The
    -- cache is weak-keyed so old HRPs disappear automatically after respawns.
    MotionSamples = setmetatable({}, { __mode = "k" }),
    ObservedMotionCap = 5000, -- safety ceiling; 300+ / 500+ / 1000+ motion stays measurable instead of being crushed
    CFrameStepThreshold = 0.55,
    CFrameSpeedThreshold = 55,
    CFrameMismatchThreshold = 80,
    CFramePreTeleportWait = 0.012,
    CFrameSettleTime = 0.012,
    CFrameArrivalMinTime = 0.012,
    CFrameArrivalTimeout = 0.075,
    CFrameReadyTimeout = 0.060,
    CFrameShotVerifyTime = 0.54,
    CFrameAimLeadTime = 0.0035,
    CFrameAimLeadCap = 2.60,

    -- E/H are physically only ~1 stud from the target when they fire. This is
    -- speed-adaptive for EVERY fast target, not a 300-stud/s special case: 300,
    -- 500, 1000+ studs/s all stay aimed inside the live HRP instead of leading
    -- several body-widths ahead. Two clean origin frames are still required so
    -- the teleport/follow origin has a chance to replicate before Mouse.Hit is read.
    CloseRangeAimDistance = 8.0,
    -- Close-range prediction now includes measured network latency. The previous
    -- ~0.003s ceiling could only lead a 300 studs/s target by <1 stud, while the
    -- server can be several network frames ahead of the replicated HRP we see.
    CloseRangeFlyLeadTime = 0.010,
    CloseRangeFastLeadTime = 0.008,
    CloseRangeNormalLeadTime = 0.004,
    CloseRangeHorizontalLeadCap = 1.25,
    CloseRangeVerticalLeadCap = 0.85,
    CloseRangeExtremeLeadCap = 1.75,
    CloseRangeCFrameLeadCap = 1.60,
    CFrameRetryLeadTime = 0.008,
    PredictionRetryLeadBoost = 0.003,
    MaxClosePredictionLeadTime = 0.040,
    PredictionAccelerationCap = 0.35,
    CloseRangeSharedMotionLeadTime = 0.00045, -- pass 1 stays conservative; retries add bounded shared-motion lead
    CloseRangeSharedMotionLeadCap = 0.70,
    CloseRangeSharedMotionRetryBoost = 0.00030, -- +0.00030s per verified miss; helps very fast shared CFrame/fly motion converge
    CloseRangeSharedMotionRetryCapBoost = 0.30, -- +0.30 stud cap per retry, still body-sized and bounded
    RecentMotionHoldTime = 0.12, -- keep the last real fast displacement briefly so one stale CFrame sample cannot collapse 900+ studs/s to ~0
    RecentMotionBlend = 0.72, -- only used while current CFrame/fly velocity suddenly collapses below the recent sample
    LastPredictionMotionSpeed = 0,
    MovingOriginConfirmFrames = 2,

    -- Teleporting the local HRP and firing 1-2 heartbeats later was fast locally
    -- but too early for server replication. Keep travel instant, then hold a stable
    -- 1.5-stud origin for a latency-scaled commit window before sending the shot.
    NetworkCommitMin = 0.055,
    NetworkCommitMax = 0.160,
    NetworkCommitPingScale = 0.70,
    NetworkCommitFastExtra = 0.018,
    NetworkCommitCFrameExtra = 0.030,
    ShotInputLatchMin = 0.055,
    ShotInputLatchPingScale = 0.80,

    RegistrationGraceNormal = 0.12,
    RegistrationGraceFast = 0.16,
    RegistrationGraceExtreme = 0.20,
    RegistrationGraceCFrame = 0.24,
    LastPredictionLeadDistance = 0,
    LastPredictionMode = "none",
    LastPingMs = 0,
    OriginLockPrepared = false,

    -- Runtime shot diagnostics. This powers the small miss/block notifier without
    -- changing targeting, queueing, or weapon behavior.
    LastIssueNotifyAt = 0,
    LastIssueReason = nil,
    LastHDiagnosticAt = 0,
    -- LOS diagnostics + H retry-side memory. Stored on AllIn1 to avoid adding
    -- main-chunk locals near Luau's register limit.
    LastLOSDetail = "not sampled",
    ApproachAngleByUserId = {},
}

-- MultiTarget = H-key queue/loop built on the proven AllIn1 combat sequence.
-- It deliberately stores almost everything on one table so the main Luau chunk
-- stays under the 200-local compiler limit.
local MultiTarget = {
    Enabled = false,
    Running = false,
    Token = 0,
    ActivationKey = Enum.KeyCode.H,
    AbortKey = Enum.KeyCode.J,

    -- Target-pool / ordering controls.
    BlacklistOnly = false,
    SelectedOnly = false,
    SafeMode = true,
    ForceFieldCheck = true,
    ReturnBetweenTargets = false,
    Priority = "nearest", -- "nearest", "lowest hp", "threat"
    Continuous = true,
    RespawnMemory = true,

    -- ForceField safety is live-state based instead of a guessed timer. Hood
    -- Customs can change its FFA protection duration without breaking this.
    ForceFieldPollInterval = 0.025,
    ForceFieldReleaseGrace = 0.04,
    ForceFieldWaitTimeout = 20.0,
    ForceFieldSince = {},
    ForceFieldWaitingUserId = nil,

    -- Reliability controls.
    RetryLimit = 2,
    PerTargetTimeout = 3.20,
    RetrySettleDelay = 0.04,
    CycleDelay = 0.14,
    ActionSpeedScale = 0.46, -- faster travel/precheck; fast-target READY gates below remain bounded
    ArrivalSafetyScale = 0.72, -- quick arrival handoff while still verifying clear origin/LOS
    FireSafetyScale = 1.00, -- never shorten server damage/shot verification
    ClientShotRetryGap = 0.00, -- H has no extra client-side fire cooldown; the game/server may still enforce one
    UnsafeSpeed = 820,
    UnsafeVerticalSpeed = 520,
    UnsafePostponeLimit = 1,
    AmmoReadyTimeout = 4.00, -- safety valve; H never attacks while an empty-mag reload is incomplete
    RespawnReadyTimeout = 12.0,
    RespawnEquipDelay = 0.03,
    RespawnRecovering = false,
    MissRecovering = false,
    LastDBEnsureAt = 0,
    DBEnsureInterval = 0.18,

    -- Safe void-hide state. While MultiTarget is searching/waiting/deferred,
    -- keep the local character far away instead of sitting beside a KO target.
    -- HideMinDistance/HideMaxDistance are true radial distances from StartPivot:
    -- the direction is randomized across the upper hemisphere so Y stays safely
    -- above the world while X/Z still vary. No persistent player connections are
    -- used: the existing queue scan supplies all readiness data.
    VoidHideEnabled = true,
    HideMinDistance = 50000,
    HideMaxDistance = 250000,
    HideRefreshInterval = 0.20,
    HideLockDistance = 100000,
    PreAttackHoldTime = 0.10,
    HiddenScanInterval = 0.04,
    HideActive = false,
    HideMode = "idle", -- "search", "arming", "attack", "idle"
    HideCFrame = nil,
    HideLastMove = 0,
    HideAnchoredRoot = nil,
    SearchAnchoredRoot = nil,
    SavedVoidSpamEnabled = nil,
    GroundActionMode = false, -- when H starts from void hide, stay on the saved map position for the whole H run

    -- Persistent selections + live run state.
    SelectedUserIds = {},
    Queue = {},
    QueueSet = {},
    KilledThisPass = {},
    RetryCounts = {},
    PostponeCounts = {},
    CurrentUserId = nil,
    ForceSafeCurrent = false,
    CurrentIndex = 0,
    Total = 0,
    QueueDirty = false,
    StartPivot = nil,
    SavedAim = nil,

    -- Last completed AllIn1 outcome is recorded here for queue decisions.
    Completed = 0,
    Failed = 0,
}

-- Void Spam (checkbox-only for now)
local VoidSpam = {
    Enabled = false,
    Interval = 0.06, -- ~16.7 swaps/sec: fast enough to replicate without returning to ground each frame
    LowHeight = 371954072084,
    HighHeight = 371956072084,
    Last = 0,
    Phase = false,
    Away = false,
    SavedCFrame = nil,
    SavedRoot = nil,
    Generation = 0,
    ActionGroundActive = false,
    ActionOwner = nil,
    ActionReturnCFrame = nil,
    ActionGroundCFrame = nil,
    ActionSettleStatus = "idle",
}

local Utility = {
    CFrameEnabled = false,
    CFrameSpeed = 400,
    FlyEnabled = false,
    FlySpeed = 400,
    MinSpeed = 1,
    MaxSpeed = 9999,
    WindowFocused = true,

    -- Fake Pos: integrated version of the user-provided PhysicsRepRootPart loop.
    -- Kept on Utility fields to avoid spending more top-level Luau local registers.
    FakePosEnabled = false,
    FakePosKey = Enum.KeyCode.F,
    FakePosGeneration = 0,
    FakePosRoot = nil,
    FakePosOriginalSenderRate = nil,
    FakePosOriginalSenderRateKnown = false,
    FakePosFlagApplied = false,
    FakePosCompatStatus = "unchecked",
    FakePosCompatDetail = "not tested",

    -- E/H movement handoff. Fake Pos stays enabled visually, but its temporary
    -- nil replication-root pulse is held while E/H physically owns the HRP.
    -- This prevents two independent systems from rewriting the same origin.
    FakePosCombatHold = false,
    FakePosCombatToken = 0,

    -- Manual E + Fake Pos origin thaw. E temporarily pauses the nil-root cadence,
    -- verifies that PhysicsRepRootPart is really back on the live HRP for several
    -- network frames, keeps it there through the shot commit, then releases only
    -- after E has returned to its saved map position.
    FakePosEThawActive = false,
    FakePosEThawToken = 0,
    FakePosEThawStartedAt = 0,
    FakePosEThawReadyAt = 0,
    FakePosEThawTimeout = 0.70,
    FakePosEThawStableFrames = 5,
    FakePosEPreMoveSettleMin = 0.10,
    FakePosEFireCommitMin = 0.20,
    FakePosEFireCommitPingScale = 1.65,
    FakePosEFireCommitExtra = 0.060,
    -- Fake Pos manual-E server commit: after the target-side origin freezes, keep
    -- the REAL character + native RightGrip + real Handle on one stable relative
    -- pose for a ping-scaled 0.25-0.40s before firing. After ammo consumption, keep
    -- that exact firing side for another 0.20-0.30s before E may return/retry.
    FakePosEStablePreFireMin = 0.25,
    FakePosEStablePreFireMax = 0.40,
    FakePosEStablePreFirePingScale = 2.00,
    FakePosEStablePreFireBase = 0.10,
    FakePosEPostFireHoldMin = 0.20,
    FakePosEPostFireHoldMax = 0.30,
    FakePosEPostFireHoldPingScale = 1.25,
    FakePosEPostFireHoldBase = 0.15,
    FakePosEPostReturnSettleMin = 0.10,
    FakePosEThawStatus = "idle",
    FakePosEThawSenderRestored = false,
    FakePosEThawSenderVerified = false,
    FakePosEThawReapplySender = false,
    FakePosEHardSuspendActive = false,

    -- During manual E, temporarily stop the local Fake Pos gun carrier and return
    -- ownership of the SAME Tool/Handle to the game's normal RightGrip chain. The
    -- server can then see the same native hand->Tool relationship as an ordinary shot.
    FakePosENativeToolMode = false,
    FakePosENativeTool = nil,
    FakePosENativeToolStatus = "idle",
    FakePosENativeToolTimeout = 0.45,
    FakePosENativeToolStableFrames = 3,

    -- E real-character Tool glue. This is deliberately separate from the normal
    -- Fake Pos carrier: while E owns the real character, keep the SAME Handle
    -- physically constrained to the REAL right hand while preserving native RightGrip.
    FakePosERealGlue = nil,
    FakePosERealGlueTool = nil,
    FakePosERealGlueHand = nil,
    FakePosERealGlueHandle = nil,
    FakePosERealGlueStatus = "idle",

    -- Armed Fake Pos force-carrier. When F is active with a gun equipped, keep the
    -- real HRP as the live replication root and continuously keep that exact Tool in
    -- the right hand. This leaves every non-Fake-Pos system untouched.
    FakePosForceTool = nil,
    FakePosForceToolName = nil,
    FakePosForceHandle = nil,
    FakePosForceHandleState = nil,
    FakePosForceHandOffset = nil,
    FakePosForceGrip = nil,
    FakePosForceNextRepair = 0,
    FakePosForceRepairInterval = 0.02,
    FakePosForceCarrierActive = false,
    FakePosForceStatus = "idle",

    -- Short live-origin lease used only around a real/manual shot or a newly
    -- detected origin warning. Fake Pos keeps its normal nil/root cadence when
    -- no shot is happening, so this does not permanently turn Fake Pos off.
    FakePosOriginHoldUntil = 0,
    FakePosOriginHoldReason = "idle",
    FakePosOriginShotHoldDuration = 0.24,
    FakePosOriginWarningHoldDuration = 0.34,
    FakePosOriginRepairCount = 0,
}

function Utility.InputBlocked()
    if not Utility.WindowFocused then
        return true
    end

    return UserInputService:GetFocusedTextBox() ~= nil
end

local function track(connection)
    if connection then
        table.insert(Connections, connection)
    end
    return connection
end

local function safeDisconnect(connection)
    pcall(function()
        connection:Disconnect()
    end)
end

-- ============================================================
-- Integrated hitsounds (user-provided sound library)
-- Plays immediately when a local Tool shot is activated.
-- No standalone window and no separate hitsound unload button.
-- ============================================================
local HitSound = {
    Alive = true,
    Enabled = true,
    Selected = "Rust Headshot",
    Volume = 0.5,
    PlaybackSpeed = 1,
    LastPlayAt = -math.huge,
    PlayDedupeWindow = 0.025,
    BoundTools = setmetatable({}, { __mode = "k" }),
    Names = {},
    Resolved = {},
    Library = {
    ["Sparkles"] = "https://files.catbox.moe/bgy8au.ogg",
    ["Neverlose"] = "110168723447153",
    ["Skeet"] = "5633695679",
    ["Fatality"] = "6534947869",
    ["Old Fatality"] = "6607142036",
    ["Hood Customs"] = "330595293",
    ["Fortnite Shield"] = "130919835188323",
    ["Register"] = "134810204798705",
    ["Call of Duty"] = "5952120301",
    ["Cod Alt"] = "77082587278347",
    ["Cod Hit"] = "160432334",
    ["Bonebreak"] = "135076986499326",
    ["Pickaxe Hit"] = "9120146349",
    ["Rust Headshot"] = "138750331387064",
    ["Rust"] = "6565371338",
    ["Bubble"] = "6534947588",
    ["Laser"] = "7837461331",
    ["LazerBeam"] = "130791043",
    ["Steve"] = "4965083997",
    ["TF2 Critical"] = "296102734",
    ["TF2 Hitsound"] = "3455144981",
    ["TF2 Bat"] = "3333907347",
    ["TF2 Pan"] = "3431749479",
    ["TF2"] = "2868331684",
    ["Saber"] = "8415678813",
    ["Bameware"] = "3124331820",
    ["Money"] = "13956013041",
    ["Notif"] = "6696469190",
    ["Shutter"] = "10066921516",
    ["RIFK7"] = "9102080552",
    ["Windows XP Error"] = "160715357",
    ["Bow Hit"] = "1053296915",
    ["Bow"] = "3442683707",
    ["OSU"] = "7147454322",
    ["Osu Alt"] = "7149255551",
    ["OneNN"] = "7349055654",
    ["One"] = "7380502345",
    ["Mario"] = "5709456554",
    ["Bell"] = "6534947240",
    ["Pick"] = "1347140027",
    ["Pop"] = "198598793",
    ["Sans"] = "3188795283",
    ["Fart"] = "130833677",
    ["Big"] = "5332005053",
    ["Vine"] = "5332680810",
    ["Bruh"] = "4578740568",
    ["Bonk"] = "5766898159",
    ["Minecraft"] = "5869422451",
    ["Gamesense"] = "4817809188",
    ["Bamboo"] = "3769434519",
    ["Crowbar"] = "546410481",
    ["Weeb"] = "6442965016",
    ["Beep"] = "8177256015",
    ["Bambi"] = "8437203821",
    ["Stone"] = "3581383408",
    ["Click"] = "8053704437",
    ["Ding"] = "7149516994",
    ["Snow"] = "6455527632",
    ["Slime"] = "6916371803",
    ["Among Us"] = "5700183626",
    ["Bullet Deflect"] = "1657157666",
    ["UwU"] = "8679659744",
    ["Blood SFX"] = "8164951181",
    ["Blood Burst"] = "3781479909",
    ["Blood Hit"] = "429400881",
    },
    Sound = nil,
    StatusLabel = nil,
    EnabledButton = nil,
    SoundButton = nil,
    VolumeButton = nil,
    Section = nil,
}

for name in pairs(HitSound.Library) do
    table.insert(HitSound.Names, name)
end
table.sort(HitSound.Names)

HitSound.SetStatus = function(text)
    if HitSound.StatusLabel and HitSound.StatusLabel.Parent then
        HitSound.StatusLabel.Text = tostring(text)
    end
end

HitSound.NormalizeAssetId = function(value)
    value = tostring(value or "")
    local numeric = value:match("(%d+)")
    if numeric and not value:find("^https?://") then
        return "rbxassetid://" .. numeric
    end
    return nil
end

HitSound.TryLoadHttpSound = function(url)
    if type(url) ~= "string" or not url:find("^https?://") then
        return nil
    end
    if type(isfile) ~= "function" or type(writefile) ~= "function" or type(getcustomasset) ~= "function" then
        return nil
    end

    local folder = "NLAssets"
    if type(isfolder) == "function" and type(makefolder) == "function" and not isfolder(folder) then
        pcall(makefolder, folder)
    end
    local ext = url:match("%.%w+$") or ".ogg"
    local path = folder .. "/" .. url:gsub("[^%w]", "") .. ext
    if not isfile(path) and type(game.HttpGet) == "function" then
        local ok, body = pcall(function()
            return game:HttpGet(url)
        end)
        if ok and type(body) == "string" and #body > 0 and not body:find("404") then
            pcall(writefile, path, body)
        end
    end
    if isfile(path) then
        local ok, asset = pcall(getcustomasset, path)
        if ok then
            return asset
        end
    end
    return nil
end

HitSound.ResolveSoundId = function(value)
    return HitSound.NormalizeAssetId(value) or HitSound.TryLoadHttpSound(value)
end

HitSound.ApplySelectedSound = function(preload)
    if not HitSound.Sound then
        return false
    end
    local raw = HitSound.Library[HitSound.Selected]
    if not raw then
        HitSound.SetStatus("missing sound: " .. tostring(HitSound.Selected))
        return false
    end

    local soundId = HitSound.Resolved[HitSound.Selected]
    if not soundId then
        soundId = HitSound.ResolveSoundId(raw)
        if soundId then
            HitSound.Resolved[HitSound.Selected] = soundId
        end
    end
    if not soundId then
        HitSound.SetStatus("sound unavailable: " .. tostring(HitSound.Selected))
        return false
    end

    HitSound.Sound.SoundId = soundId
    HitSound.Sound.Volume = math.clamp(HitSound.Volume, 0, 1)
    HitSound.Sound.PlaybackSpeed = math.clamp(HitSound.PlaybackSpeed, 0.25, 3)
    if preload then
        task.spawn(function()
            pcall(function()
                ref(game:GetService("ContentProvider")):PreloadAsync({ HitSound.Sound })
            end)
        end)
    end
    return true
end

HitSound.Play = function(reason, bypassDedupe)
    if Unloaded or not HitSound.Alive or not HitSound.Enabled or not HitSound.Sound then
        return false
    end

    local now = os.clock()
    if not bypassDedupe and now - (HitSound.LastPlayAt or -math.huge) < HitSound.PlayDedupeWindow then
        return false
    end

    if not HitSound.ApplySelectedSound(false) then
        return false
    end

    HitSound.LastPlayAt = now
    pcall(function()
        HitSound.Sound:Stop()
        HitSound.Sound.TimePosition = 0
        HitSound.Sound:Play()
    end)
    if reason == "preview" then
        HitSound.SetStatus("preview: " .. HitSound.Selected)
    else
        HitSound.SetStatus("played instantly: " .. HitSound.Selected)
    end
    return true
end

HitSound.Sound = Instance.new("Sound")
HitSound.Sound.Name = "alex.ftn_HitSound"
HitSound.Sound.Volume = HitSound.Volume
HitSound.Sound.PlaybackSpeed = HitSound.PlaybackSpeed
HitSound.Sound.Parent = ref(game:GetService("SoundService"))
HitSound.ApplySelectedSound(true)

local function new(className, properties, parent)
    local object = Instance.new(className)
    for key, value in pairs(properties or {}) do
        object[key] = value
    end
    object.Parent = parent
    return object
end

local RootGui = new("ScreenGui", {
    Name = "alex.ftn",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 999,
}, PlayerGui)

local VisualWorldFolder = Instance.new("Folder")
VisualWorldFolder.Name = "alex.ftn_VisualWorld"
VisualWorldFolder.Parent = Workspace

-- Persistent grass005 compatibility. The original one-shot move could lose the
-- object when the map refreshed, and our own shot raycasts still queried the same
-- grass. Keep ONLY grass005 out of shot queries and keep it under Workspace.Ignored
-- while this script is active. Nothing else in the map is touched.
AllIn1.GrassIgnoreCache = setmetatable({}, { __mode = "k" })
AllIn1.GrassOriginalCanQuery = setmetatable({}, { __mode = "k" })
AllIn1.GrassOriginalParent = setmetatable({}, { __mode = "k" })
AllIn1.GrassIgnoreNextScan = 0
AllIn1.GrassIgnoreScanInterval = 0.35

AllIn1.RegisterGrassIgnore = function(grass, ignored)
    if not grass or not grass.Parent or string.lower(tostring(grass.Name or "")) ~= "grass005" then
        return false
    end

    AllIn1.GrassIgnoreCache[grass] = true
    if AllIn1.GrassOriginalParent[grass] == nil then
        AllIn1.GrassOriginalParent[grass] = grass.Parent
    end

    local function disableQuery(part)
        if not part or not part:IsA("BasePart") then
            return
        end
        if AllIn1.GrassOriginalCanQuery[part] == nil then
            local okValue, oldValue = pcall(function()
                return part.CanQuery
            end)
            if okValue then
                AllIn1.GrassOriginalCanQuery[part] = oldValue
            else
                AllIn1.GrassOriginalCanQuery[part] = true
            end
        end
        pcall(function()
            part.CanQuery = false
        end)
    end

    if grass:IsA("BasePart") then
        disableQuery(grass)
    end
    for _, descendant in ipairs(grass:GetDescendants()) do
        if descendant:IsA("BasePart") then
            disableQuery(descendant)
        end
    end

    if ignored and ignored.Parent and grass.Parent ~= ignored then
        pcall(function()
            grass.Parent = ignored
        end)
    end
    return true
end

AllIn1.RefreshGrassIgnore = function(force)
    local now = os.clock()
    if not force and now < (AllIn1.GrassIgnoreNextScan or 0) then
        return
    end
    AllIn1.GrassIgnoreNextScan = now + (AllIn1.GrassIgnoreScanInterval or 0.35)

    local ignored = Workspace:FindFirstChild("Ignored")
    local ffaMap = Workspace:FindFirstChild("FFA_MAP")
    local mapFolder = ffaMap and ffaMap:FindFirstChild("Map")

    local function scan(container)
        if not container then
            return
        end
        -- The supplied addon targets the direct grass005 map object. Keep the scan
        -- narrow so this fix never walks the complete map every few tenths of a second.
        local grass = container:FindFirstChild("grass005")
        if grass then
            AllIn1.RegisterGrassIgnore(grass, ignored)
        end
    end

    scan(ignored)
    scan(mapFolder)
end

AllIn1.AppendGrassIgnores = function(ignore)
    if type(ignore) ~= "table" then
        return ignore
    end
    AllIn1.RefreshGrassIgnore(false)
    for grass in pairs(AllIn1.GrassIgnoreCache) do
        if grass and grass.Parent then
            table.insert(ignore, grass)
        else
            AllIn1.GrassIgnoreCache[grass] = nil
        end
    end
    return ignore
end

AllIn1.RestoreGrassIgnore = function()
    for part, oldValue in pairs(AllIn1.GrassOriginalCanQuery) do
        if part and part.Parent and part:IsA("BasePart") then
            pcall(function()
                part.CanQuery = oldValue == true
            end)
        end
    end

    for grass, oldParent in pairs(AllIn1.GrassOriginalParent) do
        if grass and grass.Parent and oldParent and oldParent.Parent then
            pcall(function()
                grass.Parent = oldParent
            end)
        end
    end

    AllIn1.GrassIgnoreCache = setmetatable({}, { __mode = "k" })
    AllIn1.GrassOriginalCanQuery = setmetatable({}, { __mode = "k" })
    AllIn1.GrassOriginalParent = setmetatable({}, { __mode = "k" })
end

track(Workspace.DescendantAdded:Connect(function(object)
    if not object then
        return
    end
    local name = string.lower(tostring(object.Name or ""))
    local grassAncestor = object:FindFirstAncestor("grass005")
    if name == "grass005" or grassAncestor then
        task.defer(function()
            if not Unloaded then
                AllIn1.RefreshGrassIgnore(true)
            end
        end)
    end
end))

task.defer(function()
    if not Unloaded then
        AllIn1.RefreshGrassIgnore(true)
    end
end)

-- ============================================================
-- FFA_MAP.Map -> Workspace.Ignored compatibility
-- ============================================================
-- Keep the actual floor/baseplate where it is, but move every other map branch
-- into Workspace.Ignored. This mirrors the grass005 compatibility above while
-- preserving hierarchy as much as possible: if a container also owns the protected
-- floor, only its non-ground children are moved instead of moving the whole container.
AllIn1.MapIgnoreCache = setmetatable({}, { __mode = "k" })
AllIn1.MapIgnoreOriginalParent = setmetatable({}, { __mode = "k" })
AllIn1.MapIgnoreOriginalCanQuery = setmetatable({}, { __mode = "k" })
AllIn1.MapIgnoreNextScan = 0
AllIn1.MapIgnoreScanInterval = 0.35

AllIn1.IsProtectedMapGround = function(object)
    if not object then
        return false
    end
    local name = string.lower(tostring(object.Name or ""))
    local normalized = name:gsub("[^%w]", "")
    return normalized == "baseplate"
        or normalized == "ground"
        or normalized == "mapground"
        or normalized == "ffaground"
        or normalized == "groundplate"
        or normalized == "groundbase"
end

AllIn1.MapBranchHasProtectedGround = function(object)
    if not object then
        return false
    end
    if AllIn1.IsProtectedMapGround(object) then
        return true
    end
    for _, descendant in ipairs(object:GetDescendants()) do
        if AllIn1.IsProtectedMapGround(descendant) then
            return true
        end
    end
    return false
end

AllIn1.DisableMapBranchQuery = function(object)
    if not object then
        return
    end
    local function disable(part)
        if not part or not part:IsA("BasePart") then
            return
        end
        if AllIn1.MapIgnoreOriginalCanQuery[part] == nil then
            local okValue, oldValue = pcall(function()
                return part.CanQuery
            end)
            AllIn1.MapIgnoreOriginalCanQuery[part] = okValue and oldValue or true
        end
        pcall(function()
            part.CanQuery = false
        end)
    end
    disable(object)
    for _, descendant in ipairs(object:GetDescendants()) do
        disable(descendant)
    end
end

AllIn1.RegisterMapIgnore = function(object, ignored)
    if not object or not object.Parent or not ignored or not ignored.Parent then
        return false
    end
    -- grass005 already has its own stronger bookkeeping/restore path above.
    if string.lower(tostring(object.Name or "")) == "grass005" then
        AllIn1.RegisterGrassIgnore(object, ignored)
        return true
    end
    if AllIn1.IsProtectedMapGround(object) then
        return false
    end

    AllIn1.MapIgnoreCache[object] = true
    if AllIn1.MapIgnoreOriginalParent[object] == nil then
        AllIn1.MapIgnoreOriginalParent[object] = object.Parent
    end
    AllIn1.DisableMapBranchQuery(object)

    if object.Parent ~= ignored then
        pcall(function()
            object.Parent = ignored
        end)
    end
    return true
end

AllIn1.RefreshMapIgnore = function(force)
    local now = os.clock()
    if not force and now < (AllIn1.MapIgnoreNextScan or 0) then
        return
    end
    AllIn1.MapIgnoreNextScan = now + (AllIn1.MapIgnoreScanInterval or 0.35)

    local ignored = Workspace:FindFirstChild("Ignored")
    local ffaMap = Workspace:FindFirstChild("FFA_MAP")
    local mapFolder = ffaMap and ffaMap:FindFirstChild("Map")
    if not ignored or not mapFolder then
        return
    end

    local function drain(container)
        if not container or not container.Parent then
            return
        end
        -- Snapshot first because this loop reparents children while iterating.
        local children = container:GetChildren()
        for _, child in ipairs(children) do
            if child and child.Parent == container then
                if string.lower(tostring(child.Name or "")) == "grass005" then
                    AllIn1.RegisterGrassIgnore(child, ignored)
                elseif AllIn1.IsProtectedMapGround(child) then
                    -- Explicitly preserve the playable floor/baseplate.
                elseif AllIn1.MapBranchHasProtectedGround(child) then
                    -- A mixed Model/Folder owns the ground plus other map geometry.
                    -- Keep the container/ground hierarchy and drain only its other branches.
                    drain(child)
                else
                    AllIn1.RegisterMapIgnore(child, ignored)
                end
            end
        end
    end

    drain(mapFolder)

    -- Re-assert CanQuery=false for cached branches in case a map script adds new parts
    -- underneath an already-moved Model after it reached Workspace.Ignored.
    for object in pairs(AllIn1.MapIgnoreCache) do
        if object and object.Parent then
            AllIn1.DisableMapBranchQuery(object)
        else
            AllIn1.MapIgnoreCache[object] = nil
        end
    end
end

AllIn1.AppendMapIgnores = function(ignore)
    if type(ignore) ~= "table" then
        return ignore
    end
    AllIn1.RefreshMapIgnore(false)
    for object in pairs(AllIn1.MapIgnoreCache) do
        if object and object.Parent then
            table.insert(ignore, object)
        else
            AllIn1.MapIgnoreCache[object] = nil
        end
    end
    return ignore
end

AllIn1.RestoreMapIgnore = function()
    -- Restore query state first while all moved objects still exist in Ignored.
    for part, oldValue in pairs(AllIn1.MapIgnoreOriginalCanQuery) do
        if part and part.Parent and part:IsA("BasePart") then
            pcall(function()
                part.CanQuery = oldValue == true
            end)
        end
    end

    -- Restore only roots that we actually moved. Children kept their internal hierarchy.
    for object, oldParent in pairs(AllIn1.MapIgnoreOriginalParent) do
        if object and object.Parent and oldParent and oldParent.Parent then
            pcall(function()
                object.Parent = oldParent
            end)
        end
    end

    AllIn1.MapIgnoreCache = setmetatable({}, { __mode = "k" })
    AllIn1.MapIgnoreOriginalParent = setmetatable({}, { __mode = "k" })
    AllIn1.MapIgnoreOriginalCanQuery = setmetatable({}, { __mode = "k" })
end

track(Workspace.DescendantAdded:Connect(function(object)
    if not object or Unloaded then
        return
    end

    -- New descendants inside an already-ignored map branch must also stop querying.
    local ancestor = object
    while ancestor do
        if AllIn1.MapIgnoreCache[ancestor] then
            if object:IsA("BasePart") then
                AllIn1.DisableMapBranchQuery(object)
            end
            return
        end
        ancestor = ancestor.Parent
    end

    -- Map refreshes can recreate FFA_MAP, Map, or any of their children. Defer one
    -- tick so parenting settles, then drain the fresh map again.
    local current = object
    local belongsToMap = false
    while current and current ~= Workspace do
        if current.Name == "Map" and current.Parent and current.Parent.Name == "FFA_MAP" then
            belongsToMap = true
            break
        end
        current = current.Parent
    end
    local name = tostring(object.Name or "")
    if belongsToMap or name == "FFA_MAP" or name == "Map" then
        task.defer(function()
            if not Unloaded then
                AllIn1.RefreshMapIgnore(true)
            end
        end)
    end
end))

task.defer(function()
    if not Unloaded then
        AllIn1.RefreshMapIgnore(true)
    end
end)

-- ============================================================
-- Theme / notification system
-- ============================================================

local Theme = {
    -- Plague-style reference palette sampled from the supplied screenshot.
    Bg = Color3.fromRGB(14, 14, 14),
    Panel = Color3.fromRGB(21, 21, 21),
    Panel2 = Color3.fromRGB(24, 24, 24),
    Border = Color3.fromRGB(43, 43, 43),
    BorderDark = Color3.fromRGB(5, 5, 5),
    Text = Color3.fromRGB(190, 190, 190),
    Muted = Color3.fromRGB(108, 108, 108),
    Accent = Color3.fromRGB(209, 179, 182),
    AccentBright = Color3.fromRGB(224, 197, 200),
    ESP = Config.ESP.Color, -- world ESP uses the same dusty-pink GUI accent
    Red = Color3.fromRGB(145, 68, 72),
    RedBright = Color3.fromRGB(190, 92, 98),
}

local BLACKLIST_ESP_COLOR = Color3.fromRGB(230, 62, 62) -- preserve world ESP behavior

local NotificationHolder = new("Frame", {
    Name = "Notifications",
    AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -18, 1, -238),
    Size = UDim2.fromOffset(290, 0),
    BackgroundTransparency = 1,
}, RootGui)

local NotificationLayout = new("UIListLayout", {
    FillDirection = Enum.FillDirection.Vertical,
    HorizontalAlignment = Enum.HorizontalAlignment.Right,
    VerticalAlignment = Enum.VerticalAlignment.Bottom,
    Padding = UDim.new(0, 6),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, NotificationHolder)

track(NotificationLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    NotificationHolder.Size = UDim2.fromOffset(290, NotificationLayout.AbsoluteContentSize.Y)
end))

local function notify(title, message, kind, duration)
    if Unloaded or not RootGui.Parent then
        return
    end

    NotifIndex = NotifIndex + 1
    local accentColor = Theme.Accent
    if kind == "blacklist" then
        accentColor = Theme.RedBright
    elseif kind == "visual" then
        accentColor = Theme.Accent
    elseif kind == "mod" then
        accentColor = Theme.AccentBright
    elseif kind == "warning" then
        accentColor = Theme.RedBright
    end

    local card = new("Frame", {
        Name = "Popup_" .. tostring(NotifIndex),
        Size = UDim2.fromOffset(282, 52),
        BackgroundColor3 = Theme.Bg,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        LayoutOrder = NotifIndex,
    }, NotificationHolder)

    new("UIStroke", {
        Color = Theme.Border,
        Thickness = 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, card)

    local stripe = new("Frame", {
        Size = UDim2.new(0, 3, 1, 0),
        BackgroundColor3 = accentColor,
        BorderSizePixel = 0,
    }, card)

    local titleLabel = new("TextLabel", {
        Position = UDim2.fromOffset(12, 7),
        Size = UDim2.new(1, -20, 0, 17),
        BackgroundTransparency = 1,
        Text = title,
        TextColor3 = Theme.Text,
        Font = Enum.Font.Code,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, card)

    local messageLabel = new("TextLabel", {
        Position = UDim2.fromOffset(12, 26),
        Size = UDim2.new(1, -20, 0, 17),
        BackgroundTransparency = 1,
        Text = message,
        TextColor3 = Theme.Muted,
        Font = Enum.Font.Code,
        TextSize = 10,
        TextTruncate = Enum.TextTruncate.AtEnd,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, card)

    card.Position = UDim2.fromOffset(320, 0)
    card.BackgroundTransparency = 0.1
    stripe.BackgroundTransparency = 0
    titleLabel.TextTransparency = 0
    messageLabel.TextTransparency = 0

    TweenService:Create(card, TweenInfo.new(0.34, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Position = UDim2.fromOffset(0, 0),
    }):Play()

    task.delay(duration or 3.5, function()
        if Unloaded or not card.Parent then
            return
        end

        local tween = TweenService:Create(card, TweenInfo.new(0.26, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {
            Position = UDim2.fromOffset(320, 0),
            BackgroundTransparency = 1,
        })
        tween:Play()
        tween.Completed:Connect(function()
            if card.Parent then
                card:Destroy()
            end
        end)
    end)
end

-- ============================================================
-- Aim helpers
-- ============================================================

local function getTargetPart(player)
    if not player then
        return nil
    end
    local character = player.Character
    return character and character:FindFirstChild(Config.Aimbot.TargetPart)
end

local function getHumanoid(player)
    local character = player and player.Character
    return character and character:FindFirstChildOfClass("Humanoid")
end

local function isSameTeam(player)
    return Config.Aimbot.TeamCheck
        and LocalPlayer.Team ~= nil
        and player.Team == LocalPlayer.Team
end

local function isKnockedOut(player)
    if not Config.Aimbot.KOCheck then
        return false
    end

    local character = player and player.Character
    if not character then
        return false
    end

    local bodyEffects = character:FindFirstChild("BodyEffects")
    local koValue = bodyEffects and bodyEffects:FindFirstChild("K.O")
    if koValue and koValue:IsA("BoolValue") then
        return koValue.Value == true
    end

    local attr = character:GetAttribute("K.O")
    return attr == true
end

-- Read the freshest replicated combat vitals without assuming every hood game
-- stores HP in exactly the same place. Humanoid.Health remains the normal source,
-- while explicit replicated HP/Health values are supported as a safe fallback.
local function readNumericStat(container, firstName, secondName, thirdName)
    if not container then
        return nil
    end

    local function readName(name)
        if not name then
            return nil
        end

        local object = container:FindFirstChild(name)
        if object and (object:IsA("NumberValue") or object:IsA("IntValue")) then
            return tonumber(object.Value)
        end

        local attribute = container:GetAttribute(name)
        if type(attribute) == "number" then
            return attribute
        end

        return nil
    end

    return readName(firstName) or readName(secondName) or readName(thirdName)
end

local function getPlayerVitals(player)
    local character = player and player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local bodyEffects = character and character:FindFirstChild("BodyEffects")

    local health = humanoid and tonumber(humanoid.Health) or 0
    local maxHealth = humanoid and tonumber(humanoid.MaxHealth) or 100

    -- Some hood variants mirror HP into replicated NumberValues/attributes.
    -- Prefer an explicit combat HP value when one exists; otherwise use Humanoid.
    local customHealth = readNumericStat(bodyEffects, "Health", "HP", "CurrentHealth")
        or readNumericStat(character, "Health", "HP", "CurrentHealth")
        or readNumericStat(humanoid, "HealthValue", "HP", "CurrentHealth")
    local customMax = readNumericStat(bodyEffects, "MaxHealth", "MaxHP", "HealthMax")
        or readNumericStat(character, "MaxHealth", "MaxHP", "HealthMax")
        or readNumericStat(humanoid, "MaxHealthValue", "MaxHP", "HealthMax")

    if customHealth ~= nil and customHealth >= 0 then
        health = customHealth
    end
    if customMax ~= nil and customMax > 0 then
        maxHealth = customMax
    end

    health = math.max(0, tonumber(health) or 0)
    maxHealth = math.max(1, tonumber(maxHealth) or 100, health)

    local armor = readNumericStat(bodyEffects, "Armor", "Armour", "Shield")
        or readNumericStat(character, "Armor", "Armour", "Shield")
    armor = math.max(0, tonumber(armor) or 0)

    return health, maxHealth, armor, humanoid
end

local function isBlacklisted(player)
    return player and BlacklistedUserIds[player.UserId] == true
end

-- When at least one blacklisted user is currently in this server, the
-- blacklist becomes the only pool the C lock is allowed to acquire from.
-- Stored UIDs still persist if somebody leaves, but an offline entry does
-- not block normal locking until that user rejoins.
local function refreshBlacklistPresence()
    local present = false
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and isBlacklisted(player) then
            present = true
            break
        end
    end
    PresentBlacklistedTargets = present
    return present
end

local function hasPresentBlacklistedTargets()
    return PresentBlacklistedTargets
end

local function clearTarget()
    Aim.CurrentTarget = nil
    Aim.LockedUserId = nil
    Aim.SmoothedVelocity = Vector3.zero
end

local function findPlayerByUserId(userId)
    if not userId then
        return nil
    end
    for _, player in ipairs(Players:GetPlayers()) do
        if player.UserId == userId then
            return player
        end
    end
    return nil
end

local function isValidTarget(player)
    if not player or player == LocalPlayer or not Camera then
        return false
    end
    if isSameTeam(player) then
        return false
    end

    -- Blacklist-only lock mode: as soon as at least one blacklisted target is
    -- present in the server, non-blacklisted players cannot be acquired by C.
    if hasPresentBlacklistedTargets() and not isBlacklisted(player) then
        return false
    end

    local character = player.Character
    local humanoid = getHumanoid(player)
    local part = getTargetPart(player)

    if not character or not humanoid or not part then
        return false
    end
    if Config.Aimbot.DeadCheck and humanoid.Health <= 0 then
        return false
    end
    if isKnockedOut(player) then
        return false
    end
    if (Camera.CFrame.Position - part.Position).Magnitude > Config.Aimbot.MaxDistance then
        return false
    end

    -- WallCheck intentionally does not run here. The requested lock must be
    -- able to acquire targets through walls.

    if Config.Aimbot.VisibleCheck then
        local _, onScreen = Camera:WorldToViewportPoint(part.Position)
        if not onScreen then
            return false
        end
    end

    return true
end

local function isInFov(player)
    if not Camera then
        return false
    end
    local part = getTargetPart(player)
    if not part then
        return false
    end

    local point, onScreen = Camera:WorldToViewportPoint(part.Position)
    if not onScreen or point.Z <= 0 then
        return false
    end

    local mouse = UserInputService:GetMouseLocation()
    return (Vector2.new(point.X, point.Y) - mouse).Magnitude <= Config.Aimbot.Radius
end

local function getBestTarget()
    if not Camera then
        return nil
    end
    local bestPlayer = nil
    local bestDistance = math.huge
    local mouse = UserInputService:GetMouseLocation()

    for _, player in ipairs(Players:GetPlayers()) do
        if isValidTarget(player) then
            local part = getTargetPart(player)
            local screenPoint, onScreen = Camera:WorldToViewportPoint(part.Position)
            if onScreen and screenPoint.Z > 0 then
                local distance = (Vector2.new(screenPoint.X, screenPoint.Y) - mouse).Magnitude
                if distance <= Config.Aimbot.Radius and distance < bestDistance then
                    bestDistance = distance
                    bestPlayer = player
                end
            end
        end
    end

    return bestPlayer
end

-- Sample both physics velocity and replicated position deltas. Direct CFrame
-- movement/flying can make AssemblyLinearVelocity stale or even zero while the
-- HRP is visibly travelling hundreds of studs/s. E/H use this effective motion
-- sample so a moving target can never be misclassified as stationary.
AllIn1.SampleTargetMotion = function(part, now)
    if not part or not part.Parent then
        return nil
    end

    now = tonumber(now) or os.clock()
    local ok, position, assemblyVelocity = pcall(function()
        return part.Position, part.AssemblyLinearVelocity
    end)
    if not ok or typeof(position) ~= "Vector3" or typeof(assemblyVelocity) ~= "Vector3" then
        return nil
    end

    local sample = AllIn1.MotionSamples[part]
    if not sample then
        sample = {
            LastPosition = position,
            LastTime = now,
            Position = position,
            AssemblyVelocity = assemblyVelocity,
            ObservedVelocity = assemblyVelocity,
            EffectiveVelocity = assemblyVelocity,
            Acceleration = Vector3.zero,
            DirectionDot = 1,
            SampleDt = 0,
            StepDistance = 0,
            Desync = 0,
            CFrameMotion = false,
            CFrameUntil = 0,
            RecentMotionVelocity = assemblyVelocity,
            RecentMotionUntil = assemblyVelocity.Magnitude >= AllIn1.FastTargetSpeed and (now + AllIn1.RecentMotionHoldTime) or 0,
            RecentMotionSpeed = assemblyVelocity.Magnitude,
            FlyMotion = assemblyVelocity.Magnitude >= AllIn1.FastTargetSpeed
                or math.abs(assemblyVelocity.Y) >= AllIn1.FastTargetVerticalSpeed,
        }
        AllIn1.MotionSamples[part] = sample
    else
        local dt = now - (sample.LastTime or now)
        if dt >= (1 / 300) then
            local delta = position - (sample.LastPosition or position)
            local stepDistance = delta.Magnitude
            local observedVelocity = delta / math.max(dt, 1 / 300)
            local observedSpeed = observedVelocity.Magnitude
            local assemblySpeed = assemblyVelocity.Magnitude
            local desync = (observedVelocity - assemblyVelocity).Magnitude
            local previousObserved = sample.ObservedVelocity or assemblyVelocity
            local acceleration = (observedVelocity - previousObserved) / math.max(dt, 1 / 300)
            local accelerationCap = 120000
            if acceleration.Magnitude > accelerationCap and acceleration.Magnitude > 0 then
                acceleration = acceleration.Unit * accelerationCap
            end
            local directionDot = 1
            if previousObserved.Magnitude > 1 and observedVelocity.Magnitude > 1 then
                directionDot = previousObserved.Unit:Dot(observedVelocity.Unit)
            end

            local cframeNow = stepDistance >= AllIn1.CFrameStepThreshold
                and observedSpeed >= AllIn1.CFrameSpeedThreshold
                and (assemblySpeed <= math.max(60, observedSpeed * 0.55)
                    or desync >= AllIn1.CFrameMismatchThreshold)

            if cframeNow then
                sample.CFrameUntil = now + 0.090
            end

            local effectiveVelocity = assemblyVelocity
            if cframeNow or now <= (sample.CFrameUntil or 0) then
                -- Position deltas are the authoritative motion signal for CFrame
                -- movement because physics velocity may be missing entirely.
                effectiveVelocity = observedVelocity
            elseif observedSpeed >= AllIn1.FastTargetSpeed and desync >= 70 then
                -- Blend replicated displacement into ordinary fly/flintlock motion
                -- without replacing a healthy physics velocity sample outright.
                effectiveVelocity = assemblyVelocity:Lerp(observedVelocity, 0.50)
            elseif stepDistance >= 0.40 and observedSpeed > (assemblySpeed * 1.35) then
                effectiveVelocity = assemblyVelocity:Lerp(observedVelocity, 0.30)
            end

            if effectiveVelocity.Magnitude > AllIn1.ObservedMotionCap then
                effectiveVelocity = effectiveVelocity.Unit * AllIn1.ObservedMotionCap
            end
            if observedVelocity.Magnitude > AllIn1.ObservedMotionCap then
                observedVelocity = observedVelocity.Unit * AllIn1.ObservedMotionCap
            end

            -- FAST/CFRAME STALE-SAMPLE FIX: direct CFrame/fly movement can produce a
            -- single tiny displacement sample on the exact firing heartbeat even though
            -- the target was moving hundreds/thousands of studs/s immediately before it.
            -- Keep the last genuine fast replicated velocity for a very short window and
            -- blend it back only when the current sample collapses abnormally. This does
            -- not affect stationary/ordinary targets and expires in 0.12s if they stop.
            local motionCandidate = effectiveVelocity.Magnitude >= observedVelocity.Magnitude
                and effectiveVelocity or observedVelocity
            local motionCandidateSpeed = motionCandidate.Magnitude
            local storedRecentVelocity = sample.RecentMotionVelocity
            local storedRecentSpeed = tonumber(sample.RecentMotionSpeed) or 0
            local storedRecentLive = typeof(storedRecentVelocity) == "Vector3"
                and now <= (sample.RecentMotionUntil or 0)
            local directionChanged = storedRecentLive
                and motionCandidateSpeed >= AllIn1.CFrameSpeedThreshold
                and storedRecentVelocity.Magnitude > 1
                and motionCandidate.Magnitude > 1
                and storedRecentVelocity.Unit:Dot(motionCandidate.Unit) < 0.20
            local meaningfulCandidate = cframeNow
                or motionCandidateSpeed >= AllIn1.FastTargetSpeed
                or math.abs(motionCandidate.Y) >= AllIn1.FastTargetVerticalSpeed
            if meaningfulCandidate and (not storedRecentLive
                or motionCandidateSpeed >= (storedRecentSpeed * 0.55)
                or directionChanged)
            then
                sample.RecentMotionVelocity = motionCandidate
                sample.RecentMotionSpeed = motionCandidateSpeed
                sample.RecentMotionUntil = now + AllIn1.RecentMotionHoldTime
            end

            local recentVelocity = sample.RecentMotionVelocity
            local recentSpeed = tonumber(sample.RecentMotionSpeed) or 0
            local recentLive = typeof(recentVelocity) == "Vector3"
                and now <= (sample.RecentMotionUntil or 0)
                and recentSpeed >= AllIn1.FastTargetSpeed
            local cframeWindow = cframeNow or now <= (sample.CFrameUntil or 0)
            local flyWindow = assemblySpeed >= AllIn1.FastTargetSpeed
                or math.abs(assemblyVelocity.Y) >= AllIn1.FastTargetVerticalSpeed
            if recentLive and (cframeWindow or flyWindow)
                and effectiveVelocity.Magnitude < (recentSpeed * 0.55)
            then
                effectiveVelocity = effectiveVelocity:Lerp(recentVelocity, AllIn1.RecentMotionBlend)
            end

            sample.LastPosition = position
            sample.LastTime = now
            sample.ObservedVelocity = observedVelocity
            sample.EffectiveVelocity = effectiveVelocity
            sample.Acceleration = acceleration
            sample.DirectionDot = directionDot
            sample.SampleDt = dt
            sample.StepDistance = stepDistance
            sample.Desync = desync
        end

        sample.Position = position
        sample.AssemblyVelocity = assemblyVelocity
        sample.CFrameMotion = now <= (sample.CFrameUntil or 0)
        sample.FlyMotion = not sample.CFrameMotion
            and (assemblyVelocity.Magnitude >= AllIn1.FastTargetSpeed
                or math.abs(assemblyVelocity.Y) >= AllIn1.FastTargetVerticalSpeed)
    end

    local effective = sample.EffectiveVelocity or assemblyVelocity
    local recentVelocity = sample.RecentMotionVelocity
    local recentLive = typeof(recentVelocity) == "Vector3"
        and now <= (sample.RecentMotionUntil or 0)
        and (sample.CFrameMotion or sample.FlyMotion)
    if recentLive and effective.Magnitude < ((sample.RecentMotionSpeed or 0) * 0.55) then
        effective = effective:Lerp(recentVelocity, AllIn1.RecentMotionBlend)
        sample.EffectiveVelocity = effective
    end
    sample.Speed = math.max(assemblyVelocity.Magnitude, effective.Magnitude)
    sample.Vertical = math.max(math.abs(assemblyVelocity.Y), math.abs(effective.Y))
    return sample
end

local function getPredictedPosition(part)
    if not part or not part.Parent then
        return nil
    end

    -- A target can swap HRP/character between two replicated frames. Read both
    -- values together so a stale part cannot throw inside the fire path.
    local ok, position, rawVelocity = pcall(function()
        return part.Position, part.AssemblyLinearVelocity
    end)
    if not ok or typeof(position) ~= "Vector3" or typeof(rawVelocity) ~= "Vector3" then
        return nil
    end

    if not Config.Aimbot.Prediction.Enabled then
        Aim.SmoothedVelocity = Vector3.zero
        return position
    end

    local rawSpeed = rawVelocity.Magnitude
    local extreme = rawSpeed >= AllIn1.ExtremeTargetSpeed
        or math.abs(rawVelocity.Y) >= AllIn1.ExtremeTargetVerticalSpeed
    local fast = extreme
        or rawSpeed >= AllIn1.FastTargetSpeed
        or math.abs(rawVelocity.Y) >= AllIn1.FastTargetVerticalSpeed

    -- Keep the real replicated speed for fast targets instead of flattening every
    -- 300+ target to the same 340/420 value. Only absurd spikes hit the global
    -- safety ceiling; the lead-distance caps below still prevent wild overshoot.
    local velocityCap = fast and AllIn1.ObservedMotionCap or 240
    if rawSpeed > velocityCap and rawSpeed > 0 then
        rawVelocity = rawVelocity.Unit * velocityCap
        rawSpeed = velocityCap
    end

    local response = fast and 0.94 or 0.82
    Aim.SmoothedVelocity = Aim.SmoothedVelocity:Lerp(rawVelocity, response)
    local velocity = Aim.SmoothedVelocity
    if velocity.Magnitude < 0.5 then
        return position
    end

    local distance = Camera and (position - Camera.CFrame.Position).Magnitude or 0
    local leadTime
    local horizontalCap
    local verticalCap

    if extreme then
        leadTime = AllIn1.ExtremeAimLeadTime + math.clamp(distance / 18000, 0, 0.018)
        horizontalCap = AllIn1.ExtremeAimLeadCap
        verticalCap = 5.0
    elseif fast then
        leadTime = AllIn1.FastAimLeadTime + math.clamp(distance / 20000, 0, 0.016)
        horizontalCap = AllIn1.FastAimLeadCap
        verticalCap = 3.0
    else
        leadTime = 0.034 + math.clamp(distance / 14000, 0, 0.026)
        horizontalCap = 2.35
        verticalCap = 0.65
    end

    local lead = velocity * leadTime
    local horizontal = Vector3.new(lead.X, 0, lead.Z)
    if horizontal.Magnitude > horizontalCap then
        horizontal = horizontal.Unit * horizontalCap
    end
    local vertical = math.clamp(lead.Y, -verticalCap, verticalCap)

    return position + Vector3.new(horizontal.X, vertical, horizontal.Z)
end

-- E can use the normal network prediction above. H is physically soft-hooked
-- about one stud from the live target, so using the same 8-12 stud fast-target
-- lead can overshoot the body entirely. Give H its own fresh, short lead based
-- only on the current replicated HRP sample. This changes aim math only while H
-- is actually running; normal C/E behavior stays untouched.
-- Read Roblox's current data ping when available. This is deliberately bounded:
-- it is used only to decide how long the teleported shot origin should replicate
-- and how far a moving target may advance before the server receives the shot.
AllIn1.GetDataPingSeconds = function()
    local pingSeconds = 0.060
    pcall(function()
        local stats = game:GetService("Stats")
        local network = stats and stats:FindFirstChild("Network")
        local serverStats = network and network:FindFirstChild("ServerStatsItem")
        local dataPing = serverStats and serverStats:FindFirstChild("Data Ping")
        if dataPing then
            local value = nil
            pcall(function()
                value = tonumber(dataPing:GetValue())
            end)
            if not value then
                pcall(function()
                    value = tonumber(tostring(dataPing:GetValueString()):match("[%d%.]+"))
                end)
            end
            if value and value > 0 then
                pingSeconds = value / 1000
            end
        end
    end)
    pingSeconds = math.clamp(tonumber(pingSeconds) or 0.060, 0.020, 0.250)
    AllIn1.LastPingMs = math.floor((pingSeconds * 1000) + 0.5)
    return pingSeconds
end

AllIn1.GetNetworkCommitTime = function(isCFrame, isFast, isExtreme)
    local ping = AllIn1.GetDataPingSeconds()
    local commit = 0.030 + (ping * AllIn1.NetworkCommitPingScale)
    if isCFrame then
        commit = commit + AllIn1.NetworkCommitCFrameExtra
    elseif isExtreme or isFast then
        commit = commit + AllIn1.NetworkCommitFastExtra
    end
    return math.clamp(commit, AllIn1.NetworkCommitMin, AllIn1.NetworkCommitMax)
end

AllIn1.GetAttackAimPosition = function(part, attemptIndex)
    local motion = AllIn1.SampleTargetMotion(part, os.clock())
    if not motion then
        AllIn1.LastPredictionLeadDistance = 0
        AllIn1.LastPredictionMode = "fallback"
        return getPredictedPosition(part)
    end

    local position = motion.Position
    local velocity = motion.EffectiveVelocity or motion.AssemblyVelocity or Vector3.zero
    local acceleration = motion.Acceleration or Vector3.zero
    local speed = velocity.Magnitude
    local cframeMotion = motion.CFrameMotion == true
    local extreme = cframeMotion
        or speed >= AllIn1.ExtremeTargetSpeed
        or math.abs(velocity.Y) >= AllIn1.ExtremeTargetVerticalSpeed
    local fast = extreme
        or motion.FlyMotion == true
        or speed >= AllIn1.FastTargetSpeed
        or math.abs(velocity.Y) >= AllIn1.FastTargetVerticalSpeed

    local localCharacter = LocalPlayer.Character
    local localRoot = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")
    local closeDistance = localRoot and (localRoot.Position - position).Magnitude or math.huge

    -- REGISTRATION FIX: E/H is already travelling WITH the target while glued.
    -- Predicting from absolute target speed can therefore aim many studs in front
    -- of the body even though the muzzle is only ~2 studs away. Use relative
    -- target-vs-shooter motion for the main lead, plus only a tiny capped shared
    -- world-motion correction for network delay.
    local relativeVelocity = velocity
    if localRoot then
        pcall(function()
            local rootVelocity = localRoot.AssemblyLinearVelocity
            if typeof(rootVelocity) == "Vector3" then
                relativeVelocity = velocity - rootVelocity
            end
        end)
    end

    attemptIndex = math.max(1, tonumber(attemptIndex) or 1)
    local retryPass = math.max(0, attemptIndex - 1)
    if MultiTarget.Running and MultiTarget.CurrentUserId then
        retryPass = math.max(retryPass, MultiTarget.RetryCounts[MultiTarget.CurrentUserId] or 0)
    end
    retryPass = math.min(retryPass, 3)

    -- E/H fire at close range while travelling with the target. Prediction should
    -- compensate relative drift, NOT project absolute speed tens of studs ahead.
    -- On each verified miss the next retry earns a little more lead. This gives
    -- flintlock/fly/CFrame motion a real adaptive search without ever aiming wildly
    -- outside the target's replicated body corridor.
    if closeDistance <= AllIn1.CloseRangeAimDistance then
        local leadTime
        local horizontalCap
        local verticalCap
        local mode

        local ping = AllIn1.GetDataPingSeconds()

        if cframeMotion then
            leadTime = math.min(
                AllIn1.MaxClosePredictionLeadTime,
                AllIn1.CFrameRetryLeadTime
                    + (ping * 0.50)
                    + (retryPass * AllIn1.PredictionRetryLeadBoost)
            )
            horizontalCap = math.min(AllIn1.CloseRangeCFrameLeadCap, 1.15 + (retryPass * 0.15))
            verticalCap = math.min(1.00, 0.70 + (retryPass * 0.10))
            mode = "cframe-relative"
        elseif extreme or motion.FlyMotion == true then
            leadTime = math.min(
                AllIn1.MaxClosePredictionLeadTime,
                AllIn1.CloseRangeFlyLeadTime
                    + (ping * 0.65)
                    + (retryPass * AllIn1.PredictionRetryLeadBoost)
            )
            horizontalCap = math.min(AllIn1.CloseRangeExtremeLeadCap, 1.25 + (retryPass * 0.15))
            verticalCap = math.min(1.10, 0.75 + (retryPass * 0.10))
            mode = "fly/extreme-relative"
        elseif fast then
            leadTime = math.min(
                0.045,
                AllIn1.CloseRangeFastLeadTime
                    + (ping * 0.55)
                    + (retryPass * 0.0045)
            )
            horizontalCap = math.min(1.50, 1.05 + (retryPass * 0.12))
            verticalCap = math.min(0.95, 0.65 + (retryPass * 0.08))
            mode = "fast-relative"
        else
            -- Stationary targets still lead by zero because velocity is zero. For
            -- ordinary walking, compensate only a fraction of ping so the aim does
            -- not jump several body-widths ahead.
            leadTime = math.min(0.025, AllIn1.CloseRangeNormalLeadTime + (ping * 0.25))
            horizontalCap = AllIn1.CloseRangeHorizontalLeadCap
            verticalCap = AllIn1.CloseRangeVerticalLeadCap
            mode = "normal-relative"
        end

        local lead = relativeVelocity * leadTime

        -- The root and target share most world velocity while glued, but CFrame/fly
        -- retries still need a SMALL forward search because the remote target can be
        -- several replicated frames ahead of the exact sample used at fire time. Pass 1
        -- remains unchanged; each verified miss adds only a bounded body-sized amount.
        -- Use the short-held recent velocity if the current CFrame sample collapsed.
        local sharedVelocity = velocity
        if (cframeMotion or motion.FlyMotion == true)
            and typeof(motion.RecentMotionVelocity) == "Vector3"
            and os.clock() <= (motion.RecentMotionUntil or 0)
            and motion.RecentMotionVelocity.Magnitude > sharedVelocity.Magnitude
        then
            sharedVelocity = motion.RecentMotionVelocity
        end
        local sharedLeadTime = (AllIn1.CloseRangeSharedMotionLeadTime or 0)
            + (retryPass * (AllIn1.CloseRangeSharedMotionRetryBoost or 0))
        local sharedLead = sharedVelocity * sharedLeadTime
        local sharedCap = (tonumber(AllIn1.CloseRangeSharedMotionLeadCap) or 0.70)
            + (retryPass * (AllIn1.CloseRangeSharedMotionRetryCapBoost or 0))
        if sharedLead.Magnitude > sharedCap and sharedLead.Magnitude > 0 then
            sharedLead = sharedLead.Unit * sharedCap
        end
        lead = lead + sharedLead
        AllIn1.LastPredictionMotionSpeed = sharedVelocity.Magnitude

        -- Acceleration is useful for real fly/flintlock motion, but discontinuous
        -- CFrame teleports can report absurd acceleration. Only use it when recent
        -- movement direction is coherent, and cap it to less than one stud.
        if not cframeMotion and relativeVelocity.Magnitude >= 6 and (motion.DirectionDot or 1) >= 0.20 then
            local accelLead = acceleration * (0.5 * leadTime * leadTime)
            if accelLead.Magnitude > AllIn1.PredictionAccelerationCap and accelLead.Magnitude > 0 then
                accelLead = accelLead.Unit * AllIn1.PredictionAccelerationCap
            end
            lead = lead + accelLead
        end

        local horizontal = Vector3.new(lead.X, 0, lead.Z)
        if horizontal.Magnitude > horizontalCap then
            horizontal = horizontal.Unit * horizontalCap
        end
        local vertical = math.clamp(lead.Y, -verticalCap, verticalCap)
        local finalLead = Vector3.new(horizontal.X, vertical, horizontal.Z)

        AllIn1.LastPredictionLeadDistance = finalLead.Magnitude
        AllIn1.LastPredictionMotionSpeed = math.max(
            tonumber(AllIn1.LastPredictionMotionSpeed) or 0,
            velocity.Magnitude
        )
        AllIn1.LastPredictionMode = mode
            .. ":pass" .. tostring(retryPass + 1)
            .. "@" .. tostring(AllIn1.LastPingMs or 0) .. "ms"
        return position + finalLead
    end

    -- Long-range fallback. Keep the old bounded behavior, but record the lead so
    -- miss diagnostics can show whether prediction or registration is the problem.
    local leadTime
    local horizontalCap
    local verticalCap
    if cframeMotion then
        leadTime = AllIn1.CFrameAimLeadTime
        horizontalCap = AllIn1.CFrameAimLeadCap
        verticalCap = 1.80
    elseif extreme then
        leadTime = MultiTarget.Running and 0.014 or 0.016
        horizontalCap = 5.25
        verticalCap = 3.00
    elseif fast then
        leadTime = MultiTarget.Running and 0.010 or 0.012
        horizontalCap = 3.50
        verticalCap = 1.90
    else
        leadTime = MultiTarget.Running and 0.0040 or 0.0050
        horizontalCap = 1.00
        verticalCap = 0.55
    end

    local lead = velocity * leadTime
    local horizontal = Vector3.new(lead.X, 0, lead.Z)
    if horizontal.Magnitude > horizontalCap then
        horizontal = horizontal.Unit * horizontalCap
    end
    local vertical = math.clamp(lead.Y, -verticalCap, verticalCap)
    local finalLead = Vector3.new(horizontal.X, vertical, horizontal.Z)
    AllIn1.LastPredictionLeadDistance = finalLead.Magnitude
    AllIn1.LastPredictionMode = "long-range"
    return position + finalLead
end

-- ============================================================
-- alex.ftn old-school skeet-inspired menu
-- ============================================================

local Menu = new("Frame", {
    Name = "MainMenu",
    Size = UDim2.fromOffset(500, 380),
    Position = UDim2.new(0, 40, 0.5, -190),
    BackgroundColor3 = Theme.Bg,
    BorderSizePixel = 0,
    Active = true,
    ClipsDescendants = true,
}, RootGui)

new("UIStroke", {
    Color = Theme.BorderDark,
    Thickness = 3,
    ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
}, Menu)

new("UIStroke", {
    Color = Theme.Border,
    Thickness = 1,
    ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
}, Menu)

local MenuScale = new("UIScale", {
    Scale = 1,
}, Menu)

local Header = new("Frame", {
    Name = "Header",
    Size = UDim2.new(1, 0, 0, 24),
    BackgroundColor3 = Color3.fromRGB(17, 17, 17),
    BorderSizePixel = 0,
    Active = true,
}, Menu)

new("Frame", {
    Position = UDim2.new(0, 1, 0, 1),
    Size = UDim2.new(1, -2, 0, 1),
    BackgroundColor3 = Theme.Accent,
    BorderSizePixel = 0,
}, Header)

new("TextLabel", {
    Position = UDim2.fromOffset(8, 1),
    Size = UDim2.new(1, -275, 1, -2),
    BackgroundTransparency = 1,
    Text = "alex.ftn",
    TextColor3 = Theme.Text,
    Font = Enum.Font.Code,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
}, Header)

local TabBar = new("Frame", {
    Name = "TabBar",
    Position = UDim2.new(1, -270, 0, 2),
    Size = UDim2.fromOffset(260, 20),
    BackgroundTransparency = 1,
}, Menu)

local function makeTabButton(name, x)
    local button = new("TextButton", {
        Name = name .. "Tab",
        Position = UDim2.fromOffset(x, 0),
        Size = UDim2.fromOffset(63, 20),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Text = string.lower(name),
        TextColor3 = Theme.Muted,
        Font = Enum.Font.Code,
        TextSize = 10,
        AutoButtonColor = false,
    }, TabBar)
    return button
end

local CombatTab = makeTabButton("Combat", 0)
local VisualsTab = makeTabButton("Visuals", 65)
local UtilityTab = makeTabButton("Utility", 130)
local HitsoundsTab = makeTabButton("Hitsounds", 195)

local PageHolder = new("Frame", {
    Name = "PageHolder",
    Position = UDim2.fromOffset(10, 34),
    Size = UDim2.new(1, -20, 1, -71),
    BackgroundTransparency = 1,
    ClipsDescendants = true,
}, Menu)

local CombatPage = new("Frame", {
    Name = "CombatPage",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
}, PageHolder)

local VisualsPage = new("Frame", {
    Name = "VisualsPage",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    ClipsDescendants = true,
    Visible = false,
}, PageHolder)

local UtilityPage = new("Frame", {
    Name = "UtilityPage",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Visible = false,
}, PageHolder)

local HitsoundsPage = new("Frame", {
    Name = "HitsoundsPage",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Visible = false,
}, PageHolder)

local function makeSection(parent, titleText, position, size)
    local frame = new("Frame", {
        Position = position,
        Size = size,
        BackgroundColor3 = Theme.Panel,
        BorderSizePixel = 0,
    }, parent)

    new("UIStroke", {
        Color = Theme.Border,
        Thickness = 1,
    }, frame)

    new("TextLabel", {
        Position = UDim2.fromOffset(8, -8),
        Size = UDim2.fromOffset(math.max(64, #titleText * 7 + 14), 16),
        BackgroundColor3 = Theme.Panel,
        BorderSizePixel = 0,
        Text = " " .. string.lower(titleText) .. " ",
        TextColor3 = Color3.fromRGB(145, 145, 145),
        Font = Enum.Font.Code,
        TextSize = 10,
    }, frame)

    return frame
end

local LockSection = makeSection(
    CombatPage,
    "main",
    UDim2.fromOffset(0, 6),
    UDim2.new(0, 190, 0, 140)
)

local VoidSection = makeSection(
    CombatPage,
    "void hide",
    UDim2.new(0, 202, 0, 6),
    UDim2.new(1, -202, 0, 64)
)

MultiTarget.Section = makeSection(
    CombatPage,
    "multitarget",
    UDim2.new(0, 202, 0, 82),
    UDim2.new(1, -202, 0, 214)
)
MultiTarget.Section.ClipsDescendants = true

local PlayerSection = makeSection(
    VisualsPage,
    "players / blacklist",
    UDim2.new(0, 202, 0, 6),
    UDim2.new(1, -202, 1, -6)
)
PlayerSection.ClipsDescendants = true

local VisualSection = makeSection(
    VisualsPage,
    "esp",
    UDim2.fromOffset(0, 6),
    UDim2.new(0, 190, 1, -6)
)

local TeleportSection = makeSection(
    UtilityPage,
    "teleport",
    UDim2.fromOffset(0, 6),
    UDim2.new(1, 0, 0, 60)
)

local CFrameSection = makeSection(
    UtilityPage,
    "cframe speed",
    UDim2.fromOffset(0, 80),
    UDim2.new(1, 0, 0, 92)
)

local FlySection = makeSection(
    UtilityPage,
    "fly",
    UDim2.fromOffset(0, 190),
    UDim2.new(1, 0, 0, 92)
)

HitSound.Section = makeSection(
    HitsoundsPage,
    "hitsound",
    UDim2.fromOffset(0, 6),
    UDim2.new(1, 0, 1, -6)
)

HitSound.MakeButton = function(y, text, callback)
    local button = new("TextButton", {
        Position = UDim2.fromOffset(12, y),
        Size = UDim2.new(1, -24, 0, 28),
        BackgroundColor3 = Theme.Panel2,
        BorderSizePixel = 0,
        Text = text,
        TextColor3 = Theme.Text,
        Font = Enum.Font.Code,
        TextSize = 11,
        AutoButtonColor = false,
    }, HitSound.Section)
    new("UIStroke", { Color = Theme.Border, Thickness = 1 }, button)
    track(button.MouseButton1Click:Connect(function()
        if not Unloaded and HitSound.Alive then
            callback(button)
        end
    end))
    return button
end

HitSound.EnabledButton = HitSound.MakeButton(20, "Enabled: ON", function(button)
    HitSound.Enabled = not HitSound.Enabled
    button.Text = "Enabled: " .. (HitSound.Enabled and "ON" or "OFF")
    HitSound.SetStatus(HitSound.Enabled and "ready - instant on shot" or "disabled")
end)

HitSound.SoundIndex = table.find(HitSound.Names, HitSound.Selected) or 1
HitSound.SoundButton = HitSound.MakeButton(56, "Sound: " .. HitSound.Selected, function(button)
    HitSound.SoundIndex = (HitSound.SoundIndex % #HitSound.Names) + 1
    HitSound.Selected = HitSound.Names[HitSound.SoundIndex]
    button.Text = "Sound: " .. HitSound.Selected
    HitSound.ApplySelectedSound(true)
    HitSound.SetStatus("selected: " .. HitSound.Selected)
end)

HitSound.MakeButton(92, "Previous sound", function()
    HitSound.SoundIndex = HitSound.SoundIndex - 1
    if HitSound.SoundIndex < 1 then
        HitSound.SoundIndex = #HitSound.Names
    end
    HitSound.Selected = HitSound.Names[HitSound.SoundIndex]
    HitSound.SoundButton.Text = "Sound: " .. HitSound.Selected
    HitSound.ApplySelectedSound(true)
    HitSound.SetStatus("selected: " .. HitSound.Selected)
end)

HitSound.VolumeButton = HitSound.MakeButton(128, "Volume: 50%", function(button)
    HitSound.Volume = HitSound.Volume + 0.1
    if HitSound.Volume > 1.001 then
        HitSound.Volume = 0
    end
    HitSound.Volume = math.floor(HitSound.Volume * 10 + 0.5) / 10
    if HitSound.Sound then
        HitSound.Sound.Volume = HitSound.Volume
    end
    button.Text = string.format("Volume: %d%%", HitSound.Volume * 100)
end)

HitSound.MakeButton(164, "Preview selected sound", function()
    HitSound.Play("preview", true)
end)

HitSound.StatusLabel = new("TextLabel", {
    Position = UDim2.fromOffset(12, 204),
    Size = UDim2.new(1, -24, 0, 34),
    BackgroundTransparency = 1,
    Text = "ready - instant on shot",
    TextWrapped = true,
    TextColor3 = Theme.Muted,
    Font = Enum.Font.Code,
    TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Center,
    TextYAlignment = Enum.TextYAlignment.Top,
}, HitSound.Section)

-- Player / blacklist panel follows the same old skeet-style charcoal theme.
PlayerSection.BackgroundColor3 = Theme.Panel
for _, child in ipairs(PlayerSection:GetChildren()) do
    if child:IsA("UIStroke") then
        child.Color = Theme.Border
    elseif child:IsA("TextLabel") then
        child.BackgroundColor3 = Theme.Panel
        child.TextColor3 = Color3.fromRGB(165, 165, 165)
    end
end

local function makeToggleRow(parent, y, labelText, keyText)
    local box = new("Frame", {
        Position = UDim2.fromOffset(13, y + 6),
        Size = UDim2.fromOffset(7, 7),
        BackgroundColor3 = Color3.fromRGB(24, 24, 24),
        BorderSizePixel = 0,
    }, parent)

    local stroke = new("UIStroke", {
        Color = Color3.fromRGB(68, 68, 68),
        Thickness = 1,
    }, box)

    new("TextLabel", {
        Position = UDim2.fromOffset(28, y),
        Size = UDim2.new(1, -82, 0, 18),
        BackgroundTransparency = 1,
        Text = labelText,
        TextColor3 = Theme.Text,
        Font = Enum.Font.Code,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, parent)

    if keyText then
        local key = new("TextLabel", {
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, -10, 0, y),
            Size = UDim2.fromOffset(42, 18),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Text = "[" .. keyText .. "]",
            TextColor3 = Color3.fromRGB(125, 125, 125),
            Font = Enum.Font.Code,
            TextSize = 9,
        }, parent)
    end

    local hitbox = new("TextButton", {
        Position = UDim2.fromOffset(8, y - 3),
        Size = UDim2.new(1, -16, 0, 26),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
    }, parent)

    return box, stroke, hitbox
end

local LockBox, LockStroke, LockHitbox = makeToggleRow(LockSection, 20, "lock", "C")
AllIn1.Box, AllIn1.Stroke, AllIn1.Hitbox = makeToggleRow(LockSection, 48, "allin1", "E")
local VoidSpamBox, VoidSpamStroke, VoidSpamHitbox = makeToggleRow(VoidSection, 20, "void hide", "V")

MultiTarget.Box, MultiTarget.Stroke, MultiTarget.Hitbox = makeToggleRow(MultiTarget.Section, 16, "multitarget", "H")
MultiTarget.BlacklistBox, MultiTarget.BlacklistStroke, MultiTarget.BlacklistHitbox =
    makeToggleRow(MultiTarget.Section, 42, "blacklist only", nil)
MultiTarget.BlacklistHitbox.Active = true
MultiTarget.BlacklistHitbox.Selectable = true
MultiTarget.BlacklistHitbox.ZIndex = 20
MultiTarget.SelectedBox, MultiTarget.SelectedStroke, MultiTarget.SelectedHitbox =
    makeToggleRow(MultiTarget.Section, 68, "selected only", nil)
MultiTarget.SafeBox, MultiTarget.SafeStroke, MultiTarget.SafeHitbox =
    makeToggleRow(MultiTarget.Section, 94, "safe mode", nil)
MultiTarget.ForceFieldBox, MultiTarget.ForceFieldStroke, MultiTarget.ForceFieldHitbox =
    makeToggleRow(MultiTarget.Section, 120, "forcefield check", nil)
MultiTarget.ReturnBox, MultiTarget.ReturnStroke, MultiTarget.ReturnHitbox =
    makeToggleRow(MultiTarget.Section, 146, "return each", nil)

MultiTarget.PriorityButton = new("TextButton", {
    Position = UDim2.fromOffset(12, 171),
    Size = UDim2.new(1, -24, 0, 18),
    BackgroundColor3 = Color3.fromRGB(17, 17, 17),
    BorderSizePixel = 0,
    Text = "priority: nearest",
    TextColor3 = Theme.AccentBright,
    Font = Enum.Font.Code,
    TextSize = 10,
    AutoButtonColor = false,
}, MultiTarget.Section)
new("UIStroke", { Color = Theme.Border, Thickness = 1 }, MultiTarget.PriorityButton)

MultiTarget.StatusLabel = new("TextLabel", {
    Position = UDim2.fromOffset(13, 191),
    Size = UDim2.new(1, -26, 0, 14),
    BackgroundTransparency = 1,
    Text = "idle  |  abort J",
    TextColor3 = Theme.Muted,
    Font = Enum.Font.Code,
    TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Left,
}, MultiTarget.Section)

MultiTarget.HUD = new("TextLabel", {
    Name = "MultiTargetHUD",
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.new(0.5, 0, 0, 66),
    Size = UDim2.fromOffset(330, 24),
    BackgroundColor3 = Color3.fromRGB(16, 16, 16),
    BackgroundTransparency = 0.08,
    BorderSizePixel = 0,
    Text = "",
    TextColor3 = Theme.AccentBright,
    Font = Enum.Font.Code,
    TextSize = 11,
    Visible = false,
}, RootGui)
new("UIStroke", { Color = Theme.Border, Thickness = 1 }, MultiTarget.HUD)

local TeleportBox, TeleportStroke, TeleportHitbox = makeToggleRow(TeleportSection, 20, "teleport to target", "T")
local CFrameBox, CFrameStroke, CFrameHitbox = makeToggleRow(CFrameSection, 18, "cframe", "Z")
local FlyBox, FlyStroke, FlyHitbox = makeToggleRow(FlySection, 18, "fly", "X")
Utility.FakePosBox, Utility.FakePosStroke, Utility.FakePosHitbox =
    makeToggleRow(UtilityPage, 286, "fake pos", "F")
Utility.FakePosStatusLabel = new("TextLabel", {
    Position = UDim2.new(0, 105, 0, 286),
    Size = UDim2.new(1, -165, 0, 18),
    BackgroundTransparency = 1,
    Text = "compat: unchecked",
    TextColor3 = Theme.Muted,
    Font = Enum.Font.Code,
    TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Right,
}, UtilityPage)

Utility.FakePosDiagLabel = new("TextLabel", {
    Position = UDim2.new(0, 12, 0, 304),
    Size = UDim2.new(1, -24, 0, 14),
    BackgroundTransparency = 1,
    Text = "",
    TextColor3 = Theme.Muted,
    Font = Enum.Font.Code,
    TextSize = 8,
    TextXAlignment = Enum.TextXAlignment.Right,
    Visible = false,
}, UtilityPage)

local function makeSpeedSlider(parent, y, labelText, initialValue)
    local label = new("TextLabel", {
        Position = UDim2.fromOffset(13, y),
        Size = UDim2.new(1, -70, 0, 16),
        BackgroundTransparency = 1,
        Text = labelText,
        TextColor3 = Theme.Text,
        Font = Enum.Font.Code,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, parent)

    local valueLabel = new("TextLabel", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -13, 0, y),
        Size = UDim2.fromOffset(58, 16),
        BackgroundTransparency = 1,
        Text = tostring(initialValue),
        TextColor3 = Theme.AccentBright,
        Font = Enum.Font.Code,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Right,
    }, parent)

    local bar = new("Frame", {
        Position = UDim2.fromOffset(13, y + 22),
        Size = UDim2.new(1, -26, 0, 6),
        BackgroundColor3 = Color3.fromRGB(15, 15, 15),
        BorderSizePixel = 0,
    }, parent)
    new("UIStroke", { Color = Theme.Border, Thickness = 1 }, bar)

    local alpha = math.clamp((initialValue - Utility.MinSpeed) / (Utility.MaxSpeed - Utility.MinSpeed), 0, 1)
    local fill = new("Frame", {
        Size = UDim2.new(alpha, 0, 1, 0),
        BackgroundColor3 = Theme.Accent,
        BorderSizePixel = 0,
    }, bar)

    local knob = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(alpha, 0, 0.5, 0),
        Size = UDim2.fromOffset(7, 12),
        BackgroundColor3 = Theme.AccentBright,
        BorderSizePixel = 0,
    }, bar)
    new("UIStroke", { Color = Theme.BorderDark, Thickness = 1 }, knob)

    local hitbox = new("TextButton", {
        Position = UDim2.fromOffset(-4, -7),
        Size = UDim2.new(1, 8, 1, 14),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
    }, bar)

    return label, valueLabel, bar, fill, knob, hitbox
end

local _, CFrameSpeedValue, CFrameSpeedBar, CFrameSpeedFill, CFrameSpeedKnob, CFrameSpeedHitbox =
    makeSpeedSlider(CFrameSection, 46, "speed", Utility.CFrameSpeed)
local _, FlySpeedValue, FlySpeedBar, FlySpeedFill, FlySpeedKnob, FlySpeedHitbox =
    makeSpeedSlider(FlySection, 46, "speed", Utility.FlySpeed)

new("TextLabel", {
    Position = UDim2.fromOffset(13, 80),
    Size = UDim2.new(1, -26, 0, 16),
    BackgroundTransparency = 1,
    Text = "walls: ignore  |  KO: untoggle",
    TextColor3 = Theme.Muted,
    Font = Enum.Font.Code,
    TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Left,
}, LockSection)

local LockStatus = new("TextLabel", {
    Position = UDim2.fromOffset(13, 108),
    Size = UDim2.new(1, -26, 0, 18),
    BackgroundTransparency = 1,
    Text = "status: OFF",
    TextColor3 = Theme.RedBright,
    Font = Enum.Font.Code,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
}, LockSection)


local SearchBox = new("TextBox", {
    Position = UDim2.fromOffset(10, 15),
    Size = UDim2.new(1, -20, 0, 24),
    BackgroundColor3 = Color3.fromRGB(17, 17, 17),
    BorderSizePixel = 0,
    PlaceholderText = "search players...",
    PlaceholderColor3 = Color3.fromRGB(90, 90, 90),
    Text = "",
    TextColor3 = Theme.Text,
    ClearTextOnFocus = false,
    Font = Enum.Font.Code,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
}, PlayerSection)

new("UIPadding", {
    PaddingLeft = UDim.new(0, 7),
    PaddingRight = UDim.new(0, 7),
}, SearchBox)

new("UIStroke", {
    Color = Theme.Border,
    Thickness = 1,
}, SearchBox)

local PlayerList = new("ScrollingFrame", {
    Position = UDim2.fromOffset(10, 47),
    Size = UDim2.new(1, -20, 1, -57),
    BackgroundColor3 = Color3.fromRGB(17, 17, 17),
    BorderSizePixel = 0,
    CanvasSize = UDim2.fromOffset(0, 0),
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = Theme.Accent,
    AutomaticCanvasSize = Enum.AutomaticSize.None,
    ClipsDescendants = true,
    Active = true,
    ScrollingEnabled = true,
}, PlayerSection)

new("UIStroke", {
    Color = Theme.Border,
    Thickness = 1,
}, PlayerList)

local PlayerListLayout = new("UIListLayout", {
    SortOrder = Enum.SortOrder.LayoutOrder,
    Padding = UDim.new(0, 3),
}, PlayerList)

new("UIPadding", {
    PaddingTop = UDim.new(0, 4),
    PaddingBottom = UDim.new(0, 4),
    PaddingLeft = UDim.new(0, 4),
    PaddingRight = UDim.new(0, 4),
}, PlayerList)

track(PlayerListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    PlayerList.CanvasSize = UDim2.fromOffset(0, PlayerListLayout.AbsoluteContentSize.Y + 8)
end))

local ESPBox, ESPStroke, ESPHitbox = makeToggleRow(VisualSection, 20, "enhanced ESP", "G")
local ESPHealthBox, ESPHealthStroke, ESPHealthHitbox = makeToggleRow(VisualSection, 50, "health bar", nil)
local ESPOffscreenBox, ESPOffscreenStroke, ESPOffscreenHitbox = makeToggleRow(VisualSection, 80, "offscreen indicators", nil)
local ESPTargetBox, ESPTargetStroke, ESPTargetHitbox = makeToggleRow(VisualSection, 110, "silhouette outline", nil)

local ESPStatus = new("TextLabel", {
    Position = UDim2.fromOffset(13, 143),
    Size = UDim2.new(1, -26, 0, 18),
    BackgroundTransparency = 1,
    Text = "status: OFF",
    TextColor3 = Theme.RedBright,
    Font = Enum.Font.Code,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
}, VisualSection)


local UnloadButton = new("TextButton", {
    Name = "Unload",
    AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -17, 1, -9),
    Size = UDim2.fromOffset(76, 22),
    BackgroundColor3 = Theme.Panel2,
    BorderSizePixel = 0,
    Text = "unload",
    TextColor3 = Theme.Muted,
    Font = Enum.Font.Code,
    TextSize = 11,
    AutoButtonColor = false,
}, Menu)

new("UIStroke", {
    Color = Theme.Border,
    Thickness = 1,
}, UnloadButton)

local ResizeHandle = new("TextButton", {
    Name = "ResizeHandle",
    AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -3, 1, -3),
    Size = UDim2.fromOffset(20, 20),
    BackgroundTransparency = 1,
    Text = "◢",
    TextColor3 = Theme.AccentBright,
    Font = Enum.Font.Code,
    TextSize = 16,
    AutoButtonColor = false,
    ZIndex = 50,
}, Menu)

-- Small visibility boost for every menu text object, including player rows
-- created later. The attribute prevents accidental double-scaling.
Utility.BoostMenuFont = function(object)
    if not object or object:GetAttribute("alex.ftn_FontBoosted") then
        return
    end
    if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
        object.TextSize = math.min((tonumber(object.TextSize) or 10) + 1, 17)
        object:SetAttribute("alex.ftn_FontBoosted", true)
    end
end

for _, descendant in ipairs(Menu:GetDescendants()) do
    Utility.BoostMenuFont(descendant)
end
track(Menu.DescendantAdded:Connect(function(descendant)
    task.defer(Utility.BoostMenuFont, descendant)
end))

local ActiveTab = "Combat"
local function setTab(tabName)
    ActiveTab = tabName
    local combat = tabName == "Combat"
    local visuals = tabName == "Visuals"
    local utility = tabName == "Utility"
    local hitsounds = tabName == "Hitsounds"

    CombatPage.Visible = combat
    VisualsPage.Visible = visuals
    UtilityPage.Visible = utility
    HitsoundsPage.Visible = hitsounds

    CombatTab.TextColor3 = combat and Theme.AccentBright or Theme.Muted
    VisualsTab.TextColor3 = visuals and Theme.AccentBright or Theme.Muted
    UtilityTab.TextColor3 = utility and Theme.AccentBright or Theme.Muted
    HitsoundsTab.TextColor3 = hitsounds and Theme.AccentBright or Theme.Muted
end

track(CombatTab.MouseButton1Click:Connect(function()
    setTab("Combat")
end))

track(VisualsTab.MouseButton1Click:Connect(function()
    setTab("Visuals")
end))

track(UtilityTab.MouseButton1Click:Connect(function()
    setTab("Utility")
end))

track(HitsoundsTab.MouseButton1Click:Connect(function()
    setTab("Hitsounds")
end))

setTab("Combat")

-- ============================================================
-- Target HUD based on the supplied reference
-- ============================================================

local TargetHUD = new("Frame", {
    Name = "TargetHUD",
    AnchorPoint = Vector2.new(0.5, 1),
    Position = UDim2.new(0.5, 0, 1, -112),
    Size = UDim2.fromOffset(304, 108),
    BackgroundColor3 = Theme.Bg,
    BackgroundTransparency = 0.03,
    BorderSizePixel = 0,
    Visible = false,
}, RootGui)

new("UICorner", {
    CornerRadius = UDim.new(0, 3),
}, TargetHUD)

new("UIStroke", {
    Color = Theme.Border,
    Thickness = 1,
}, TargetHUD)

new("Frame", {
    Position = UDim2.fromOffset(5, 5),
    Size = UDim2.new(0, 2, 1, -10),
    BackgroundColor3 = Theme.Accent,
    BorderSizePixel = 0,
}, TargetHUD)

local TargetAvatar = new("ImageLabel", {
    Position = UDim2.fromOffset(16, 21),
    Size = UDim2.fromOffset(62, 62),
    BackgroundColor3 = Color3.fromRGB(14, 14, 14),
    BorderSizePixel = 0,
    Image = "",
    ScaleType = Enum.ScaleType.Crop,
}, TargetHUD)

new("UICorner", {
    CornerRadius = UDim.new(0, 6),
}, TargetAvatar)

new("UIStroke", {
    Color = Theme.Border,
    Thickness = 1,
}, TargetAvatar)

local TargetName = new("TextLabel", {
    Position = UDim2.fromOffset(90, 13),
    Size = UDim2.new(1, -101, 0, 18),
    BackgroundTransparency = 1,
    Text = "target",
    TextColor3 = Color3.fromRGB(235, 235, 235),
    Font = Enum.Font.Code,
    TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
}, TargetHUD)

local TargetState = new("TextLabel", {
    Position = UDim2.fromOffset(90, 37),
    Size = UDim2.new(1, -101, 0, 18),
    BackgroundColor3 = Color3.fromRGB(17, 17, 17),
    BorderSizePixel = 0,
    Text = "LOCKED",
    TextColor3 = Theme.AccentBright,
    Font = Enum.Font.Code,
    TextSize = 10,
}, TargetHUD)

local HealthBarBg = new("Frame", {
    Position = UDim2.fromOffset(90, 64),
    Size = UDim2.new(1, -101, 0, 4),
    BackgroundColor3 = Color3.fromRGB(12, 12, 12),
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, TargetHUD)

local HealthBar = new("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Theme.Accent,
    BorderSizePixel = 0,
}, HealthBarBg)

-- Hood-style games commonly absorb damage into BodyEffects.Armor before HP.
-- Keep it separate from the green HP bar so the HUD never makes armor damage
-- look like a broken/stuck health meter.
local ArmorBarBg = new("Frame", {
    Position = UDim2.fromOffset(90, 70),
    Size = UDim2.new(1, -101, 0, 2),
    BackgroundColor3 = Color3.fromRGB(12, 12, 12),
    BorderSizePixel = 0,
    ClipsDescendants = true,
    Visible = false,
}, TargetHUD)

local ArmorBar = new("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Theme.AccentBright,
    BorderSizePixel = 0,
}, ArmorBarBg)

local TargetInfo = new("TextLabel", {
    Position = UDim2.fromOffset(90, 76),
    Size = UDim2.new(1, -101, 0, 18),
    BackgroundTransparency = 1,
    Text = "HP 0/0  •  0 studs",
    TextColor3 = Theme.Muted,
    Font = Enum.Font.Code,
    TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
}, TargetHUD)

local HUDPlayerId = nil
local TargetHUDArmorMax = {}
local function updateTargetThumbnail(player)
    if not player or HUDPlayerId == player.UserId then
        return
    end

    HUDPlayerId = player.UserId
    local cached = ThumbnailCache[player.UserId]
    if cached then
        TargetAvatar.Image = cached
        return
    end

    task.spawn(function()
        local success, image = pcall(function()
            return Players:GetUserThumbnailAsync(
                player.UserId,
                Enum.ThumbnailType.HeadShot,
                Enum.ThumbnailSize.Size150x150
            )
        end)

        if Unloaded then
            return
        end
        if success and image then
            ThumbnailCache[player.UserId] = image
            if Aim.CurrentTarget == player and TargetAvatar.Parent then
                TargetAvatar.Image = image
            end
        end
    end)
end

local function updateTargetHUD()
    local target = Aim.CurrentTarget
    if not Aim.Toggled or not target or target.Parent == nil then
        TargetHUD.Visible = false
        HUDPlayerId = nil
        return
    end

    -- Resolve every frame from the live Character rather than trusting an ESP
    -- cache. This keeps the HUD correct across damage, KO and respawn swaps.
    local health, maxHealth, armor, humanoid = getPlayerVitals(target)
    local targetPart = getTargetPart(target)
    local localRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local character = target.Character
    local ko = isKnockedOut(target)
    local forceField = character and character:FindFirstChildOfClass("ForceField") ~= nil

    TargetHUD.Visible = true
    TargetName.Text = target.DisplayName or target.Name
    updateTargetThumbnail(target)

    if ko then
        TargetState.Text = "KO"
        TargetState.TextColor3 = Theme.RedBright
    elseif not humanoid or health <= 0 then
        TargetState.Text = "RESPAWNING"
        TargetState.TextColor3 = Theme.Muted
    elseif forceField then
        TargetState.Text = "FORCEFIELD"
        TargetState.TextColor3 = Theme.AccentBright
    else
        TargetState.Text = "LOCKED"
        TargetState.TextColor3 = Theme.AccentBright
    end

    local ratio = math.clamp(health / math.max(1, maxHealth), 0, 1)
    -- Direct sizing is intentional: no tween lag/restart, so every replicated
    -- health change is visible on the very next HUD refresh.
    HealthBar.Size = UDim2.new(ratio, 0, 1, 0)

    local armorCache = TargetHUDArmorMax[target.UserId]
    if armor > 0 then
        -- Reset the observed armor maximum on a new character so a previous
        -- life cannot leave the next spawn's armor bar permanently undersized.
        if not armorCache or armorCache.Character ~= character then
            armorCache = { Character = character, Max = math.max(100, armor) }
            TargetHUDArmorMax[target.UserId] = armorCache
        elseif armor > armorCache.Max then
            armorCache.Max = armor
        end

        ArmorBarBg.Visible = true
        ArmorBar.Size = UDim2.new(math.clamp(armor / math.max(1, armorCache.Max), 0, 1), 0, 1, 0)
    else
        ArmorBarBg.Visible = false
        ArmorBar.Size = UDim2.new(0, 0, 1, 0)
    end

    local distance = 0
    if targetPart and localRoot then
        distance = (targetPart.Position - localRoot.Position).Magnitude
    elseif targetPart and Camera then
        distance = (targetPart.Position - Camera.CFrame.Position).Magnitude
    end

    if armor > 0 then
        TargetInfo.Text = string.format(
            "HP %d/%d  •  ARM %d  •  %d studs",
            math.floor(health + 0.5),
            math.floor(maxHealth + 0.5),
            math.floor(armor + 0.5),
            math.floor(distance + 0.5)
        )
    else
        TargetInfo.Text = string.format(
            "HP %d/%d  •  %d studs",
            math.floor(health + 0.5),
            math.floor(maxHealth + 0.5),
            math.floor(distance + 0.5)
        )
    end
end

-- ============================================================
-- Cursor tracer
-- ============================================================

-- Keybind list removed by request.

local CursorTracerGlow = new("Frame", {
    Name = "CursorTracerGlow",
    AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundColor3 = Theme.Accent,
    BackgroundTransparency = 0.72,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 998,
}, RootGui)

local CursorTracer = new("Frame", {
    Name = "CursorTracer",
    AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundColor3 = Theme.AccentBright,
    BackgroundTransparency = 0.08,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 999,
}, RootGui)

local function setScreenLine(frame, fromPoint, toPoint, thickness)
    local delta = toPoint - fromPoint
    local length = delta.Magnitude
    if length < 1 then
        frame.Visible = false
        return
    end

    frame.Visible = true
    frame.Position = UDim2.fromOffset((fromPoint.X + toPoint.X) * 0.5, (fromPoint.Y + toPoint.Y) * 0.5)
    frame.Size = UDim2.fromOffset(length, thickness)
    frame.Rotation = math.deg(math.atan2(delta.Y, delta.X))
end

-- Screen-edge projection used only by the two persistent visual tracers.
-- If an endpoint leaves the camera POV (or moves behind the camera), keep the
-- line visible by pinning that endpoint to the matching edge of the viewport.
Utility.ProjectWorldToScreenEdge = function(worldPosition, margin)
    if not Camera or typeof(worldPosition) ~= "Vector3" then
        return nil, false
    end

    margin = math.max(4, tonumber(margin) or 12)
    local point, onScreen = Camera:WorldToViewportPoint(worldPosition)
    if onScreen and point.Z > 0 then
        return Vector2.new(point.X, point.Y), true
    end

    local viewport = Camera.ViewportSize
    local center = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
    local direction = Vector2.new(point.X, point.Y) - center

    -- WorldToViewportPoint mirrors points that are behind the camera. Flip the
    -- direction back so the edge indicator stays on the correct side.
    if point.Z <= 0 then
        direction = -direction
    end

    if direction.Magnitude < 0.001 then
        local cameraSpace = Camera.CFrame:PointToObjectSpace(worldPosition)
        direction = Vector2.new(cameraSpace.X, -cameraSpace.Y)
        if direction.Magnitude < 0.001 then
            direction = Vector2.new(0, -1)
        end
    end

    local halfWidth = math.max(1, center.X - margin)
    local halfHeight = math.max(1, center.Y - margin)
    local xScale = math.abs(direction.X) > 0.001 and (halfWidth / math.abs(direction.X)) or math.huge
    local yScale = math.abs(direction.Y) > 0.001 and (halfHeight / math.abs(direction.Y)) or math.huge
    local scale = math.min(xScale, yScale)
    local edge = center + (direction * scale)

    edge = Vector2.new(
        math.clamp(edge.X, margin, math.max(margin, viewport.X - margin)),
        math.clamp(edge.Y, margin, math.max(margin, viewport.Y - margin))
    )
    return edge, false
end

-- Fake Pos visual snapshot. This is visual-only: when Fake Pos turns ON, a
-- stationary transparent cham is left exactly where the local character was,
-- and a GUI-accent tracer links that ghost HRP to the live HRP until Fake Pos
-- is turned OFF. The replication/desync code below is intentionally untouched.
Utility.FakePosGhost = nil
Utility.FakePosGhostRoot = nil
Utility.FakePosVisualLiveRoot = nil
Utility.FakePosVisualCreatedAt = 0
Utility.FakePosLastDistance = 0
Utility.FakePosCycleNilOK = nil
Utility.FakePosCycleRestoreOK = nil
Utility.FakePosCycleHoldOK = nil
Utility.FakePosCycleState = "idle"
Utility.FakePosRootState = "unknown"
Utility.FakePosDiagLastUpdate = 0
Utility.FakePosLastHealth = nil
Utility.FakePosDamageFlashUntil = 0
Utility.FakePosJoinStatus = "idle"
Utility.FakePosJoinDetail = ""
Utility.FakePosJoinStatusUntil = 0
Utility.FakePosJoinUserId = nil
Utility.FakePosJoinGeneration = 0
Utility.FakePosJoinRoot = nil

Utility.FakePosTracerGlow = new("Frame", {
    Name = "FakePosTracerGlow",
    AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundColor3 = Theme.Accent,
    BackgroundTransparency = 0.72,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 996,
}, RootGui)

Utility.FakePosTracer = new("Frame", {
    Name = "FakePosTracer",
    AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundColor3 = Theme.AccentBright,
    BackgroundTransparency = 0.08,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 997,
}, RootGui)

-- Live-HRP marker. Small circular standing-person badge matching the supplied
-- reference, recolored to the existing alex.ftn GUI palette. Primitive GUI shapes
-- keep it self-contained and avoid any external image/asset dependency.
Utility.FakePosRealMarker = new("Frame", {
    Name = "FakePosRealMarker",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Size = UDim2.fromOffset(30, 30),
    BackgroundColor3 = Theme.Panel,
    BackgroundTransparency = 0.04,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 1000,
}, RootGui)

new("UICorner", {
    CornerRadius = UDim.new(1, 0),
}, Utility.FakePosRealMarker)

Utility.FakePosRealMarkerStroke = new("UIStroke", {
    Color = Theme.Accent,
    Thickness = 1,
    Transparency = 0.18,
    ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
}, Utility.FakePosRealMarker)

-- Compact standing-person silhouette centered inside the circular badge.
Utility.FakePosRealMarkerHead = new("Frame", {
    Name = "Head",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromOffset(15, 7),
    Size = UDim2.fromOffset(6, 6),
    BackgroundColor3 = Theme.AccentBright,
    BorderSizePixel = 0,
    ZIndex = 1002,
}, Utility.FakePosRealMarker)

new("UICorner", {
    CornerRadius = UDim.new(1, 0),
}, Utility.FakePosRealMarkerHead)

Utility.FakePosRealMarkerCore = new("Frame", {
    Name = "Body",
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.fromOffset(15, 11),
    Size = UDim2.fromOffset(7, 9),
    BackgroundColor3 = Theme.AccentBright,
    BorderSizePixel = 0,
    ZIndex = 1002,
}, Utility.FakePosRealMarker)

new("UICorner", {
    CornerRadius = UDim.new(0, 3),
}, Utility.FakePosRealMarkerCore)

Utility.FakePosRealMarkerArms = new("Frame", {
    Name = "Shoulders",
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.fromOffset(15, 12),
    Size = UDim2.fromOffset(13, 3),
    BackgroundColor3 = Theme.AccentBright,
    BorderSizePixel = 0,
    ZIndex = 1001,
}, Utility.FakePosRealMarker)

new("UICorner", {
    CornerRadius = UDim.new(1, 0),
}, Utility.FakePosRealMarkerArms)

Utility.FakePosRealMarkerLeftArm = new("Frame", {
    Name = "LeftArm",
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.fromOffset(9.5, 13),
    Size = UDim2.fromOffset(3, 8),
    BackgroundColor3 = Theme.AccentBright,
    BorderSizePixel = 0,
    ZIndex = 1002,
}, Utility.FakePosRealMarker)

new("UICorner", {
    CornerRadius = UDim.new(1, 0),
}, Utility.FakePosRealMarkerLeftArm)

Utility.FakePosRealMarkerRightArm = new("Frame", {
    Name = "RightArm",
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.fromOffset(20.5, 13),
    Size = UDim2.fromOffset(3, 8),
    BackgroundColor3 = Theme.AccentBright,
    BorderSizePixel = 0,
    ZIndex = 1002,
}, Utility.FakePosRealMarker)

new("UICorner", {
    CornerRadius = UDim.new(1, 0),
}, Utility.FakePosRealMarkerRightArm)

Utility.FakePosRealMarkerLeftLeg = new("Frame", {
    Name = "LeftLeg",
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.fromOffset(13, 19),
    Size = UDim2.fromOffset(3, 8),
    BackgroundColor3 = Theme.AccentBright,
    BorderSizePixel = 0,
    ZIndex = 1002,
}, Utility.FakePosRealMarker)

new("UICorner", {
    CornerRadius = UDim.new(1, 0),
}, Utility.FakePosRealMarkerLeftLeg)

Utility.FakePosRealMarkerRightLeg = new("Frame", {
    Name = "RightLeg",
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.fromOffset(17, 19),
    Size = UDim2.fromOffset(3, 8),
    BackgroundColor3 = Theme.AccentBright,
    BorderSizePixel = 0,
    ZIndex = 1002,
}, Utility.FakePosRealMarker)

new("UICorner", {
    CornerRadius = UDim.new(1, 0),
}, Utility.FakePosRealMarkerRightLeg)

-- Only the numeric stud distance is shown below the person icon.
Utility.FakePosDistanceLabel = new("TextLabel", {
    Name = "FakePosDistance",
    AnchorPoint = Vector2.new(0.5, 0),
    Size = UDim2.fromOffset(56, 14),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    Text = "",
    TextColor3 = Theme.Text,
    TextStrokeColor3 = Theme.BorderDark,
    TextStrokeTransparency = 0.18,
    Font = Enum.Font.Code,
    TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Center,
    Visible = false,
    ZIndex = 1000,
}, RootGui)

-- Visual-only ghost proxy. While Fake Pos is active, the real local character
-- can stay hidden only on this client with LocalTransparencyModifier, but the
-- normal Roblox camera remains attached to the ACTUAL character/humanoid.
-- No combat, replication, targeting, weapon, movement, E/H, or Fake Pos timing
-- code is changed by this layer.
Utility.FakePosProxyActive = false
Utility.FakePosProxyOriginalCameraSubject = nil
Utility.FakePosProxyCharacter = nil
Utility.FakePosProxyTransparency = setmetatable({}, { __mode = "k" })
Utility.FakePosProxyLastScan = 0

Utility.RestoreFakePosProxyVisibility = function()
    for part, oldValue in pairs(Utility.FakePosProxyTransparency) do
        if part and part.Parent and part:IsA("BasePart") then
            pcall(function()
                part.LocalTransparencyModifier = tonumber(oldValue) or 0
            end)
        end
    end
    Utility.FakePosProxyTransparency = setmetatable({}, { __mode = "k" })
    Utility.FakePosProxyCharacter = nil
end

Utility.ApplyFakePosProxyVisibility = function(character)
    if not character then
        return
    end

    if Utility.FakePosProxyCharacter ~= character then
        Utility.RestoreFakePosProxyVisibility()
        Utility.FakePosProxyCharacter = character
    end

    for _, descendant in ipairs(character:GetDescendants()) do
        -- Fake Pos hides the real body, NOT the equipped Tool. Hiding Handle/muzzle
        -- geometry made the gun appear to vanish exactly when F was enabled and also
        -- left weapon-origin checks looking at an apparently missing gun.
        if descendant:IsA("BasePart") and not descendant:FindFirstAncestorOfClass("Tool") then
            if Utility.FakePosProxyTransparency[descendant] == nil then
                local okValue, oldValue = pcall(function()
                    return descendant.LocalTransparencyModifier
                end)
                Utility.FakePosProxyTransparency[descendant] = okValue and oldValue or 0
            end
            pcall(function()
                descendant.LocalTransparencyModifier = 1
            end)
        end
    end
end

Utility.SetFakePosProxyActive = function(state)
    state = state == true

    if state then
        if not Utility.FakePosProxyActive then
            Utility.FakePosProxyActive = true
            if Camera then
                pcall(function()
                    Utility.FakePosProxyOriginalCameraSubject = Camera.CameraSubject
                end)
            end
        end

        local character = LocalPlayer.Character
        if character then
            Utility.ApplyFakePosProxyVisibility(character)
        end

        if Camera then
            local subject = character and character:FindFirstChildOfClass("Humanoid")
                or (character and character:FindFirstChild("HumanoidRootPart"))
            if subject then
                pcall(function()
                    Camera.CameraSubject = subject
                end)
            end
        end
        Utility.FakePosProxyLastScan = os.clock()
        return
    end

    Utility.FakePosProxyActive = false
    Utility.RestoreFakePosProxyVisibility()

    if Camera then
        local restoreSubject = Utility.FakePosProxyOriginalCameraSubject
        if not restoreSubject or not restoreSubject.Parent then
            local character = LocalPlayer.Character
            restoreSubject = character and character:FindFirstChildOfClass("Humanoid")
                or (character and character:FindFirstChild("HumanoidRootPart"))
        end
        if restoreSubject then
            pcall(function()
                Camera.CameraSubject = restoreSubject
            end)
        end
    end

    Utility.FakePosProxyOriginalCameraSubject = nil
    Utility.FakePosProxyLastScan = 0
end

Utility.UpdateFakePosProxy = function()
    if not Utility.FakePosEnabled
        or not Utility.FakePosProxyActive
        or not Utility.FakePosGhostRoot
        or not Utility.FakePosGhostRoot.Parent
    then
        return
    end

    local character = LocalPlayer.Character

    -- Keep the camera on the actual character while the frozen ghost remains
    -- only a visual snapshot of the activation position.
    if Camera and character then
        local subject = character:FindFirstChildOfClass("Humanoid")
            or character:FindFirstChild("HumanoidRootPart")
        if subject and Camera.CameraSubject ~= subject then
            pcall(function()
                Camera.CameraSubject = subject
            end)
        end
    end

    -- No periodic visual re-application. Apply proxy visibility only when the
    -- local character object actually changes (for example, a real respawn).
    -- This prevents the 0.12s visual "refresh" effect while Fake Pos is active.
    if character ~= Utility.FakePosProxyCharacter then
        if character then
            Utility.ApplyFakePosProxyVisibility(character)
        end
        Utility.FakePosProxyLastScan = os.clock()
    end
end

-- Safe event-driven join diagnostic. Read-only: it never reapplies
-- PhysicsRepRootPart, restarts Fake Pos, recreates the ghost, moves the character,
-- or changes combat behavior. It only records whether the CURRENT local Fake Pos
-- worker/root still looks healthy when another player joins/rejoins.
Utility.RunFakePosJoinDiagnostic = function(player)
    if Unloaded or not Utility.FakePosEnabled or not player or player == LocalPlayer then
        return
    end

    local generationBefore = Utility.FakePosGeneration
    local characterBefore = LocalPlayer.Character
    local rootBefore = characterBefore and characterBefore:FindFirstChild("HumanoidRootPart")
    local status = "healthy"
    local detail = "root stable"

    if not rootBefore then
        status = "root-missing"
        detail = "local HRP unavailable"
    elseif Utility.FakePosRoot and Utility.FakePosRoot ~= rootBefore then
        status = "root-changed"
        detail = "worker root differs from live HRP"
    elseif not Utility.FakePosRoot then
        status = "root-pending"
        detail = "worker has not bound a root yet"
    end

    if rootBefore and type(gethiddenproperty) == "function" then
        local okRead, value = pcall(gethiddenproperty, rootBefore, "PhysicsRepRootPart")
        if okRead then
            if value ~= nil and value ~= rootBefore then
                status = "property-mismatch"
                detail = "PhysicsRepRootPart points elsewhere"
            elseif value == nil then
                detail = "join occurred during nil cycle window"
            else
                detail = "replication root readable/stable"
            end
        else
            detail = "hidden property unreadable"
        end
    end

    Utility.FakePosJoinUserId = player.UserId
    Utility.FakePosJoinGeneration = generationBefore
    Utility.FakePosJoinRoot = rootBefore
    Utility.FakePosJoinStatus = status
    Utility.FakePosJoinDetail = detail
    Utility.FakePosJoinStatusUntil = os.clock() + 3.0

    -- Re-check once after the normal 0.1s nil window has had time to finish.
    -- Again: read-only; this does not refresh/reapply the desync.
    task.delay(0.18, function()
        if Unloaded or not Utility.FakePosEnabled then
            return
        end

        local finalStatus = "healthy"
        local finalDetail = "join did not disturb local Fake Pos state"
        local characterAfter = LocalPlayer.Character
        local rootAfter = characterAfter and characterAfter:FindFirstChild("HumanoidRootPart")

        if Utility.FakePosGeneration ~= generationBefore then
            finalStatus = "generation-changed"
            finalDetail = "Fake Pos generation changed during join check"
        elseif not rootAfter then
            finalStatus = "root-missing"
            finalDetail = "local HRP unavailable after join"
        elseif rootAfter ~= rootBefore then
            finalStatus = "root-changed"
            finalDetail = "live HRP object changed during join"
        elseif Utility.FakePosRoot and Utility.FakePosRoot ~= rootAfter then
            finalStatus = "worker-root-mismatch"
            finalDetail = "worker root differs from live HRP"
        elseif Utility.FakePosCycleState == "nil-fail"
            or Utility.FakePosCycleState == "restore-fail"
            or Utility.FakePosCycleState == "hold-fail"
        then
            finalStatus = "cycle-fail"
            finalDetail = tostring(Utility.FakePosCycleState)
        elseif type(gethiddenproperty) == "function" then
            local okRead, value = pcall(gethiddenproperty, rootAfter, "PhysicsRepRootPart")
            if okRead and value ~= nil and value ~= rootAfter then
                finalStatus = "property-mismatch"
                finalDetail = "PhysicsRepRootPart points elsewhere"
            elseif not okRead then
                finalDetail = "worker/root stable; hidden property unreadable"
            end
        end

        Utility.FakePosJoinUserId = player.UserId
        Utility.FakePosJoinStatus = finalStatus
        Utility.FakePosJoinDetail = finalDetail
        Utility.FakePosJoinStatusUntil = os.clock() + 3.0
    end)
end

track(Players.PlayerAdded:Connect(function(player)
    Utility.RunFakePosJoinDiagnostic(player)
end))

Utility.DestroyFakePosGhost = function()
    Utility.SetFakePosProxyActive(false)

    if Utility.FakePosTracer then
        Utility.FakePosTracer.Visible = false
    end
    if Utility.FakePosTracerGlow then
        Utility.FakePosTracerGlow.Visible = false
    end
    if Utility.FakePosRealMarker then
        Utility.FakePosRealMarker.Visible = false
    end
    if Utility.FakePosDistanceLabel then
        Utility.FakePosDistanceLabel.Visible = false
        Utility.FakePosDistanceLabel.Text = ""
    end
    if Utility.FakePosDiagLabel then
        Utility.FakePosDiagLabel.Visible = false
        Utility.FakePosDiagLabel.Text = ""
    end
    Utility.FakePosLastHealth = nil
    Utility.FakePosDamageFlashUntil = 0
    Utility.FakePosRootState = "unknown"
    Utility.FakePosCycleState = "idle"
    Utility.FakePosJoinStatus = "idle"
    Utility.FakePosJoinDetail = ""
    Utility.FakePosJoinStatusUntil = 0
    Utility.FakePosJoinUserId = nil
    Utility.FakePosJoinGeneration = 0
    Utility.FakePosJoinRoot = nil

    if Utility.FakePosGhost and Utility.FakePosGhost.Parent then
        Utility.FakePosGhost:Destroy()
    end
    Utility.FakePosGhost = nil
    Utility.FakePosGhostRoot = nil
    Utility.FakePosVisualLiveRoot = nil
    Utility.FakePosVisualCreatedAt = 0
    Utility.FakePosLastDistance = 0
end

Utility.CreateFakePosGhost = function()
    Utility.DestroyFakePosGhost()

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not character or not root or not VisualWorldFolder or not VisualWorldFolder.Parent then
        return false
    end

    local ghost = Instance.new("Model")
    ghost.Name = "alex.ftn_FakePosGhost"
    ghost.Parent = VisualWorldFolder

    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") and not descendant:FindFirstAncestorOfClass("Tool") then
            local okClone, ghostPart = pcall(function()
                return descendant:Clone()
            end)

            if okClone and ghostPart then
                -- Keep only visible geometry from each cloned part. No scripts,
                -- joints, effects, sounds or interaction objects run on the ghost.
                for _, child in ipairs(ghostPart:GetDescendants()) do
                    if child:IsA("SpecialMesh") then
                        child.TextureId = ""
                    elseif child:IsA("Decal") or child:IsA("Texture") then
                        child:Destroy()
                    elseif child:IsA("SurfaceAppearance")
                        or child:IsA("ParticleEmitter")
                        or child:IsA("Trail")
                        or child:IsA("Beam")
                        or child:IsA("Sound")
                        or child:IsA("Script")
                        or child:IsA("LocalScript")
                        or child:IsA("ModuleScript")
                        or child:IsA("JointInstance")
                        or child:IsA("WeldConstraint")
                        or child:IsA("ProximityPrompt")
                        or child:IsA("ClickDetector")
                    then
                        child:Destroy()
                    end
                end

                ghostPart.Anchored = true
                ghostPart.CanCollide = false
                ghostPart.CanTouch = false
                ghostPart.CanQuery = false
                ghostPart.CastShadow = false
                ghostPart.Massless = true
                ghostPart.CFrame = descendant.CFrame
                ghostPart.Material = Enum.Material.Neon
                ghostPart.Color = Theme.Accent
                ghostPart.Transparency = descendant.Name == "HumanoidRootPart" and 1 or 0.62
                if ghostPart:IsA("MeshPart") then
                    ghostPart.TextureID = ""
                end
                ghostPart.Parent = ghost

                if descendant == root then
                    Utility.FakePosGhostRoot = ghostPart
                end
            end
        end
    end

    local highlight = Instance.new("Highlight")
    highlight.Name = "Cham"
    highlight.Adornee = ghost
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.FillColor = Theme.Accent
    highlight.FillTransparency = 0.76
    highlight.OutlineColor = Theme.AccentBright
    highlight.OutlineTransparency = 0.08
    highlight.Parent = ghost

    Utility.FakePosGhost = ghost
    Utility.FakePosVisualLiveRoot = root
    Utility.FakePosVisualCreatedAt = os.clock()
    if not Utility.FakePosGhostRoot then
        ghost:Destroy()
        Utility.FakePosGhost = nil
        Utility.FakePosVisualLiveRoot = nil
        return false
    end

    Utility.SetFakePosProxyActive(true)
    return true
end

Utility.UpdateFakePosGhostTracer = function()
    local tracer = Utility.FakePosTracer
    local glow = Utility.FakePosTracerGlow
    local marker = Utility.FakePosRealMarker
    local label = Utility.FakePosDistanceLabel
    if not tracer or not glow or not marker or not label then
        return
    end

    local ghostRoot = Utility.FakePosGhostRoot
    local character = LocalPlayer.Character
    local liveRoot = character and character:FindFirstChild("HumanoidRootPart")
    if not Utility.FakePosEnabled
        or not ghostRoot
        or not ghostRoot.Parent
        or not liveRoot
        or not liveRoot.Parent
        or not Camera
    then
        tracer.Visible = false
        glow.Visible = false
        marker.Visible = false
        label.Visible = false
        if Utility.FakePosDiagLabel then
            Utility.FakePosDiagLabel.Visible = false
        end
        return
    end

    -- Respawns simply rebind the visual endpoint to the new live HRP. The ghost
    -- remains the original frozen snapshot and no second ghost/tracer is created.
    Utility.FakePosVisualLiveRoot = liveRoot

    local distance = (liveRoot.Position - ghostRoot.Position).Magnitude
    Utility.FakePosLastDistance = distance

    local now = os.clock()
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local health = humanoid and tonumber(humanoid.Health) or nil
    if health ~= nil then
        if Utility.FakePosLastHealth ~= nil and health < (Utility.FakePosLastHealth - 0.001) then
            Utility.FakePosDamageFlashUntil = now + 0.34
        end
        Utility.FakePosLastHealth = health
    end

    -- Low-cost replication diagnostic. Read-only: this does not reapply, refresh,
    -- or alter the Fake Pos state.
    if now - (Utility.FakePosDiagLastUpdate or 0) >= 0.10 then
        Utility.FakePosDiagLastUpdate = now
        Utility.FakePosRootState = "unreadable"
        if type(gethiddenproperty) == "function" then
            local okRead, value = pcall(gethiddenproperty, liveRoot, "PhysicsRepRootPart")
            if okRead then
                if value == nil then
                    Utility.FakePosRootState = "nil"
                elseif value == liveRoot then
                    Utility.FakePosRootState = "hrp"
                else
                    Utility.FakePosRootState = "other"
                end
            end
        end
        if Utility.FakePosDiagLabel then
            local joinSuffix = ""
            if now <= (Utility.FakePosJoinStatusUntil or 0) then
                joinSuffix = " | join:" .. tostring(Utility.FakePosJoinStatus or "unknown")
            end
            Utility.FakePosDiagLabel.Text = string.format(
                "root:%s | cycle:%s | dist:%d%s",
                tostring(Utility.FakePosRootState),
                tostring(Utility.FakePosCycleState),
                math.floor(distance + 0.5),
                joinSuffix
            )
            Utility.FakePosDiagLabel.TextColor3 =
                (Utility.FakePosCycleState == "ok" or Utility.FakePosCycleState == "nil-ok")
                and Theme.Accent or Theme.Muted
            Utility.FakePosDiagLabel.Visible = true
        end
    end

    local ghostPoint, ghostOnScreen = Camera:WorldToViewportPoint(ghostRoot.Position)
    local livePoint, liveOnScreen = Camera:WorldToViewportPoint(liveRoot.Position)

    -- The real-HRP marker and numeric distance stay independent from the line.
    -- They render only while the real HRP is inside the POV. The tracer itself
    -- remains visible off-screen by pinning endpoints to the viewport edge.
    if liveOnScreen and livePoint.Z > 0 then
        local damaged = now < (Utility.FakePosDamageFlashUntil or 0)
        local markerColor = damaged and Theme.RedBright or Theme.AccentBright
        marker.Position = UDim2.fromOffset(livePoint.X, livePoint.Y)
        marker.Visible = true

        Utility.FakePosRealMarkerHead.BackgroundColor3 = markerColor
        Utility.FakePosRealMarkerCore.BackgroundColor3 = markerColor
        Utility.FakePosRealMarkerArms.BackgroundColor3 = markerColor
        Utility.FakePosRealMarkerLeftArm.BackgroundColor3 = markerColor
        Utility.FakePosRealMarkerRightArm.BackgroundColor3 = markerColor
        Utility.FakePosRealMarkerLeftLeg.BackgroundColor3 = markerColor
        Utility.FakePosRealMarkerRightLeg.BackgroundColor3 = markerColor

        label.Position = UDim2.fromOffset(livePoint.X, livePoint.Y + 20)
        label.Text = tostring(math.floor(distance + 0.5))
        label.TextColor3 = damaged and Theme.RedBright or Theme.Text
        label.Visible = true
    else
        marker.Visible = false
        label.Visible = false
    end

    local fromPoint = Utility.ProjectWorldToScreenEdge(ghostRoot.Position, 12)
    local toPoint = Utility.ProjectWorldToScreenEdge(liveRoot.Position, 12)
    if not fromPoint or not toPoint then
        tracer.Visible = false
        glow.Visible = false
        return
    end

    local pulse = (math.sin(os.clock() * 5.2) + 1) * 0.5
    glow.BackgroundTransparency = 0.78 - (pulse * 0.18)
    tracer.BackgroundTransparency = 0.10 - (pulse * 0.055)
    setScreenLine(glow, fromPoint, toPoint, 3)
    setScreenLine(tracer, fromPoint, toPoint, 1)
end

local function updateCursorTracer()
    local target = Aim.CurrentTarget
    local part = target and getTargetPart(target)
    if not Aim.Toggled or not target or not part or isKnockedOut(target) then
        CursorTracer.Visible = false
        CursorTracerGlow.Visible = false
        return
    end

    local toPoint = Utility.ProjectWorldToScreenEdge(part.Position, 12)
    if not toPoint then
        CursorTracer.Visible = false
        CursorTracerGlow.Visible = false
        return
    end

    local mouse = UserInputService:GetMouseLocation()
    local fromPoint = Vector2.new(mouse.X, mouse.Y)
    setScreenLine(CursorTracerGlow, fromPoint, toPoint, 3)
    setScreenLine(CursorTracer, fromPoint, toPoint, 1)
end

local function getWeaponMuzzle(tool)
    -- Never keep reading muzzle/Handle data from a Tool that has already been
    -- reparented/destroyed. This is the stale-reference case that can appear
    -- after the game rejects an origin and moves a gun/knife out of Character.
    if not tool or not tool.Parent then
        return nil, nil
    end

    local preferredAttachment = nil
    for _, descendant in ipairs(tool:GetDescendants()) do
        if descendant:IsA("Attachment") then
            local name = string.lower(descendant.Name)
            if name == "muzzle" or name == "muzzleattachment" or name == "barrelattachment" then
                preferredAttachment = descendant
                break
            end
        end
    end
    if preferredAttachment and preferredAttachment.Parent and preferredAttachment.Parent:IsA("BasePart") then
        return preferredAttachment.Parent, preferredAttachment.WorldPosition
    end

    local handle = tool:FindFirstChild("Handle")
    if handle and handle:IsA("BasePart") then
        return handle, handle.Position
    end

    for _, descendant in ipairs(tool:GetDescendants()) do
        if descendant:IsA("BasePart") then
            local name = string.lower(descendant.Name)
            if string.find(name, "barrel", 1, true) or string.find(name, "muzzle", 1, true) then
                return descendant, descendant.Position
            end
        end
    end
    return nil, nil
end

local function getCursorWorldPoint(maxDistance)
    maxDistance = maxDistance or 1200
    local mouse = UserInputService:GetMouseLocation()
    local ray = Camera:ViewportPointToRay(mouse.X, mouse.Y)

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = { LocalPlayer.Character, VisualWorldFolder }
    if AllIn1.AppendGrassIgnores then
        AllIn1.AppendGrassIgnores(ignore)
    end
    if AllIn1.AppendMapIgnores then
        AllIn1.AppendMapIgnores(ignore)
    end
    params.FilterDescendantsInstances = ignore

    local result = Workspace:Raycast(ray.Origin, ray.Direction * maxDistance, params)
    if result then
        return result.Position
    end
    return ray.Origin + ray.Direction * maxDistance
end

local ActiveShotTracers = {}
local LastShotTracerAt = 0

local function registerShotTracer(container)
    table.insert(ActiveShotTracers, container)
    while #ActiveShotTracers > 24 do
        local oldest = table.remove(ActiveShotTracers, 1)
        if oldest and oldest.Parent then
            oldest:Destroy()
        end
    end
end

local function spawnShotTracer(explicitTool)
    -- Video-style neon tracer. It fires whether lock is ON or OFF.
    if Unloaded then
        return
    end

    local now = os.clock()
    if now - LastShotTracerAt < 0.024 then
        return
    end
    LastShotTracerAt = now

    local character = LocalPlayer.Character
    local tool = explicitTool or (character and character:FindFirstChildOfClass("Tool"))
    if not tool or not character or tool.Parent ~= character then
        return
    end

    local _, sourceWorld = getWeaponMuzzle(tool)
    if not sourceWorld then
        return
    end

    local targetWorld
    local targetPart = Aim.Toggled and Aim.CurrentTarget and getTargetPart(Aim.CurrentTarget) or nil
    if targetPart and not isKnockedOut(Aim.CurrentTarget) then
        targetWorld = getPredictedPosition(targetPart) or targetPart.Position
    else
        targetWorld = getCursorWorldPoint(5000)
    end
    if not targetWorld then
        return
    end

    local tracer = Instance.new("Folder")
    tracer.Name = "alex.ftn_NeonShot"
    tracer.Parent = VisualWorldFolder
    registerShotTracer(tracer)

    -- Both endpoints are world-anchored, so each streak lingers like the video
    -- instead of swinging around with the gun after the shot.
    local startPart = Instance.new("Part")
    startPart.Name = "Start"
    startPart.Anchored = true
    startPart.CanCollide = false
    startPart.CanTouch = false
    startPart.CanQuery = false
    startPart.CastShadow = false
    startPart.Transparency = 1
    startPart.Size = Vector3.new(0.02, 0.02, 0.02)
    startPart.CFrame = CFrame.new(sourceWorld)
    startPart.Parent = tracer

    local endPart = startPart:Clone()
    endPart.Name = "End"
    endPart.CFrame = CFrame.new(sourceWorld)
    endPart.Parent = tracer

    local a0 = Instance.new("Attachment")
    a0.Name = "A0"
    a0.Parent = startPart
    local a1 = Instance.new("Attachment")
    a1.Name = "A1"
    a1.Parent = endPart

    local glow = Instance.new("Beam")
    glow.Name = "Glow"
    glow.Attachment0 = a0
    glow.Attachment1 = a1
    glow.FaceCamera = true
    glow.Width0 = 0.19
    glow.Width1 = 0.105
    glow.LightEmission = 1
    glow.LightInfluence = 0
    glow.Brightness = 7
    glow.Color = ColorSequence.new(Theme.Accent)
    glow.Transparency = NumberSequence.new(0.67)
    glow.Parent = tracer

    local core = Instance.new("Beam")
    core.Name = "Core"
    core.Attachment0 = a0
    core.Attachment1 = a1
    core.FaceCamera = true
    core.Width0 = 0.062
    core.Width1 = 0.034
    core.LightEmission = 1
    core.LightInfluence = 0
    core.Brightness = 12
    core.Color = ColorSequence.new(Theme.AccentBright)
    core.Transparency = NumberSequence.new(0.015)
    core.Parent = tracer

    -- Grow the streak quickly out of the muzzle, then leave it hanging and
    -- smoothly fade/shrink instead of popping in/out.
    local distance = (targetWorld - sourceWorld).Magnitude
    local growTime = math.clamp(distance / 8500, 0.035, 0.095)
    local growTween = TweenService:Create(
        endPart,
        TweenInfo.new(growTime, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
        { CFrame = CFrame.new(targetWorld) }
    )
    growTween:Play()

    task.delay(growTime + 0.12, function()
        if Unloaded or not tracer.Parent then
            return
        end

        local fade = Instance.new("NumberValue")
        fade.Name = "Fade"
        fade.Value = 0
        fade.Parent = tracer

        local fadeConnection
        fadeConnection = fade:GetPropertyChangedSignal("Value"):Connect(function()
            if not tracer.Parent then
                if fadeConnection then fadeConnection:Disconnect() end
                return
            end
            local alpha = math.clamp(fade.Value, 0, 1)
            core.Transparency = NumberSequence.new(0.015 + (0.985 * alpha))
            glow.Transparency = NumberSequence.new(0.67 + (0.33 * alpha))
            core.Width0 = 0.062 * (1 - 0.48 * alpha)
            core.Width1 = 0.034 * (1 - 0.55 * alpha)
            glow.Width0 = 0.19 * (1 - 0.38 * alpha)
            glow.Width1 = 0.105 * (1 - 0.45 * alpha)
        end)

        local fadeTween = TweenService:Create(
            fade,
            TweenInfo.new(0.48, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
            { Value = 1 }
        )
        fadeTween:Play()
        fadeTween.Completed:Connect(function()
            if fadeConnection then
                fadeConnection:Disconnect()
            end
            if tracer.Parent then
                tracer:Destroy()
            end
        end)
    end)

    Debris:AddItem(tracer, 0.9)
end

-- Hook actual Tool activation so tracer creation follows shots instead of
-- every arbitrary screen click. MouseButton1 remains a debounced fallback.
local TracedTools = setmetatable({}, { __mode = "k" })
local function hookTracerTool(tool)
    if not tool or not tool:IsA("Tool") or TracedTools[tool] then
        return
    end
    TracedTools[tool] = true
    track(tool.Activated:Connect(function()
        -- InputBegan gives manual fire a pre-shot origin lease. Activated extends the
        -- same lease through the weapon/server commit frames without changing the shot.
        if Utility.FakePosEnabled and type(Utility.BeginFakePosOriginHold) == "function" then
            Utility.BeginFakePosOriginHold(
                Utility.FakePosOriginShotHoldDuration,
                "tool-activated"
            )
        end
        spawnShotTracer(tool)
        HitSound.Play("shot")
    end))
end

local function hookTracerCharacter(character)
    if not character then return end
    for _, child in ipairs(character:GetChildren()) do
        hookTracerTool(child)
    end
    track(character.ChildAdded:Connect(hookTracerTool))
end

hookTracerCharacter(LocalPlayer.Character)
track(LocalPlayer.CharacterAdded:Connect(hookTracerCharacter))

-- Immediate manual-fire fallback from the user-provided hitsound system.
-- Tool.Activated remains the primary trigger; the short dedupe window prevents
-- the same physical shot from playing twice when both events arrive together.
track(UserInputService.InputBegan:Connect(function(input, processed)
    if processed or Unloaded or not HitSound.Enabled then
        return
    end
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        local character = LocalPlayer.Character
        if character and character:FindFirstChildOfClass("Tool") then
            HitSound.Play("shot")
        end
    end
end))

-- ============================================================
-- Blacklist player list
-- ============================================================

local function clearPlayerRows()
    for _, child in ipairs(PlayerList:GetChildren()) do
        if child:IsA("Frame") and child.Name == "PlayerRow" then
            child:Destroy()
        end
    end
end

local function refreshPlayerList()
    if Unloaded then
        return
    end

    clearPlayerRows()
    local query = string.lower(SearchBox.Text or "")

    local rowOrder = 0
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            rowOrder = rowOrder + 1
            local searchable = string.lower((player.DisplayName or "") .. " " .. player.Name .. " " .. tostring(player.UserId))
            if query == "" or string.find(searchable, query, 1, true) then
                local rowPlayer = player
                local blacklisted = BlacklistedUserIds[rowPlayer.UserId] == true

                local row = new("Frame", {
                    Name = "PlayerRow",
                    Size = UDim2.new(1, -2, 0, 29),
                    BackgroundColor3 = blacklisted and Color3.fromRGB(34, 8, 8) or Color3.fromRGB(22, 22, 22),
                    BorderSizePixel = 0,
                    LayoutOrder = rowOrder,
                }, PlayerList)

                local rowStroke = new("UIStroke", {
                    Color = blacklisted and Color3.fromRGB(145, 28, 28) or Theme.Border,
                    Thickness = 1,
                }, row)

                local selectedForMulti = MultiTarget.SelectedUserIds[rowPlayer.UserId] == true

                new("TextLabel", {
                    Position = UDim2.fromOffset(7, 0),
                    Size = UDim2.new(1, -72, 1, 0),
                    BackgroundTransparency = 1,
                    Text = rowPlayer.DisplayName,
                    TextColor3 = blacklisted and Color3.fromRGB(255, 180, 180) or Theme.Text,
                    Font = Enum.Font.Code,
                    TextSize = 10,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                }, row)

                local multiPick = new("TextButton", {
                    AnchorPoint = Vector2.new(1, 0.5),
                    Position = UDim2.new(1, -38, 0.5, 0),
                    Size = UDim2.fromOffset(26, 24),
                    BackgroundTransparency = 1,
                    Text = selectedForMulti and "M+" or "M",
                    TextColor3 = selectedForMulti and Theme.AccentBright or Theme.Muted,
                    Font = Enum.Font.Code,
                    TextSize = 10,
                    AutoButtonColor = false,
                    Active = true,
                    Selectable = true,
                    ZIndex = 4,
                }, row)

                local heart = new("TextButton", {
                    AnchorPoint = Vector2.new(1, 0.5),
                    Position = UDim2.new(1, -3, 0.5, 0),
                    Size = UDim2.fromOffset(34, 26),
                    BackgroundTransparency = 1,
                    Text = blacklisted and "♥" or "♡",
                    TextColor3 = blacklisted and Theme.RedBright or Theme.Muted,
                    Font = Enum.Font.Code,
                    TextSize = 15,
                    AutoButtonColor = false,
                    Active = true,
                    Selectable = true,
                    ZIndex = 5,
                }, row)

                track(multiPick.Activated:Connect(function()
                    if Unloaded or not rowPlayer or not rowPlayer.Parent then
                        return
                    end

                    local nextSelected = not (MultiTarget.SelectedUserIds[rowPlayer.UserId] == true)
                    MultiTarget.SelectedUserIds[rowPlayer.UserId] = nextSelected or nil
                    MultiTarget.QueueDirty = true
                    notify(
                        nextSelected and "MULTITARGET SELECTED" or "MULTITARGET REMOVED",
                        rowPlayer.DisplayName,
                        "lock",
                        2.2
                    )
                    refreshPlayerList()
                end))

                track(heart.Activated:Connect(function()
                    if Unloaded or not rowPlayer or not rowPlayer.Parent then
                        return
                    end

                    local nextValue = not (BlacklistedUserIds[rowPlayer.UserId] == true)
                    BlacklistedUserIds[rowPlayer.UserId] = nextValue or nil
                    refreshBlacklistPresence()

                    -- H's pool changes immediately when the blacklist changes.
                    -- Mark the queue dirty so the next queue pass is rebuilt from
                    -- the new blacklist-priority pool instead of using stale UIDs.
                    MultiTarget.QueueDirty = true

                    -- If blacklist-only mode just became active while we were
                    -- locked to somebody outside the list, release that invalid
                    -- lock. Blacklisting the currently locked player keeps it.
                    if Aim.CurrentTarget
                        and hasPresentBlacklistedTargets()
                        and not isBlacklisted(Aim.CurrentTarget) then
                        Aim.Toggled = false
                        Aim.Active = false
                        clearTarget()
                    end

                    notify(
                        nextValue and "BLACKLISTED" or "BLACKLIST REMOVED",
                        rowPlayer.DisplayName .. "  •  UID " .. tostring(rowPlayer.UserId),
                        "blacklist",
                        3
                    )
                    refreshPlayerList()
                end))
            end
        end
    end
end

track(SearchBox:GetPropertyChangedSignal("Text"):Connect(refreshPlayerList))
track(Players.PlayerAdded:Connect(function()
    refreshBlacklistPresence()
    task.defer(refreshPlayerList)
end))
track(Players.PlayerRemoving:Connect(function(player)
    if Aim.CurrentTarget == player then
        clearTarget()
    end
    MultiTarget.QueueSet[player.UserId] = nil
    MultiTarget.ForceFieldSince[player.UserId] = nil
    if MultiTarget.ForceFieldWaitingUserId == player.UserId then
        MultiTarget.ForceFieldWaitingUserId = nil
    end
    if MultiTarget.CurrentUserId == player.UserId then
        MultiTarget.QueueDirty = true
    end
    refreshBlacklistPresence()
    task.defer(refreshPlayerList)
end))

refreshBlacklistPresence()
refreshPlayerList()

-- ============================================================
-- ESP through walls - performance optimized
-- ============================================================

local ESPLayer = new("Frame", {
    Name = "ESPLayer",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Visible = false,
}, RootGui)

local function destroyESPEntry(userId)
    local entry = ESPEntries[userId]
    if entry then
        if entry.HealthConnection then
            safeDisconnect(entry.HealthConnection)
            entry.HealthConnection = nil
        end
        if entry.MaxHealthConnection then
            safeDisconnect(entry.MaxHealthConnection)
            entry.MaxHealthConnection = nil
        end
        if entry.Root and entry.Root.Parent then
            entry.Root:Destroy()
        end
        if entry.Highlight and entry.Highlight.Parent then
            entry.Highlight:Destroy()
        end
        if entry.Billboard and entry.Billboard.Parent then
            entry.Billboard:Destroy()
        end
        ESPEntries[userId] = nil
    end
end

local function makeESPEntry(player)
    destroyESPEntry(player.UserId)

    local root = new("Frame", {
        Name = "ESP_" .. tostring(player.UserId),
        BackgroundTransparency = 1,
        Visible = false,
        Size = UDim2.fromOffset(1, 1),
    }, ESPLayer)

    local highlight = Instance.new("Highlight")
    highlight.Name = "alex.ftn_ESP_" .. tostring(player.UserId)
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.FillColor = Theme.ESP
    highlight.FillTransparency = 1
    highlight.OutlineColor = Theme.ESP
    highlight.OutlineTransparency = 0
    highlight.Enabled = false
    highlight.Parent = VisualWorldFolder

    local billboard = new("BillboardGui", {
        Name = "Info",
        Size = UDim2.fromOffset(150, 38),
        StudsOffset = Vector3.new(0, 3.35, 0),
        AlwaysOnTop = true,
        ResetOnSpawn = false,
        Enabled = false,
    }, PlayerGui)

    local nameLabel = new("TextLabel", {
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.new(1, 0, 0, 14),
        BackgroundTransparency = 1,
        Text = player.DisplayName,
        TextColor3 = Theme.ESP,
        Font = Enum.Font.Code,
        TextSize = 10,
        TextStrokeTransparency = 0.05,
        TextStrokeColor3 = Color3.new(0, 0, 0),
        TextXAlignment = Enum.TextXAlignment.Center,
    }, billboard)

    local infoLabel = new("TextLabel", {
        Position = UDim2.fromOffset(0, 14),
        Size = UDim2.new(1, 0, 0, 13),
        BackgroundTransparency = 1,
        Text = "",
        TextColor3 = Theme.ESP,
        Font = Enum.Font.Code,
        TextSize = 9,
        TextStrokeTransparency = 0.05,
        TextStrokeColor3 = Color3.new(0, 0, 0),
        TextXAlignment = Enum.TextXAlignment.Center,
    }, billboard)

    local healthBg = new("Frame", {
        Position = UDim2.new(0.5, -47, 1, -5),
        Size = UDim2.fromOffset(94, 3),
        BackgroundColor3 = Color3.fromRGB(25, 25, 25),
        BorderSizePixel = 0,
        Visible = false,
    }, billboard)

    local healthFill = new("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Theme.ESP,
        BorderSizePixel = 0,
    }, healthBg)

    local offscreen = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(8, 8),
        BackgroundColor3 = Theme.ESP,
        BorderSizePixel = 0,
        Rotation = 45,
        Visible = false,
    }, root)
    new("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 1 }, offscreen)

    local offscreenText = new("TextLabel", {
        AnchorPoint = Vector2.new(0.5, 0),
        Size = UDim2.fromOffset(110, 28),
        BackgroundTransparency = 1,
        Text = "",
        TextColor3 = Theme.ESP,
        Font = Enum.Font.Code,
        TextSize = 9,
        TextStrokeTransparency = 0.05,
        TextStrokeColor3 = Color3.new(0, 0, 0),
        TextXAlignment = Enum.TextXAlignment.Center,
        Visible = false,
    }, root)

    ESPEntries[player.UserId] = {
        Player = player,
        Root = root,
        Highlight = highlight,
        Billboard = billboard,
        Name = nameLabel,
        Info = infoLabel,
        HealthBg = healthBg,
        HealthFill = healthFill,
        Offscreen = offscreen,
        OffscreenText = offscreenText,
        Character = nil,
        Humanoid = nil,
        RootPart = nil,
        Head = nil,
        LastColor = nil,
        LastInfo = nil,
        LastRatio = -1,
        Hidden = true,
        BoundHumanoid = nil,
        HealthConnection = nil,
        MaxHealthConnection = nil,
    }
end

local function espEntryIsHealthy(entry)
    return entry
        and entry.Root and entry.Root.Parent == ESPLayer
        and entry.Highlight and entry.Highlight.Parent ~= nil
        and entry.Billboard and entry.Billboard.Parent == PlayerGui
        and entry.Name and entry.Name.Parent == entry.Billboard
        and entry.Info and entry.Info.Parent == entry.Billboard
        and entry.HealthBg and entry.HealthBg.Parent == entry.Billboard
        and entry.HealthFill and entry.HealthFill.Parent == entry.HealthBg
end

local function ensureESPEntries()
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local entry = ESPEntries[player.UserId]
            if not espEntryIsHealthy(entry) then
                makeESPEntry(player)
            end
        end
    end
end

track(Players.PlayerAdded:Connect(function(player)
    if player ~= LocalPlayer then
        makeESPEntry(player)
    end
end))

track(Players.PlayerRemoving:Connect(function(player)
    destroyESPEntry(player.UserId)
    TargetHUDArmorMax[player.UserId] = nil
end))

ensureESPEntries()

local function hideESPEntry(entry)
    if entry.Hidden then
        return
    end
    entry.Hidden = true
    entry.Root.Visible = false
    entry.Highlight.Enabled = false
    entry.Highlight.Adornee = nil
    entry.Billboard.Enabled = false
    entry.Billboard.Adornee = nil
    entry.Offscreen.Visible = false
    entry.OffscreenText.Visible = false
end

local function refreshESPCharacter(entry, character)
    if entry.Character ~= character then
        entry.Character = character
        entry.Humanoid = nil
        entry.RootPart = nil
        entry.Head = nil

        if entry.HealthConnection then
            safeDisconnect(entry.HealthConnection)
            entry.HealthConnection = nil
        end
        if entry.MaxHealthConnection then
            safeDisconnect(entry.MaxHealthConnection)
            entry.MaxHealthConnection = nil
        end
        entry.BoundHumanoid = nil
    end

    if not character then
        return nil, nil, nil
    end

    if not entry.Humanoid or entry.Humanoid.Parent ~= character then
        entry.Humanoid = character:FindFirstChildOfClass("Humanoid")
    end
    if not entry.RootPart or entry.RootPart.Parent ~= character then
        entry.RootPart = character:FindFirstChild(Config.Aimbot.TargetPart)
    end
    if not entry.Head or entry.Head.Parent ~= character then
        entry.Head = character:FindFirstChild("Head")
    end

    -- Health changes are event-driven so HP bars/text refresh on the next
    -- render frame without raising the normal all-player ESP update rate.
    if entry.Humanoid and entry.BoundHumanoid ~= entry.Humanoid then
        if entry.HealthConnection then
            safeDisconnect(entry.HealthConnection)
        end
        if entry.MaxHealthConnection then
            safeDisconnect(entry.MaxHealthConnection)
        end

        entry.BoundHumanoid = entry.Humanoid
        entry.HealthConnection = entry.Humanoid.HealthChanged:Connect(function()
            Config.ESP.HealthDirty = true
            if Aim.CurrentTarget == entry.Player then
                Config.ESP.HUDHealthDirty = true
            end
        end)
        entry.MaxHealthConnection = entry.Humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
            Config.ESP.HealthDirty = true
            if Aim.CurrentTarget == entry.Player then
                Config.ESP.HUDHealthDirty = true
            end
        end)
    end

    return entry.Humanoid, entry.RootPart, entry.Head
end

local function getESPBlacklistOnlyMode()
    -- Compute this from the ESP entries that actually exist right now instead
    -- of the lock system's cached blacklist-presence flag. This avoids stale
    -- ESP filtering when a blacklisted player leaves/rejoins during PlayerRemoving.
    for _, entry in pairs(ESPEntries) do
        local player = entry.Player
        if player and player ~= LocalPlayer and player.Parent ~= nil and isBlacklisted(player) then
            return true
        end
    end
    return false
end

local function getOffscreenPosition(point)
    if not Camera then
        return Vector2.new(0, 0), 0
    end
    local viewport = Camera.ViewportSize
    local center = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
    local projected = Vector2.new(point.X, point.Y)

    if point.Z < 0 then
        projected = center - (projected - center)
    end

    local direction = projected - center
    if direction.Magnitude < 0.001 then
        direction = Vector2.new(0, -1)
    end

    local margin = 34
    local halfW = math.max(1, viewport.X * 0.5 - margin)
    local halfH = math.max(1, viewport.Y * 0.5 - margin)
    local dx = direction.X
    local dy = direction.Y
    local tx = math.abs(dx) > 0.001 and (halfW / math.abs(dx)) or math.huge
    local ty = math.abs(dy) > 0.001 and (halfH / math.abs(dy)) or math.huge
    local t = math.min(tx, ty)
    local pos = center + direction * t

    return pos, math.deg(math.atan2(direction.Y, direction.X)) + 45
end

local ESPNextSanityCheck = 0
local function updateESP()
    ESPLayer.Visible = Config.ESP.Enabled
    if not Config.ESP.Enabled then
        for _, entry in pairs(ESPEntries) do
            hideESPEntry(entry)
        end
        return
    end
    if not Camera then
        for _, entry in pairs(ESPEntries) do
            hideESPEntry(entry)
        end
        return
    end

    -- Rare recovery pass for a missed/late PlayerAdded event. This fixes the
    -- occasional player that never received an ESP entry without scanning the
    -- entire player list every render frame.
    local now = os.clock()
    if now >= ESPNextSanityCheck then
        ESPNextSanityCheck = now + 1
        ensureESPEntries()
    end

    local localRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local blacklistOnly = getESPBlacklistOnlyMode()

    for _, entry in pairs(ESPEntries) do
        local player = entry.Player
        local blacklisted = isBlacklisted(player)
        local shouldShow = player
            and player.Parent ~= nil
            and player ~= LocalPlayer
            and ((not blacklistOnly) or blacklisted)

        if not shouldShow then
            hideESPEntry(entry)
        else
            local character = player.Character
            local humanoid, rootPart, head = refreshESPCharacter(entry, character)

            if humanoid and rootPart and character and humanoid.Health > 0 then
                entry.Hidden = false
                local espColor = blacklisted and BLACKLIST_ESP_COLOR or Theme.ESP

                local distance
                if localRoot then
                    distance = (rootPart.Position - localRoot.Position).Magnitude
                else
                    distance = (rootPart.Position - Camera.CFrame.Position).Magnitude
                end

                local hp, maxHp, armor = getPlayerVitals(player)
                local ratio = math.clamp(hp / math.max(1, maxHp), 0, 1)
                local ko = isKnockedOut(player)
                local screenPoint, onScreen = Camera:WorldToViewportPoint(rootPart.Position)
                local visibleOnScreen = onScreen and screenPoint.Z > 0

                -- Highlights are GPU-expensive. When a player is offscreen there
                -- is nothing to draw, so disable that Highlight until they return.
                local wantHighlight = Config.ESP.HighlightTarget and visibleOnScreen
                if entry.Highlight.Enabled ~= wantHighlight then
                    entry.Highlight.Enabled = wantHighlight
                end
                if wantHighlight and entry.Highlight.Adornee ~= character then
                    entry.Highlight.Adornee = character
                elseif not wantHighlight and entry.Highlight.Adornee ~= nil then
                    entry.Highlight.Adornee = nil
                end

                if entry.LastColor ~= espColor then
                    entry.LastColor = espColor
                    entry.Highlight.FillColor = espColor
                    entry.Highlight.OutlineColor = espColor
                    entry.Name.TextColor3 = espColor
                    entry.Info.TextColor3 = espColor
                    entry.HealthFill.BackgroundColor3 = espColor
                    entry.Offscreen.BackgroundColor3 = espColor
                    entry.OffscreenText.TextColor3 = espColor
                end

                if visibleOnScreen then
                    local adornee = head or rootPart
                    if entry.Billboard.Adornee ~= adornee then
                        entry.Billboard.Adornee = adornee
                    end
                    if not entry.Billboard.Enabled then
                        entry.Billboard.Enabled = true
                    end
                    local multiMarked = MultiTarget.QueueSet[player.UserId] == true
                        or MultiTarget.SelectedUserIds[player.UserId] == true
                    local displayNameText = multiMarked and ("M • " .. player.DisplayName) or player.DisplayName
                    if entry.Name.Text ~= displayNameText then
                        entry.Name.Text = displayNameText
                    end
                    entry.Name.Visible = Config.ESP.ShowName

                    local pieces = {}
                    if Config.ESP.ShowHealth then
                        table.insert(pieces, string.format("%d HP", math.floor(hp + 0.5)))
                        if armor > 0 then
                            table.insert(pieces, string.format("%d ARM", math.floor(armor + 0.5)))
                        end
                    end
                    if Config.ESP.ShowDistance then
                        table.insert(pieces, string.format("%d studs", math.floor(distance + 0.5)))
                    end
                    if ko then
                        table.insert(pieces, "KO")
                    end
                    local infoText = table.concat(pieces, "  |  ")
                    entry.Info.Visible = infoText ~= ""
                    if entry.LastInfo ~= infoText then
                        entry.LastInfo = infoText
                        entry.Info.Text = infoText
                    end

                    entry.HealthBg.Visible = Config.ESP.ShowHealthBar
                    if math.abs(entry.LastRatio - ratio) >= 0.002 then
                        entry.LastRatio = ratio
                        entry.HealthFill.Size = UDim2.new(ratio, 0, 1, 0)
                    end

                    entry.Root.Visible = false
                    entry.Offscreen.Visible = false
                    entry.OffscreenText.Visible = false
                else
                    if entry.Billboard.Enabled then
                        entry.Billboard.Enabled = false
                    end
                    if entry.Billboard.Adornee ~= nil then
                        entry.Billboard.Adornee = nil
                    end

                    if Config.ESP.ShowOffscreen then
                        local pos, rotation = getOffscreenPosition(screenPoint)
                        entry.Root.Visible = true
                        entry.Offscreen.Visible = true
                        entry.Offscreen.Position = UDim2.fromOffset(math.floor(pos.X), math.floor(pos.Y))
                        entry.Offscreen.Rotation = rotation

                        local offPrefix = (MultiTarget.QueueSet[player.UserId] == true
                            or MultiTarget.SelectedUserIds[player.UserId] == true) and "M • " or ""
                        local offText = string.format("%s%s  %d studs", offPrefix, player.DisplayName, math.floor(distance + 0.5))
                        entry.OffscreenText.Visible = true
                        entry.OffscreenText.Position = UDim2.fromOffset(math.floor(pos.X), math.floor(pos.Y + 9))
                        if entry.OffscreenText.Text ~= offText then
                            entry.OffscreenText.Text = offText
                        end
                    else
                        entry.Root.Visible = false
                        entry.Offscreen.Visible = false
                        entry.OffscreenText.Visible = false
                    end
                end
            else
                hideESPEntry(entry)
            end
        end
    end
end

-- ============================================================
-- Void Spam
-- ============================================================

local function getVoidRoot()
    local character = LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function restoreVoidPosition()
    local character = LocalPlayer.Character
    local root = getVoidRoot()
    if character and root and VoidSpam.SavedCFrame and (not VoidSpam.SavedRoot or VoidSpam.SavedRoot == root) then
        pcall(function()
            root.CFrame = VoidSpam.SavedCFrame
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
    end

    VoidSpam.Away = false
    VoidSpam.Phase = false
    VoidSpam.SavedCFrame = nil
    VoidSpam.SavedRoot = nil
end

local function setVoidSpamEnabled(state)
    if state == true and MultiTarget.Running then
        notify("void hide", "paused while MultiTarget owns void movement", "warning", 1.8)
        return
    end

    VoidSpam.Generation = VoidSpam.Generation + 1
    VoidSpam.Enabled = state == true
    VoidSpam.Last = 0

    if VoidSpam.Enabled then
        VoidSpam.Away = false
        VoidSpam.Phase = false
        VoidSpam.SavedCFrame = nil
        VoidSpam.SavedRoot = nil
        task.defer(function()
            if VoidSpam.Enabled and not Unloaded then
                VoidSpam.Step(true)
            end
        end)
    else
        restoreVoidPosition()
    end
end

VoidSpam.PrepareRoot = function()
    if not VoidSpam.Enabled or Unloaded then
        return nil, nil, nil
    end

    local character = LocalPlayer.Character
    local root = getVoidRoot()
    if not character or not root then
        return nil, nil, nil
    end

    -- Save the real position once. While enabled we NEVER pulse back to ground;
    -- SavedCFrame is used only when Void Spam is turned off/unloaded.
    if VoidSpam.SavedRoot ~= root or not VoidSpam.SavedCFrame then
        VoidSpam.SavedRoot = root
        VoidSpam.SavedCFrame = root.CFrame
        VoidSpam.Phase = false
        VoidSpam.Last = 0
    end

    return character, root, VoidSpam.SavedCFrame
end

VoidSpam.Step = function(force)
    -- E/H owns the local HRP while an action is in progress. Letting VoidSpam
    -- write a 10M-1B stud CFrame on the same heartbeat creates the gigantic
    -- arrival/origin distances seen in diagnostics. Preserve the toggle state,
    -- but pause its movement until the action finishes.
    if AllIn1.Busy or MultiTarget.Running then
        return
    end

    local character, root, baseCFrame = VoidSpam.PrepareRoot()
    if not character or not root or not baseCFrame then
        return
    end

    local now = os.clock()
    if not force and VoidSpam.Last > 0 and (now - VoidSpam.Last) < VoidSpam.Interval then
        return
    end
    VoidSpam.Last = now
    VoidSpam.Phase = not VoidSpam.Phase

    local height = VoidSpam.Phase and VoidSpam.LowHeight or VoidSpam.HighHeight
    local destination = baseCFrame + Vector3.new(0, height, 0)

    -- Move the assembly root directly so the replicated character position is
    -- the void position. Both destinations are void-only; there is no ground phase.
    pcall(function()
        root.CFrame = destination
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)

    VoidSpam.Away = true
end

-- Temporarily bring the real character back to the exact map CFrame that was
-- saved when void hide was enabled. The toggle remains ON, the Fake Pos ghost is
-- never recreated/moved, and VoidSpam.Step is naturally paused while E/H owns
-- movement. This gives the weapon origin a normal map-level baseline before fire.
VoidSpam.EnterGroundAction = function(owner, token)
    if not VoidSpam.Enabled or not VoidSpam.SavedCFrame then
        return true, false
    end

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not character or not root or not humanoid or humanoid.Health <= 0 then
        VoidSpam.ActionSettleStatus = "character unavailable"
        return false, false
    end

    VoidSpam.ActionGroundActive = true
    VoidSpam.ActionOwner = tostring(owner or "action")
    VoidSpam.ActionReturnCFrame = root.CFrame
    VoidSpam.ActionGroundCFrame = VoidSpam.SavedCFrame
    VoidSpam.ActionSettleStatus = "moving to ground"

    local ok = pcall(function()
        root.Anchored = false
        character:PivotTo(VoidSpam.ActionGroundCFrame)
        root.CFrame = VoidSpam.ActionGroundCFrame
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)
    if not ok then
        VoidSpam.ActionSettleStatus = "ground move failed"
        return false, true
    end

    local ping = 0.060
    if AllIn1.GetDataPingSeconds then
        ping = AllIn1.GetDataPingSeconds()
    end
    local settleTime = math.clamp(0.16 + (ping * 0.70), 0.18, 0.34)
    local started = os.clock()

    while not Unloaded and (os.clock() - started) < settleTime do
        if owner == "E" then
            if not AllIn1.Busy or AllIn1.Token ~= token then
                VoidSpam.ActionSettleStatus = "cancelled"
                return false, true
            end
        elseif owner == "H" then
            if not MultiTarget.Running or MultiTarget.Token ~= token then
                VoidSpam.ActionSettleStatus = "cancelled"
                return false, true
            end
        end

        local liveCharacter = LocalPlayer.Character
        local liveRoot = liveCharacter and liveCharacter:FindFirstChild("HumanoidRootPart")
        if liveCharacter ~= character or not liveRoot then
            VoidSpam.ActionSettleStatus = "root changed"
            return false, true
        end

        if (liveRoot.Position - VoidSpam.ActionGroundCFrame.Position).Magnitude > 4 then
            pcall(function()
                liveRoot.Anchored = false
                liveCharacter:PivotTo(VoidSpam.ActionGroundCFrame)
                liveRoot.CFrame = VoidSpam.ActionGroundCFrame
                liveRoot.AssemblyLinearVelocity = Vector3.zero
                liveRoot.AssemblyAngularVelocity = Vector3.zero
            end)
        end
        if Utility.FakePosEnabled and type(Utility.RestoreFakePosRoot) == "function" then
            Utility.RestoreFakePosRoot(liveRoot)
        end
        RunService.Heartbeat:Wait()
    end

    VoidSpam.Away = false
    VoidSpam.ActionSettleStatus = "ground ready"
    return true, true
end

VoidSpam.ResumeAfterAction = function(owner)
    if not VoidSpam.ActionGroundActive then
        return
    end
    if owner and VoidSpam.ActionOwner and tostring(owner) ~= tostring(VoidSpam.ActionOwner) then
        return
    end

    local returnCFrame = VoidSpam.ActionReturnCFrame
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if VoidSpam.Enabled and returnCFrame and character and root then
        pcall(function()
            root.Anchored = false
            character:PivotTo(returnCFrame)
            root.CFrame = returnCFrame
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
        VoidSpam.Away = true
        VoidSpam.Last = 0
    end

    VoidSpam.ActionGroundActive = false
    VoidSpam.ActionOwner = nil
    VoidSpam.ActionReturnCFrame = nil
    VoidSpam.ActionGroundCFrame = nil
    VoidSpam.ActionSettleStatus = "idle"
end

-- ============================================================
-- AllIn1 - E: locked target only, orbit + rapid fire + exact return
-- ============================================================

AllIn1.GetLockedTarget = function()
    -- The cursor tracer already proves which Player C currently owns. Resolve
    -- that exact Player/UserId without comparing Parent against the cloned
    -- Players service (that comparison can be false in some executors).
    local target = nil
    if MultiTarget.Running and MultiTarget.CurrentUserId then
        target = findPlayerByUserId(MultiTarget.CurrentUserId)
    end
    target = target or Aim.CurrentTarget

    if target and target ~= LocalPlayer then
        local okUserId, userId = pcall(function()
            return target.UserId
        end)
        if okUserId and userId then
            target = findPlayerByUserId(userId) or target
        else
            target = nil
        end
    else
        target = nil
    end

    if not target and Aim.LockedUserId then
        target = findPlayerByUserId(Aim.LockedUserId)
    end

    if not target and HUDPlayerId then
        target = findPlayerByUserId(HUDPlayerId)
    end

    if not target or target == LocalPlayer then
        return nil, nil, nil, "no_target"
    end

    -- Once the identity is known, keep it synchronized immediately so a
    -- respawn cannot make E lose the same C-selected user.
    Aim.CurrentTarget = target
    Aim.LockedUserId = target.UserId

    local humanoid = getHumanoid(target)
    local hrp = getTargetPart(target)

    if isKnockedOut(target) then
        return target, humanoid, hrp, "ko"
    end

    if not humanoid or humanoid.Health <= 0 or not hrp then
        return target, humanoid, hrp, "respawning"
    end

    return target, humanoid, hrp, nil
end

AllIn1.GetEquippedTool = function(character)
    if not character then
        return nil
    end

    for _, child in ipairs(character:GetChildren()) do
        if child:IsA("Tool") then
            return child
        end
    end

    local recursive = character:FindFirstChildWhichIsA("Tool", true)
    return recursive
end

-- Fake Pos force-carrier: preserve the real gun/hand/HRP chain while the visual
-- ghost is active. No Tool is cloned or fabricated; only the exact live Tool instance
-- that was equipped when Fake Pos was entered is allowed to be recovered.
Utility.GetFakePosRightHand = function(character)
    if not character then
        return nil
    end
    return character:FindFirstChild("RightHand", true)
        or character:FindFirstChild("Right Arm", true)
        or character:FindFirstChild("RightLowerArm", true)
end

Utility.FindFakePosToolGrip = function(character, hand, handle)
    if not character or not hand or not handle then
        return nil
    end

    for _, joint in ipairs(character:GetDescendants()) do
        if joint:IsA("JointInstance") or joint:IsA("WeldConstraint") then
            local ok, part0, part1 = pcall(function()
                return joint.Part0, joint.Part1
            end)
            if ok and ((part0 == hand and part1 == handle) or (part0 == handle and part1 == hand)) then
                return joint
            end
        end
    end
    return nil
end

Utility.ReleaseFakePosToolCarrier = function(clearRememberedTool)
    local grip = Utility.FakePosForceGrip
    Utility.FakePosForceGrip = nil
    if grip and grip.Parent then
        pcall(function()
            grip:Destroy()
        end)
    end

    local handle = Utility.FakePosForceHandle
    local oldState = Utility.FakePosForceHandleState
    if handle and handle.Parent and oldState then
        pcall(function()
            handle.CanCollide = oldState.CanCollide
            handle.Massless = oldState.Massless
        end)
    end

    Utility.FakePosForceHandle = nil
    Utility.FakePosForceHandleState = nil
    Utility.FakePosForceHandOffset = nil
    Utility.FakePosForceCarrierActive = false
    Utility.FakePosForceStatus = "idle"

    if clearRememberedTool then
        Utility.FakePosForceTool = nil
        Utility.FakePosForceToolName = nil
    end
end

Utility.DestroyFakePosERealToolGlue = function()
    local glue = Utility.FakePosERealGlue
    Utility.FakePosERealGlue = nil
    if glue and glue.Parent then
        pcall(function()
            glue:Destroy()
        end)
    end
    Utility.FakePosERealGlueTool = nil
    Utility.FakePosERealGlueHand = nil
    Utility.FakePosERealGlueHandle = nil
    Utility.FakePosERealGlueStatus = "idle"
end

-- Keep the SAME server/game Tool physically attached to the REAL character hand
-- during E. Native RightGrip remains untouched and authoritative; this weld is a
-- redundant physical brace only, so the gun cannot lag behind the real firing body.
Utility.EnsureFakePosERealToolGlue = function(tool)
    if Unloaded or not Utility.FakePosEnabled or not Utility.FakePosEThawActive then
        Utility.DestroyFakePosERealToolGlue()
        return false, "E real glue inactive"
    end

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local hand = character and Utility.GetFakePosRightHand(character)
    tool = tool or (character and AllIn1.GetEquippedTool(character)) or Utility.FakePosENativeTool
    local handle = tool and tool:FindFirstChild("Handle", true)
    if handle and not handle:IsA("BasePart") then
        handle = nil
    end
    if not handle and tool then
        handle = tool:FindFirstChildWhichIsA("BasePart", true)
    end

    if not character or not root or not hand or not hand:IsA("BasePart")
        or not tool or not tool:IsA("Tool") or not tool:IsDescendantOf(character)
        or not handle or not handle:IsA("BasePart")
    then
        Utility.FakePosERealGlueStatus = "real hand/tool unavailable"
        return false, Utility.FakePosERealGlueStatus
    end

    -- Do not replace RightGrip. Require the normal game joint first, then add the
    -- physical brace over the exact same real hand/Handle pair.
    local nativeGrip = Utility.FindFakePosNativeToolGrip
        and Utility.FindFakePosNativeToolGrip(character, hand, handle)
    if not nativeGrip then
        Utility.FakePosERealGlueStatus = "native RightGrip missing"
        return false, Utility.FakePosERealGlueStatus
    end

    local glue = Utility.FakePosERealGlue
    if not glue or not glue.Parent
        or Utility.FakePosERealGlueTool ~= tool
        or Utility.FakePosERealGlueHand ~= hand
        or Utility.FakePosERealGlueHandle ~= handle
        or glue.Part0 ~= hand
        or glue.Part1 ~= handle
    then
        Utility.DestroyFakePosERealToolGlue()
        glue = Instance.new("WeldConstraint")
        glue.Name = "alex.ftn_ERealCharacterToolGlue"
        glue.Part0 = hand
        glue.Part1 = handle
        glue.Parent = hand
        Utility.FakePosERealGlue = glue
        Utility.FakePosERealGlueTool = tool
        Utility.FakePosERealGlueHand = hand
        Utility.FakePosERealGlueHandle = handle
    end

    -- Wake the REAL hand/Handle assembly and keep the Tool collision-free. Do not
    -- CFrame the Handle independently: native RightGrip determines the correct pose.
    pcall(function()
        handle.CanCollide = false
        handle.Massless = true
        handle.AssemblyLinearVelocity = hand.AssemblyLinearVelocity
        handle.AssemblyAngularVelocity = hand.AssemblyAngularVelocity
    end)
    if type(sethiddenproperty) == "function" then
        pcall(sethiddenproperty, root, "PhysicsRepRootPart", root)
        pcall(sethiddenproperty, root, "NetworkIsSleeping", false)
        pcall(sethiddenproperty, hand, "NetworkIsSleeping", false)
        pcall(sethiddenproperty, handle, "NetworkIsSleeping", false)
    end

    local handDistance = (handle.Position - hand.Position).Magnitude
    local rootDistance = (handle.Position - root.Position).Magnitude
    if handDistance > 6.0 or rootDistance > 12.0 then
        Utility.FakePosERealGlueStatus = string.format(
            "real glue out-of-range hand %.2f / root %.2f",
            handDistance,
            rootDistance
        )
        return false, Utility.FakePosERealGlueStatus
    end

    Utility.FakePosERealGlueStatus = string.format(
        "REAL-GLUED %s | hand %.2f | root %.2f",
        tostring(nativeGrip.Name),
        handDistance,
        rootDistance
    )
    return true, Utility.FakePosERealGlueStatus
end

-- Find ONLY a normal/game-created hand<->Handle joint. The temporary
-- alex.ftn_FakePosToolGrip is deliberately excluded so E never mistakes our local
-- safety carrier for the Tool relationship the game/server normally uses.
Utility.FindFakePosNativeToolGrip = function(character, hand, handle)
    if not character or not hand or not handle then
        return nil
    end

    for _, joint in ipairs(character:GetDescendants()) do
        if joint ~= Utility.FakePosForceGrip
            and joint.Name ~= "alex.ftn_FakePosToolGrip"
            and (joint:IsA("JointInstance") or joint:IsA("WeldConstraint"))
        then
            local ok, part0, part1 = pcall(function()
                return joint.Part0, joint.Part1
            end)
            if ok and ((part0 == hand and part1 == handle)
                or (part0 == handle and part1 == hand))
            then
                return joint
            end
        end
    end

    return nil
end

Utility.ValidateFakePosNativeToolForE = function(tool)
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not character or not root or not humanoid then
        return false, "character unavailable"
    end

    tool = tool or AllIn1.GetEquippedTool(character) or Utility.FakePosENativeTool
    if not tool or not tool:IsA("Tool") or not tool.Parent or not tool:IsDescendantOf(character) then
        return false, "native tool not equipped"
    end

    local hand = Utility.GetFakePosRightHand(character)
    local handle = tool:FindFirstChild("Handle", true)
    if not handle or not handle:IsA("BasePart") then
        handle = tool:FindFirstChildWhichIsA("BasePart", true)
    end
    if not hand or not hand:IsA("BasePart") or not handle or not handle:IsA("BasePart") then
        return false, "native hand/handle unavailable"
    end

    local grip = Utility.FindFakePosNativeToolGrip(character, hand, handle)
    if not grip then
        return false, "native RightGrip missing"
    end

    local handDistance = (handle.Position - hand.Position).Magnitude
    local rootDistance = (handle.Position - root.Position).Magnitude
    if handDistance > 6.0 then
        return false, string.format("native handle %.2f studs from hand", handDistance)
    end
    if rootDistance > 12.0 then
        return false, string.format("native handle %.2f studs from HRP", rootDistance)
    end

    return true, string.format(
        "native-ready %s | hand %.2f | root %.2f",
        tostring(grip.Name),
        handDistance,
        rootDistance
    )
end

Utility.PrepareFakePosNativeToolForE = function(token, timeout)
    if Unloaded or not Utility.FakePosEnabled then
        return true
    end

    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not character or not humanoid then
        Utility.FakePosENativeToolStatus = "character unavailable"
        return false
    end

    local tool = AllIn1.GetEquippedTool(character)
        or Utility.FakePosForceTool
        or AllIn1.LastEquippedTool
    if not tool or not tool:IsA("Tool") or not tool.Parent then
        Utility.FakePosENativeToolStatus = "no live tool for native E"
        return false
    end

    Utility.FakePosENativeToolMode = true
    Utility.FakePosENativeTool = tool
    Utility.FakePosENativeToolStatus = "releasing Fake Pos carrier"

    -- Remove ONLY our local fallback weld/physics edits. Keep the remembered exact
    -- Tool so Fake Pos can rebind it after E has fully returned.
    Utility.ReleaseFakePosToolCarrier(false)

    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if backpack and tool.Parent == backpack then
        pcall(function()
            humanoid:EquipTool(tool)
        end)
        RunService.Heartbeat:Wait()
    end

    local deadline = os.clock() + math.clamp(
        tonumber(timeout) or Utility.FakePosENativeToolTimeout or 0.45,
        0.15,
        0.80
    )
    local stableFrames = 0
    local forcedReequip = false

    while not Unloaded
        and Utility.FakePosEnabled
        and Utility.FakePosEThawActive
        and Utility.FakePosEThawToken == token
        and AllIn1.Busy
        and AllIn1.Token == token
        and os.clock() < deadline
    do
        character = LocalPlayer.Character
        humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if not character or not humanoid then
            stableFrames = 0
            Utility.FakePosENativeToolStatus = "character changed during native E"
            RunService.Heartbeat:Wait()
            continue
        end

        local equipped = AllIn1.GetEquippedTool(character)
        if equipped == tool then
            local valid, detail = Utility.ValidateFakePosNativeToolForE(tool)
            if valid and type(Utility.EnsureFakePosERealToolGlue) == "function" then
                local glued, glueDetail = Utility.EnsureFakePosERealToolGlue(tool)
                valid = glued == true
                detail = valid
                    and (tostring(detail) .. " / " .. tostring(glueDetail))
                    or tostring(glueDetail)
            end
            Utility.FakePosENativeToolStatus = detail
            if valid then
                stableFrames = stableFrames + 1
            else
                stableFrames = 0
            end
        else
            stableFrames = 0
            Utility.FakePosENativeToolStatus = "waiting for exact native tool"
        end

        if stableFrames >= (Utility.FakePosENativeToolStableFrames or 3) then
            Utility.FakePosENativeToolStatus = "native-ready"
            AllIn1.LastEquippedTool = tool
            AllIn1.LastEquippedToolName = tool.Name
            AllIn1.LastEquippedSeenAt = os.clock()
            return true
        end

        -- One bounded normal unequip/re-equip rebuilds Roblox's/game's own RightGrip.
        -- Do this BEFORE E moves, never during the actual shot/verification window.
        if not forcedReequip and stableFrames == 0 then
            forcedReequip = true
            pcall(function()
                humanoid:UnequipTools()
            end)
            RunService.Heartbeat:Wait()
            backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
            if backpack and tool.Parent == backpack then
                pcall(function()
                    humanoid:EquipTool(tool)
                end)
            end
        elseif backpack and tool.Parent == backpack then
            pcall(function()
                humanoid:EquipTool(tool)
            end)
        end

        RunService.Heartbeat:Wait()
    end

    Utility.FakePosENativeToolStatus = "native grip timeout"
    return false
end

Utility.BindFakePosToolCarrier = function(tool)
    if not Utility.FakePosEnabled or not tool or not tool:IsA("Tool") then
        return false
    end

    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not character or not humanoid or not root then
        Utility.FakePosForceStatus = "character unavailable"
        return false
    end

    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if backpack and tool.Parent == backpack then
        pcall(function()
            humanoid:EquipTool(tool)
        end)
    end

    if not tool.Parent or not tool:IsDescendantOf(character) then
        Utility.FakePosForceStatus = "tool not equipped"
        return false
    end

    local hand = Utility.GetFakePosRightHand(character)
    local handle = tool:FindFirstChild("Handle", true)
    if not handle or not handle:IsA("BasePart") then
        handle = tool:FindFirstChildWhichIsA("BasePart", true)
    end
    if not hand or not hand:IsA("BasePart") or not handle or not handle:IsA("BasePart") then
        Utility.FakePosForceStatus = "hand/handle unavailable"
        if type(sethiddenproperty) == "function" then
            pcall(sethiddenproperty, root, "PhysicsRepRootPart", root)
        end
        return false
    end

    if Utility.FakePosForceHandle ~= handle then
        local rememberedTool = Utility.FakePosForceTool
        local rememberedName = Utility.FakePosForceToolName
        local rememberedOffset = rememberedTool == tool and Utility.FakePosForceHandOffset or nil
        Utility.ReleaseFakePosToolCarrier(false)
        Utility.FakePosForceTool = rememberedTool or tool
        Utility.FakePosForceToolName = rememberedName or tool.Name
        Utility.FakePosForceHandle = handle
        Utility.FakePosForceHandleState = {
            CanCollide = handle.CanCollide,
            Massless = handle.Massless,
        }
        Utility.FakePosForceHandOffset = rememberedOffset or hand.CFrame:ToObjectSpace(handle.CFrame)
    end

    Utility.FakePosForceTool = tool
    Utility.FakePosForceToolName = tool.Name

    pcall(function()
        handle.CanCollide = false
        handle.Massless = true
    end)

    local existingGrip = Utility.FindFakePosToolGrip(character, hand, handle)
    local expected = hand.CFrame * (Utility.FakePosForceHandOffset or CFrame.new())

    -- If the game drops/deletes RightGrip for a frame, place the SAME Handle back at
    -- its last valid hand offset and install one temporary local weld until the game's
    -- normal grip comes back. This prevents the gun becoming a loose physics object.
    if not existingGrip then
        pcall(function()
            if (handle.Position - expected.Position).Magnitude > 1.5 then
                handle.CFrame = expected
                handle.AssemblyLinearVelocity = hand.AssemblyLinearVelocity
                handle.AssemblyAngularVelocity = hand.AssemblyAngularVelocity
            end
        end)

        local safetyGrip = Utility.FakePosForceGrip
        if not safetyGrip or not safetyGrip.Parent or safetyGrip.Part0 ~= hand or safetyGrip.Part1 ~= handle then
            if safetyGrip and safetyGrip.Parent then
                pcall(function()
                    safetyGrip:Destroy()
                end)
            end
            safetyGrip = Instance.new("WeldConstraint")
            safetyGrip.Name = "alex.ftn_FakePosToolGrip"
            safetyGrip.Part0 = hand
            safetyGrip.Part1 = handle
            safetyGrip.Parent = hand
            Utility.FakePosForceGrip = safetyGrip
        end
    elseif Utility.FakePosForceGrip and Utility.FakePosForceGrip.Parent then
        -- Roblox rebuilt its normal RightGrip; hand ownership can go back to the game.
        pcall(function()
            Utility.FakePosForceGrip:Destroy()
        end)
        Utility.FakePosForceGrip = nil
    end

    -- Keep the Tool physically attached during ordinary Fake Pos, but do NOT pin
    -- PhysicsRepRootPart to the live HRP every repair tick. The Fake Pos worker must
    -- be allowed to run its normal replication cycle while idle. E/H (and the actual
    -- shot preflight below) take temporary ownership of the live root only when a
    -- shot/action is really being committed.
    local rootOK = true
    local rootOwnedForCombat = Utility.FakePosCombatHold
        or MultiTarget.GroundActionMode
        or AllIn1.Busy
        or os.clock() < (Utility.FakePosOriginHoldUntil or 0)
    if rootOwnedForCombat and type(sethiddenproperty) == "function" then
        rootOK = pcall(sethiddenproperty, root, "PhysicsRepRootPart", root)
    end

    Utility.FakePosForceCarrierActive = true
    if rootOwnedForCombat then
        Utility.FakePosForceStatus = rootOK and "HRP + TOOL LIVE" or "tool live / root write failed"
    else
        Utility.FakePosForceStatus = "TOOL LIVE / FAKE POS CYCLING"
    end
    return true
end

Utility.UpdateFakePosToolCarrier = function(force)
    if Unloaded or not Utility.FakePosEnabled then
        return false
    end

    -- Manual E deliberately returns the Tool to the game's native RightGrip chain.
    -- Never recreate the local fallback carrier until E has returned and the thaw
    -- has ended, otherwise the local muzzle can disagree with the server gun state.
    if Utility.FakePosENativeToolMode then
        Utility.FakePosForceCarrierActive = false
        Utility.FakePosForceStatus = "E NATIVE TOOL"
        return false
    end

    local now = os.clock()
    if not force and now < (Utility.FakePosForceNextRepair or 0) then
        return Utility.FakePosForceCarrierActive == true
    end
    Utility.FakePosForceNextRepair = now + (Utility.FakePosForceRepairInterval or 0.02)

    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not character or not humanoid or not root then
        Utility.FakePosForceCarrierActive = false
        Utility.FakePosForceStatus = "character unavailable"
        return false
    end

    local equipped = AllIn1.GetEquippedTool(character)
    if equipped then
        Utility.FakePosForceTool = equipped
        Utility.FakePosForceToolName = equipped.Name
        AllIn1.LastEquippedTool = equipped
        AllIn1.LastEquippedToolName = equipped.Name
        AllIn1.LastEquippedSeenAt = now
    end

    local tool = equipped or Utility.FakePosForceTool
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if (not tool or not tool.Parent) and AllIn1.GetRecoverableTool then
        local recoveredCandidate = AllIn1.GetRecoverableTool()
        if recoveredCandidate then
            tool = recoveredCandidate
            Utility.FakePosForceTool = recoveredCandidate
            Utility.FakePosForceToolName = recoveredCandidate.Name
        end
    end
    if tool and tool:IsA("Tool") and backpack and tool.Parent == backpack then
        -- Immediate recovery: no 80 ms delay and no 700 ms cooldown while Fake Pos
        -- owns the same gun. Re-equip exactly that instance and nothing else.
        pcall(function()
            humanoid:EquipTool(tool)
        end)
        equipped = AllIn1.GetEquippedTool(character)
        if equipped then
            tool = equipped
        end
    end

    if not tool or not tool:IsA("Tool") then
        Utility.FakePosForceCarrierActive = false
        Utility.FakePosForceStatus = "no remembered tool"
        return false
    end

    if not tool:IsDescendantOf(character) then
        -- Do not pin the replication root just because the Tool is between Backpack
        -- and Character. The next repair tick keeps trying the exact remembered Tool;
        -- shot/combat preflight owns the root only when a shot is actually requested.
        Utility.FakePosForceCarrierActive = true
        Utility.FakePosForceStatus = "re-equipping tool"
        return false
    end

    return Utility.BindFakePosToolCarrier(tool)
end

Utility.BeginFakePosOriginHold = function(duration, reason)
    if Unloaded or not Utility.FakePosEnabled then
        return false
    end

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root or not root.Parent then
        Utility.FakePosOriginHoldReason = "root unavailable"
        return false
    end

    local now = os.clock()
    local holdFor = math.clamp(
        tonumber(duration) or Utility.FakePosOriginShotHoldDuration or 0.24,
        0.04,
        0.75
    )

    Utility.FakePosOriginHoldUntil = math.max(
        tonumber(Utility.FakePosOriginHoldUntil) or 0,
        now + holdFor
    )
    Utility.FakePosOriginHoldReason = tostring(reason or "shot")

    local restored = true
    if type(sethiddenproperty) == "function" then
        restored = pcall(
            sethiddenproperty,
            root,
            "PhysicsRepRootPart",
            root
        )
    elseif type(Utility.RestoreFakePosRoot) == "function" then
        Utility.RestoreFakePosRoot(root)
    end

    Utility.FakePosRoot = root
    Utility.FakePosCycleState = restored and "origin-hold" or "origin-hold-fail"
    Utility.FakePosOriginRepairCount = (Utility.FakePosOriginRepairCount or 0) + 1

    -- Keep the exact equipped Tool attached while the root lease is active.
    -- This is intentionally bounded by the hold timer above.
    if type(Utility.UpdateFakePosToolCarrier) == "function" then
        Utility.UpdateFakePosToolCarrier(true)
    end

    return restored
end


Utility.BeginFakePosEThaw = function(token, timeout)
    if Unloaded or not Utility.FakePosEnabled then
        return true
    end

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not character or not root or not root.Parent then
        Utility.FakePosEThawStatus = "root unavailable"
        return false
    end

    Utility.FakePosCombatHold = true
    Utility.FakePosCombatToken = token
    Utility.FakePosEThawActive = true
    Utility.FakePosEThawToken = token
    Utility.FakePosEThawStartedAt = os.clock()
    Utility.FakePosEThawReadyAt = 0
    Utility.FakePosEThawStatus = "hard-suspending worker"
    Utility.FakePosCycleState = "e-hard-suspend"

    -- IMPORTANT: merely pausing the worker was not enough. If E arrived while the
    -- old generation was already inside its 0.1s PhysicsRepRootPart=nil window, that
    -- coroutine could still be unwinding while E started to teleport/fire. Invalidate
    -- the worker generation completely, exactly like the older working disable->E
    -- handoff did, but keep FakePosEnabled/ghost visuals alive so F never visually
    -- toggles off. A fresh worker is started only after E returns.
    Utility.FakePosGeneration = Utility.FakePosGeneration + 1
    Utility.FakePosEHardSuspendActive = true

    -- Restore the pre-Fake-Pos sender rate when it is readable. A pcall success alone
    -- is not considered proof when getfflag exists; verify the value as well.
    Utility.FakePosEThawReapplySender = Utility.FakePosFlagApplied == true
    Utility.FakePosEThawSenderRestored = not Utility.FakePosFlagApplied
    Utility.FakePosEThawSenderVerified = not Utility.FakePosFlagApplied
    if Utility.FakePosOriginalSenderRateKnown and type(setfflag) == "function" then
        Utility.FakePosEThawSenderRestored = pcall(
            setfflag,
            "S2PhysicsSenderRate",
            Utility.FakePosOriginalSenderRate
        )
        Utility.FakePosEThawSenderVerified = Utility.FakePosEThawSenderRestored
        if Utility.FakePosEThawSenderRestored and type(getfflag) == "function" then
            local readOK, currentRate = pcall(getfflag, "S2PhysicsSenderRate")
            Utility.FakePosEThawSenderVerified = readOK
                and currentRate ~= nil
                and tostring(currentRate) == tostring(Utility.FakePosOriginalSenderRate)
        end
    elseif Utility.FakePosFlagApplied then
        -- Some executors expose setfflag without getfflag. We cannot recover an
        -- unknown original value safely, so leave the sender flag alone and rely on
        -- the hard-stopped nil-root worker + live HRP verification below.
        Utility.FakePosEThawSenderRestored = false
        Utility.FakePosEThawSenderVerified = false
    end

    -- HRP being live is not enough if the gun is still riding our LOCAL fallback
    -- carrier. Rebuild the exact Tool on the game's normal RightGrip before E moves.
    -- This is the key difference between a locally-correct muzzle and a server-valid
    -- weapon origin.
    if type(Utility.PrepareFakePosNativeToolForE) == "function" then
        local nativeReady = Utility.PrepareFakePosNativeToolForE(
            token,
            Utility.FakePosENativeToolTimeout
        )
        if not nativeReady then
            Utility.FakePosEThawStatus = "native tool restore failed"
            Utility.FakePosCycleState = "e-native-tool-fail"
            return false
        end
    end

    -- Give the invalidated worker two scheduler/physics frames to leave any active
    -- nil window. Force HRP live on both frames; the retiring worker's own cleanup
    -- also restores this same root, so the two paths are cooperative rather than
    -- competing.
    for _ = 1, 2 do
        character = LocalPlayer.Character
        root = character and character:FindFirstChild("HumanoidRootPart")
        if not root or not root.Parent then
            Utility.FakePosEThawStatus = "root lost during suspend"
            return false
        end
        if type(sethiddenproperty) == "function" then
            pcall(sethiddenproperty, root, "PhysicsRepRootPart", root)
            pcall(sethiddenproperty, root, "NetworkIsSleeping", false)
        elseif type(Utility.RestoreFakePosRoot) == "function" then
            Utility.RestoreFakePosRoot(root)
        end
        RunService.Heartbeat:Wait()
    end

    local ping = (AllIn1.GetDataPingSeconds and AllIn1.GetDataPingSeconds()) or 0.060
    local minimumReadyAt = os.clock() + math.max(
        tonumber(Utility.FakePosEPreMoveSettleMin) or 0.10,
        math.clamp(ping * 1.10, 0.06, 0.22)
    )
    local deadline = os.clock() + math.clamp(
        tonumber(timeout) or Utility.FakePosEThawTimeout or 0.70,
        0.25,
        1.20
    )
    local stableFrames = 0

    while not Unloaded
        and Utility.FakePosEnabled
        and Utility.FakePosEThawActive
        and Utility.FakePosEThawToken == token
        and AllIn1.Busy
        and AllIn1.Token == token
        and os.clock() < deadline
    do
        character = LocalPlayer.Character
        local liveRoot = character and character:FindFirstChild("HumanoidRootPart")
        if not liveRoot or not liveRoot.Parent then
            stableFrames = 0
            RunService.Heartbeat:Wait()
            continue
        end

        if liveRoot ~= root then
            root = liveRoot
            Utility.FakePosRoot = root
            stableFrames = 0
        end

        local writeOK = false
        if type(sethiddenproperty) == "function" then
            writeOK = pcall(sethiddenproperty, root, "PhysicsRepRootPart", root)
            pcall(sethiddenproperty, root, "NetworkIsSleeping", false)
        elseif type(Utility.RestoreFakePosRoot) == "function" then
            Utility.RestoreFakePosRoot(root)
            writeOK = true
        end

        local rootConfirmed = writeOK
        if writeOK and type(gethiddenproperty) == "function" then
            local readOK, value = pcall(gethiddenproperty, root, "PhysicsRepRootPart")
            rootConfirmed = readOK and value == root
        end

        if rootConfirmed then
            stableFrames = stableFrames + 1
        else
            stableFrames = 0
        end

        if Utility.FakePosENativeToolMode and type(Utility.ValidateFakePosNativeToolForE) == "function" then
            local nativeOK, nativeDetail = Utility.ValidateFakePosNativeToolForE(
                Utility.FakePosENativeTool
            )
            if nativeOK and type(Utility.EnsureFakePosERealToolGlue) == "function" then
                local glued, glueDetail = Utility.EnsureFakePosERealToolGlue(
                    Utility.FakePosENativeTool
                )
                nativeOK = glued == true
                nativeDetail = nativeOK
                    and (tostring(nativeDetail) .. " / " .. tostring(glueDetail))
                    or tostring(glueDetail)
            end
            Utility.FakePosENativeToolStatus = nativeDetail
            if not nativeOK then
                stableFrames = 0
            end
        end

        if stableFrames >= (Utility.FakePosEThawStableFrames or 5)
            and os.clock() >= minimumReadyAt
        then
            Utility.FakePosEThawReadyAt = os.clock()
            Utility.FakePosEThawStatus = Utility.FakePosEThawSenderVerified
                and "hard-ready / sender verified"
                or "hard-ready / root verified"
            Utility.FakePosCycleState = "e-hard-ready"
            return true
        end

        RunService.Heartbeat:Wait()
    end

    Utility.FakePosEThawStatus = "hard restore timeout"
    Utility.FakePosCycleState = "e-hard-timeout"
    return false
end

Utility.EndFakePosEThaw = function(token, settleReturn)
    if not Utility.FakePosEThawActive then
        return
    end
    if token and Utility.FakePosEThawToken ~= token then
        return
    end

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")

    -- Keep the returned map origin live for a ping-aware window, not just two
    -- heartbeats. This gives the server time to receive the real return CFrame before
    -- the fresh Fake Pos worker is allowed to start another nil-root cycle.
    if settleReturn and root and root.Parent then
        local ping = (AllIn1.GetDataPingSeconds and AllIn1.GetDataPingSeconds()) or 0.060
        local settleUntil = os.clock() + math.max(
            tonumber(Utility.FakePosEPostReturnSettleMin) or 0.10,
            math.clamp(ping * 1.15, 0.07, 0.24)
        )
        repeat
            character = LocalPlayer.Character
            root = character and character:FindFirstChild("HumanoidRootPart")
            if not root or not root.Parent then
                break
            end
            if type(sethiddenproperty) == "function" then
                pcall(sethiddenproperty, root, "PhysicsRepRootPart", root)
                pcall(sethiddenproperty, root, "NetworkIsSleeping", false)
            elseif type(Utility.RestoreFakePosRoot) == "function" then
                Utility.RestoreFakePosRoot(root)
            end
            -- Keep the native Tool chain untouched until the returned HRP itself has
            -- replicated. Fake Pos carrier is restored only after this thaw ends.
            RunService.Heartbeat:Wait()
        until os.clock() >= settleUntil
    end

    Utility.FakePosEThawActive = false
    Utility.FakePosEThawToken = 0
    Utility.FakePosEThawStartedAt = 0
    Utility.FakePosEThawReadyAt = 0
    Utility.FakePosEThawStatus = "idle"

    -- Resume the Fake Pos sender accelerator only after E's return position has been
    -- committed. Then start a BRAND NEW worker generation; the pre-E worker was
    -- deliberately invalidated and can never re-enter its old nil window.
    if Utility.FakePosEnabled
        and Utility.FakePosEThawReapplySender
        and type(setfflag) == "function"
    then
        local senderOK = pcall(setfflag, "S2PhysicsSenderRate", "1000")
        if not senderOK then
            senderOK = pcall(setfflag, "S2PhysicsSenderRate", 1000)
        end
        if not senderOK then
            Utility.FakePosFlagApplied = false
        end
    end
    Utility.FakePosEThawSenderRestored = false
    Utility.FakePosEThawSenderVerified = false
    Utility.FakePosEThawReapplySender = false

    -- E is completely finished with the gun now. Remove only our redundant REAL
    -- hand brace; native RightGrip remains untouched. Hand ownership may then return
    -- to the ordinary Fake Pos carrier after the map-side origin is committed.
    if type(Utility.DestroyFakePosERealToolGlue) == "function" then
        Utility.DestroyFakePosERealToolGlue()
    end
    Utility.FakePosENativeToolMode = false
    Utility.FakePosENativeTool = nil
    Utility.FakePosENativeToolStatus = "idle"

    if not token or Utility.FakePosCombatToken == token then
        Utility.FakePosCombatHold = false
        Utility.FakePosCombatToken = 0
    end

    if Utility.FakePosEnabled and type(Utility.RestoreFakePosRoot) == "function" then
        Utility.RestoreFakePosRoot(root)
    end

    if Utility.FakePosEnabled and Utility.FakePosEHardSuspendActive then
        Utility.FakePosGeneration = Utility.FakePosGeneration + 1
        Utility.FakePosEHardSuspendActive = false
        Utility.FakePosCycleState = "restarting"
        Utility.RunFakePosLoop(Utility.FakePosGeneration)
    else
        Utility.FakePosEHardSuspendActive = false
    end

    if Utility.FakePosEnabled then
        Utility.FakePosCycleState = "ok"
        -- Reattach Fake Pos gun protection one heartbeat AFTER the fresh worker/return
        -- handoff. This prevents the E shot's native grip from being replaced while the
        -- server is still accepting the final combat/return packets.
        task.defer(function()
            RunService.Heartbeat:Wait()
            if not Unloaded
                and Utility.FakePosEnabled
                and not Utility.FakePosEThawActive
                and not Utility.FakePosENativeToolMode
                and type(Utility.UpdateFakePosToolCarrier) == "function"
            then
                Utility.UpdateFakePosToolCarrier(true)
            end
        end)
    end
end

-- Manual shots do not pass through AllIn1.ActivateWeapon, so give normal left-click
-- firing the SAME live-origin handoff. This runs as soon as MouseButton1 begins, then
-- the Fake Pos worker keeps HRP live only for the short server/weapon commit window.
track(UserInputService.InputBegan:Connect(function(input)
    if Unloaded
        or not Utility.FakePosEnabled
        or input.UserInputType ~= Enum.UserInputType.MouseButton1
        or Utility.InputBlocked()
    then
        return
    end

    local character = LocalPlayer.Character
    local tool = AllIn1.GetEquippedTool(character)
    if tool and tool.Parent and tool:IsDescendantOf(character) then
        Utility.BeginFakePosOriginHold(
            Utility.FakePosOriginShotHoldDuration,
            "manual-fire"
        )
    end
end))

Utility.PrepareFakePosToolForShot = function(tool)
    if not Utility.FakePosEnabled then
        return tool
    end

    if tool and tool:IsA("Tool") then
        Utility.FakePosForceTool = tool
        Utility.FakePosForceToolName = tool.Name
    end

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local liveTool = AllIn1.GetEquippedTool(character)

    -- Manual E hard-thaw uses the game's native Tool joint. Never call BindFakePosToolCarrier
    -- here or the local fallback weld can be recreated on the exact frame we fire.
    if Utility.FakePosEThawActive and Utility.FakePosENativeToolMode then
        if liveTool and type(Utility.ValidateFakePosNativeToolForE) == "function" then
            local nativeOK, nativeDetail = Utility.ValidateFakePosNativeToolForE(liveTool)
            if nativeOK and type(Utility.EnsureFakePosERealToolGlue) == "function" then
                local glued, glueDetail = Utility.EnsureFakePosERealToolGlue(liveTool)
                nativeOK = glued == true
                nativeDetail = nativeOK
                    and (tostring(nativeDetail) .. " / " .. tostring(glueDetail))
                    or tostring(glueDetail)
            end
            Utility.FakePosENativeToolStatus = nativeDetail
            if nativeOK then
                if root and type(Utility.BeginFakePosOriginHold) == "function" then
                    Utility.BeginFakePosOriginHold(
                        Utility.FakePosOriginShotHoldDuration,
                        "E-native-script-fire"
                    )
                end
                AllIn1.OriginBlockedUntil = 0
                return liveTool
            end
        end
        return nil
    end

    Utility.UpdateFakePosToolCarrier(true)
    if liveTool then
        Utility.BindFakePosToolCarrier(liveTool)

        -- Shot preflight uses the same bounded live-origin lease as manual firing.
        -- Keeping the lease alive for a few network frames is important: a one-frame
        -- root restore can be immediately undone by the normal Fake Pos nil cycle.
        if root and type(Utility.BeginFakePosOriginHold) == "function" then
            Utility.BeginFakePosOriginHold(
                Utility.FakePosOriginShotHoldDuration,
                "script-fire"
            )
        end
        AllIn1.OriginBlockedUntil = 0
        return liveTool
    end
    return nil
end

AllIn1.ResetTransientWeaponState = function(reason)
    -- A vanished/reparented Tool must not leave a stale muzzle, aim point, firing
    -- latch, or reload worker alive. Clearing only transient weapon state keeps
    -- C/E/H target selection and every unrelated feature untouched.
    AllIn1.Firing = false
    AllIn1.FiringUntil = 0
    AllIn1.ShotAimPosition = nil
    AllIn1.ShotTargetPart = nil
    AllIn1.ShotGeometryReady = false
    AllIn1.OriginLockPrepared = false
    AllIn1.LastFireInputDetail = tostring(reason or "tool state reset")

    -- Any origin/tool reset invalidates the current reload worker too. If the
    -- magazine is still empty, AutoReloadStep starts a fresh worker on the live
    -- equipped Tool instead of leaving a stale Reloading=true latch behind.
    if AllIn1.Reloading or AllIn1.ReloadTool then
        AllIn1.ReloadToken = AllIn1.ReloadToken + 1
        AllIn1.Reloading = false
        AllIn1.ReloadTool = nil
        AllIn1.ReloadHeartbeatAt = 0
    end
end

AllIn1.GetRecoverableTool = function()
    local character = LocalPlayer.Character
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if not character or not backpack then
        return nil
    end

    local last = AllIn1.LastEquippedTool
    if last and last:IsA("Tool") and last.Parent == backpack then
        return last
    end

    local lastName = tostring(AllIn1.LastEquippedToolName or "")
    if lastName ~= "" then
        for _, child in ipairs(backpack:GetChildren()) do
            if child:IsA("Tool") and child.Name == lastName then
                return child
            end
        end
    end

    return nil
end

AllIn1.CacheOriginTextObject = function(object)
    if object and (object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox")) then
        AllIn1.OriginTextCache[object] = true
    end
end

AllIn1.EnsureOriginTextCache = function()
    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not playerGui then
        return false
    end

    if AllIn1.OriginTextCacheReady and AllIn1.OriginTextCacheGui == playerGui then
        return true
    end

    -- Build this once, then maintain it incrementally. The previous recovery code
    -- called PlayerGui:GetDescendants() every 0.15s, allocating/traversing the
    -- complete UI tree repeatedly and causing the regular frametime spikes.
    AllIn1.OriginTextCache = setmetatable({}, { __mode = "k" })
    AllIn1.OriginTextCacheGui = playerGui
    AllIn1.OriginTextCacheReady = true

    for _, object in ipairs(playerGui:GetDescendants()) do
        AllIn1.CacheOriginTextObject(object)
    end

    track(playerGui.DescendantAdded:Connect(function(object)
        AllIn1.CacheOriginTextObject(object)
    end))
    track(playerGui.DescendantRemoving:Connect(function(object)
        AllIn1.OriginTextCache[object] = nil
    end))

    return true
end

AllIn1.ScanOriginLimitError = function()
    -- Origin recovery only matters while Fake Pos is active. Avoid doing any UI
    -- work at all during ordinary gameplay.
    if Unloaded or not Utility.FakePosEnabled then
        AllIn1.OriginErrorLatched = false
        return false
    end

    local now = os.clock()
    if now < (AllIn1.OriginScanNextAt or 0) then
        return AllIn1.OriginErrorLatched == true
    end
    AllIn1.OriginScanNextAt = now + (AllIn1.OriginScanInterval or 0.25)

    if not AllIn1.EnsureOriginTextCache() then
        return false
    end

    local found = false
    -- Scan only the cached text objects. DescendantAdded/Removing keeps this set
    -- current without repeatedly rebuilding the entire PlayerGui descendant list.
    for object in pairs(AllIn1.OriginTextCache) do
        if object and object.Parent then
            local ok, value = pcall(function()
                return string.upper(tostring(object.Text or ""))
            end)
            if ok and string.find(value, "ORIGIN EXCEEDS LIMIT", 1, true) then
                found = true
                break
            end
        else
            AllIn1.OriginTextCache[object] = nil
        end
    end

    if found then
        -- IMPORTANT: the warning text can remain visible after the underlying origin
        -- has already recovered. The old logic refreshed a 0.60s fire lock every scan,
        -- which made Fake Pos unable to shoot at all. Treat the warning as a repair
        -- signal only; never use persistent UI text as a hard fire gate.
        AllIn1.OriginBlockedUntil = 0
        if not AllIn1.OriginErrorLatched then
            AllIn1.OriginErrorLatched = true
            if type(Utility.BeginFakePosOriginHold) == "function" then
                Utility.BeginFakePosOriginHold(
                    Utility.FakePosOriginWarningHoldDuration,
                    "origin-warning"
                )
            else
                local character = LocalPlayer.Character
                local root = character and character:FindFirstChild("HumanoidRootPart")
                if root and type(Utility.RestoreFakePosRoot) == "function" then
                    Utility.RestoreFakePosRoot(root)
                end
            end
            notify("WEAPON", "origin warning detected | live origin repaired", "warning", 2.0)
        end
    else
        AllIn1.OriginErrorLatched = false
        AllIn1.OriginBlockedUntil = 0
    end

    return found
end

AllIn1.ToolRecoveryStep = function()
    if Unloaded then
        return
    end

    -- Manual E intentionally releases/rebuilds the normal game RightGrip. Do not let
    -- the background Fake Pos recovery worker race that deliberate native re-equip.
    if Utility.FakePosENativeToolMode then
        return
    end

    -- This used to walk Character/tool state every Heartbeat. 12.5 Hz is more
    -- than enough to catch an unexpected Tool reparent while avoiding per-frame
    -- GetChildren/recursive Tool searches and hook checks.
    local now = os.clock()
    if now < (AllIn1.ToolRecoveryScanNextAt or 0) then
        return
    end
    AllIn1.ToolRecoveryScanNextAt = now + (AllIn1.ToolRecoveryScanInterval or 0.08)

    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not character or not humanoid then
        return
    end

    local equipped = AllIn1.GetEquippedTool(character)
    if equipped and equipped.Parent and equipped:IsDescendantOf(character) then
        AllIn1.LastEquippedTool = equipped
        AllIn1.LastEquippedToolName = equipped.Name
        AllIn1.LastEquippedSeenAt = os.clock()
        AllIn1.EnsureReloadHook(equipped)
        hookTracerTool(equipped)
        return
    end

    -- Recovery is intentionally limited to Fake Pos. Outside Fake Pos, normal
    -- Roblox hotbar/equip behavior remains completely untouched.
    if not Utility.FakePosEnabled or AllIn1.ToolRecoveryBusy then
        return
    end

    if now < (AllIn1.ToolRecoveryNextAt or 0) then
        return
    end

    -- Only recover an actual recent disappearance. This prevents Fake Pos from
    -- fighting an intentional long-term unequip/empty-hands state.
    if now - (AllIn1.LastEquippedSeenAt or 0) > 0.45 then
        return
    end

    local candidate = AllIn1.GetRecoverableTool()
    if not candidate then
        return
    end

    AllIn1.ToolRecoveryBusy = true
    AllIn1.ToolRecoveryToken = (AllIn1.ToolRecoveryToken or 0) + 1
    local token = AllIn1.ToolRecoveryToken
    AllIn1.ToolRecoveryNextAt = now + (AllIn1.ToolRecoveryCooldown or 0.70)
    AllIn1.ResetTransientWeaponState("equipped tool moved to Backpack; reacquiring")

    task.spawn(function()
        task.wait(AllIn1.ToolRecoveryDelay or 0.08)
        if Unloaded or token ~= AllIn1.ToolRecoveryToken or not Utility.FakePosEnabled then
            if token == AllIn1.ToolRecoveryToken then
                AllIn1.ToolRecoveryBusy = false
            end
            return
        end

        local liveCharacter = LocalPlayer.Character
        local liveHumanoid = liveCharacter and liveCharacter:FindFirstChildOfClass("Humanoid")
        if liveCharacter and liveHumanoid and not AllIn1.GetEquippedTool(liveCharacter) then
            local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
            if backpack and candidate.Parent == backpack then
                -- Re-equip the same server-provided Tool instance once. Never clone,
                -- recreate, or force a Tool that the server actually removed.
                pcall(function()
                    liveHumanoid:EquipTool(candidate)
                end)
                RunService.Heartbeat:Wait()
            end
        end

        local recovered = liveCharacter and AllIn1.GetEquippedTool(liveCharacter) or nil
        if recovered then
            AllIn1.LastEquippedTool = recovered
            AllIn1.LastEquippedToolName = recovered.Name
            AllIn1.LastEquippedSeenAt = os.clock()
            AllIn1.EnsureReloadHook(recovered)
            hookTracerTool(recovered)
            AllIn1.LastFireInputDetail = "tool recovered: " .. tostring(recovered.Name)
        else
            AllIn1.LastFireInputDetail = "tool recovery unavailable; server/game did not return tool"
        end

        if token == AllIn1.ToolRecoveryToken then
            AllIn1.ToolRecoveryBusy = false
        end
    end)
end

AllIn1.GetWeaponCapacity = function(tool)
    if not tool then
        return nil
    end

    local name = string.lower(tostring(tool.Name or ""))
    local compact = string.gsub(name, "[^%w]", "")

    -- Exact supported magazines:
    -- Double-Barrel / DB = 2, Tactical Shotgun = 6, Silencer = 12, Revolver = 6.
    if compact == "db"
        or string.find(compact, "doublebarrel", 1, true)
    then
        return 2
    end

    if string.find(compact, "tacticalshotgun", 1, true)
        or string.find(compact, "tacticalshot", 1, true)
    then
        return 6
    end

    if string.find(compact, "silencer", 1, true) then
        return 12
    end

    if string.find(compact, "revolver", 1, true) then
        return 6
    end

    return nil
end

AllIn1.ReadAmmo = function(tool)
    if not tool then
        return nil, nil
    end

    for _, name in ipairs({
        "Ammo",
        "AMMO",
        "CurrentAmmo",
        "Current Ammo",
        "Bullets",
        "Clip",
        "Magazine",
        "AmmoCount",
        "AmmoLeft",
        "LoadedAmmo",
        "CurrentBullets",
    }) do
        local object = tool:FindFirstChild(name, true)
        if object then
            local ok, value = pcall(function()
                return tonumber(object.Value)
            end)
            if ok and value ~= nil then
                return value, object
            end
        end
    end

    for _, name in ipairs({
        "Ammo",
        "AMMO",
        "CurrentAmmo",
        "Current Ammo",
        "Bullets",
        "Clip",
        "Magazine",
        "AmmoCount",
        "AmmoLeft",
        "LoadedAmmo",
        "CurrentBullets",
    }) do
        local ok, value = pcall(function()
            return tool:GetAttribute(name)
        end)
        value = ok and tonumber(value) or nil
        if value ~= nil then
            return value, name
        end
    end

    return nil, nil
end

AllIn1.GetMainEvent = function()
    local event = ReplicatedStorage:FindFirstChild("MainEvent")
        or ReplicatedStorage:FindFirstChild("MainEvent", true)

    if event and event:IsA("RemoteEvent") then
        return event
    end

    return nil
end

AllIn1.PressReloadKey = function()
    -- Send ONE real R-key path per reload pulse. Double-sending executor input
    -- plus VirtualInput on the same frame could toggle/restart some gun reloads.
    if type(keypress) == "function" and type(keyrelease) == "function" then
        local ok = pcall(function()
            keypress(0x52)
            task.delay(0.018, function()
                pcall(keyrelease, 0x52)
            end)
        end)
        if ok then
            return true
        end
    end

    local okService, virtualInput = pcall(function()
        return game:GetService("VirtualInputManager")
    end)
    if okService and virtualInput then
        return pcall(function()
            virtualInput:SendKeyEvent(true, Enum.KeyCode.R, false, game)
            task.delay(0.018, function()
                pcall(function()
                    virtualInput:SendKeyEvent(false, Enum.KeyCode.R, false, game)
                end)
            end)
        end)
    end

    return false
end

AllIn1.IssueReload = function(tool)
    if not tool or not tool.Parent then
        return false
    end

    local hMode = MultiTarget.Running == true
    local backgroundH = hMode and Utility.WindowFocused == false
    local event = AllIn1.GetMainEvent()
    local sent = false

    -- H reload reliability: a pcall-successful keypress can still be ignored by
    -- Roblox/game input. While H owns the gun, keep the real R path AND periodically
    -- send the game's direct reload paths. The reload worker still stops only when
    -- readable ammo reaches the exact weapon capacity, so this cannot stop early.
    if AllIn1.PressReloadKey then
        local ok = AllIn1.PressReloadKey()
        sent = ok or sent
    end

    if hMode then
        AllIn1.ReloadPulseIndex = (AllIn1.ReloadPulseIndex or 0) + 1
        local directPulse = backgroundH or (AllIn1.ReloadPulseIndex % 3 == 0)
        if directPulse and event then
            local ok = pcall(function()
                event:FireServer("Reload", tool)
            end)
            sent = ok or sent
        end

        if directPulse then
            for _, name in ipairs({ "Reload", "ReloadEvent", "ReloadRemote" }) do
                local remote = tool:FindFirstChild(name, true)
                if remote and remote:IsA("RemoteEvent") then
                    local ok = pcall(function()
                        remote:FireServer()
                    end)
                    sent = ok or sent
                end
            end
        end

        return sent
    end

    -- Manual E/non-H behavior stays conservative and keeps the original fallback
    -- order so unrelated weapon behavior is not changed.
    if sent then
        return true
    end

    if event then
        local ok = pcall(function()
            event:FireServer("Reload", tool)
        end)
        if ok then
            return true
        end
    end

    for _, name in ipairs({ "Reload", "ReloadEvent", "ReloadRemote" }) do
        local remote = tool:FindFirstChild(name, true)
        if remote and remote:IsA("RemoteEvent") then
            local ok = pcall(function()
                remote:FireServer()
            end)
            if ok then
                return true
            end
        end
    end

    return false
end

AllIn1.StartReload = function(tool, forceFull)
    if Unloaded or not tool or not tool.Parent then
        return false
    end

    local capacity = AllIn1.GetWeaponCapacity(tool)
    if not capacity then
        return false
    end

    forceFull = forceFull == true

    -- Normal E/heartbeat behavior stays EMPTY-ONLY. H miss recovery is the one
    -- explicit exception: after H has already returned to void, forceFull=true
    -- may top off the same supported gun before retrying that target.
    local ammo = AllIn1.ReadAmmo(tool)
    local predictedEmpty = ammo == nil and (AllIn1.ShotCounts[tool] or 0) >= capacity
    if ammo ~= nil then
        if ammo >= capacity then
            AllIn1.ShotCounts[tool] = 0
            return true
        end
        if not forceFull and ammo > 0 then
            return false
        end
    elseif not forceFull and not predictedEmpty then
        return false
    end

    if AllIn1.Reloading and AllIn1.ReloadTool == tool then
        return true
    end

    AllIn1.ReloadToken = AllIn1.ReloadToken + 1
    local token = AllIn1.ReloadToken
    AllIn1.Reloading = true
    AllIn1.ReloadTool = tool
    AllIn1.ReloadHeartbeatAt = os.clock()

    task.spawn(function()
        local unknownAmmoRequests = 0

        while not Unloaded
            and AllIn1.Reloading
            and AllIn1.ReloadToken == token
            and tool
            and tool.Parent
        do
            AllIn1.ReloadHeartbeatAt = os.clock()
            -- R is a global input. If this specific reload tool is no longer the
            -- equipped Tool, stop this worker immediately so its R-spam can never
            -- leak into the next H target / newly equipped gun.
            local reloadCharacter = LocalPlayer.Character
            if not reloadCharacter or not tool:IsDescendantOf(reloadCharacter) then
                break
            end

            local currentAmmo = AllIn1.ReadAmmo(tool)

            if currentAmmo ~= nil then
                -- Once an EMPTY mag triggered this worker, keep pulsing R until
                -- the exact supported capacity is actually observed. Partial ammo
                -- never starts a worker, but it also never stops an already-valid
                -- empty-mag reload halfway through.
                if currentAmmo >= capacity then
                    AllIn1.ShotCounts[tool] = 0
                    break
                end

                AllIn1.IssueReload(tool)
                task.wait(AllIn1.ReloadInterval)
            else
                -- Last-resort fallback only for games that do not replicate an ammo
                -- value. Keep this bounded so an unreadable tool cannot create a
                -- permanent R loop; the shot counter remains the empty detector.
                if unknownAmmoRequests >= AllIn1.ReloadUnknownPulseLimit then
                    AllIn1.ShotCounts[tool] = 0
                    break
                end
                AllIn1.IssueReload(tool)
                unknownAmmoRequests = unknownAmmoRequests + 1
                task.wait(AllIn1.ReloadInterval)
            end
        end

        local finalAmmo = AllIn1.ReadAmmo(tool)
        if finalAmmo ~= nil and finalAmmo >= capacity then
            AllIn1.ShotCounts[tool] = 0
        end

        if AllIn1.ReloadToken == token then
            AllIn1.Reloading = false
            AllIn1.ReloadTool = nil
            AllIn1.ReloadHeartbeatAt = 0
        end
    end)

    return true
end

AllIn1.RecordShot = function(tool)
    if Unloaded or not tool or not tool.Parent or AllIn1.Reloading then
        return
    end

    local capacity = AllIn1.GetWeaponCapacity(tool)
    if not capacity then
        return
    end

    -- One physical shot can be observed through Tool.Activated AND through our
    -- explicit fire path. Dedupe them so DB=2, TAC=6, REV=6 and SILENCER=12
    -- can never be double-counted when ammo itself is not readable.
    local now = os.clock()
    local last = AllIn1.LastShotSignal[tool] or 0
    if now - last < 0.03 then
        return
    end
    AllIn1.LastShotSignal[tool] = now

    local ammo = AllIn1.ReadAmmo(tool)
    if ammo ~= nil then
        -- Ammo replication can decrement one frame after the click. The global
        -- heartbeat watcher catches the exact 0; do not guess an early reload.
        if ammo <= 0 then
            task.defer(function()
                AllIn1.StartReload(tool)
            end)
        elseif ammo >= capacity then
            AllIn1.ShotCounts[tool] = 0
        end
        return
    end

    local count = math.min(capacity, (AllIn1.ShotCounts[tool] or 0) + 1)
    AllIn1.ShotCounts[tool] = count
    if count >= capacity then
        task.defer(function()
            AllIn1.StartReload(tool)
        end)
    end
end

AllIn1.EnsureReloadHook = function(tool)
    if not tool or AllIn1.ReloadHooked[tool] then
        return
    end

    if not AllIn1.GetWeaponCapacity(tool) then
        return
    end

    AllIn1.ReloadHooked[tool] = true
    track(tool.Activated:Connect(function()
        AllIn1.RecordShot(tool)
    end))
end

AllIn1.AutoReloadStep = function()
    if Unloaded then
        return
    end

    -- QOL watchdog: a runtime error inside an old reload coroutine must never
    -- permanently block future reloads. A healthy worker updates this every loop.
    if AllIn1.Reloading then
        local reloadTool = AllIn1.ReloadTool
        local heartbeatAge = os.clock() - (AllIn1.ReloadHeartbeatAt or 0)
        if not reloadTool or not reloadTool.Parent or heartbeatAge > 0.80 then
            AllIn1.ReloadToken = AllIn1.ReloadToken + 1
            AllIn1.Reloading = false
            AllIn1.ReloadTool = nil
            AllIn1.ReloadHeartbeatAt = 0
        end
    end

    local character = LocalPlayer.Character
    local tool = AllIn1.GetEquippedTool(character)
    if not tool then
        return
    end

    local capacity = AllIn1.GetWeaponCapacity(tool)
    if not capacity then
        return
    end

    AllIn1.EnsureReloadHook(tool)

    local ammo = AllIn1.ReadAmmo(tool)
    if ammo ~= nil then
        if ammo <= 0 then
            AllIn1.StartReload(tool)
        elseif ammo >= capacity then
            AllIn1.ShotCounts[tool] = 0
        end
    elseif (AllIn1.ShotCounts[tool] or 0) >= capacity then
        AllIn1.StartReload(tool)
    end
end

AllIn1.StompVerified = function(target, originalCharacter)
    if not target then
        return true
    end

    local currentCharacter = target.Character
    if not currentCharacter or currentCharacter ~= originalCharacter then
        return true
    end

    if not currentCharacter.Parent then
        return true
    end

    local humanoid = currentCharacter:FindFirstChildOfClass("Humanoid")

    local bodyEffects = currentCharacter:FindFirstChild("BodyEffects")
    local dead = bodyEffects and (bodyEffects:FindFirstChild("Dead")
        or bodyEffects:FindFirstChild("DEAD"))
    if dead then
        local ok, value = pcall(function()
            return dead.Value
        end)
        if ok and value == true then
            return true
        end
    end

    local deadAttribute = currentCharacter:GetAttribute("Dead")
    if deadAttribute == true then
        return true
    end

    -- A KO body can still report zero/near-zero health before the stomp. Do
    -- not mistake that pre-stomp state for verification. Zero health only
    -- confirms the stomp after the KO flag has cleared.
    if humanoid and humanoid.Health <= 0 and not isKnockedOut(target) then
        return true
    end

    return false
end

AllIn1.PerformStomp = function(targetUserId, character)
    local target = findPlayerByUserId(targetUserId)
    if not target then
        return true
    end

    local originalCharacter = target.Character
    if not originalCharacter then
        return true
    end

    local event = AllIn1.GetMainEvent()
    if not event then
        return false
    end

    AllIn1.StompToken = (AllIn1.StompToken or 0) + 1
    local stompToken = AllIn1.StompToken
    AllIn1.Stomping = true

    while not Unloaded
        and AllIn1.Busy
        and AllIn1.StompToken == stompToken
    do
        target = findPlayerByUserId(targetUserId)
        if AllIn1.StompVerified(target, originalCharacter) then
            AllIn1.Stomping = false
            return true
        end

        local liveTargetPart = getTargetPart(target)
        local liveCharacter = LocalPlayer.Character
        local liveRoot = liveCharacter and liveCharacter:FindFirstChild("HumanoidRootPart")

        -- If our own character was replaced/cancelled, this stomp attempt cannot
        -- safely continue. Do NOT mark it verified; H will recover on respawn.
        if liveCharacter ~= character or not liveRoot then
            break
        end

        if liveTargetPart then
            -- FULL HRP glue every Heartbeat. Keep the critical stomp path tiny:
            -- no reload polling/timers here, so later targets stomp at the exact
            -- same cadence as the first target.
            local glued = liveTargetPart.CFrame
            liveCharacter:PivotTo(glued)
            liveRoot.CFrame = glued
            liveRoot.Anchored = false
            liveRoot.AssemblyLinearVelocity = Vector3.zero
            liveRoot.AssemblyAngularVelocity = Vector3.zero
        end

        -- One pulse EVERY Heartbeat. The previous 0.018-second gate was slightly
        -- slower than a 60 Hz frame (~0.0167) and could fall to every other frame
        -- under load, which is what made later stomps feel slow/sloppy.
        pcall(function()
            event:FireServer("Stomp")
        end)

        RunService.Heartbeat:Wait()
    end

    AllIn1.Stomping = false
    return AllIn1.StompVerified(findPlayerByUserId(targetUserId), originalCharacter)
end

AllIn1.ActivateWeapon = function(tool, pass)
    -- Fake Pos gets one immediate carrier repair before any fire input. This forces
    -- the real Handle/right-hand/HRP chain back live instead of firing from a stale
    -- or backpacked Tool reference.
    if Utility.FakePosEnabled and type(Utility.PrepareFakePosToolForShot) == "function" then
        local preparedTool = Utility.PrepareFakePosToolForShot(tool)
        if Utility.FakePosEThawActive and Utility.FakePosENativeToolMode and not preparedTool then
            AllIn1.LastFireInputDetail = "E native gun chain not ready: "
                .. tostring(Utility.FakePosENativeToolStatus or "unknown")
            return false
        end
        tool = preparedTool or tool
    end

    -- Always reacquire the live Character Tool immediately before a fire input.
    -- A gun moved to Backpack can otherwise leave E/H holding a stale Tool/muzzle
    -- reference and repeatedly trigger origin/cooldown errors.
    local character = LocalPlayer.Character
    local liveTool = AllIn1.GetEquippedTool(character)
    if liveTool and liveTool.Parent and liveTool:IsDescendantOf(character) then
        tool = liveTool
        AllIn1.LastEquippedTool = liveTool
        AllIn1.LastEquippedToolName = liveTool.Name
        AllIn1.LastEquippedSeenAt = os.clock()
    end

    if not tool or not character or not tool.Parent or not tool:IsDescendantOf(character) then
        AllIn1.LastFireInputDetail = "no live equipped tool (stale/unequipped reference blocked)"
        return false
    end

    -- A successful pcall only means the input API itself did not error; it does NOT
    -- prove the gun accepted the shot. Rotate through normal client-side activation
    -- paths on subsequent retries, while the shot loop verifies acceptance by watching
    -- the real magazine value. This avoids sitting through a full damage timeout after
    -- a click that Roblox/game input simply ignored.
    pass = math.max(1, tonumber(pass) or 1)
    local equipped = tool and tool.Parent and character and tool:IsDescendantOf(character)

    if equipped and tool:IsA("Tool") and tool.Enabled == false then
        AllIn1.LastFireInputDetail = "Tool.Enabled=false (cooldown/not ready)"
        return false
    end

    -- Reject a stale/detached muzzle before sending any fire input. The Tool may still
    -- be parented to Character for a frame while its Handle/muzzle is at an old origin.
    -- This is a local sanity gate only; it does not bypass server origin validation.
    local liveRoot = character and character:FindFirstChild("HumanoidRootPart")
    local _, liveMuzzle = getWeaponMuzzle(tool)
    if liveRoot and liveMuzzle and (liveMuzzle - liveRoot.Position).Magnitude > 12 then
        AllIn1.LastFireInputDetail = string.format(
            "stale weapon origin blocked (muzzle %.1f studs from root)",
            (liveMuzzle - liveRoot.Position).Magnitude
        )
        return false
    end

    local backgroundH = MultiTarget.Running and Utility.WindowFocused == false
    if backgroundH then
        -- Tool:Activate() is the only real Tool-native activation path here. Calling
        -- firesignal(Tool.Activated) merely invokes listeners and can report success
        -- without the weapon consuming ammo, which caused repeated false accepts.
        if equipped then
            local ok = pcall(function()
                tool:Activate()
            end)
            AllIn1.LastFireInputDetail = ok and "Tool:Activate()" or "Tool:Activate failed"
            return ok
        end

        AllIn1.LastFireInputDetail = "background H has no usable equipped tool path"
        return false
    end

    -- Foreground E/H rotates real input methods ONLY after the previous method produced
    -- no ammo decrease. Prefer Tool:Activate first because it does not depend on OS
    -- mouse injection; keep mouse paths as bounded fallbacks.
    local method = ((pass - 1) % 3) + 1
    if method == 1 and equipped then
        local ok = pcall(function()
            tool:Activate()
        end)
        AllIn1.LastFireInputDetail = ok and "Tool:Activate()" or "Tool:Activate failed"
        return ok
    elseif method == 2 and type(mouse1click) == "function" then
        local ok = pcall(mouse1click)
        AllIn1.LastFireInputDetail = ok and "mouse1click" or "mouse1click failed"
        return ok
    elseif method == 3 and type(mouse1press) == "function" and type(mouse1release) == "function" then
        local ok = pcall(mouse1press)
        if ok then
            task.delay(0.018, function()
                pcall(mouse1release)
            end)
        end
        AllIn1.LastFireInputDetail = ok and "mouse1press/release" or "mouse1press failed"
        return ok
    end

    -- If the chosen path is unavailable, fall back to the equipped Tool path; the
    -- magazine acceptance check still decides whether the weapon truly fired.
    if equipped then
        local ok = pcall(function()
            tool:Activate()
        end)
        AllIn1.LastFireInputDetail = ok and "Tool:Activate() fallback" or "fallback failed"
        return ok
    end

    AllIn1.LastFireInputDetail = "no usable fire input path"
    return false
end

AllIn1.IsIgnorableShotHelper = function(instance)
    if not instance or not instance.Parent then
        return false
    end

    -- Hood-style character rigs can spawn non-damage helper limbs outside the
    -- actual Character model (for example LeftLowerLegFake). Those pieces are
    -- visual/rigging geometry and must never fail E's local muzzle LOS gate.
    local current = instance
    for _ = 1, 5 do
        if not current then
            break
        end

        local name = string.lower(tostring(current.Name or ""))
        if name:match("fake$")
            or name:find("proxy", 1, true) ~= nil
            or name:find("decoy", 1, true) ~= nil
        then
            return true
        end

        current = current.Parent
    end

    if Utility.FakePosGhost
        and Utility.FakePosGhost.Parent
        and instance:IsDescendantOf(Utility.FakePosGhost)
    then
        return true
    end

    if VisualWorldFolder
        and VisualWorldFolder.Parent
        and instance:IsDescendantOf(VisualWorldFolder)
    then
        return true
    end

    return false
end

AllIn1.HasClearShot = function(tool, targetPart)
    if not targetPart or not targetPart.Parent then
        AllIn1.LastLOSDetail = "invalid target part"
        return false
    end

    local muzzlePart, origin = getWeaponMuzzle(tool)
    if not origin then
        local character = LocalPlayer.Character
        local head = character and character:FindFirstChild("Head")
        local root = character and character:FindFirstChild("HumanoidRootPart")
        origin = head and head.Position
            or (root and root.Position)
            or (Camera and Camera.CFrame.Position)
    end
    if not origin then
        AllIn1.LastLOSDetail = "no valid muzzle/head/root origin"
        return false
    end

    local delta = targetPart.Position - origin
    if delta.Magnitude <= 0.05 then
        AllIn1.LastLOSDetail = "clear: origin already at target corridor"
        return true
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = {}
    local localCharacter = LocalPlayer.Character
    if localCharacter then
        -- This excludes our body, equipped tool and our own accessories in one go.
        table.insert(ignore, localCharacter)
    end
    -- Some tools can briefly be reparented during equip/activation; exclude the tool
    -- explicitly too so a stale parent never causes a false self-LOS block.
    if tool and tool.Parent and (not localCharacter or not tool:IsDescendantOf(localCharacter)) then
        table.insert(ignore, tool)
    end
    if VisualWorldFolder then
        table.insert(ignore, VisualWorldFolder)
    end
    if AllIn1.AppendGrassIgnores then
        AllIn1.AppendGrassIgnores(ignore)
    end
    if AllIn1.AppendMapIgnores then
        AllIn1.AppendMapIgnores(ignore)
    end
    params.FilterDescendantsInstances = ignore
    params.IgnoreWater = true

    local targetCharacter = targetPart.Parent
    for _ = 1, 10 do
        local result = Workspace:Raycast(origin, delta, params)
        if not result or not result.Instance then
            AllIn1.LastLOSDetail = string.format(
                "clear: no obstruction (muzzle %s, %.2f studs)",
                muzzlePart and muzzlePart.Name or "fallback",
                delta.Magnitude
            )
            return true
        end

        local hit = result.Instance
        local helperGeometry = AllIn1.IsIgnorableShotHelper
            and AllIn1.IsIgnorableShotHelper(hit)

        -- Never let a non-damage helper limb/proxy stop E. Recast the exact same
        -- muzzle corridor after excluding only that helper. Real map geometry and
        -- real character body parts are still handled normally.
        if helperGeometry then
            table.insert(ignore, hit)
            params.FilterDescendantsInstances = ignore
            AllIn1.LastLOSDetail = string.format(
                "skipped helper geometry %s [%s] at %.2f studs",
                hit.Name,
                hit.ClassName,
                (result.Position - origin).Magnitude
            )
        elseif targetCharacter and hit:IsDescendantOf(targetCharacter) then
            -- Any real body part/accessory belonging to the intended target is a
            -- valid LOS path. Final shot geometry still resolves the exact damageable
            -- surface immediately before the fire input.
            AllIn1.LastLOSDetail = string.format(
                "clear: target geometry %s [%s] at %.2f studs",
                hit.Name,
                hit.ClassName,
                (result.Position - origin).Magnitude
            )
            return true
        else
            AllIn1.LastLOSDetail = string.format(
                "blocked by %s [%s] at %.2f studs%s",
                hit.Name,
                hit.ClassName,
                (result.Position - origin).Magnitude,
                hit.Parent and (" in " .. hit.Parent.Name) or ""
            )
            return false
        end
    end

    AllIn1.LastLOSDetail = "blocked: too many helper-geometry intersections"
    return false
end

-- Resolve the FINAL shot geometry from the real weapon muzzle.  Prediction is
-- only accepted when that exact ray actually intersects the intended character.
-- If the predicted point misses (common with CFrame/fly movement), fall back to
-- the freshest HRP point and use the first real target surface hit.  This keeps
-- Mouse.Target / Mouse.Hit / UnitRay internally consistent without changing the
-- targeting, queue, reload, or movement systems.
AllIn1.ResolveShotGeometry = function(tool, targetPart, proposedPosition)
    if not targetPart or not targetPart.Parent then
        AllIn1.LastShotRayDetail = "invalid target geometry"
        return nil, nil, false
    end

    local _, origin = getWeaponMuzzle(tool)
    if not origin then
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local head = character and character:FindFirstChild("Head")
        origin = root and root.Position
            or (head and head.Position)
            or (Camera and Camera.CFrame.Position)
    end
    if not origin then
        AllIn1.LastShotRayDetail = "no muzzle/root origin"
        return nil, nil, false
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = {}
    local localCharacter = LocalPlayer.Character
    if localCharacter then table.insert(ignore, localCharacter) end
    if tool and tool.Parent and (not localCharacter or not tool:IsDescendantOf(localCharacter)) then
        table.insert(ignore, tool)
    end
    if VisualWorldFolder then table.insert(ignore, VisualWorldFolder) end
    if AllIn1.AppendGrassIgnores then
        AllIn1.AppendGrassIgnores(ignore)
    end
    if AllIn1.AppendMapIgnores then
        AllIn1.AppendMapIgnores(ignore)
    end
    params.FilterDescendantsInstances = ignore
    params.IgnoreWater = true

    local targetCharacter = targetPart.Parent
    local function probe(point, label)
        if typeof(point) ~= "Vector3" then return nil, nil end
        local delta = point - origin
        if delta.Magnitude <= 0.01 then return nil, nil end
        -- Extend very slightly past the requested point so a point on/inside the
        -- HRP cannot end the ray just before the visible body surface.
        local direction = delta.Unit * math.max(delta.Magnitude + 2.0, 4.0)
        -- Cosmetics/accessory Handles can be the first target descendant the local
        -- ray sees, but many gun systems do not treat those as damageable body hits.
        -- Skip only helper/cosmetic geometry and keep probing along the exact
        -- same ray until a real character body part or real obstruction is reached.
        for _ = 1, 10 do
            local result = Workspace:Raycast(origin, direction, params)
            if not result or not result.Instance then
                AllIn1.LastShotRayDetail = label .. " ray did not intersect target"
                return nil, nil
            end

            local helperGeometry = AllIn1.IsIgnorableShotHelper
                and AllIn1.IsIgnorableShotHelper(result.Instance)

            if helperGeometry then
                -- A fake/proxy limb can exist outside LocalPlayer.Character, so the
                -- normal character exclusion does not always catch it. Exclude only
                -- that helper and continue along the identical muzzle ray.
                table.insert(ignore, result.Instance)
                params.FilterDescendantsInstances = ignore
                AllIn1.LastShotRayDetail = string.format(
                    "%s skipped helper geometry %s [%s]",
                    label,
                    result.Instance.Name,
                    result.Instance.ClassName
                )
            elseif targetCharacter and result.Instance:IsDescendantOf(targetCharacter) then
                local cosmetic = result.Instance:FindFirstAncestorOfClass("Accessory")
                    or result.Instance:FindFirstAncestorOfClass("Tool")
                if cosmetic and cosmetic:IsDescendantOf(targetCharacter) then
                    table.insert(ignore, cosmetic)
                    params.FilterDescendantsInstances = ignore
                else
                    local hitPoint = result.Position
                    AllIn1.LastShotRayDetail = string.format(
                        "%s body hit %s [%s] at %.2f studs",
                        label,
                        result.Instance.Name,
                        result.Instance.ClassName,
                        (hitPoint - origin).Magnitude
                    )
                    return hitPoint, result.Instance
                end
            else
                AllIn1.LastShotRayDetail = string.format(
                    "%s blocked by %s [%s] at %.2f studs",
                    label,
                    result.Instance.Name,
                    result.Instance.ClassName,
                    (result.Position - origin).Magnitude
                )
                return nil, nil
            end
        end

        AllIn1.LastShotRayDetail = label .. " only intersected target cosmetics"
        return nil, nil
    end

    -- First try the existing prediction. If it is actually on the body, keep it.
    local hitPoint, hitPart = probe(proposedPosition, "predicted")
    if hitPoint then
        return hitPoint, hitPart, true
    end

    -- CFrame/fly movement can make even a sensible prediction point fall outside
    -- the body on the exact firing heartbeat. Fresh HRP center is the safest
    -- close-range fallback because the local character is already glued to it.
    hitPoint, hitPart = probe(targetPart.Position, "direct")
    if hitPoint then
        return hitPoint, hitPart, true
    end

    return nil, nil, false
end

AllIn1.ReleaseAttackAnchor = function()
    local root = AllIn1.AttackAnchoredRoot
    AllIn1.AttackAnchoredRoot = nil
    if root and root.Parent then
        pcall(function()
            root.Anchored = false
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
    end
end

AllIn1.HookAndAnchorToTarget = function(character, targetPart, angle, angularSpeed)
    if not character or not targetPart or not targetPart.Parent then
        return nil
    end

    local root = character:FindFirstChild("HumanoidRootPart")
    if not root then
        AllIn1.ReleaseAttackAnchor()
        return nil
    end

    if AllIn1.AttackAnchoredRoot and AllIn1.AttackAnchoredRoot ~= root then
        AllIn1.ReleaseAttackAnchor()
    end

    local motion = AllIn1.SampleTargetMotion(targetPart, os.clock())
    if not motion then
        return nil
    end

    local targetPosition = motion.Position
    -- Use the freshest readable HRP position for the physical hook. Motion.Position can
    -- be one sample old on direct-CFrame/flintlock movement, which previously produced
    -- absurd post-hook distances (hundreds of millions of studs) before the next heartbeat.
    pcall(function()
        local livePosition = targetPart.Position
        if typeof(livePosition) == "Vector3" then
            targetPosition = livePosition
        end
    end)
    local targetVelocity = motion.EffectiveVelocity or motion.AssemblyVelocity or Vector3.zero
    local speed = targetVelocity.Magnitude
    local matchVelocityCap = math.min(
        AllIn1.ObservedMotionCap,
        math.max(AllIn1.MatchVelocityCap, speed * 1.05)
    )
    local replicatedVelocity = targetVelocity
    if speed > matchVelocityCap and speed > 0 then
        replicatedVelocity = targetVelocity.Unit * matchVelocityCap
    end

    -- Keep the physical hook on the freshest HRP. The forward correction is tiny
    -- and distance-capped so very fast motion does not put the local character
    -- several studs ahead of the target.
    local followPosition = targetPosition
    if speed >= AllIn1.FastTargetSpeed and speed > 0 then
        local followLeadTime = motion.CFrameMotion and 0.00035 or 0.00055
        local followLead = targetVelocity * followLeadTime
        local followLeadCap = motion.CFrameMotion and 0.45 or 0.60
        if followLead.Magnitude > followLeadCap then
            followLead = followLead.Unit * followLeadCap
        end
        followPosition = followPosition + followLead
    end

    angle = tonumber(angle) or 0
    angularSpeed = tonumber(angularSpeed) or 0
    local radius = tonumber(AllIn1.OrbitRadius) or 1.5
    local offset = Vector3.new(
        math.sin(angle) * radius,
        0,
        math.cos(angle) * radius
    )
    local hookPosition = followPosition + offset
    local desired = CFrame.lookAt(hookPosition, followPosition)

    -- If we are orbiting, also mirror the tangential velocity that our repeated
    -- CFrame writes imply. Previously the HRP could visibly circle while reporting
    -- only the target's velocity (or zero on a stationary target), producing a
    -- client/server origin mismatch even against people who were not moving.
    if angularSpeed ~= 0 then
        local tangential = Vector3.new(
            math.cos(angle) * radius * angularSpeed,
            0,
            -math.sin(angle) * radius * angularSpeed
        )
        replicatedVelocity = replicatedVelocity + tangential
    end

    local ok = pcall(function()
        root.Anchored = false
        character:PivotTo(desired)
        root.CFrame = desired
        root.AssemblyLinearVelocity = replicatedVelocity
        -- Orientation is hard-written by CFrame.lookAt every frame. Do not also
        -- inject self-spin angular velocity; that can fight the facing direction.
        root.AssemblyAngularVelocity = Vector3.zero
    end)
    if not ok then
        AllIn1.ReleaseAttackAnchor()
        return nil
    end

    -- One bounded same-heartbeat correction for targets that direct-CFrame again
    -- between our motion sample and PivotTo. This is intentionally only one retry so
    -- a teleporting target cannot create an expensive inner loop or a frametime spike.
    pcall(function()
        local newestTargetPosition = targetPart.Position
        local drift = (root.Position - newestTargetPosition).Magnitude
        if drift > math.max(12, radius + 8) then
            local correctedFollow = newestTargetPosition
            if speed >= AllIn1.FastTargetSpeed and speed > 0 then
                local correctionLeadTime = motion.CFrameMotion and 0.00035 or 0.00055
                local correctionLead = targetVelocity * correctionLeadTime
                local correctionCap = motion.CFrameMotion and 0.45 or 0.60
                if correctionLead.Magnitude > correctionCap then
                    correctionLead = correctionLead.Unit * correctionCap
                end
                correctedFollow = correctedFollow + correctionLead
            end
            local correctedPosition = correctedFollow + offset
            local correctedCFrame = CFrame.lookAt(correctedPosition, correctedFollow)
            character:PivotTo(correctedCFrame)
            root.CFrame = correctedCFrame
            root.AssemblyLinearVelocity = replicatedVelocity
            root.AssemblyAngularVelocity = Vector3.zero
        end
    end)

    AllIn1.AttackAnchoredRoot = root
    return root
end

AllIn1.EquipDoubleBarrel = function(character, humanoid, forceDB)
    if not character or not humanoid then
        return AllIn1.GetEquippedTool(character)
    end

    local function isDoubleBarrel(tool)
        if not tool or not tool:IsA("Tool") then
            return false
        end
        local compact = string.gsub(string.lower(tostring(tool.Name or "")), "[^%w]", "")
        return compact == "db" or string.find(compact, "doublebarrel", 1, true) ~= nil
    end

    local equipped = AllIn1.GetEquippedTool(character)
    if equipped then
        if isDoubleBarrel(equipped) then
            return equipped
        end

        -- Do not hide/swap a gun the user manually pulled out. E/H can use every
        -- supported magazine type already handled by the shared reload system.
        -- Slot 1 is forced only for explicit respawn recovery.
        local readableAmmo = AllIn1.ReadAmmo(equipped)
        if forceDB ~= true and (AllIn1.GetWeaponCapacity(equipped) or readableAmmo ~= nil) then
            return equipped
        end
    end

    if forceDB ~= true and equipped then
        -- Unknown equipped Tool: leave it alone instead of forcibly making it
        -- disappear. The caller can decide whether that Tool is usable.
        return equipped
    end

    -- Slot 1 is the user's Double Barrel. Send the normal hotbar key first so
    -- respawn recovery gets the same equip input it would receive from the player.
    if type(keypress) == "function" and type(keyrelease) == "function" then
        pcall(function()
            keypress(0x31)
            task.delay(0.01, function()
                pcall(keyrelease, 0x31)
            end)
        end)
    end

    pcall(function()
        local virtualInput = game:GetService("VirtualInputManager")
        virtualInput:SendKeyEvent(true, Enum.KeyCode.One, false, game)
        task.delay(0.01, function()
            pcall(function()
                virtualInput:SendKeyEvent(false, Enum.KeyCode.One, false, game)
            end)
        end)
    end)

    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if backpack then
        for _, child in ipairs(backpack:GetChildren()) do
            if isDoubleBarrel(child) then
                pcall(function()
                    humanoid:EquipTool(child)
                end)
                break
            end
        end
    end

    RunService.Heartbeat:Wait()
    return AllIn1.GetEquippedTool(LocalPlayer.Character)
end

-- Compact miss stack modelled after the supplied video: thin dark rows are
-- drawn over the right side of the target indicator, with the prefix in normal
-- GUI text and only the reason highlighted red. It intentionally reuses the
-- current Theme so it looks like part of this menu rather than a second UI.
AllIn1.ShotIssueCards = {}
AllIn1.ShotIssueHolder = new("Frame", {
    Name = "ShotIssueHolder",
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -7, 0, 7),
    Size = UDim2.fromOffset(494, 330),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ZIndex = 80,
}, TargetHUD)

AllIn1.ShotIssueLayout = new("UIListLayout", {
    FillDirection = Enum.FillDirection.Vertical,
    HorizontalAlignment = Enum.HorizontalAlignment.Right,
    VerticalAlignment = Enum.VerticalAlignment.Top,
    Padding = UDim.new(0, 1),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, AllIn1.ShotIssueHolder)

AllIn1.ShowShotIssue = function(reason)
    if Unloaded or not AllIn1.ShotIssueHolder or not AllIn1.ShotIssueHolder.Parent then
        return
    end

    -- Keep the COMPLETE diagnostic. The previous version shortened
    -- "no HP/armor registration" to "no registration" and used AtEnd, so the
    -- useful half of the reason was invisible. Only RichText metacharacters are
    -- escaped now; the actual reason text is left untouched.
    local clean = tostring(reason or "unknown reason")
    clean = string.gsub(clean, "&", "&amp;")
    clean = string.gsub(clean, "<", "&lt;")
    clean = string.gsub(clean, ">", "&gt;")

    NotifIndex = NotifIndex + 1
    local card = new("Frame", {
        Name = "ShotMiss_" .. tostring(NotifIndex),
        Size = UDim2.fromOffset(486, 92),
        BackgroundColor3 = Color3.fromRGB(10, 10, 10),
        BackgroundTransparency = 0.04,
        BorderSizePixel = 0,
        LayoutOrder = NotifIndex,
        ZIndex = 81,
    }, AllIn1.ShotIssueHolder)

    new("UIStroke", {
        Color = Theme.Border,
        Thickness = 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, card)

    new("Frame", {
        Position = UDim2.fromOffset(1, 1),
        Size = UDim2.new(1, -2, 0, 1),
        BackgroundColor3 = Theme.Accent,
        BackgroundTransparency = 0.18,
        BorderSizePixel = 0,
        ZIndex = 82,
    }, card)

    local label = new("TextLabel", {
        Position = UDim2.fromOffset(5, 2),
        Size = UDim2.new(1, -10, 1, -4),
        BackgroundTransparency = 1,
        Text = string.format(
            '[alex.ftn] shot missed due to <font color="#BE5C62">%s</font>',
            clean
        ),
        RichText = true,
        TextColor3 = Theme.Text,
        Font = Enum.Font.Code,
        TextSize = 10,
        TextWrapped = true,
        TextTruncate = Enum.TextTruncate.None,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        ZIndex = 83,
    }, card)

    table.insert(AllIn1.ShotIssueCards, card)
    while #AllIn1.ShotIssueCards > 4 do
        local oldest = table.remove(AllIn1.ShotIssueCards, 1)
        if oldest and oldest.Parent then
            oldest:Destroy()
        end
    end

    -- Keep it visible long enough to read a full two-line reason.
    task.delay(3.25, function()
        if Unloaded or not card.Parent then
            return
        end
        TweenService:Create(card, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            BackgroundTransparency = 1,
        }):Play()
        TweenService:Create(label, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            TextTransparency = 1,
        }):Play()
        task.delay(0.20, function()
            for i = #AllIn1.ShotIssueCards, 1, -1 do
                if AllIn1.ShotIssueCards[i] == card then
                    table.remove(AllIn1.ShotIssueCards, i)
                    break
                end
            end
            if card.Parent then
                card:Destroy()
            end
        end)
    end)
end

AllIn1.ReportShotIssue = function(target, reason, speed)
    if Unloaded then
        return
    end

    local now = os.clock()
    if MultiTarget.Running and (now - (AllIn1.LastHDiagnosticAt or 0)) < 0.65 then
        return
    end
    if MultiTarget.Running then
        AllIn1.LastHDiagnosticAt = now
    end
    local userId = target and target.UserId or 0
    local signature = tostring(userId) .. ":" .. tostring(reason)
    if AllIn1.LastIssueReason == signature
        and (now - (AllIn1.LastIssueNotifyAt or 0)) < 0.18
    then
        return
    end

    AllIn1.LastIssueReason = signature
    AllIn1.LastIssueNotifyAt = now

    -- Keep speed in state and append it when the caller supplied only a short
    -- diagnostic. Timeout misses already contain richer speed/origin details.
    AllIn1.LastIssueSpeed = math.floor((tonumber(speed) or 0) + 0.5)
    local displayReason = tostring(reason or "unknown reason")
    if AllIn1.LastIssueSpeed > 0 and not string.find(displayReason, "studs/s", 1, true) then
        displayReason = displayReason .. string.format(" | target speed: %d studs/s", AllIn1.LastIssueSpeed)
    end
    AllIn1.ShowShotIssue(displayReason)
end

AllIn1.Run = function(fromMultiTarget)
    if Unloaded or AllIn1.Busy then
        return
    end
    -- Never inherit any physical anchor from an interrupted E/H/100k phase.
    -- This is the critical movement handoff: E must begin from an unanchored HRP.
    if MultiTarget.UnlockOwnedMovement then
        MultiTarget.UnlockOwnedMovement()
    else
        AllIn1.ReleaseAttackAnchor()
    end
    AllIn1.ShotAimPosition = nil
    AllIn1.ShotTargetPart = nil
    AllIn1.ShotGeometryReady = false
    if MultiTarget.Running and not fromMultiTarget then
        return
    end

    local target, targetHumanoid, targetPart, targetState = AllIn1.GetLockedTarget()

    -- C can keep the same UserId while the target is rebuilding after a
    -- respawn. Wait briefly for that SAME target instead of acquiring another.
    if target and targetState == "respawning" then
        for _ = 1, 15 do
            RunService.Heartbeat:Wait()
            target, targetHumanoid, targetPart, targetState = AllIn1.GetLockedTarget()
            if targetHumanoid and targetPart and targetState == nil then
                break
            end
            if targetState == "ko" then
                break
            end
        end
    end

    if not target or not targetHumanoid or not targetPart or targetState ~= nil then
        local message = "lock a target with C first"
        if targetState == "ko" then
            message = "locked target is KO"
        elseif targetState == "respawning" then
            message = "locked target is respawning"
        end
        notify("ALLIN1", message, "warning", 2.3)
        return
    end

    -- H retries a genuine miss from a different side instead of reusing the
    -- exact same muzzle/origin corridor. Manual E remains on its normal path.
    local approachAngle = (MultiTarget.Running
        and AllIn1.ApproachAngleByUserId[target.UserId]) or 0

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not character or not root or not humanoid then
        notify("ALLIN1", "character unavailable", "warning", 2.2)
        return
    end

    -- Respect a supported gun the user already has equipped. If no usable gun is
    -- out, fall back to slot 1 / Double Barrel without hiding manual weapon swaps.
    local tool = AllIn1.EquipDoubleBarrel(character, humanoid)

    local hasInputFire = type(mouse1click) == "function"
        or (type(mouse1press) == "function" and type(mouse1release) == "function")
    if not tool and not hasInputFire then
        notify("ALLIN1", "equip a gun first", "warning", 2.2)
        return
    end

    if tool then
        AllIn1.EnsureReloadHook(tool)
    end

    AllIn1.Busy = true
    AllIn1.Token = AllIn1.Token + 1
    local token = AllIn1.Token

    -- Fake Pos and E/H both touch replication/origin state. Manual E gets a
    -- stronger thaw than H: interrupt any active nil-root window, verify the live
    -- HRP for several real Heartbeats, and only then allow E to move toward target.
    if Utility.FakePosEnabled then
        -- When E starts from void hide, do NOT deliberately replicate the enormous
        -- void CFrame for three thaw frames. First hold the root live, return to the
        -- saved ground action position, then run the verified E thaw there.
        if not MultiTarget.Running
            and not (VoidSpam.Enabled and VoidSpam.SavedCFrame)
            and type(Utility.BeginFakePosEThaw) == "function"
        then
            if not Utility.BeginFakePosEThaw(token, Utility.FakePosEThawTimeout) then
                Utility.EndFakePosEThaw(token, false)
                AllIn1.Busy = false
                notify("ALLIN1", "fake pos origin did not thaw for E", "warning", 2.4)
                return
            end
        else
            Utility.FakePosCombatHold = true
            Utility.FakePosCombatToken = token
            Utility.FakePosCycleState = "combat-hold"
            if type(Utility.RestoreFakePosRoot) == "function" then
                Utility.RestoreFakePosRoot(root)
            end
        end
    end

    -- If manual E was pressed while V/void hide is active, return to the saved
    -- map position first and let replication settle before any target hook/fire.
    -- H uses the same helper once at H startup, so its per-target AllIn1 calls do
    -- not repeatedly bounce between map and void.
    if not MultiTarget.Running and VoidSpam.Enabled and VoidSpam.SavedCFrame then
        local groundOK = VoidSpam.EnterGroundAction("E", token)
        if not groundOK then
            if Utility.FakePosEThawActive and Utility.FakePosEThawToken == token then
                Utility.EndFakePosEThaw(token, false)
            elseif Utility.FakePosCombatToken == token then
                Utility.FakePosCombatHold = false
                Utility.FakePosCombatToken = 0
                Utility.RestoreFakePosRoot(root)
            end
            VoidSpam.ResumeAfterAction("E")
            AllIn1.Busy = false
            notify("ALLIN1", "ground/origin handoff failed", "warning", 2.2)
            return
        end

        character = LocalPlayer.Character
        root = character and character:FindFirstChild("HumanoidRootPart")
        humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if not character or not root or not humanoid then
            if Utility.FakePosEThawActive and Utility.FakePosEThawToken == token then
                Utility.EndFakePosEThaw(token, false)
            elseif Utility.FakePosCombatToken == token then
                Utility.FakePosCombatHold = false
                Utility.FakePosCombatToken = 0
                Utility.RestoreFakePosRoot(root)
            end
            VoidSpam.ResumeAfterAction("E")
            AllIn1.Busy = false
            return
        end

        -- Now that void->ground has completed, perform the verified Fake Pos E thaw
        -- on the NORMAL map origin, never at the gigantic void coordinate.
        if Utility.FakePosEnabled
            and not MultiTarget.Running
            and not Utility.FakePosEThawActive
            and type(Utility.BeginFakePosEThaw) == "function"
        then
            if not Utility.BeginFakePosEThaw(token, Utility.FakePosEThawTimeout) then
                Utility.EndFakePosEThaw(token, false)
                VoidSpam.ResumeAfterAction("E")
                AllIn1.Busy = false
                notify("ALLIN1", "fake pos ground origin did not thaw for E", "warning", 2.4)
                return
            end
        end

        -- The Tool can be reparented/rebuilt after the huge void->map move. Always
        -- reacquire the live equipped Tool and retire any stale reload worker.
        tool = AllIn1.GetEquippedTool(character) or AllIn1.EquipDoubleBarrel(character, humanoid)
        if tool then
            AllIn1.EnsureReloadHook(tool)
            if AllIn1.Reloading and AllIn1.ReloadTool ~= tool then
                AllIn1.ReloadToken = AllIn1.ReloadToken + 1
                AllIn1.Reloading = false
                AllIn1.ReloadTool = nil
                AllIn1.ReloadHeartbeatAt = 0
            end
        end
    end
    -- H keeps the fast travel/search profile, but critical arrival + fire
    -- verification now have their own scales. The previous single 0.68 scale also
    -- shortened damage replication/shot verification, which could classify a real
    -- H hit as a miss before the server state arrived.
    local hSpeedScale = MultiTarget.Running and (MultiTarget.ActionSpeedScale or 1) or 1
    local arrivalScale = MultiTarget.Running and (MultiTarget.ArrivalSafetyScale or 1) or 1
    local fireScale = MultiTarget.Running and (MultiTarget.FireSafetyScale or 1) or 1
    local safetyScale = hSpeedScale
        * ((MultiTarget.Running and not MultiTarget.SafeMode and not MultiTarget.ForceSafeCurrent) and 0.85 or 1)
    local suppressReturn = MultiTarget.Running and not MultiTarget.ReturnBetweenTargets
    local savedPivot = character:GetPivot()
    local savedLinearVelocity = root.AssemblyLinearVelocity
    local savedAngularVelocity = root.AssemblyAngularVelocity
    local savedPlatformStand = humanoid.PlatformStand
    local savedSit = humanoid.Sit
    local savedHumanoidState = humanoid:GetState()
    AllIn1.LastResultUserId = target.UserId
    AllIn1.LastDamageConfirmed = false
    AllIn1.LastKillVerified = false
    AllIn1.LastStompVerified = false
    AllIn1.LastShotAttempts = 0
    local savedAutoRotate = humanoid.AutoRotate
    local baselineHealth, _, baselineArmor = getPlayerVitals(target)
    baselineHealth = tonumber(baselineHealth) or targetHumanoid.Health
    baselineArmor = tonumber(baselineArmor) or 0
    local damageConfirmed = false
    local killVerified = false
    local stompVerified = false
    local healthConnection = nil

    healthConnection = targetHumanoid.HealthChanged:Connect(function(newHealth)
        newHealth = tonumber(newHealth)
        if newHealth and newHealth < baselineHealth then
            damageConfirmed = true
        end
        if newHealth and newHealth <= 0 then
            killVerified = true
        end
    end)

    humanoid.AutoRotate = false
    -- Do not arm the silent-fire window until the safety precheck + HRP settle
    -- phases finish. This prevents an instant shot on a stale fast-target frame.
    AllIn1.Firing = false
    AllIn1.FiringUntil = 0
    if AllIn1.Box and AllIn1.Stroke then
        AllIn1.Box.BackgroundColor3 = Theme.Accent
        AllIn1.Stroke.Color = Theme.Accent
    end

    task.spawn(function()
        local step = 0

        local actionOK, actionError = pcall(function()
            -- PHASE 0: SPEED-SAFETY PRECHECK. Do not teleport or shoot yet.
            -- Sample several replicated HRP frames first so flintlock/fly/very-fast
            -- movement is classified before we commit to an aggressive snap.
            local checkStarted = os.clock()
            local maxSpeed = 0
            local maxVertical = 0
            local maxVelocityJump = 0
            local previousVelocity = nil
            local sawCFrameMotion = false
            local sawFlyMotion = false

            while not Unloaded
                and AllIn1.Busy
                and AllIn1.Token == token
                and (os.clock() - checkStarted) < (AllIn1.PrecheckTime * safetyScale)
            do
                local checkTarget = findPlayerByUserId(target.UserId)
                local checkHumanoid = getHumanoid(checkTarget)
                local checkPart = getTargetPart(checkTarget)

                if not checkTarget or not checkHumanoid or not checkPart
                    or checkHumanoid.Health <= 0 or isKnockedOut(checkTarget)
                then
                    return
                end

                local motion = AllIn1.SampleTargetMotion(checkPart, os.clock())
                if not motion then
                    return
                end
                local velocity = motion.EffectiveVelocity or motion.AssemblyVelocity or Vector3.zero
                maxSpeed = math.max(maxSpeed, motion.Speed or velocity.Magnitude)
                maxVertical = math.max(maxVertical, motion.Vertical or math.abs(velocity.Y))
                sawCFrameMotion = sawCFrameMotion or motion.CFrameMotion == true
                sawFlyMotion = sawFlyMotion or motion.FlyMotion == true
                if previousVelocity then
                    maxVelocityJump = math.max(maxVelocityJump, (velocity - previousVelocity).Magnitude)
                end
                previousVelocity = velocity
                targetPart = checkPart
                RunService.Heartbeat:Wait()
            end

            local cframePrecheck = sawCFrameMotion
            local extremePrecheck = cframePrecheck
                or maxSpeed >= AllIn1.ExtremeTargetSpeed
                or maxVertical >= AllIn1.ExtremeTargetVerticalSpeed
                or maxVelocityJump >= 160
            local fastPrecheck = extremePrecheck
                or sawFlyMotion
                or maxSpeed >= AllIn1.FastTargetSpeed
                or maxVertical >= AllIn1.FastTargetVerticalSpeed
                or maxVelocityJump >= 105

            -- Fast targets must never be asked to "stand still" before E/H can act.
            -- Take only a tiny bounded fresh-sample window so flintlock/fly movement
            -- is classified, then follow that velocity at the target instead.
            if fastPrecheck then
                local extraWait = (cframePrecheck
                    and AllIn1.CFramePreTeleportWait
                    or (extremePrecheck and AllIn1.ExtremePreTeleportWait or AllIn1.FastPreTeleportWait)) * safetyScale
                local waitStarted = os.clock()

                while not Unloaded
                    and AllIn1.Busy
                    and AllIn1.Token == token
                    and (os.clock() - waitStarted) < extraWait
                do
                    local waitTarget = findPlayerByUserId(target.UserId)
                    local waitHumanoid = getHumanoid(waitTarget)
                    local waitPart = getTargetPart(waitTarget)
                    if not waitTarget or not waitHumanoid or not waitPart
                        or waitHumanoid.Health <= 0 or isKnockedOut(waitTarget)
                    then
                        return
                    end

                    targetPart = waitPart
                    RunService.Heartbeat:Wait()
                end
            end

            -- Re-resolve after the checks. This is the only target E is allowed to use.
            local firstTarget = findPlayerByUserId(target.UserId)
            local firstHumanoid = getHumanoid(firstTarget)
            local firstPart = getTargetPart(firstTarget)
            local firstRoot = character:FindFirstChild("HumanoidRootPart")
            if not firstTarget or not firstHumanoid or not firstPart or not firstRoot
                or firstHumanoid.Health <= 0 or isKnockedOut(firstTarget)
            then
                return
            end

            -- PHASE 1: SAFE HRP HOOK. Arrive 1.5 studs from the target and
            -- soft-lock our HRP there while following the newest replicated HRP.
            -- No physical anchor is used here, so E/H can always transition/move.
            local settleTime = AllIn1.NormalSettleTime
            if cframePrecheck then
                settleTime = AllIn1.CFrameSettleTime
            elseif extremePrecheck then
                settleTime = AllIn1.ExtremeSettleTime
            elseif fastPrecheck then
                settleTime = AllIn1.FastSettleTime
            end
            settleTime = settleTime * safetyScale

            local settleStarted = os.clock()
            while not Unloaded
                and AllIn1.Busy
                and AllIn1.Token == token
                and (os.clock() - settleStarted) < settleTime
            do
                local settleTarget = findPlayerByUserId(target.UserId)
                local settleHumanoid = getHumanoid(settleTarget)
                local settlePart = getTargetPart(settleTarget)
                if not settleTarget or not settleHumanoid or not settlePart
                    or settleHumanoid.Health <= 0 or isKnockedOut(settleTarget)
                then
                    return
                end

                targetPart = settlePart
                if not AllIn1.HookAndAnchorToTarget(character, settlePart, approachAngle) then
                    return
                end
                RunService.Heartbeat:Wait()
            end

            -- PHASE 1B: ARRIVAL SPEED/SAFETY CHECK. This is intentionally separate
            -- from the pre-teleport scan: after arriving we sample the target AGAIN
            -- because flintlock/fly movement can change during the teleport itself.
            -- We remain soft-locked one stud away and do not arm/fire until READY.
            local arrivalMinTime = AllIn1.NormalArrivalMinTime
            local arrivalTimeout = AllIn1.NormalArrivalTimeout
            local arrivalNeededFrames = AllIn1.NormalArrivalStableFrames
            if cframePrecheck then
                arrivalMinTime = AllIn1.CFrameArrivalMinTime
                arrivalTimeout = AllIn1.CFrameArrivalTimeout
                arrivalNeededFrames = 1
            elseif extremePrecheck then
                arrivalMinTime = AllIn1.ExtremeArrivalMinTime
                arrivalTimeout = AllIn1.ExtremeArrivalTimeout
                arrivalNeededFrames = AllIn1.ExtremeArrivalStableFrames
            elseif fastPrecheck then
                arrivalMinTime = AllIn1.FastArrivalMinTime
                arrivalTimeout = AllIn1.FastArrivalTimeout
                arrivalNeededFrames = AllIn1.FastArrivalStableFrames
            end
            arrivalMinTime = arrivalMinTime * arrivalScale
            arrivalTimeout = arrivalTimeout * arrivalScale

            local arrivalStarted = os.clock()
            local arrivalStableFrames = 0
            local arrivalPreviousVelocity = nil
            local arrivalReady = false
            local lastArrivalSpeed = 0
            while not Unloaded
                and AllIn1.Busy
                and AllIn1.Token == token
                and (os.clock() - arrivalStarted) < arrivalTimeout
            do
                local arrivalTarget = findPlayerByUserId(target.UserId)
                local arrivalHumanoid = getHumanoid(arrivalTarget)
                local arrivalPart = getTargetPart(arrivalTarget)
                local arrivalTool = AllIn1.GetEquippedTool(LocalPlayer.Character) or tool
                if not arrivalTarget or not arrivalHumanoid or not arrivalPart
                    or arrivalHumanoid.Health <= 0 or isKnockedOut(arrivalTarget)
                then
                    return
                end

                targetPart = arrivalPart
                tool = arrivalTool or tool
                local motion = AllIn1.SampleTargetMotion(arrivalPart, os.clock())
                if not motion then
                    return
                end
                local velocity = motion.EffectiveVelocity or motion.AssemblyVelocity or Vector3.zero
                local speed = motion.Speed or velocity.Magnitude
                local vertical = motion.Vertical or math.abs(velocity.Y)
                local cframeNow = motion.CFrameMotion == true
                local flyNow = motion.FlyMotion == true
                lastArrivalSpeed = speed
                local jump = arrivalPreviousVelocity and (velocity - arrivalPreviousVelocity).Magnitude or 0
                arrivalPreviousVelocity = velocity

                local extremeNow = cframeNow
                    or speed >= AllIn1.ExtremeTargetSpeed
                    or vertical >= AllIn1.ExtremeTargetVerticalSpeed
                    or jump >= 160
                local fastNow = extremeNow
                    or flyNow
                    or speed >= AllIn1.FastTargetSpeed
                    or vertical >= AllIn1.FastTargetVerticalSpeed
                    or jump >= 105

                -- Arrival classification can upgrade after the teleport. If a
                -- previously normal target suddenly flintlocks/flys, immediately
                -- expand the safety window instead of using the old fast timing.
                if cframeNow then
                    -- CFrame targets never become physically "quiet". Do not grow
                    -- their wait window, but still require two consecutive live-origin
                    -- samples so the teleport can reach replication before firing.
                    arrivalMinTime = math.min(arrivalMinTime, AllIn1.CFrameArrivalMinTime * arrivalScale)
                    arrivalTimeout = math.max(arrivalTimeout, AllIn1.CFrameArrivalTimeout * arrivalScale)
                    arrivalNeededFrames = 1
                elseif extremeNow then
                    arrivalMinTime = math.max(arrivalMinTime, AllIn1.ExtremeArrivalMinTime * arrivalScale)
                    arrivalTimeout = math.max(arrivalTimeout, AllIn1.ExtremeArrivalTimeout * arrivalScale)
                    arrivalNeededFrames = math.max(arrivalNeededFrames, AllIn1.ExtremeArrivalStableFrames)
                elseif fastNow then
                    arrivalMinTime = math.max(arrivalMinTime, AllIn1.FastArrivalMinTime * arrivalScale)
                    arrivalTimeout = math.max(arrivalTimeout, AllIn1.FastArrivalTimeout * arrivalScale)
                    arrivalNeededFrames = math.max(arrivalNeededFrames, AllIn1.FastArrivalStableFrames)
                end

                local adaptiveArrivalJump = math.max(0, speed * 0.90)
                local jumpLimit = cframeNow and math.huge
                    or (extremeNow and math.max(320, adaptiveArrivalJump)
                        or (fastNow and math.max(260, adaptiveArrivalJump * 0.80) or 95))
                local movingConfirmFrames = (cframeNow or fastNow or extremeNow)
                    and AllIn1.MovingOriginConfirmFrames or arrivalNeededFrames

                local arrivalRoot = AllIn1.HookAndAnchorToTarget(character, arrivalPart, approachAngle)
                if not arrivalRoot then
                    return
                end
                local distance = (arrivalRoot.Position - arrivalPart.Position).Magnitude

                -- Do not cast a hundreds-of-millions-stud LOS ray if another local
                -- movement writer displaced our HRP between two scheduler phases.
                -- Give the next heartbeat a chance to reacquire the current target
                -- and hook again; the normal timeout still bounds this recovery.
                if distance > 64 then
                    AllIn1.LastArrivalDistance = distance
                    AllIn1.LastArrivalPositionReady = false
                    AllIn1.LastLOSDetail = "movement handoff not settled"
                    arrivalStableFrames = 0
                    RunService.Heartbeat:Wait()
                    continue
                end

                local arrivalTolerance = extremeNow and 0.55 or (fastNow and 0.35 or 0.10)
                local arrivalPositionReady = math.abs(distance - AllIn1.OrbitRadius) <= arrivalTolerance
                local arrivalLOS = arrivalPositionReady and AllIn1.HasClearShot(tool, arrivalPart) or false
                AllIn1.LastArrivalDistance = distance
                AllIn1.LastArrivalPositionReady = arrivalPositionReady
                local clear = arrivalPositionReady and arrivalLOS

                if clear and (cframeNow or jump <= jumpLimit) then
                    arrivalStableFrames = arrivalStableFrames + 1
                else
                    arrivalStableFrames = 0
                end

                local arrivalElapsed = os.clock() - arrivalStarted
                local arrivalFallbackJump = cframeNow and math.huge
                    or (extremeNow and math.max(420, speed * 1.20)
                        or (fastNow and math.max(340, speed * 0.95) or 120))
                local arrivalFallbackReady = arrivalElapsed >= (arrivalTimeout * 0.58)
                    and clear
                    and (cframeNow or jump <= arrivalFallbackJump)
                local movingTargetReady = (cframeNow or fastNow or extremeNow)
                    and arrivalElapsed >= arrivalMinTime
                    and clear
                    and arrivalStableFrames >= movingConfirmFrames

                local movingClass = cframeNow or fastNow or extremeNow
                local stableEnough = (movingClass
                    and arrivalStableFrames >= movingConfirmFrames)
                    or ((not movingClass)
                        and arrivalStableFrames >= arrivalNeededFrames)
                local fallbackEnough = arrivalFallbackReady
                    and (not movingClass or arrivalStableFrames >= movingConfirmFrames)

                if arrivalElapsed >= arrivalMinTime
                    and (movingTargetReady or stableEnough or fallbackEnough)
                then
                    -- A moving target does not need quiet velocity frames. Once our
                    -- 1.5-stud orbit origin is live and the muzzle path is clear, proceed.
                    arrivalReady = true
                    break
                end
                RunService.Heartbeat:Wait()
            end

            if not arrivalReady then
                -- Report the actual gate that prevented a shot instead of silently
                -- looking like H/E "did nothing".
                if MultiTarget.Running then
                    AllIn1.ApproachAngleByUserId[target.UserId] =
                        (approachAngle + (math.pi * 0.5)) % (math.pi * 2)
                end
                AllIn1.ReportShotIssue(
                    firstTarget,
                    string.format(
                        "blocked: arrival/LOS | root %.2f studs | %s",
                        tonumber(AllIn1.LastArrivalDistance) or -1,
                        tostring(AllIn1.LastLOSDetail or "LOS detail unavailable")
                    ),
                    lastArrivalSpeed
                )
                return
            end

            -- Only now arm the gun hook. The target passed both the pre-teleport
            -- scan and the post-arrival scan while our HRP was glued at the configured orbit radius.
            AllIn1.Firing = true
            local actionDuration = 0.90
            if cframePrecheck then
                actionDuration = 1.35
            elseif extremePrecheck then
                actionDuration = 1.25
            elseif fastPrecheck then
                actionDuration = 1.08
            end
            if MultiTarget.Running then
                -- Travel is already accelerated. Give the actual gun enough time
                -- for two verified attempts instead of clipping the fire window.
                actionDuration = math.max(0.95, actionDuration * 0.95)
            elseif Utility.FakePosEnabled then
                -- Manual E + Fake Pos deliberately spends longer in one coherent
                -- real-character firing pose so the server sees the new origin/tool
                -- assembly before and after the trigger. Normal E and H are unchanged.
                actionDuration = math.max(actionDuration, 1.55)
            end
            local startTime = os.clock()
            -- Fixed replication hold, timing-only:
            -- every target speed uses the same 0.10s pre-fire orbit.
            -- Stay hard-glued at 1.5 studs and keep the existing moderate orbit for the
            -- full hold, then freeze the relative angle and let the existing READY/fire
            -- checks continue unchanged.
            local preFireOrbitTime = tonumber(AllIn1.PreFireOrbitTime) or 0.10
            local safeFireAfter = startTime + preFireOrbitTime
            local originLockAfter = safeFireAfter
            AllIn1.OriginLockPrepared = false
            local previousLiveVelocity = nil
            local previousLivePosition = nil
            local previousSampleTime = nil
            local stableFrames = 0
            local clearFrames = 0
            local orbitAngle = approachAngle
            local orbitLastTime = startTime
            local waitingForShotResult = false
            local shotVerifyUntil = 0
            local healthBeforeShot = baselineHealth
            local ammoBeforeShot = nil
            local ammoConsumedAfterShot = false
            local fakePosEPostFireHoldUntil = 0
            local registrationGraceUsed = false
            local directHealthBeforeShot = nil
            local latchedAimPosition = nil
            local shotInputLatchUntil = 0
            local shotInputConfirmUntil = 0
            local shotAttempts = 0
            local inputRetryPass = 1
            local inputRejectCount = 0
            local readyScanStarted = startTime
            AllIn1.FiringUntil = startTime + actionDuration + 0.55

            -- PHASE 2/3/4: SAFE SHOT LOOP.
            -- Keep the local HRP hard-glued at the configured radius from the latest replicated
            -- target HRP. Orbit slowly while preparing, freeze that relative angle
            -- during each shot verification window, and only send ONE fire input.
            while not Unloaded
                and AllIn1.Busy
                and AllIn1.Token == token
                and (os.clock() - startTime) < actionDuration
            do
                local liveTarget = findPlayerByUserId(target.UserId)
                local liveHumanoid = getHumanoid(liveTarget)
                local livePart = getTargetPart(liveTarget)
                local liveCharacter = LocalPlayer.Character
                local liveRoot = liveCharacter and liveCharacter:FindFirstChild("HumanoidRootPart")
                local liveTool = AllIn1.GetEquippedTool(liveCharacter)

                if not liveTarget or not livePart or liveCharacter ~= character or not liveRoot then
                    break
                end

                if isKnockedOut(liveTarget)
                    or (liveHumanoid and liveHumanoid.Health <= 0)
                then
                    killVerified = true
                    break
                end

                if not liveHumanoid then
                    break
                end

                if liveHumanoid.Health < baselineHealth then
                    damageConfirmed = true
                end

                targetPart = livePart
                if liveTool then
                    tool = liveTool
                    AllIn1.EnsureReloadHook(tool)
                end

                if tool then
                    local capacity = AllIn1.GetWeaponCapacity(tool)
                    local currentAmmo = AllIn1.ReadAmmo(tool)
                    if capacity and currentAmmo ~= nil and currentAmmo <= 0 then
                        AllIn1.StartReload(tool)
                    end
                end

                local now = os.clock()
                local motion = AllIn1.SampleTargetMotion(targetPart, now)
                if not motion then
                    AllIn1.ReportShotIssue(liveTarget, "motion sample invalid", 0)
                    break
                end
                local targetVelocity = motion.EffectiveVelocity or motion.AssemblyVelocity or Vector3.zero
                local targetSpeed = motion.Speed or targetVelocity.Magnitude
                local cframeMotion = motion.CFrameMotion == true
                local flyMotion = motion.FlyMotion == true
                local velocityJump = previousLiveVelocity
                    and (targetVelocity - previousLiveVelocity).Magnitude or 0
                local sampleDt = previousSampleTime and math.max(now - previousSampleTime, 1 / 240) or 0
                local predictionError = 0
                if previousLivePosition and previousLiveVelocity and sampleDt > 0 then
                    local predicted = previousLivePosition + (previousLiveVelocity * sampleDt)
                    predictionError = (motion.Position - predicted).Magnitude
                end
                -- Large position discontinuities are expected during CFrame movement.
                -- They should classify the target as moving, not permanently fail READY.
                if cframeMotion then
                    predictionError = math.min(predictionError, 2.0)
                end
                previousLivePosition = motion.Position
                previousSampleTime = now
                previousLiveVelocity = targetVelocity

                local extremeMovement = cframeMotion
                    or targetSpeed >= AllIn1.ExtremeTargetSpeed
                    or math.abs(targetVelocity.Y) >= AllIn1.ExtremeTargetVerticalSpeed
                    or velocityJump >= 160
                local unstableMovement = extremeMovement
                    or flyMotion
                    or targetSpeed >= AllIn1.FastTargetSpeed
                    or math.abs(targetVelocity.Y) >= AllIn1.FastTargetVerticalSpeed
                    or velocityJump >= 105

                -- Fast motion must not continuously restart the READY timer. That was
                -- the main reason flintlock/fly targets could make E/H never fire:
                -- every velocity spike reset readyScanStarted before the fallback
                -- window could ever expire. Keep one bounded attempt window and use
                -- the live one-stud origin + LOS as the decisive fast-target checks.
                local movementFrameDistance = targetSpeed * math.max(sampleDt, 1 / 60)
                local stableLimit = cframeMotion and math.huge
                    or (extremeMovement and math.max(460, targetSpeed * 0.90)
                        or (unstableMovement and math.max(340, targetSpeed * 0.72) or 105))
                local predictionLimit = cframeMotion and math.huge
                    or (extremeMovement and math.max(12.00, math.min(48, movementFrameDistance * 1.65))
                        or (unstableMovement and math.max(8.50, math.min(28, movementFrameDistance * 1.35)) or 0.80))
                if velocityJump <= stableLimit and predictionError <= predictionLimit then
                    stableFrames = stableFrames + 1
                else
                    stableFrames = 0
                    if not unstableMovement then
                        clearFrames = 0
                        safeFireAfter = math.max(safeFireAfter, now + 0.045)
                        readyScanStarted = now
                    end
                end

                local requiredStableFrames = AllIn1.NormalStableFrames
                local requiredClearFrames = AllIn1.NormalOriginConfirmFrames or AllIn1.NormalClearFrames
                local readyTimeout = AllIn1.NormalReadyTimeout * fireScale
                local verifyTime = AllIn1.NormalShotVerifyTime * fireScale
                if cframeMotion then
                    requiredStableFrames = 1
                    requiredClearFrames = AllIn1.MovingOriginConfirmFrames
                    readyTimeout = math.max(AllIn1.CFrameReadyTimeout * fireScale, 0.050)
                    verifyTime = AllIn1.CFrameShotVerifyTime * fireScale
                elseif extremeMovement then
                    requiredStableFrames = AllIn1.ExtremeStableFrames
                    requiredClearFrames = AllIn1.MovingOriginConfirmFrames
                    readyTimeout = math.max(AllIn1.ExtremeReadyTimeout * fireScale, 0.060)
                    verifyTime = AllIn1.ExtremeShotVerifyTime * fireScale
                elseif unstableMovement then
                    requiredStableFrames = AllIn1.FastStableFrames
                    requiredClearFrames = AllIn1.MovingOriginConfirmFrames
                    readyTimeout = math.max(AllIn1.FastReadyTimeout * fireScale, 0.055)
                    verifyTime = AllIn1.FastShotVerifyTime * fireScale
                end

                -- HARD GLUE ORBIT: stay attached to the newest HRP every Heartbeat,
                -- 1.5 studs away, while circling at a moderate fixed angular speed.
                -- The hook function mirrors both target velocity and our tangential
                -- orbit velocity so stationary, walking, flying and CFrame targets
                -- all present a coherent shot origin to replication.
                local orbitDt = math.clamp(now - orbitLastTime, 0, 0.05)
                orbitLastTime = now
                -- Stage the firing origin: once LOS/origin starts earning READY,
                -- stop changing the relative orbit angle. Keep following the live
                -- target HRP, but hold the same side through activation + verification.
                -- This prevents asynchronous gun LocalScripts from seeing a different
                -- muzzle/root origin one frame after ammo was consumed.
                -- Keep spinning for the ENTIRE fixed 0.10s even if READY is earned
                -- early. At 0.10s freeze the current side, clear stale LOS frames, and
                -- hold that exact origin for one short replication slice before fire.
                if now >= originLockAfter and not AllIn1.OriginLockPrepared then
                    AllIn1.OriginLockPrepared = true
                    -- IMPORTANT: the READY timeout used to keep counting from startTime.
                    -- For fast/extreme targets that timeout (0.055-0.085s) could expire
                    -- BEFORE the fixed 0.10s orbit finished. We then cleared clearFrames
                    -- here and immediately fell into "blocked: muzzle LOS" on the first
                    -- post-lock heartbeat, even with a perfectly clear muzzle path.
                    -- Start a fresh READY window from the actual frozen firing origin.
                    readyScanStarted = now
                    stableFrames = 0
                    clearFrames = 0
                    safeFireAfter = math.max(
                        safeFireAfter,
                        now + (
                            Utility.FakePosEnabled and not MultiTarget.Running
                            and math.max(
                                tonumber(AllIn1.FinalOriginSettleTime) or 0.018,
                                tonumber(Utility.FakePosEFireCommitMin) or 0.20,
                                AllIn1.GetNetworkCommitTime(
                                    cframeMotion,
                                    unstableMovement,
                                    extremeMovement
                                ) + (Utility.FakePosEFireCommitExtra or 0.060),
                                (AllIn1.GetDataPingSeconds() * (Utility.FakePosEFireCommitPingScale or 1.65)) + 0.04,
                                math.clamp(
                                    (AllIn1.GetDataPingSeconds() * (Utility.FakePosEStablePreFirePingScale or 2.00))
                                        + (Utility.FakePosEStablePreFireBase or 0.10),
                                    Utility.FakePosEStablePreFireMin or 0.25,
                                    Utility.FakePosEStablePreFireMax or 0.40
                                )
                            )
                            or (tonumber(AllIn1.FinalOriginSettleTime) or 0.018)
                        )
                    )
                end
                local stagingOrigin = waitingForShotResult or AllIn1.OriginLockPrepared
                local activeOrbitSpeed = stagingOrigin and 0 or AllIn1.OrbitAngularSpeed
                if activeOrbitSpeed ~= 0 then
                    orbitAngle = (orbitAngle + (activeOrbitSpeed * orbitDt)) % (math.pi * 2)
                end
                liveRoot = AllIn1.HookAndAnchorToTarget(
                    character,
                    targetPart,
                    orbitAngle,
                    activeOrbitSpeed
                )
                if not liveRoot then
                    break
                end
                AllIn1.FiringUntil = now + 0.30
                -- Aim from the freshest motion sample with a sub-body close-range
                -- lead. The math scales with the observed speed, including far above
                -- 300 studs/s, while hard distance caps prevent high-speed overshoot.
                if waitingForShotResult
                    and latchedAimPosition
                    and now <= shotInputLatchUntil
                then
                    -- Some gun LocalScripts consume ammo immediately but read
                    -- Mouse.Hit/UnitRay on a deferred frame. Keep the exact fire-time
                    -- aim point latched long enough for that callback to finish.
                    AllIn1.ShotAimPosition = latchedAimPosition
                else
                    AllIn1.ShotAimPosition =
                        AllIn1.GetAttackAimPosition(targetPart, shotAttempts + 1)
                        or targetPart.Position
                end

                local liveHealth, _, liveArmor = getPlayerVitals(liveTarget)
                liveHealth = tonumber(liveHealth) or liveHumanoid.Health
                liveArmor = tonumber(liveArmor) or 0

                -- H never wastes its firing window standing beside a target while
                -- an empty-mag reload is running. Finish verifying the shot first;
                -- then leave to void, let the shared E/H reload finish to FULL, and
                -- retry this same UserId through the existing queue logic.
                if MultiTarget.Running and AllIn1.Reloading and not waitingForShotResult then
                    break
                end

                if waitingForShotResult then
                    -- While a Fake Pos E shot is being accepted/verified, keep the REAL
                    -- HRP and the real-hand/native-RightGrip gun assembly coherent. The
                    -- orbit angle is already frozen while waitingForShotResult is true.
                    if Utility.FakePosEnabled and not MultiTarget.Running then
                        if type(Utility.RestoreFakePosRoot) == "function" then
                            Utility.RestoreFakePosRoot(liveRoot)
                        end
                        if type(Utility.EnsureFakePosERealToolGlue) == "function" then
                            Utility.EnsureFakePosERealToolGlue(tool)
                        end
                    end

                    local observedAmmo = tool and AllIn1.ReadAmmo(tool) or nil
                    if ammoBeforeShot ~= nil and observedAmmo ~= nil and observedAmmo < ammoBeforeShot then
                        if not ammoConsumedAfterShot then
                            ammoConsumedAfterShot = true
                            if Utility.FakePosEnabled and not MultiTarget.Running then
                                fakePosEPostFireHoldUntil = now + math.clamp(
                                    (AllIn1.GetDataPingSeconds() * (Utility.FakePosEPostFireHoldPingScale or 1.25))
                                        + (Utility.FakePosEPostFireHoldBase or 0.15),
                                    Utility.FakePosEPostFireHoldMin or 0.20,
                                    Utility.FakePosEPostFireHoldMax or 0.30
                                )
                                shotVerifyUntil = math.max(shotVerifyUntil, fakePosEPostFireHoldUntil)
                            end
                        end
                        inputRejectCount = 0
                    end

                    -- Separate "did the gun actually accept the trigger?" from the much
                    -- longer damage/KO verification window. A pcall-successful click can be
                    -- ignored by the game, which was producing the screenshot's no-ammo-
                    -- decrease error after ~0.7s. If readable ammo is unchanged after this
                    -- short confirmation window, retry a DIFFERENT normal activation path
                    -- while staying glued to the target instead of immediately abandoning it.
                    if ammoBeforeShot ~= nil
                        and not ammoConsumedAfterShot
                        and shotInputConfirmUntil > 0
                        and now >= shotInputConfirmUntil
                    then
                        waitingForShotResult = false
                        shotAttempts = math.max(0, shotAttempts - 1)
                        inputRejectCount = inputRejectCount + 1
                        inputRetryPass = inputRetryPass + 1
                        safeFireAfter = now + 0.035
                        stableFrames = 0
                        clearFrames = 0
                        readyScanStarted = now
                        latchedAimPosition = nil
                        shotInputLatchUntil = 0
                        shotInputConfirmUntil = 0

                        if inputRejectCount >= 3 then
                            AllIn1.ReportShotIssue(
                                liveTarget,
                                "fire input rejected 3x; ammo never decreased; last path "
                                    .. tostring(AllIn1.LastFireInputDetail or "unknown"),
                                targetSpeed
                            )
                            if MultiTarget.Running then
                                AllIn1.ApproachAngleByUserId[target.UserId] =
                                    (orbitAngle + (math.pi * 0.5)) % (math.pi * 2)
                                break
                            end
                            inputRejectCount = 0
                        end

                        RunService.Heartbeat:Wait()
                        continue
                    end

                    local directHealth = tonumber(liveHumanoid.Health) or liveHealth
                    local observedDamage = (directHealthBeforeShot ~= nil and directHealth < directHealthBeforeShot)
                        or liveHealth < healthBeforeShot
                        or liveArmor < (AllIn1.HealthArmorBeforeShot or 0)
                    local observedKill = isKnockedOut(liveTarget) or liveHealth <= 0
                    local fakePosEPostHoldActive = Utility.FakePosEnabled
                        and not MultiTarget.Running
                        and ammoConsumedAfterShot
                        and fakePosEPostFireHoldUntil > 0
                        and now < fakePosEPostFireHoldUntil

                    if observedDamage then
                        -- Record damage immediately, but Fake Pos E deliberately keeps
                        -- the exact real-character firing pose until its post-fire
                        -- replication hold finishes before allowing return/retry.
                        damageConfirmed = true
                    end
                    if observedKill then
                        killVerified = true
                    end

                    if fakePosEPostHoldActive then
                        -- Keep waitingForShotResult=true so activeOrbitSpeed remains zero
                        -- and HookAndAnchorToTarget keeps one stable relative firing side.
                    elseif observedKill then
                        break
                    elseif observedDamage then
                        waitingForShotResult = false
                        safeFireAfter = now + (MultiTarget.Running
                            and (MultiTarget.ClientShotRetryGap or 0)
                            or (AllIn1.ShotRetryGap * fireScale))
                        stableFrames = 0
                        clearFrames = 0
                        readyScanStarted = now
                    elseif now >= shotVerifyUntil then
                        -- Ammo consumption proves the gun accepted the shot input. On
                        -- fast/CFrame motion the HP/armor replication can arrive a few
                        -- frames later than the magazine decrement. Give exactly one
                        -- bounded registration grace before declaring a real miss.
                        local registrationGrace = cframeMotion and AllIn1.RegistrationGraceCFrame
                            or (extremeMovement and AllIn1.RegistrationGraceExtreme
                                or (unstableMovement and AllIn1.RegistrationGraceFast
                                    or AllIn1.RegistrationGraceNormal))
                        if ammoConsumedAfterShot and not registrationGraceUsed and registrationGrace > 0 then
                            registrationGraceUsed = true
                            shotVerifyUntil = now + registrationGrace
                        else
                            waitingForShotResult = false

                        local effectiveVerifyWindow = verifyTime + ((registrationGraceUsed and registrationGrace) or 0)
                        local movementKind = cframeMotion and "CFrame"
                            or (flyMotion and "flying"
                                or (unstableMovement and "fast-moving" or "moving"))
                        local originDistance = (liveRoot.Position - targetPart.Position).Magnitude
                        local _, missMuzzlePosition = getWeaponMuzzle(tool)
                        local missMuzzleDistance = missMuzzlePosition
                            and (missMuzzlePosition - targetPart.Position).Magnitude or nil
                        local predictionDetails = string.format(
                            "prediction %s / lead %.2f studs / tracked %.0f studs/s / ping %dms / ray %s",
                            tostring(AllIn1.LastPredictionMode or "unknown"),
                            tonumber(AllIn1.LastPredictionLeadDistance) or 0,
                            tonumber(AllIn1.LastPredictionMotionSpeed) or 0,
                            tonumber(AllIn1.LastPingMs) or 0,
                            tostring(AllIn1.LastShotRayDetail or "not sampled")
                        )
                        local eOriginState = ""
                        if Utility.FakePosEnabled and not MultiTarget.Running then
                            eOriginState = string.format(
                                " / E-origin %s / gun %s / worker %s",
                                tostring(Utility.FakePosEThawStatus or "unknown"),
                                tostring(Utility.FakePosENativeToolStatus or "unknown"),
                                Utility.FakePosEHardSuspendActive and "SUSPENDED" or "RUNNING"
                            )
                        end
                        local originDetails = missMuzzleDistance
                            and string.format(
                                "root %.2f studs / muzzle %.2f studs from HRP; humanoid %.1f->%.1f; %s%s",
                                originDistance,
                                missMuzzleDistance,
                                tonumber(directHealthBeforeShot) or -1,
                                tonumber(liveHumanoid.Health) or -1,
                                predictionDetails,
                                eOriginState
                            )
                            or string.format(
                                "root %.2f studs from HRP; muzzle unavailable; humanoid %.1f->%.1f; %s%s",
                                originDistance,
                                tonumber(directHealthBeforeShot) or -1,
                                tonumber(liveHumanoid.Health) or -1,
                                predictionDetails,
                                eOriginState
                            )
                        local missReason
                        if ammoBeforeShot == nil then
                            missReason = string.format(
                                "MISS: fire input was sent; ammo state is unreadable, but the server showed no HP/armor/KO change within %.2fs; %s target %.0f studs/s; %s",
                                effectiveVerifyWindow,
                                movementKind,
                                targetSpeed,
                                originDetails
                            )
                        elseif not ammoConsumedAfterShot then
                            missReason = string.format(
                                "MISS: fire input was sent but no ammo decrease was observed before timeout (possible weapon cooldown/input rejection); %s target %.0f studs/s; %s",
                                movementKind,
                                targetSpeed,
                                originDetails
                            )
                        else
                            missReason = string.format(
                                "MISS: ammo decreased, but the server registered no HP/armor/KO change within %.2fs; %s target %.0f studs/s; %s",
                                effectiveVerifyWindow,
                                movementKind,
                                targetSpeed,
                                originDetails
                            )
                        end
                        AllIn1.ReportShotIssue(liveTarget, missReason, targetSpeed)

                        -- H miss policy: the instant a real fired shot finishes its
                        -- verification window with NO HP/armor/KO change, leave the
                        -- target. The H runner moves to void, force-refills to FULL,
                        -- then comes back through the normal safe approach. Manual E
                        -- keeps its original in-place second-attempt behavior.
                        if MultiTarget.Running then
                            AllIn1.ApproachAngleByUserId[target.UserId] =
                                (orbitAngle + (math.pi * 0.5)) % (math.pi * 2)
                            break
                        end

                        safeFireAfter = now + (AllIn1.ShotRetryGap * fireScale)
                        stableFrames = 0
                        clearFrames = 0
                        readyScanStarted = now
                        orbitAngle = orbitAngle + (math.pi * 0.5)
                        end
                    end
                else
                    local distance = (liveRoot.Position - targetPart.Position).Magnitude
                    local direction = targetPart.Position - liveRoot.Position
                    local facingDot = direction.Magnitude > 0.01
                        and liveRoot.CFrame.LookVector:Dot(direction.Unit) or 1
                    local positionTolerance = cframeMotion and 0.85 or (extremeMovement and 0.65 or (unstableMovement and 0.45 or 0.20))
                    local facingThreshold = cframeMotion and 0.90 or (extremeMovement and 0.93 or (unstableMovement and 0.95 or 0.980))
                    local positionReady = math.abs(distance - AllIn1.OrbitRadius) <= positionTolerance
                        and facingDot >= facingThreshold

                    -- Ammo-decreased/no-damage misses also happened on completely
                    -- stationary targets. At the old 1-stud hook the gun muzzle could
                    -- sit inside/past the target body even though the HRP position was
                    -- perfect. Refuse only obviously bad muzzle geometry and let the
                    -- moderate orbit find a clean side on the next Heartbeat.
                    local _, muzzlePosition = getWeaponMuzzle(tool)
                    local muzzleDistance = muzzlePosition
                        and (muzzlePosition - targetPart.Position).Magnitude or nil
                    local muzzleReady = muzzleDistance == nil
                        or (muzzleDistance >= AllIn1.MinMuzzleTargetDistance
                            and muzzleDistance <= AllIn1.MaxMuzzleTargetDistance)
                    local clearLOS = AllIn1.HasClearShot(tool, targetPart)
                    local clearShot = positionReady
                        and muzzleReady
                        and clearLOS

                    if clearShot then
                        clearFrames = clearFrames + 1
                    else
                        clearFrames = 0
                    end

                    local stableReady = stableFrames >= requiredStableFrames
                    local clearReady = clearFrames >= requiredClearFrames
                    local timingReady = now >= safeFireAfter
                    local readinessTimedOut = (now - readyScanStarted) >= readyTimeout
                    -- FAST-TARGET FAILSAFE: H must never sit glued to ANY high-speed
                    -- target forever merely because velocity jitter prevents the
                    -- strict stable-frame counter from completing. Once the
                    -- bounded READY window expires, allow ONE controlled shot only
                    -- if our 1.5-stud orbit position is correct, LOS stayed clear, and the
                    -- replication error is still inside a wider safe envelope.
                    local fallbackPredictionLimit = cframeMotion and math.huge
                        or (extremeMovement and math.max(15.0, math.min(56, movementFrameDistance * 1.90))
                            or (unstableMovement and math.max(10.0, math.min(34, movementFrameDistance * 1.55)) or 1.00))
                    local fallbackJumpLimit = cframeMotion and math.huge
                        or (extremeMovement and math.max(620, targetSpeed * 1.25)
                            or (unstableMovement and math.max(480, targetSpeed) or 120))
                    local fallbackReady = readinessTimedOut
                        and clearReady
                        and positionReady
                        and predictionError <= fallbackPredictionLimit
                        and velocityJump <= fallbackJumpLimit

                    -- For a genuinely moving target, two consecutive clean origin/LOS
                    -- heartbeats are enough. We still do not wait for the HRP velocity
                    -- to become quiet because flintlock/fly movement may never do so.
                    local fastMotionReady = unstableMovement
                        and clearReady
                        and positionReady
                        and (now - readyScanStarted) >= (cframeMotion and 0.006 or 0.010)

                    if shotAttempts >= AllIn1.MaxSafeShotAttempts then
                        break
                    elseif readinessTimedOut
                        and not (stableReady and clearReady)
                        and not fallbackReady
                        and not fastMotionReady
                    then
                        local reason = not positionReady and "blocked: HRP orbit origin"
                            or (not muzzleReady and string.format(
                                "blocked: weapon muzzle geometry %.2f studs from HRP",
                                tonumber(muzzleDistance) or -1
                            ))
                            or (not clearReady and (
                                "blocked: muzzle LOS | "
                                .. tostring(AllIn1.LastLOSDetail or "LOS detail unavailable")
                            ))
                            or "blocked: motion/replication gate"
                        if MultiTarget.Running then
                            AllIn1.ApproachAngleByUserId[target.UserId] =
                                (orbitAngle + (math.pi * 0.5)) % (math.pi * 2)
                        end
                        AllIn1.ReportShotIssue(liveTarget, reason, targetSpeed)
                        break
                    elseif timingReady
                        and clearReady
                        and (stableReady or fallbackReady or fastMotionReady)
                        and not AllIn1.Reloading
                    then
                        -- READY -> FIRE exactly once. The global ammo watcher starts
                        -- reload only if this shot actually empties the magazine.
                        healthBeforeShot = liveHealth
                        directHealthBeforeShot = tonumber(liveHumanoid.Health) or liveHealth
                        AllIn1.HealthArmorBeforeShot = liveArmor
                        ammoBeforeShot = tool and AllIn1.ReadAmmo(tool) or nil
                        ammoConsumedAfterShot = false
                        registrationGraceUsed = false
                        AllIn1.ShotAimPosition =
                            AllIn1.GetAttackAimPosition(targetPart, shotAttempts + 1)
                            or targetPart.Position
                        AllIn1.ShotAimPosition, AllIn1.ShotTargetPart, AllIn1.ShotGeometryReady =
                            AllIn1.ResolveShotGeometry(tool, targetPart, AllIn1.ShotAimPosition)
                        if not AllIn1.ShotGeometryReady then
                            -- Do not consume a shell on a ray that our own client cannot
                            -- place through the target. H changes approach side; E keeps
                            -- its normal bounded retry loop.
                            if MultiTarget.Running then
                                AllIn1.ApproachAngleByUserId[target.UserId] =
                                    (orbitAngle + (math.pi * 0.5)) % (math.pi * 2)
                                AllIn1.ReportShotIssue(
                                    liveTarget,
                                    "blocked: client shot ray | "
                                        .. tostring(AllIn1.LastShotRayDetail or "unknown geometry"),
                                    targetSpeed
                                )
                                break
                            else
                                AllIn1.ReportShotIssue(
                                    liveTarget,
                                    "blocked: client shot ray | "
                                        .. tostring(AllIn1.LastShotRayDetail or "unknown geometry"),
                                    targetSpeed
                                )
                                safeFireAfter = now + (AllIn1.ShotRetryGap * fireScale)
                                stableFrames = 0
                                clearFrames = 0
                                readyScanStarted = now
                                orbitAngle = orbitAngle + (math.pi * 0.5)
                            end
                        else
                            AllIn1.ShotTargetPart = AllIn1.ShotTargetPart or targetPart
                            latchedAimPosition = AllIn1.ShotAimPosition
                            shotInputLatchUntil = now + math.max(
                                AllIn1.ShotInputLatchMin,
                                AllIn1.GetDataPingSeconds() * AllIn1.ShotInputLatchPingScale
                            )
                            if Utility.FakePosEnabled and not MultiTarget.Running then
                                Utility.BeginFakePosOriginHold(
                                    math.max(
                                        Utility.FakePosOriginShotHoldDuration or 0.24,
                                        tonumber(Utility.FakePosEFireCommitMin) or 0.20,
                                        AllIn1.GetNetworkCommitTime(
                                            cframeMotion,
                                            unstableMovement,
                                            extremeMovement
                                        ) + 0.30,
                                        (Utility.FakePosEStablePreFireMax or 0.40)
                                            + (Utility.FakePosEPostFireHoldMax or 0.30)
                                    ),
                                    "E-fire-commit"
                                )
                                Utility.UpdateFakePosToolCarrier(true)
                            end
                            if AllIn1.ActivateWeapon(tool, inputRetryPass) then
                            HitSound.Play("shot")
                            if tool then
                                AllIn1.RecordShot(tool)
                            end
                            shotAttempts = shotAttempts + 1
                            AllIn1.LastShotAttempts = (AllIn1.LastShotAttempts or 0) + 1
                            waitingForShotResult = true
                            shotVerifyUntil = now + verifyTime
                            -- Readable ammo should move quickly if the game truly accepted
                            -- the trigger. Scale this modestly with ping, but keep it far
                            -- shorter than damage verification so cooldown/input rejection
                            -- can recover in-place instead of looking like a real miss.
                            shotInputConfirmUntil = now + math.clamp(
                                math.max(0.075, AllIn1.GetDataPingSeconds() * 1.35),
                                0.075,
                                0.16
                            )
                            stableFrames = 0
                            clearFrames = 0
                            if tool then
                                AllIn1.StartReload(tool)
                            end
                        else
                            AllIn1.ReportShotIssue(
                                liveTarget,
                                "fire input not ready: " .. tostring(AllIn1.LastFireInputDetail or "unknown"),
                                targetSpeed
                            )
                            inputRetryPass = inputRetryPass + 1
                            safeFireAfter = now + (MultiTarget.Running
                                and (MultiTarget.ClientShotRetryGap or 0)
                                or (0.08 * fireScale))
                            stableFrames = 0
                            clearFrames = 0
                            -- Keep the same bounded READY window for fast targets;
                            -- only normal movement restarts the scan.
                            if not unstableMovement then
                                readyScanStarted = now
                            end
                            end
                        end
                    end
                end

                if isKnockedOut(liveTarget) or liveHealth <= 0 then
                    killVerified = true
                    break
                end

                RunService.Heartbeat:Wait()
            end

            -- Shooting/verification is over. Release the combat anchor before the
            -- stomp/reload phase so normal stomp physics/remotes are not blocked.
            AllIn1.ReleaseAttackAnchor()

            -- PHASE 5: once KO/death is VERIFIED, glue fully to the target HRP
            -- and spam Stomp until the target is actually dead/removed/respawned.
            local postTarget = findPlayerByUserId(target.UserId)
            local postHumanoid = postTarget and getHumanoid(postTarget) or nil
            if postTarget and (isKnockedOut(postTarget)
                or (postHumanoid and postHumanoid.Health <= 0))
            then
                killVerified = true
            end

            if killVerified then
                AllIn1.Firing = false
                AllIn1.FiringUntil = 0

                -- Kill is verified: if that shot emptied the mag, start the
                -- empty-only reload worker before glue/stomp. Partial mags are untouched.
                local reloadTool = AllIn1.GetEquippedTool(LocalPlayer.Character) or tool
                if reloadTool then
                    AllIn1.StartReload(reloadTool)
                end

                -- Before returning, fully glue to the target HRP and keep stomping
                -- until the target's post-stomp/dead/respawn state is VERIFIED.
                -- There is no timer-based fake success; J/unload can still cancel.
                stompVerified = AllIn1.PerformStomp(target.UserId, character)
            elseif damageConfirmed and tool then
                -- No verified KO: only auto-reload if the magazine happened to empty.
                local currentAmmo = AllIn1.ReadAmmo(tool)
                if currentAmmo ~= nil and currentAmmo <= 0 then
                    AllIn1.StartReload(tool)
                end
            end
        end)

        if not actionOK then
            AllIn1.ReportShotIssue(
                target,
                "runtime error: " .. tostring(actionError),
                0
            )
        end

        if healthConnection then
            healthConnection:Disconnect()
        end
        AllIn1.ReleaseAttackAnchor()
        AllIn1.ShotAimPosition = nil
        AllIn1.ShotTargetPart = nil
        AllIn1.ShotGeometryReady = false
        AllIn1.HealthArmorBeforeShot = nil
        AllIn1.OriginLockPrepared = false

        -- H can release its ordinary combat hold here. Manual E keeps its stronger
        -- Fake Pos thaw alive until AFTER the return CFrame below has replicated.
        if Utility.FakePosCombatToken == token
            and not (
                Utility.FakePosEThawActive
                and Utility.FakePosEThawToken == token
                and not MultiTarget.Running
            )
        then
            Utility.FakePosCombatHold = false
            Utility.FakePosCombatToken = 0
            if Utility.FakePosEnabled and type(Utility.RestoreFakePosRoot) == "function" then
                Utility.RestoreFakePosRoot()
                Utility.FakePosCycleState = "ok"
            end
        end

        AllIn1.LastDamageConfirmed = damageConfirmed
        AllIn1.LastKillVerified = killVerified
        AllIn1.LastStompVerified = stompVerified
        if damageConfirmed or killVerified then
            AllIn1.ApproachAngleByUserId[target.UserId] = nil
        end

        -- PHASE 6: manual E always returns exactly where it began. MultiTarget
        -- can optionally chain target-to-target; its own final cleanup still
        -- returns to the exact position where H was started.
        -- Clear the fire/hook state BEFORE the return so no combat frame can keep
        -- zeroing velocity after the user is back at the saved position.
        AllIn1.Firing = false
        AllIn1.FiringUntil = 0

        if humanoid and humanoid.Parent then
            humanoid.AutoRotate = savedAutoRotate
            humanoid.PlatformStand = savedPlatformStand
            humanoid.Sit = savedSit
        end

        local returnThisAction = not suppressReturn
        if returnThisAction and character and character.Parent then
            pcall(function()
                character:PivotTo(savedPivot)
                local returnRoot = character:FindFirstChild("HumanoidRootPart")
                if returnRoot then
                    returnRoot.Anchored = false
                    -- Preserve the motion the player had before E instead of forcing
                    -- a dead-zero physics frame on return.
                    returnRoot.AssemblyLinearVelocity = savedLinearVelocity
                    returnRoot.AssemblyAngularVelocity = savedAngularVelocity
                end

                if humanoid and humanoid.Parent and not savedPlatformStand and not savedSit then
                    local returnState = savedHumanoidState
                    if returnState == Enum.HumanoidStateType.PlatformStanding
                        or returnState == Enum.HumanoidStateType.Seated
                        or returnState == Enum.HumanoidStateType.Physics
                        or returnState == Enum.HumanoidStateType.None
                    then
                        returnState = Enum.HumanoidStateType.Running
                    end
                    humanoid:ChangeState(returnState)
                    humanoid:Move(humanoid.MoveDirection, false)
                end
            end)

            -- One heartbeat handoff handles games that locally re-apply a stale
            -- physics state immediately after a large teleport. It never loops,
            -- never changes WalkSpeed/JumpPower, and only touches this same character.
            task.defer(function()
                RunService.Heartbeat:Wait()
                if Unloaded or LocalPlayer.Character ~= character then
                    return
                end
                local freeRoot = character:FindFirstChild("HumanoidRootPart")
                local freeHumanoid = character:FindFirstChildOfClass("Humanoid")
                if freeRoot then
                    freeRoot.Anchored = false
                end
                if freeHumanoid then
                    freeHumanoid.AutoRotate = savedAutoRotate
                    freeHumanoid.PlatformStand = savedPlatformStand
                    freeHumanoid.Sit = savedSit
                    if not savedPlatformStand and not savedSit
                        and freeHumanoid:GetState() == Enum.HumanoidStateType.Physics
                    then
                        freeHumanoid:ChangeState(Enum.HumanoidStateType.Running)
                    end
                end
            end)
        end

        -- Manual E keeps Fake Pos thawed through the return-to-map CFrame. Only now,
        -- after two live-root Heartbeats, may the normal nil/root cadence resume.
        -- If E started from void hide, release the thaw BEFORE jumping back to the
        -- huge void coordinate so that giant void CFrame is not deliberately committed
        -- as the live combat origin.
        if not MultiTarget.Running
            and Utility.FakePosEThawActive
            and Utility.FakePosEThawToken == token
        then
            Utility.EndFakePosEThaw(token, true)
        end

        -- Manual E that started from void hide returns to the exact pre-E void
        -- CFrame only after the complete action/cleanup has finished. The frozen
        -- Fake Pos ghost was never touched, so it remains at its activation point.
        if not MultiTarget.Running then
            VoidSpam.ResumeAfterAction("E")
        end

        if AllIn1.Token == token then
            AllIn1.Busy = false
            AllIn1.Firing = false
            AllIn1.FiringUntil = 0
            if AllIn1.Box and AllIn1.Stroke then
                AllIn1.Box.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
                AllIn1.Stroke.Color = Color3.fromRGB(68, 68, 68)
            end
        end
    end)
end


-- ============================================================
-- MultiTarget - H: smart multi-player queue built on AllIn1
-- ============================================================

-- MultiTarget's void hide is intentionally self-contained and heartbeat-driven.
-- It does not create per-player listeners or extra permanent loops, so there is
-- nothing to leak as targets respawn/leave. The run loop owns every hide step.
MultiTarget.GetLocalHideParts = function()
    local character = LocalPlayer.Character
    if not character then
        return nil, nil, nil
    end
    local root = character:FindFirstChild("HumanoidRootPart")
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not root or not humanoid or humanoid.Health <= 0 then
        return character, nil, humanoid
    end
    return character, root, humanoid
end

MultiTarget.ReleaseSearchAnchor = function()
    local root = MultiTarget.SearchAnchoredRoot
    MultiTarget.SearchAnchoredRoot = nil
    if root and root.Parent then
        pcall(function()
            root.Anchored = false
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
    end
end

MultiTarget.ApplyHideCFrame = function(cframe)
    if not MultiTarget.VoidHideEnabled or not cframe or AllIn1.Busy then
        return false
    end

    local character, root = MultiTarget.GetLocalHideParts()
    if not character or not root then
        MultiTarget.ReleaseSearchAnchor()
        return false
    end

    -- Random VOID HIDE must stay movable. Search used to set Anchored=true,
    -- which could leave H visibly ON while the character could no longer move
    -- into the 100k hold or target phase. Search now uses a soft CFrame lock.
    if MultiTarget.SearchAnchoredRoot then
        MultiTarget.ReleaseSearchAnchor()
    end

    local ok = pcall(function()
        root.Anchored = false
        character:PivotTo(cframe)
        root.CFrame = cframe
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)
    MultiTarget.SearchAnchoredRoot = nil
    return ok and root.Parent ~= nil
end

-- The 100k pre-attack safety hold uses a real HRP anchor for exactly
-- PreAttackHoldTime. Track only the root we anchor so cleanup never blindly
-- changes an anchor state owned by the game or another feature.
MultiTarget.ReleaseHideAnchor = function()
    local root = MultiTarget.HideAnchoredRoot
    MultiTarget.HideAnchoredRoot = nil
    if root and root.Parent then
        pcall(function()
            root.Anchored = false
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
    end
end

-- One ownership-safe movement reset shared by E and H transitions. The only
-- phase allowed to leave the HRP physically anchored is the deliberate 100k
-- pre-attack hold; every movement/attack handoff calls this first.
MultiTarget.UnlockOwnedMovement = function()
    AllIn1.ReleaseAttackAnchor()
    MultiTarget.ReleaseSearchAnchor()
    MultiTarget.ReleaseHideAnchor()

    local _, root = MultiTarget.GetLocalHideParts()
    if root and root.Parent then
        pcall(function()
            root.Anchored = false
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
    end
end

MultiTarget.AnchorHideRoot = function(cframe)
    if not MultiTarget.VoidHideEnabled or not cframe or AllIn1.Busy then
        return false
    end

    local character, root = MultiTarget.GetLocalHideParts()
    if not character or not root then
        MultiTarget.ReleaseHideAnchor()
        return false
    end

    if MultiTarget.HideAnchoredRoot and MultiTarget.HideAnchoredRoot ~= root then
        MultiTarget.ReleaseHideAnchor()
    end

    local ok = pcall(function()
        character:PivotTo(cframe)
        root.CFrame = cframe
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        root.Anchored = true
    end)
    if ok then
        MultiTarget.HideAnchoredRoot = root
    end
    return ok and root.Anchored == true
end

MultiTarget.MakeRandomHideCFrame = function()
    local base = MultiTarget.StartPivot
        or (LocalPlayer.Character and LocalPlayer.Character:GetPivot())
        or CFrame.new()
    local minimum = math.max(1000, math.floor(tonumber(MultiTarget.HideMinDistance) or 50000))
    local maximum = math.max(minimum, math.floor(tonumber(MultiTarget.HideMaxDistance) or 250000))

    -- Pick one true radial distance, then distribute it over a randomized unit
    -- direction. This keeps the ACTUAL straight-line distance inside 50k-250k
    -- instead of independently applying 50k-250k to all three axes.
    local radius = math.random(minimum, maximum)
    local yaw = math.random() * math.pi * 2
    local up = 0.35 + (math.random() * 0.55) -- upper hemisphere; never below map
    local horizontal = math.sqrt(math.max(0, 1 - (up * up)))
    local direction = Vector3.new(
        math.cos(yaw) * horizontal,
        up,
        math.sin(yaw) * horizontal
    )
    local position = base.Position + (direction * radius)

    return CFrame.new(position) * (base - base.Position)
end

MultiTarget.EnsureVoidDoubleBarrel = function(forceNow)
    if not MultiTarget.Enabled or not MultiTarget.Running or AllIn1.Busy then
        return nil
    end

    local now = os.clock()
    if forceNow ~= true and (now - (MultiTarget.LastDBEnsureAt or 0)) < MultiTarget.DBEnsureInterval then
        return AllIn1.GetEquippedTool(LocalPlayer.Character)
    end
    MultiTarget.LastDBEnsureAt = now

    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not character or not humanoid or humanoid.Health <= 0 then
        return nil
    end

    local tool = AllIn1.EquipDoubleBarrel(character, humanoid, true)
    if tool then
        AllIn1.EnsureReloadHook(tool)
    end
    return tool
end

MultiTarget.BeginRandomHide = function(forceMove)
    if not MultiTarget.VoidHideEnabled or not MultiTarget.Running or AllIn1.Busy then
        return false
    end

    -- When H was launched from the user's V/void hide, stay at the saved map
    -- baseline for the ENTIRE H run. This removes repeated 100k/250k origin jumps
    -- between targets/reloads while preserving normal H hide behavior otherwise.
    if MultiTarget.GroundActionMode and MultiTarget.StartPivot then
        MultiTarget.UnlockOwnedMovement()
        MultiTarget.HideActive = true
        MultiTarget.HideMode = "search"
        MultiTarget.HideCFrame = MultiTarget.StartPivot
        MultiTarget.HideLastMove = os.clock()
        MultiTarget.ApplyHideCFrame(MultiTarget.StartPivot)
        MultiTarget.EnsureVoidDoubleBarrel(false)
        return true
    end

    -- Random-search hide must always be mobile. Clear every anchor owned by E/H
    -- before applying the new soft hide CFrame.
    MultiTarget.UnlockOwnedMovement()

    local now = os.clock()
    MultiTarget.HideActive = true
    MultiTarget.HideMode = "search"

    if forceMove
        or not MultiTarget.HideCFrame
        or (now - (MultiTarget.HideLastMove or 0)) >= MultiTarget.HideRefreshInterval
    then
        MultiTarget.HideCFrame = MultiTarget.MakeRandomHideCFrame()
        MultiTarget.HideLastMove = now
    end

    MultiTarget.ApplyHideCFrame(MultiTarget.HideCFrame)
    -- H owns slot 1 while it is safely in the void. Debounced so repeated hide
    -- Heartbeats do not spam hotbar input, but a manual weapon swap is corrected
    -- almost immediately before the next H attack/reload.
    MultiTarget.EnsureVoidDoubleBarrel(false)
    return true
end

MultiTarget.StepHide = function(forceMove)
    if not MultiTarget.VoidHideEnabled or not MultiTarget.HideActive or AllIn1.Busy then
        return false
    end

    if MultiTarget.HideMode == "search" then
        MultiTarget.BeginRandomHide(forceMove == true)
    elseif MultiTarget.HideMode == "arming" then
        -- PreAttackHide exclusively owns the REAL 100k/0.7s anchor. The global
        -- Heartbeat enforcer must not call the soft hide mover here or it would
        -- unanchor the HRP mid-hold. PreAttackHide refreshes the CFrame itself.
        return true
    else
        MultiTarget.ApplyHideCFrame(MultiTarget.HideCFrame)
    end
    return true
end

MultiTarget.WaitHidden = function(duration, runToken)
    local started = os.clock()
    while not Unloaded
        and MultiTarget.Enabled
        and MultiTarget.Token == runToken
        and (os.clock() - started) < duration
    do
        MultiTarget.StepHide(false)
        RunService.Heartbeat:Wait()
    end
end

-- Before a ready target is attacked, stop the random void movement and hold one
-- fixed point exactly 100k straight-line studs away for ~1 second. This gives target HP/KO,
-- ForceField and HRP replication a stable window before AllIn1 teleports down.
MultiTarget.PreAttackHide = function(userId, runToken)
    if not MultiTarget.VoidHideEnabled then
        return "ready"
    end

    if MultiTarget.GroundActionMode and MultiTarget.StartPivot then
        MultiTarget.UnlockOwnedMovement()
        MultiTarget.HideActive = true
        MultiTarget.HideMode = "arming"
        MultiTarget.HideCFrame = MultiTarget.StartPivot
        MultiTarget.UpdateUI()

        local started = os.clock()
        while not Unloaded
            and MultiTarget.Enabled
            and MultiTarget.Token == runToken
            and (os.clock() - started) < MultiTarget.PreAttackHoldTime
        do
            local target = findPlayerByUserId(userId)
            local humanoid = getHumanoid(target)
            local part = getTargetPart(target)
            if not target or not humanoid or humanoid.Health <= 0 or not part or isKnockedOut(target) then
                MultiTarget.HideMode = "search"
                return "defer"
            end
            if MultiTarget.ForceFieldCheck and MultiTarget.HasForceField(target) then
                MultiTarget.ForceFieldSince[userId] = MultiTarget.ForceFieldSince[userId] or os.clock()
                MultiTarget.ForceFieldWaitingUserId = userId
                MultiTarget.HideMode = "search"
                return "forcefield"
            end

            MultiTarget.ApplyHideCFrame(MultiTarget.StartPivot)
            local liveRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
            if Utility.FakePosEnabled and liveRoot and type(Utility.RestoreFakePosRoot) == "function" then
                Utility.RestoreFakePosRoot(liveRoot)
            end
            RunService.Heartbeat:Wait()
        end

        if Unloaded or not MultiTarget.Enabled or MultiTarget.Token ~= runToken then
            return "abort"
        end
        MultiTarget.HideActive = false
        MultiTarget.HideMode = "attack"
        MultiTarget.HideCFrame = nil
        MultiTarget.UpdateUI()
        return "ready"
    end

    -- Hand movement ownership from the random SEARCH anchor to the dedicated
    -- exact-100k pre-attack anchor. Never let two anchor states fight each other.
    MultiTarget.ReleaseSearchAnchor()

    local base = MultiTarget.StartPivot
        or (LocalPlayer.Character and LocalPlayer.Character:GetPivot())
        or CFrame.new()
    local distance = math.max(1000, tonumber(MultiTarget.HideLockDistance) or 100000)
    local signX = (userId % 2 == 0) and 1 or -1
    local signZ = (math.floor(userId / 2) % 2 == 0) and 1 or -1

    -- Normalize first so HideLockDistance is the REAL straight-line distance.
    -- The old X=100k/Y=100k/Z=100k point was ~173.2k studs away diagonally.
    local holdDirection = Vector3.new(signX, 1, signZ).Unit
    local position = base.Position + (holdDirection * distance)

    MultiTarget.HideActive = true
    MultiTarget.HideMode = "arming"
    MultiTarget.HideCFrame = CFrame.new(position) * (base - base.Position)
    MultiTarget.HideLastMove = os.clock()
    MultiTarget.UpdateUI()

    -- SAFETY PHASE: snap to the exact 100k point, then physically anchor the
    -- local HRP for the configured short hold. Every Heartbeat we revalidate the target and reapply
    -- the same CFrame/zero velocities so no movement can accumulate before the
    -- attack handoff. Any abort/defer/ForceField path releases the anchor first.
    if not MultiTarget.AnchorHideRoot(MultiTarget.HideCFrame) then
        MultiTarget.ReleaseHideAnchor()
        MultiTarget.HideMode = "search"
        return "defer"
    end

    local started = os.clock()
    while not Unloaded
        and MultiTarget.Enabled
        and MultiTarget.Token == runToken
        and (os.clock() - started) < MultiTarget.PreAttackHoldTime
    do
        local target = findPlayerByUserId(userId)
        local humanoid = getHumanoid(target)
        local part = getTargetPart(target)
        if not target or not humanoid or humanoid.Health <= 0 or not part or isKnockedOut(target) then
            MultiTarget.ReleaseHideAnchor()
            MultiTarget.HideMode = "search"
            return "defer"
        end

        if MultiTarget.ForceFieldCheck and MultiTarget.HasForceField(target) then
            MultiTarget.ForceFieldSince[userId] = MultiTarget.ForceFieldSince[userId] or os.clock()
            MultiTarget.ForceFieldWaitingUserId = userId
            MultiTarget.ReleaseHideAnchor()
            MultiTarget.HideMode = "search"
            return "forcefield"
        end

        -- Hard-stop all local movement throughout the configured safety hold.
        -- AnchorHideRoot also refreshes the exact 100k CFrame in case the
        -- character/root was replaced between Heartbeats.
        if not MultiTarget.AnchorHideRoot(MultiTarget.HideCFrame) then
            MultiTarget.ReleaseHideAnchor()
            MultiTarget.HideMode = "search"
            return "defer"
        end
        RunService.Heartbeat:Wait()
    end

    if Unloaded or not MultiTarget.Enabled or MultiTarget.Token ~= runToken then
        MultiTarget.ReleaseHideAnchor()
        return "abort"
    end

    -- Release the physical 100k anchor completely BEFORE target movement. One
    -- Heartbeat is intentionally given to Roblox after Anchored=false so the next
    -- PivotTo/CFrame is not swallowed by the previous anchored physics state.
    MultiTarget.UnlockOwnedMovement()
    RunService.Heartbeat:Wait()
    if Unloaded or not MultiTarget.Enabled or MultiTarget.Token ~= runToken then
        return "abort"
    end

    MultiTarget.HideActive = false
    MultiTarget.HideMode = "attack"
    MultiTarget.HideCFrame = nil
    MultiTarget.UpdateUI()
    return "ready"
end

MultiTarget.StopHide = function(mode)
    MultiTarget.ReleaseSearchAnchor()
    MultiTarget.ReleaseHideAnchor()
    MultiTarget.HideActive = false
    MultiTarget.HideMode = mode or "idle"
    MultiTarget.HideCFrame = nil
    MultiTarget.HideLastMove = 0
end

MultiTarget.UpdateUI = function()
    local function paint(box, stroke, enabled, color)
        if box and stroke then
            box.BackgroundColor3 = enabled and color or Color3.fromRGB(24, 24, 24)
            stroke.Color = enabled and color or Color3.fromRGB(68, 68, 68)
        end
    end

    if MultiTarget.Box and MultiTarget.Stroke then
        paint(MultiTarget.Box, MultiTarget.Stroke, MultiTarget.Enabled, Theme.Accent)
        paint(MultiTarget.BlacklistBox, MultiTarget.BlacklistStroke, MultiTarget.BlacklistOnly, Theme.RedBright)
        paint(MultiTarget.SelectedBox, MultiTarget.SelectedStroke, MultiTarget.SelectedOnly, Theme.AccentBright)
        paint(MultiTarget.SafeBox, MultiTarget.SafeStroke, MultiTarget.SafeMode, Theme.Accent)
        paint(MultiTarget.ForceFieldBox, MultiTarget.ForceFieldStroke, MultiTarget.ForceFieldCheck, Theme.AccentBright)
        paint(MultiTarget.ReturnBox, MultiTarget.ReturnStroke, MultiTarget.ReturnBetweenTargets, Theme.Accent)
    end

    if MultiTarget.PriorityButton then
        MultiTarget.PriorityButton.Text = "priority: " .. tostring(MultiTarget.Priority)
    end

    if MultiTarget.StatusLabel then
        if MultiTarget.Running then
            local modeText = "ACTIVE"
            if MultiTarget.ForceFieldWaitingUserId then
                modeText = "FF WAIT"
            elseif MultiTarget.HideMode == "arming" then
                modeText = "100K ANCHOR"
            elseif MultiTarget.HideMode == "search" then
                modeText = "VOID HIDE"
            elseif MultiTarget.HideMode == "attack" then
                modeText = "ATTACK"
            end
            MultiTarget.StatusLabel.Text = string.format(
                "%d/%d  |  %s  |  ok %d  fail %d  |  J abort",
                MultiTarget.CurrentIndex or 0,
                MultiTarget.Total or 0,
                modeText,
                MultiTarget.Completed or 0,
                MultiTarget.Failed or 0
            )
            MultiTarget.StatusLabel.TextColor3 = Theme.AccentBright
        else
            MultiTarget.StatusLabel.Text = "idle  |  abort J"
            MultiTarget.StatusLabel.TextColor3 = Theme.Muted
        end
    end

    if MultiTarget.HUD then
        MultiTarget.HUD.Visible = MultiTarget.Running
        if MultiTarget.Running then
            local target = MultiTarget.CurrentUserId and findPlayerByUserId(MultiTarget.CurrentUserId)
            local targetName = target and target.DisplayName or "waiting"
            local stateSuffix = ""
            if MultiTarget.RespawnRecovering then
                stateSuffix = "  •  RESPAWN RECOVERY"
            elseif MultiTarget.MissRecovering then
                stateSuffix = "  •  MISS RELOAD"
            elseif MultiTarget.ForceFieldWaitingUserId == MultiTarget.CurrentUserId then
                stateSuffix = "  •  FF WAIT"
            elseif MultiTarget.HideMode == "arming" then
                stateSuffix = "  •  100K HOLD"
            elseif MultiTarget.HideMode == "search" then
                stateSuffix = "  •  VOID HIDE"
            elseif MultiTarget.HideMode == "attack" then
                stateSuffix = "  •  ATTACK"
            end
            MultiTarget.HUD.Text = string.format(
                "MULTITARGET  %d/%d  •  %s  •  %s%s",
                MultiTarget.CurrentIndex or 0,
                MultiTarget.Total or 0,
                targetName,
                MultiTarget.SafeMode and "SAFE" or "FAST",
                stateSuffix
            )
        else
            MultiTarget.HUD.Text = ""
        end
    end
end

-- Hood Customs / FFA spawn protection checker. This follows the actual
-- replicated ForceField state instead of assuming a fixed duration. Standard
-- ForceField instances are preferred; conservative custom spawn-protection
-- markers are accepted as fallbacks. No persistent per-player connections are
-- created, keeping the checker light even in full 32-player servers.
MultiTarget.HasForceField = function(player)
    if not player or player == LocalPlayer then
        return false
    end

    local character = player.Character
    if not character then
        return false
    end

    local direct = character:FindFirstChildOfClass("ForceField")
    if direct and direct.Parent then
        return true
    end

    local ok, nested = pcall(function()
        return character:FindFirstChildWhichIsA("ForceField", true)
    end)
    if ok and nested and nested.Parent then
        return true
    end

    -- A few hood-style games expose spawn protection as a replicated marker
    -- instead of a ForceField class. Only explicit true markers count.
    local marker = character:FindFirstChild("ForceField", true)
        or character:FindFirstChild("SpawnProtection", true)
        or character:FindFirstChild("SpawnProtected", true)
    if marker and marker:IsA("BoolValue") and marker.Value == true then
        return true
    end

    return character:GetAttribute("ForceField") == true
        or character:GetAttribute("SpawnProtection") == true
        or character:GetAttribute("SpawnProtected") == true
        or player:GetAttribute("SpawnProtection") == true
        or player:GetAttribute("SpawnProtected") == true
end

MultiTarget.GetCandidateMetrics = function(player)
    local humanoid = getHumanoid(player)
    local part = getTargetPart(player)
    if not humanoid or humanoid.Health <= 0 or not part or isKnockedOut(player) then
        return nil
    end

    local localRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local distance = localRoot and (part.Position - localRoot.Position).Magnitude
        or (Camera and (part.Position - Camera.CFrame.Position).Magnitude or math.huge)
    local motion = AllIn1.SampleTargetMotion(part, os.clock())
    local speed = motion and motion.Speed or part.AssemblyLinearVelocity.Magnitude
    local vertical = motion and motion.Vertical or math.abs(part.AssemblyLinearVelocity.Y)
    local healthRatio = humanoid.Health / math.max(1, humanoid.MaxHealth)
    local character = player.Character
    local armed = character and character:FindFirstChildOfClass("Tool") ~= nil

    -- Threat favors fast/armed/near targets without introducing any game-specific
    -- remote assumptions. It is only an ordering score.
    local threat = speed * 1.35
        + vertical * 0.35
        + math.max(0, 600 - math.min(distance, 600)) * 0.22
        + (armed and 90 or 0)

    return {
        Distance = distance,
        Speed = speed,
        Vertical = vertical,
        HealthRatio = healthRatio,
        Threat = threat,
        CFrameMotion = motion and motion.CFrameMotion == true or false,
        FlyMotion = motion and motion.FlyMotion == true or false,
    }
end

MultiTarget.IsPoolMatch = function(player)
    if not player or player == LocalPlayer or isSameTeam(player) then
        return false
    end

    -- BLACKLIST PRIORITY FOR H:
    -- If at least one blacklisted player is currently present in the server, H
    -- automatically treats the blacklist as its only target pool. This mirrors
    -- the existing C-lock blacklist priority without changing any other H mode.
    -- When no blacklisted player is present, H falls back to its normal pool and
    -- the existing manual "blacklist only" / "selected only" filters still work.
    local blacklistPriority = hasPresentBlacklistedTargets()
    if blacklistPriority then
        if not isBlacklisted(player) then
            return false
        end
    elseif MultiTarget.BlacklistOnly and not isBlacklisted(player) then
        return false
    end

    if MultiTarget.SelectedOnly and not MultiTarget.SelectedUserIds[player.UserId] then
        return false
    end
    return true
end

MultiTarget.BuildQueue = function()
    table.clear(MultiTarget.Queue)
    table.clear(MultiTarget.QueueSet)
    table.clear(MultiTarget.KilledThisPass)
    table.clear(MultiTarget.RetryCounts)
    table.clear(MultiTarget.PostponeCounts)
    MultiTarget.QueueDirty = false

    local candidates = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if MultiTarget.IsPoolMatch(player) then
            local metrics = MultiTarget.GetCandidateMetrics(player)
            if metrics then
                table.insert(candidates, {
                    Player = player,
                    UserId = player.UserId,
                    Metrics = metrics,
                })
            end
        end
    end

    table.sort(candidates, function(a, b)
        if MultiTarget.Priority == "lowest hp" then
            if a.Metrics.HealthRatio == b.Metrics.HealthRatio then
                return a.Metrics.Distance < b.Metrics.Distance
            end
            return a.Metrics.HealthRatio < b.Metrics.HealthRatio
        elseif MultiTarget.Priority == "threat" then
            if a.Metrics.Threat == b.Metrics.Threat then
                return a.Metrics.Distance < b.Metrics.Distance
            end
            return a.Metrics.Threat > b.Metrics.Threat
        end
        return a.Metrics.Distance < b.Metrics.Distance
    end)

    for _, candidate in ipairs(candidates) do
        table.insert(MultiTarget.Queue, candidate.UserId)
        MultiTarget.QueueSet[candidate.UserId] = true
    end

    MultiTarget.Total = #MultiTarget.Queue
    MultiTarget.CurrentIndex = 0
    Config.ESP.HealthDirty = true
    MultiTarget.UpdateUI()
    return #MultiTarget.Queue
end

MultiTarget.PrepareAmmo = function()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not character or not humanoid then
        return false
    end

    -- Same weapon/equip behavior as E. H only changes *when* it is allowed to
    -- leave the void: an actually empty supported magazine must finish the SAME
    -- full reload worker used by E before H can approach the next target.
    local tool = AllIn1.EquipDoubleBarrel(character, humanoid, true)
    if not tool then
        return false
    end

    AllIn1.EnsureReloadHook(tool)
    local capacity = AllIn1.GetWeaponCapacity(tool)
    if not capacity then
        return true
    end

    -- A reload worker belongs to exactly one equipped gun. If H just equipped
    -- its attack gun while an older weapon's worker is still alive, retire the
    -- stale worker before any aim/fire gate sees the global Reloading flag.
    if AllIn1.Reloading and AllIn1.ReloadTool ~= tool then
        AllIn1.ReloadToken = AllIn1.ReloadToken + 1
        AllIn1.Reloading = false
        AllIn1.ReloadTool = nil
    end

    local ammo = AllIn1.ReadAmmo(tool)
    local predictedEmpty = ammo == nil and (AllIn1.ShotCounts[tool] or 0) >= capacity
    local empty = (ammo ~= nil and ammo <= 0) or predictedEmpty

    -- If another heartbeat already started this exact empty-mag reload, join it
    -- instead of spawning another R loop. Partial magazines are intentionally
    -- left alone, matching E's empty-only rule.
    if empty and not AllIn1.Reloading then
        AllIn1.StartReload(tool)
    end

    if empty or (AllIn1.Reloading and AllIn1.ReloadTool == tool) then
        local started = os.clock()
        while not Unloaded
            and MultiTarget.Enabled
            and MultiTarget.Running
            and (os.clock() - started) < MultiTarget.AmmoReadyTimeout
        do
            local currentAmmo = AllIn1.ReadAmmo(tool)
            if currentAmmo ~= nil then
                if currentAmmo >= capacity then
                    AllIn1.ShotCounts[tool] = 0
                    return true
                end
            elseif not AllIn1.Reloading then
                -- Ammo is hidden by this game build. StartReload's bounded fallback
                -- has finished its R pulses, so the exact shot counter is reset there.
                return (AllIn1.ShotCounts[tool] or 0) < capacity
            end

            -- Stay in the safe void for the entire reload. H never burns its
            -- attack/verification window while R is still filling the gun.
            MultiTarget.StepHide(false)
            RunService.Heartbeat:Wait()
        end

        local finalAmmo = AllIn1.ReadAmmo(tool)
        if finalAmmo ~= nil then
            return finalAmmo >= capacity
        end
        return not AllIn1.Reloading and (AllIn1.ShotCounts[tool] or 0) < capacity
    end

    return true
end


MultiTarget.WaitForLocalRespawn = function(runToken)
    MultiTarget.RespawnRecovering = true
    MultiTarget.HideMode = "search"
    MultiTarget.UpdateUI()

    local started = os.clock()
    while not Unloaded
        and MultiTarget.Enabled
        and MultiTarget.Running
        and MultiTarget.Token == runToken
        and (os.clock() - started) < MultiTarget.RespawnReadyTimeout
    do
        local character = LocalPlayer.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local root = character and character:FindFirstChild("HumanoidRootPart")

        if character and humanoid and root and humanoid.Health > 0 then
            -- New life: cancel all stale target/stomp physics, force slot 1 / DB
            -- out immediately, then put the fresh character back into H's void
            -- state before the queue is allowed to attack again.
            MultiTarget.CancelAllIn1()
            MultiTarget.UnlockOwnedMovement()
            root.Anchored = false

            if MultiTarget.RespawnEquipDelay > 0 then
                task.wait(MultiTarget.RespawnEquipDelay)
            end

            local tool = AllIn1.EquipDoubleBarrel(character, humanoid, true)
            if tool then
                AllIn1.EnsureReloadHook(tool)
            end

            MultiTarget.StopHide("search")
            MultiTarget.HideActive = true
            MultiTarget.HideMode = "search"
            MultiTarget.BeginRandomHide(true)
            MultiTarget.RespawnRecovering = false
            MultiTarget.UpdateUI()
            return true
        end

        RunService.Heartbeat:Wait()
    end

    MultiTarget.RespawnRecovering = false
    MultiTarget.UpdateUI()
    return false
end

MultiTarget.RefillAfterMiss = function(runToken)
    if not MultiTarget.Enabled or not MultiTarget.Running or MultiTarget.Token ~= runToken then
        return false
    end

    -- The caller has already left the target area. Reassert the void CFrame before
    -- touching reload state so a miss can never leave us standing beside somebody.
    MultiTarget.MissRecovering = true
    MultiTarget.HideMode = "search"
    MultiTarget.BeginRandomHide(true)
    MultiTarget.StepHide(false)
    MultiTarget.UpdateUI()

    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not character or not humanoid or humanoid.Health <= 0 or not root then
        MultiTarget.MissRecovering = false
        return false
    end

    local tool = AllIn1.EquipDoubleBarrel(character, humanoid, true)
    if not tool then
        MultiTarget.MissRecovering = false
        return false
    end

    AllIn1.EnsureReloadHook(tool)
    local capacity = AllIn1.GetWeaponCapacity(tool)
    if not capacity then
        MultiTarget.MissRecovering = false
        return true
    end

    -- Kill any stale worker tied to a previous tool before forcing this H miss
    -- recovery to full. E's normal empty-only behavior is unchanged.
    if AllIn1.Reloading and AllIn1.ReloadTool ~= tool then
        AllIn1.ReloadToken = AllIn1.ReloadToken + 1
        AllIn1.Reloading = false
        AllIn1.ReloadTool = nil
    end

    local ammo = AllIn1.ReadAmmo(tool)
    if ammo ~= nil and ammo >= capacity then
        AllIn1.ShotCounts[tool] = 0
        MultiTarget.MissRecovering = false
        return true
    end

    AllIn1.StartReload(tool, true)
    while not Unloaded
        and MultiTarget.Enabled
        and MultiTarget.Running
        and MultiTarget.Token == runToken
    do
        local liveCharacter = LocalPlayer.Character
        local liveHumanoid = liveCharacter and liveCharacter:FindFirstChildOfClass("Humanoid")
        if not liveCharacter or not liveHumanoid or liveHumanoid.Health <= 0 then
            MultiTarget.MissRecovering = false
            return false
        end

        local currentAmmo = AllIn1.ReadAmmo(tool)
        if currentAmmo ~= nil and currentAmmo >= capacity then
            AllIn1.ShotCounts[tool] = 0
            MultiTarget.MissRecovering = false
            return true
        end

        if not AllIn1.Reloading then
            -- Some reload implementations accept one shell/pulse at a time. If the
            -- worker ended before readable ammo is full, immediately start another
            -- force-full pass while still hidden.
            if currentAmmo ~= nil and currentAmmo < capacity then
                AllIn1.StartReload(tool, true)
            elseif currentAmmo == nil then
                MultiTarget.MissRecovering = false
                return (AllIn1.ShotCounts[tool] or 0) < capacity
            end
        end

        MultiTarget.StepHide(false)
        RunService.Heartbeat:Wait()
    end

    local finalAmmo = AllIn1.ReadAmmo(tool)
    local ready = (finalAmmo ~= nil and finalAmmo >= capacity)
        or (finalAmmo == nil and not AllIn1.Reloading and (AllIn1.ShotCounts[tool] or 0) < capacity)
    if ready then
        AllIn1.ShotCounts[tool] = 0
    end
    MultiTarget.MissRecovering = false
    return ready
end

MultiTarget.CancelAllIn1 = function()
    if not AllIn1.Busy then
        -- Still invalidate any stomp coroutine that is one scheduler frame behind
        -- the Busy flag; this prevents a stale stomp pulse from leaking into the
        -- next H target/respawn.
        AllIn1.StompToken = (AllIn1.StompToken or 0) + 1
        AllIn1.Stomping = false
        AllIn1.ShotAimPosition = nil
        AllIn1.ShotTargetPart = nil
        AllIn1.ShotGeometryReady = false
        AllIn1.HealthArmorBeforeShot = nil
        AllIn1.ReleaseAttackAnchor()
        Utility.FakePosCombatHold = false
        Utility.FakePosCombatToken = 0
        if Utility.FakePosEnabled and type(Utility.RestoreFakePosRoot) == "function" then
            Utility.RestoreFakePosRoot()
        end
        return
    end
    AllIn1.Token = AllIn1.Token + 1
    AllIn1.StompToken = (AllIn1.StompToken or 0) + 1
    AllIn1.ToolRecoveryToken = (AllIn1.ToolRecoveryToken or 0) + 1
    AllIn1.ToolRecoveryBusy = false
    AllIn1.Busy = false
    AllIn1.Stomping = false
    AllIn1.Firing = false
    AllIn1.FiringUntil = 0
    AllIn1.ShotAimPosition = nil
    AllIn1.ShotTargetPart = nil
    AllIn1.ShotGeometryReady = false
    AllIn1.ReleaseAttackAnchor()
    Utility.FakePosCombatHold = false
    Utility.FakePosCombatToken = 0
    if Utility.FakePosEnabled and type(Utility.RestoreFakePosRoot) == "function" then
        Utility.RestoreFakePosRoot()
    end
end

MultiTarget.ProcessTarget = function(userId, runToken)
    MultiTarget.ForceSafeCurrent = false
    if MultiTarget.HideMode ~= "arming" then
        MultiTarget.HideMode = "search"
    end
    if not MultiTarget.Enabled or MultiTarget.Token ~= runToken then
        return "abort"
    end

    local localCharacter = LocalPlayer.Character
    local localHumanoid = localCharacter and localCharacter:FindFirstChildOfClass("Humanoid")
    local localRoot = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")
    if not localCharacter or not localHumanoid or localHumanoid.Health <= 0 or not localRoot then
        return "local_respawn"
    end

    local target = findPlayerByUserId(userId)
    if not target or not MultiTarget.IsPoolMatch(target) then
        return "skip"
    end

    local metrics = MultiTarget.GetCandidateMetrics(target)
    if not metrics then
        -- Dead/KO/respawning targets are not wasted attempts. Stay hidden while
        -- the scanner keeps reading their replicated HP/KO state.
        MultiTarget.HideMode = "search"
        MultiTarget.UpdateUI()
        return "defer"
    end

    -- ForceField check: never spend a DB shot on replicated spawn protection.
    -- Protected targets move to the back of the same queue, allowing vulnerable
    -- players to continue immediately. As soon as the field actually disappears,
    -- wait a tiny replication grace then attack; there is no guessed FFA timer.
    if MultiTarget.ForceFieldCheck then
        if MultiTarget.HasForceField(target) then
            local now = os.clock()
            MultiTarget.ForceFieldSince[userId] = MultiTarget.ForceFieldSince[userId] or now
            MultiTarget.ForceFieldWaitingUserId = userId
            MultiTarget.HideMode = "search"
            MultiTarget.UpdateUI()

            if now - MultiTarget.ForceFieldSince[userId] >= MultiTarget.ForceFieldWaitTimeout then
                MultiTarget.ForceFieldSince[userId] = nil
                if MultiTarget.ForceFieldWaitingUserId == userId then
                    MultiTarget.ForceFieldWaitingUserId = nil
                end
                MultiTarget.UpdateUI()
                return "forcefield_timeout"
            end
            return "forcefield"
        elseif MultiTarget.ForceFieldSince[userId] then
            local releaseStarted = os.clock()
            while not Unloaded
                and MultiTarget.Enabled
                and MultiTarget.Token == runToken
                and (os.clock() - releaseStarted) < MultiTarget.ForceFieldReleaseGrace
            do
                local liveTarget = findPlayerByUserId(userId)
                if not liveTarget then
                    return "skip"
                end
                if MultiTarget.HasForceField(liveTarget) then
                    MultiTarget.ForceFieldWaitingUserId = userId
                    MultiTarget.UpdateUI()
                    return "forcefield"
                end
                MultiTarget.StepHide(false)
                RunService.Heartbeat:Wait()
            end

            MultiTarget.ForceFieldSince[userId] = nil
            if MultiTarget.ForceFieldWaitingUserId == userId then
                MultiTarget.ForceFieldWaitingUserId = nil
            end

            target = findPlayerByUserId(userId)
            metrics = target and MultiTarget.GetCandidateMetrics(target) or nil
            if not metrics then
                MultiTarget.UpdateUI()
                return "defer"
            end
            MultiTarget.UpdateUI()
        end
    else
        MultiTarget.ForceFieldSince[userId] = nil
        if MultiTarget.ForceFieldWaitingUserId == userId then
            MultiTarget.ForceFieldWaitingUserId = nil
        end
    end

    local unsafe = not (metrics.CFrameMotion or metrics.FlyMotion)
        and (metrics.Speed >= MultiTarget.UnsafeSpeed
            or metrics.Vertical >= MultiTarget.UnsafeVerticalSpeed)

    -- Any retry automatically upgrades to the full safe-shot profile. A target
    -- that already failed once should never be re-attempted with shortened
    -- settling/verification timings.
    MultiTarget.ForceSafeCurrent = (MultiTarget.RetryCounts[userId] or 0) > 0
    if unsafe then
        local count = MultiTarget.PostponeCounts[userId] or 0
        if count < MultiTarget.UnsafePostponeLimit then
            return "defer"
        end
        -- After a couple postponements, attempt the same target with the full
        -- safe profile instead of starving that UserId forever.
        MultiTarget.ForceSafeCurrent = true
    end

    -- Get the gun/ammo ready while still in the random safe hide. Never start
    -- the target approach with an empty magazine or an unfinished reload.
    local ammoReady = MultiTarget.PrepareAmmo()
    if not MultiTarget.Enabled or MultiTarget.Token ~= runToken then
        MultiTarget.ForceSafeCurrent = false
        return "abort"
    end
    if not ammoReady then
        MultiTarget.ForceSafeCurrent = false
        return "reload"
    end

    -- A target is now live, attackable and our weapon prep is finished. Freeze
    -- the void hide at a fixed 100k-stud point for ~1 second, continuously
    -- revalidate HP/KO/ForceField, then immediately hand control to AllIn1.
    local hideResult = MultiTarget.PreAttackHide(userId, runToken)
    if hideResult ~= "ready" then
        MultiTarget.BeginRandomHide(true)
        MultiTarget.UpdateUI()
        return hideResult
    end

    -- Temporarily hand the exact queue UserId to the existing AllIn1 sequence.
    -- The original C lock is restored after the entire MultiTarget run ends.
    MultiTarget.CurrentUserId = userId
    Aim.CurrentTarget = target
    Aim.LockedUserId = userId
    Aim.Toggled = true
    Aim.Active = false
    Aim.SmoothedVelocity = Vector3.zero
    updateTargetThumbnail(target)
    updateTargetHUD()
    MultiTarget.UpdateUI()

    AllIn1.LastResultUserId = nil
    AllIn1.LastDamageConfirmed = false
    AllIn1.LastKillVerified = false
    AllIn1.LastStompVerified = false
    AllIn1.LastShotAttempts = 0
    AllIn1.Run(true)

    -- AllIn1 sets Busy synchronously after its target/input checks. If it did not
    -- start, treat this as a retryable miss instead of hanging the whole queue.
    if not AllIn1.Busy then
        MultiTarget.ForceSafeCurrent = false
        local currentCharacter = LocalPlayer.Character
        local currentHumanoid = currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")
        if not currentCharacter or not currentHumanoid or currentHumanoid.Health <= 0 then
            return "local_respawn"
        end
        return "failed"
    end

    local started = os.clock()
    while not Unloaded
        and MultiTarget.Enabled
        and MultiTarget.Token == runToken
        and AllIn1.Busy
        and (AllIn1.Stomping or (os.clock() - started) < MultiTarget.PerTargetTimeout)
    do
        RunService.Heartbeat:Wait()
    end

    if not MultiTarget.Enabled or MultiTarget.Token ~= runToken then
        MultiTarget.CancelAllIn1()
        MultiTarget.ForceSafeCurrent = false
        return "abort"
    end

    if AllIn1.Busy then
        MultiTarget.CancelAllIn1()
        MultiTarget.ForceSafeCurrent = false
        local currentCharacter = LocalPlayer.Character
        local currentHumanoid = currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")
        if not currentCharacter or not currentHumanoid or currentHumanoid.Health <= 0 then
            return "local_respawn"
        end
        return "failed"
    end

    local currentCharacter = LocalPlayer.Character
    local currentHumanoid = currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")
    if not currentCharacter or not currentHumanoid or currentHumanoid.Health <= 0 then
        MultiTarget.ForceSafeCurrent = false
        return "local_respawn"
    end

    if AllIn1.LastResultUserId == userId
        and AllIn1.LastStompVerified
    then
        MultiTarget.KilledThisPass[userId] = true
        MultiTarget.Completed = MultiTarget.Completed + 1
        MultiTarget.ForceFieldSince[userId] = nil
        if MultiTarget.ForceFieldWaitingUserId == userId then
            MultiTarget.ForceFieldWaitingUserId = nil
        end
        MultiTarget.ForceSafeCurrent = false
        return "success"
    end

    MultiTarget.ForceSafeCurrent = false
    if (AllIn1.LastShotAttempts or 0) > 0
        and not AllIn1.LastDamageConfirmed
        and not AllIn1.LastKillVerified
    then
        return "miss"
    end
    return "failed"
end

MultiTarget.Restore = function()
    -- Always clear the 100k/E movement locks BEFORE returning to H's saved
    -- position. This prevents the final PivotTo from fighting a stale anchor.
    if MultiTarget.UnlockOwnedMovement then
        MultiTarget.UnlockOwnedMovement()
    end

    if Unloaded then
        MultiTarget.CurrentUserId = nil
        MultiTarget.ForceSafeCurrent = false
        MultiTarget.RespawnRecovering = false
        MultiTarget.MissRecovering = false
        MultiTarget.Running = false
        MultiTarget.Enabled = false
        MultiTarget.StopHide("idle")
        table.clear(MultiTarget.Queue)
        table.clear(MultiTarget.QueueSet)
        table.clear(MultiTarget.ForceFieldSince)
        MultiTarget.ForceFieldWaitingUserId = nil
        return
    end

    local saved = MultiTarget.SavedAim
    local character = LocalPlayer.Character
    if MultiTarget.StartPivot and character and character.Parent then
        pcall(function()
            character:PivotTo(MultiTarget.StartPivot)
            local root = character:FindFirstChild("HumanoidRootPart")
            if root then
                root.CFrame = MultiTarget.StartPivot
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
            end
        end)
    end

    if saved then
        Aim.Toggled = saved.Toggled == true
        Aim.Active = saved.Active == true
        Aim.LockedUserId = saved.LockedUserId
        Aim.CurrentTarget = saved.CurrentUserId and findPlayerByUserId(saved.CurrentUserId) or nil
        Aim.SmoothedVelocity = Vector3.zero
    end

    MultiTarget.CurrentUserId = nil
    MultiTarget.ForceSafeCurrent = false
    MultiTarget.RespawnRecovering = false
    MultiTarget.MissRecovering = false
    MultiTarget.StopHide("idle")
    MultiTarget.CurrentIndex = 0
    MultiTarget.Total = 0
    table.clear(MultiTarget.Queue)
    table.clear(MultiTarget.QueueSet)
    table.clear(MultiTarget.ForceFieldSince)
    MultiTarget.ForceFieldWaitingUserId = nil
    MultiTarget.Running = false
    MultiTarget.Enabled = false
    MultiTarget.StartPivot = nil
    MultiTarget.SavedAim = nil
    if MultiTarget.SavedVoidSpamEnabled == true then
        if VoidSpam.Enabled then
            VoidSpam.ResumeAfterAction("H")
        else
            setVoidSpamEnabled(true)
        end
    end
    MultiTarget.SavedVoidSpamEnabled = nil
    MultiTarget.GroundActionMode = false
    Config.ESP.HealthDirty = true
    if MultiTarget.RefreshMenu then
        MultiTarget.RefreshMenu()
    end
    updateTargetHUD()
    MultiTarget.UpdateUI()
end

MultiTarget.Run = function(runToken)
    while not Unloaded and MultiTarget.Enabled and MultiTarget.Token == runToken do
        -- Never idle beside the map/last KO target. Searching, queue rebuilds,
        -- ForceField waits and deferred targets all happen from the safe void hide.
        MultiTarget.BeginRandomHide(false)
        MultiTarget.BuildQueue()

        if #MultiTarget.Queue == 0 then
            MultiTarget.CurrentUserId = nil
            MultiTarget.HideMode = "search"
            MultiTarget.UpdateUI()
            MultiTarget.WaitHidden(MultiTarget.HiddenScanInterval, runToken)
        else
            local cursor = 1
            while not Unloaded
                and MultiTarget.Enabled
                and MultiTarget.Token == runToken
                and cursor <= #MultiTarget.Queue
            do
                if MultiTarget.QueueDirty then
                    break
                end

                local userId = MultiTarget.Queue[cursor]
                cursor = cursor + 1

                if not MultiTarget.KilledThisPass[userId] then
                    MultiTarget.CurrentIndex = math.min(cursor - 1, MultiTarget.Total)
                    MultiTarget.CurrentUserId = userId
                    MultiTarget.BeginRandomHide(false)
                    MultiTarget.UpdateUI()

                    local result = MultiTarget.ProcessTarget(userId, runToken)
                    if result == "abort" then
                        break
                    end

                    -- As soon as an attack/attempt finishes, leave the target area
                    -- before queue bookkeeping. This is especially important after
                    -- KO/stomp, where the next target may not be ready yet.
                    MultiTarget.BeginRandomHide(true)
                    MultiTarget.UpdateUI()

                    if result == "local_respawn" then
                        -- Our own KO/death never consumes this target's retry budget.
                        -- Wait for the fresh character, equip slot 1 immediately, move
                        -- it back to void, then rebuild/retry H automatically.
                        local recovered = MultiTarget.WaitForLocalRespawn(runToken)
                        if recovered then
                            MultiTarget.QueueDirty = true
                        else
                            break
                        end
                    elseif result == "forcefield" then
                        -- ForceField waits do not consume retry/postpone budgets. Keep
                        -- the protected UserId rotating at the back until the actual
                        -- replicated field disappears, while other targets keep moving.
                        table.insert(MultiTarget.Queue, userId)
                        MultiTarget.WaitHidden(MultiTarget.ForceFieldPollInterval, runToken)
                    elseif result == "reload" then
                        -- Empty-mag H reloads are normal state, not failed attacks and
                        -- not unsafe-target defers. Keep this UserId queued while the
                        -- shared E/H reload worker fills the gun in the void.
                        table.insert(MultiTarget.Queue, userId)
                        MultiTarget.WaitHidden(MultiTarget.HiddenScanInterval, runToken)
                    elseif result == "forcefield_timeout" then
                        -- Safety valve for permanent/custom protection. Drop it for
                        -- this pass; continuous mode will discover it again later.
                        MultiTarget.ForceFieldSince[userId] = nil
                        if MultiTarget.ForceFieldWaitingUserId == userId then
                            MultiTarget.ForceFieldWaitingUserId = nil
                        end
                    elseif result == "defer" then
                        -- Smart reordering: temporarily unavailable / unsafe players
                        -- move to the back a bounded number of times without consuming
                        -- a retry. The local character stays hidden while they recover.
                        local defers = (MultiTarget.PostponeCounts[userId] or 0) + 1
                        MultiTarget.PostponeCounts[userId] = defers
                        if defers <= MultiTarget.UnsafePostponeLimit then
                            table.insert(MultiTarget.Queue, userId)
                        end
                    elseif result == "miss" then
                        -- Verified H miss: we are already back in void. Refill the
                        -- attack gun all the way to its known capacity, then retry.
                        local reloaded = MultiTarget.RefillAfterMiss(runToken)
                        local retries = (MultiTarget.RetryCounts[userId] or 0) + 1
                        MultiTarget.RetryCounts[userId] = retries
                        MultiTarget.Failed = MultiTarget.Failed + 1
                        if not reloaded then
                            local liveCharacter = LocalPlayer.Character
                            local liveHumanoid = liveCharacter and liveCharacter:FindFirstChildOfClass("Humanoid")
                            if not liveCharacter or not liveHumanoid or liveHumanoid.Health <= 0 then
                                if MultiTarget.WaitForLocalRespawn(runToken) then
                                    MultiTarget.QueueDirty = true
                                else
                                    break
                                end
                            end
                        end
                        if retries <= MultiTarget.RetryLimit and not MultiTarget.QueueDirty then
                            MultiTarget.WaitHidden(MultiTarget.RetrySettleDelay, runToken)
                            table.insert(MultiTarget.Queue, userId)
                        end
                    elseif result == "failed" then
                        local retries = (MultiTarget.RetryCounts[userId] or 0) + 1
                        MultiTarget.RetryCounts[userId] = retries
                        MultiTarget.Failed = MultiTarget.Failed + 1
                        if retries <= MultiTarget.RetryLimit then
                            -- Give replication a short hidden reset before the
                            -- same UserId comes back with the forced-safe profile.
                            MultiTarget.WaitHidden(MultiTarget.RetrySettleDelay, runToken)
                            table.insert(MultiTarget.Queue, userId)
                        end
                    end
                    MultiTarget.UpdateUI()
                end
            end

            -- A pass never attacks one UserId twice after a verified kill. In
            -- continuous mode, the next pass rebuilds from live characters so
            -- respawned selected/blacklisted users can be processed again.
            table.clear(MultiTarget.QueueSet)
            Config.ESP.HealthDirty = true

            if MultiTarget.Enabled and MultiTarget.Token == runToken then
                MultiTarget.BeginRandomHide(true)
                MultiTarget.WaitHidden(MultiTarget.CycleDelay, runToken)
            end
        end

        if not MultiTarget.Continuous or not MultiTarget.RespawnMemory then
            break
        end
    end

    MultiTarget.CancelAllIn1()
    MultiTarget.Restore()
end

MultiTarget.SetEnabled = function(state)
    if Unloaded then
        return
    end

    state = state == true
    if state and MultiTarget.Running then
        return
    end
    if state == MultiTarget.Enabled and (not state or MultiTarget.Running) then
        return
    end

    if not state then
        MultiTarget.Enabled = false
        MultiTarget.Token = MultiTarget.Token + 1
        MultiTarget.CancelAllIn1()
        MultiTarget.UnlockOwnedMovement()
        MultiTarget.RespawnRecovering = false
        if MultiTarget.MissRecovering and AllIn1.Reloading then
            AllIn1.ReloadToken = AllIn1.ReloadToken + 1
            AllIn1.Reloading = false
            AllIn1.ReloadTool = nil
        end
        MultiTarget.MissRecovering = false
        MultiTarget.LastDBEnsureAt = 0
        -- Do not resume void hide here. The H runner always funnels through
        -- MultiTarget.Restore(), which first restores its map baseline and then
        -- returns to the exact pre-H void CFrame once, avoiding a ground overwrite.
        MultiTarget.UpdateUI()
        return
    end

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not character or not root or not humanoid or humanoid.Health <= 0 then
        notify("MULTITARGET", "character unavailable", "warning", 2.3)
        return
    end

    -- H owns movement while MultiTarget is active. Cancel stale E state and clear
    -- every owned physical anchor before the FIRST void move. This prevents H from
    -- appearing enabled while the HRP is still frozen by an earlier phase.
    MultiTarget.CancelAllIn1()
    MultiTarget.UnlockOwnedMovement()

    MultiTarget.SavedVoidSpamEnabled = VoidSpam.Enabled == true

    MultiTarget.Enabled = true
    MultiTarget.Running = true
    MultiTarget.Token = MultiTarget.Token + 1
    MultiTarget.GroundActionMode = MultiTarget.SavedVoidSpamEnabled == true

    -- H launched from V/void hide: keep V logically enabled, but move the real
    -- character to its saved map CFrame once and hold that map-level baseline for
    -- the entire H sequence. The Fake Pos ghost is never touched/recreated.
    if MultiTarget.GroundActionMode then
        local groundOK = VoidSpam.EnterGroundAction("H", MultiTarget.Token)
        if not groundOK then
            MultiTarget.Enabled = false
            MultiTarget.Running = false
            MultiTarget.GroundActionMode = false
            VoidSpam.ResumeAfterAction("H")
            notify("MULTITARGET", "ground/origin handoff failed", "warning", 2.3)
            return
        end
        character = LocalPlayer.Character
        root = character and character:FindFirstChild("HumanoidRootPart")
        humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if not character or not root or not humanoid or humanoid.Health <= 0 then
            MultiTarget.Enabled = false
            MultiTarget.Running = false
            MultiTarget.GroundActionMode = false
            VoidSpam.ResumeAfterAction("H")
            return
        end
    end

    MultiTarget.Completed = 0
    MultiTarget.Failed = 0
    MultiTarget.RespawnRecovering = false
    MultiTarget.MissRecovering = false
    MultiTarget.LastDBEnsureAt = 0
    table.clear(MultiTarget.ForceFieldSince)
    MultiTarget.ForceFieldWaitingUserId = nil
    MultiTarget.CurrentUserId = nil
    MultiTarget.StartPivot = character:GetPivot()
    MultiTarget.SavedAim = {
        Toggled = Aim.Toggled,
        Active = Aim.Active,
        LockedUserId = Aim.LockedUserId,
        CurrentUserId = Aim.CurrentTarget and Aim.CurrentTarget.UserId or nil,
    }

    MultiTarget.StopHide("search")
    MultiTarget.HideActive = true
    MultiTarget.HideMode = "search"
    MultiTarget.BeginRandomHide(true)
    MultiTarget.EnsureVoidDoubleBarrel(true)

    -- H startup self-check: confirm the local HRP actually reached the generated
    -- hide point. If physics/streaming immediately rejects the first snap, retry
    -- it for several Heartbeats while the SEARCH root is anchored, then generate
    -- one fresh point instead of silently leaving H active at ground level.
    task.spawn(function()
        for attempt = 1, 10 do
            if Unloaded or not MultiTarget.Running or AllIn1.Busy then
                break
            end
            local liveCharacter, liveRoot = MultiTarget.GetLocalHideParts()
            if not liveCharacter or not liveRoot then
                RunService.Heartbeat:Wait()
            else
                if not MultiTarget.HideCFrame then
                    MultiTarget.HideCFrame = MultiTarget.MakeRandomHideCFrame()
                end
                MultiTarget.ApplyHideCFrame(MultiTarget.HideCFrame)
                local errorDistance = (liveRoot.Position - MultiTarget.HideCFrame.Position).Magnitude
                if errorDistance <= 6 then
                    break
                end
                if attempt == 6 then
                    MultiTarget.HideCFrame = MultiTarget.MakeRandomHideCFrame()
                    MultiTarget.HideLastMove = os.clock()
                end
                RunService.Heartbeat:Wait()
            end
        end
    end)

    local runToken = MultiTarget.Token
    MultiTarget.UpdateUI()
    notify("MULTITARGET", "ON  •  VOID HIDE  •  H toggle  •  J abort", "lock", 2.5)
    task.spawn(function()
        MultiTarget.Run(runToken)
    end)
end


-- H SELF-RESPAWN QOL: if the local player is KO'd/stomped while H is still
-- enabled, the new character immediately equips slot 1 / DB and is handed back
-- to the existing H runner. This does not create a second MultiTarget.Run loop.
track(LocalPlayer.CharacterAdded:Connect(function(character)
    if Unloaded or not MultiTarget.Enabled or not MultiTarget.Running then
        return
    end

    local runToken = MultiTarget.Token
    task.spawn(function()
        local humanoid = character:WaitForChild("Humanoid", MultiTarget.RespawnReadyTimeout)
        local root = character:WaitForChild("HumanoidRootPart", MultiTarget.RespawnReadyTimeout)
        if Unloaded
            or not MultiTarget.Enabled
            or not MultiTarget.Running
            or MultiTarget.Token ~= runToken
            or not humanoid
            or not root
        then
            return
        end

        MultiTarget.CancelAllIn1()
        MultiTarget.UnlockOwnedMovement()
        root.Anchored = false

        if MultiTarget.RespawnEquipDelay > 0 then
            task.wait(MultiTarget.RespawnEquipDelay)
        end

        local tool = AllIn1.EquipDoubleBarrel(character, humanoid, true)
        if tool then
            AllIn1.EnsureReloadHook(tool)
        end

        MultiTarget.StopHide("search")
        MultiTarget.HideActive = true
        MultiTarget.HideMode = "search"
        MultiTarget.BeginRandomHide(true)
        MultiTarget.QueueDirty = true
        MultiTarget.UpdateUI()
    end)
end))


-- ============================================================
-- Utility: teleport / cframe / fly
-- ============================================================

local function getLocalCharacterParts()
    local character = LocalPlayer.Character
    if not character then
        return nil, nil, nil
    end
    local root = character:FindFirstChild("HumanoidRootPart")
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    return character, root, humanoid
end

Utility.GetHoveredESPPlayer = function()
    if not Config.ESP.Enabled then
        return nil
    end

    local mouse = UserInputService:GetMouseLocation()
    local bestPlayer = nil
    local bestDistance = math.huge

    for _, entry in pairs(ESPEntries) do
        local player = entry and entry.Player
        if player and player ~= LocalPlayer and player.Parent ~= nil then
            local humanoid = getHumanoid(player)
            local part = getTargetPart(player)
            if humanoid and humanoid.Health > 0 and part and not isKnockedOut(player) then
                local hovered = false

                -- Exact GUI hit-test first: hovering the visible display-name row
                -- selects that player for T, regardless of blacklist color.
                if entry.Billboard and entry.Billboard.Enabled and entry.Name and entry.Name.Visible then
                    local ok, absolutePosition, absoluteSize = pcall(function()
                        return entry.Name.AbsolutePosition, entry.Name.AbsoluteSize
                    end)
                    if ok and absolutePosition and absoluteSize and absoluteSize.X > 0 and absoluteSize.Y > 0 then
                        local paddingX, paddingY = 8, 6
                        hovered = mouse.X >= absolutePosition.X - paddingX
                            and mouse.X <= absolutePosition.X + absoluteSize.X + paddingX
                            and mouse.Y >= absolutePosition.Y - paddingY
                            and mouse.Y <= absolutePosition.Y + absoluteSize.Y + paddingY
                    end
                end

                -- Billboard AbsolutePosition is not exposed consistently by every
                -- executor, so keep a small projected-display fallback.
                if not hovered and entry.Billboard and entry.Billboard.Enabled then
                    local worldPoint = part.Position + Vector3.new(0, 3.35, 0)
                    local screenPoint, onScreen = Camera:WorldToViewportPoint(worldPoint)
                    if onScreen and screenPoint.Z > 0 then
                        local deltaX = math.abs(mouse.X - screenPoint.X)
                        local deltaY = math.abs(mouse.Y - screenPoint.Y)
                        hovered = deltaX <= 82 and deltaY <= 24
                    end
                end

                if hovered then
                    local screenPoint = Camera:WorldToViewportPoint(part.Position)
                    local screenDistance = (Vector2.new(screenPoint.X, screenPoint.Y) - mouse).Magnitude
                    if screenDistance < bestDistance then
                        bestDistance = screenDistance
                        bestPlayer = player
                    end
                end
            end
        end
    end

    return bestPlayer
end

local function getUtilityTarget()
    -- 1) T always prefers the exact player C already owns. This does not depend
    -- on mouse/FOV and survives temporary Player/character reference refreshes.
    local locked = Aim.CurrentTarget
    if locked and locked ~= LocalPlayer then
        local okUserId, userId = pcall(function()
            return locked.UserId
        end)
        if okUserId and userId then
            locked = findPlayerByUserId(userId) or locked
        else
            locked = nil
        end
    else
        locked = nil
    end

    if not locked and Aim.LockedUserId then
        locked = findPlayerByUserId(Aim.LockedUserId)
    end

    if locked and locked ~= LocalPlayer then
        local lockedHumanoid = getHumanoid(locked)
        local lockedPart = getTargetPart(locked)
        if lockedHumanoid
            and lockedHumanoid.Health > 0
            and lockedPart
            and not isKnockedOut(locked)
        then
            return locked
        end
    end

    -- 2) If the mouse is over a visible ESP display name, use that exact player.
    -- This works for both normal lime ESP and red blacklisted ESP.
    local hovered = Utility.GetHoveredESPPlayer()
    if hovered then
        return hovered
    end

    -- 3) Blacklisted players remain valid T targets even without a C lock. If
    -- more than one is present, use the nearest live blacklisted player.
    local localRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local bestBlacklisted = nil
    local bestDistance = math.huge

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Parent ~= nil and isBlacklisted(player) then
            local humanoid = getHumanoid(player)
            local part = getTargetPart(player)
            if humanoid and humanoid.Health > 0 and part and not isKnockedOut(player) then
                local distance = localRoot and (part.Position - localRoot.Position).Magnitude or 0
                if distance < bestDistance then
                    bestBlacklisted = player
                    bestDistance = distance
                end
            end
        end
    end

    return bestBlacklisted
end

local function teleportToTarget()
    local character, root = getLocalCharacterParts()
    local target = getUtilityTarget()
    local targetPart = target and getTargetPart(target)
    if not character or not root or not targetPart then
        notify("TELEPORT", "lock, blacklist, or hover an ESP name", "warning", 2.4)
        return
    end

    -- T is movement-only. It never uses mouse/FOV and it never changes the
    -- current C lock just because a blacklisted fallback was used.
    local targetUserId = target.UserId
    local destination = targetPart.CFrame * CFrame.new(0, 0, 2)

    pcall(function()
        character:PivotTo(destination)
        root.CFrame = destination
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)

    -- Two short correction passes cover games that locally push the first snap
    -- back before the target's next replicated HRP frame arrives.
    task.spawn(function()
        for _ = 1, 2 do
            RunService.Heartbeat:Wait()
            if Unloaded then
                return
            end

            local liveTarget = findPlayerByUserId(targetUserId)
            local livePart = liveTarget and getTargetPart(liveTarget)
            local liveCharacter, liveRoot = getLocalCharacterParts()
            if not liveTarget or not livePart or not liveCharacter or not liveRoot then
                return
            end

            local desired = livePart.CFrame * CFrame.new(0, 0, 2)
            if (liveRoot.Position - desired.Position).Magnitude > 3.5 then
                pcall(function()
                    liveCharacter:PivotTo(desired)
                    liveRoot.CFrame = desired
                    liveRoot.AssemblyLinearVelocity = Vector3.zero
                    liveRoot.AssemblyAngularVelocity = Vector3.zero
                end)
            end
        end
    end)

    updateTargetHUD()
    notify("TELEPORT", target.DisplayName, "lock", 2.2)
end

local function setCFrameEnabled(state, silent)
    Utility.CFrameEnabled = state == true
    if Utility.CFrameEnabled and Utility.FlyEnabled then
        Utility.FlyEnabled = false
    end
    if not silent then
        notify("CFRAME", Utility.CFrameEnabled and "ON" or "OFF", "lock", 2.2)
    end
end

local function setFlyEnabled(state, silent)
    Utility.FlyEnabled = state == true
    if Utility.FlyEnabled and Utility.CFrameEnabled then
        Utility.CFrameEnabled = false
    end

    if not Utility.FlyEnabled then
        local _, root, humanoid = getLocalCharacterParts()
        if root then
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end
        if humanoid then
            humanoid:Move(Vector3.zero, false)
        end
    end

    if not silent then
        notify("FLY", Utility.FlyEnabled and "ON" or "OFF", "lock", 2.2)
    end
end

Utility.SetFakePosStatus = function(status, detail)
    Utility.FakePosCompatStatus = tostring(status or "unknown")
    Utility.FakePosCompatDetail = tostring(detail or "")

    if Utility.FakePosStatusLabel then
        Utility.FakePosStatusLabel.Text = "compat: " .. Utility.FakePosCompatStatus
        if Utility.FakePosCompatStatus == "active" or Utility.FakePosCompatStatus == "ready" then
            Utility.FakePosStatusLabel.TextColor3 = Theme.Accent
        elseif Utility.FakePosCompatStatus == "unchecked" or Utility.FakePosCompatStatus == "off" then
            Utility.FakePosStatusLabel.TextColor3 = Theme.Muted
        else
            Utility.FakePosStatusLabel.TextColor3 = Theme.RedBright
        end
    end
end

Utility.RestoreFakePosRoot = function(root)
    root = root or Utility.FakePosRoot
    if root and type(sethiddenproperty) == "function" then
        pcall(sethiddenproperty, root, "PhysicsRepRootPart", root)
    end
end

-- Executor compatibility check for Fake Pos. The sender-rate FFlag is treated
-- as an optional accelerator because some executors (including some Volt builds)
-- reject that specific flag even when PhysicsRepRootPart writes still work.
-- We first try the string form, then the numeric form, and only fail the feature
-- if the hidden replication-root write itself is unavailable/rejected.
Utility.CheckFakePosCompatibility = function()
    if type(sethiddenproperty) ~= "function" then
        Utility.FakePosFlagApplied = false
        Utility.SetFakePosStatus("unsupported", "sethiddenproperty missing")
        return false, "sethiddenproperty missing"
    end

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root then
        Utility.FakePosFlagApplied = false
        Utility.SetFakePosStatus("waiting", "HumanoidRootPart unavailable")
        return false, "HumanoidRootPart unavailable"
    end

    Utility.FakePosFlagApplied = false
    if type(setfflag) == "function" then
        -- Volt compatibility fallback: some builds only accept the string form
        -- while others accept the numeric form used by the original snippet.
        local flagOK = pcall(setfflag, "S2PhysicsSenderRate", "1000")
        if not flagOK then
            flagOK = pcall(setfflag, "S2PhysicsSenderRate", 1000)
        end
        Utility.FakePosFlagApplied = flagOK == true

        -- A readable mismatch downgrades us to replication-root-only mode rather
        -- than disabling Fake Pos completely.
        if Utility.FakePosFlagApplied and type(getfflag) == "function" then
            local okRead, value = pcall(getfflag, "S2PhysicsSenderRate")
            if okRead and value ~= nil and tostring(value) ~= "1000" then
                Utility.FakePosFlagApplied = false
            end
        end
    end

    -- The supplied Fake Pos behavior fundamentally depends on this sequence.
    -- Restore is always attempted so the compatibility probe cannot strand HRP
    -- in the temporary nil replication-root state.
    local nilOK = pcall(sethiddenproperty, root, "PhysicsRepRootPart", nil)
    local restoreOK = pcall(sethiddenproperty, root, "PhysicsRepRootPart", root)
    if not nilOK or not restoreOK then
        pcall(sethiddenproperty, root, "PhysicsRepRootPart", root)
        Utility.SetFakePosStatus("property failed", "PhysicsRepRootPart write rejected")
        return false, "PhysicsRepRootPart write rejected"
    end

    if type(gethiddenproperty) == "function" then
        local okRead, value = pcall(gethiddenproperty, root, "PhysicsRepRootPart")
        if okRead and value ~= nil and value ~= root then
            Utility.SetFakePosStatus("property mismatch", "replication root did not restore")
            return false, "replication root did not restore"
        end
    end

    if Utility.FakePosFlagApplied then
        Utility.SetFakePosStatus("ready", "sender flag + replication-root writes accepted")
    else
        Utility.SetFakePosStatus("partial", "sender flag unavailable; replication-root fallback ready")
    end
    return true, Utility.FakePosCompatDetail
end

Utility.RunFakePosLoop = function(generation)
    task.spawn(function()
        local counter = 0
        local syncing = false
        local currentRoot = nil

        while not Unloaded
            and Utility.FakePosEnabled
            and Utility.FakePosGeneration == generation
        do
            local character = LocalPlayer.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")

            if not root then
                task.wait(1 / 240)
                continue
            end

            -- Follow respawns without creating a second worker. The source code's
            -- exact sync cadence restarts from dsfs=0 on each new HumanoidRootPart.
            if currentRoot ~= root then
                Utility.RestoreFakePosRoot(currentRoot)
                currentRoot = root
                Utility.FakePosRoot = root
                counter = 0
                syncing = false
            end

            task.wait(1 / 240)

            if Unloaded
                or not Utility.FakePosEnabled
                or Utility.FakePosGeneration ~= generation
            then
                break
            end

            -- E/H temporarily owns the real HRP/origin. The gun force-carrier keeps
            -- the Tool attached, but it no longer pins PhysicsRepRootPart during idle
            -- Fake Pos. This restores the pre-regression Fake Pos cycle while still
            -- giving every combat action a clean live root before firing.
            local originHoldActive = os.clock() < (Utility.FakePosOriginHoldUntil or 0)
            if Utility.FakePosCombatHold
                or MultiTarget.GroundActionMode
                or AllIn1.Busy
                or originHoldActive
            then
                Utility.FakePosCycleHoldOK = pcall(sethiddenproperty, root, "PhysicsRepRootPart", root)
                if originHoldActive and not (Utility.FakePosCombatHold or MultiTarget.GroundActionMode or AllIn1.Busy) then
                    Utility.FakePosCycleState = Utility.FakePosCycleHoldOK and "origin-hold" or "hold-fail"
                else
                    Utility.FakePosCycleState = Utility.FakePosCycleHoldOK and "combat-hold" or "hold-fail"
                end
                syncing = false
                counter = 20
                task.wait(1 / 120)
                continue
            end

            -- Normal Fake Pos cadence while E/H is not using the origin.
            if syncing then
                task.wait()
                continue
            end

            if counter <= 0 then
                syncing = true
                Utility.FakePosCycleNilOK = pcall(sethiddenproperty, root, "PhysicsRepRootPart", nil)
                Utility.FakePosCycleState = Utility.FakePosCycleNilOK and "nil-ok" or "nil-fail"

                -- Make the 0.1s nil window interruptible. If E/H starts mid-window,
                -- restore on the next scheduler slice rather than leaving its shot
                -- origin detached for the remainder of the full 0.1 seconds.
                local nilWindowEnds = os.clock() + 0.1
                while os.clock() < nilWindowEnds
                    and not Unloaded
                    and Utility.FakePosEnabled
                    and Utility.FakePosGeneration == generation
                    and not Utility.FakePosCombatHold
                    and not AllIn1.Busy
                    and os.clock() >= (Utility.FakePosOriginHoldUntil or 0)
                do
                    task.wait(1 / 240)
                end

                -- Always restore the root, even if F was toggled OFF during the window.
                Utility.FakePosCycleRestoreOK = pcall(sethiddenproperty, root, "PhysicsRepRootPart", root)
                Utility.FakePosCycleState = Utility.FakePosCycleRestoreOK and "ok" or "restore-fail"
                syncing = false
                counter = 20
            else
                counter = counter - 1
                Utility.FakePosCycleHoldOK = pcall(sethiddenproperty, root, "PhysicsRepRootPart", root)
                if not Utility.FakePosCycleHoldOK then
                    Utility.FakePosCycleState = "hold-fail"
                end
            end
        end

        -- A generation owns only its own last root. This avoids stale toggle workers
        -- touching state from a newer F-toggle generation.
        Utility.RestoreFakePosRoot(currentRoot)
        if Utility.FakePosGeneration == generation then
            Utility.FakePosRoot = nil
        end
    end)
end

Utility.SetFakePosEnabled = function(state, silent)
    state = state == true

    if Utility.FakePosEnabled == state then
        return true
    end

    if state then
        -- Remember the exact equipped Tool BEFORE the compatibility probe touches
        -- PhysicsRepRootPart. If the game reparents the gun during that transition,
        -- the force-carrier still knows which live Tool must be put back in the hand.
        local character = LocalPlayer.Character
        local equipped = AllIn1.GetEquippedTool(character)
        if equipped then
            Utility.FakePosForceTool = equipped
            Utility.FakePosForceToolName = equipped.Name
            AllIn1.LastEquippedTool = equipped
            AllIn1.LastEquippedToolName = equipped.Name
            AllIn1.LastEquippedSeenAt = os.clock()

            -- Capture the valid hand->Handle relation before Fake Pos changes any
            -- replication state. If RightGrip disappears during the transition, the
            -- fallback weld restores this known-good pose instead of learning a dropped pose.
            local hand = Utility.GetFakePosRightHand and Utility.GetFakePosRightHand(character)
            local handle = equipped:FindFirstChild("Handle", true)
            if (not handle or not handle:IsA("BasePart")) then
                handle = equipped:FindFirstChildWhichIsA("BasePart", true)
            end
            if hand and hand:IsA("BasePart") and handle and handle:IsA("BasePart") then
                Utility.FakePosForceHandOffset = hand.CFrame:ToObjectSpace(handle.CFrame)
            end
        end

        -- Save the old flag before the compatibility check writes 1000, when the
        -- current environment exposes a readable FFlag API.
        if not Utility.FakePosOriginalSenderRateKnown and type(getfflag) == "function" then
            local okRate, oldRate = pcall(getfflag, "S2PhysicsSenderRate")
            if okRate then
                Utility.FakePosOriginalSenderRate = oldRate
                Utility.FakePosOriginalSenderRateKnown = true
            end
        end

        local compatible, detail = Utility.CheckFakePosCompatibility()
        if not compatible then
            Utility.FakePosEnabled = false
            Utility.RestoreFakePosRoot()
            Utility.DestroyFakePosGhost()
            if Utility.FakePosOriginalSenderRateKnown and type(setfflag) == "function" then
                pcall(setfflag, "S2PhysicsSenderRate", Utility.FakePosOriginalSenderRate)
            end
            if not silent then
                notify("FAKE POS", "compat failed: " .. tostring(detail), "warning", 3.0)
            end
            return false
        end
    end

    Utility.FakePosGeneration = Utility.FakePosGeneration + 1
    Utility.FakePosEnabled = state
    if not state then
        Utility.FakePosCombatHold = false
        Utility.FakePosCombatToken = 0
        Utility.FakePosEThawActive = false
        Utility.FakePosEThawToken = 0
        Utility.FakePosEThawStartedAt = 0
        Utility.FakePosEThawReadyAt = 0
        Utility.FakePosEThawStatus = "idle"
        Utility.FakePosEThawSenderRestored = false
        Utility.FakePosEThawSenderVerified = false
        Utility.FakePosEThawReapplySender = false
        Utility.FakePosEHardSuspendActive = false
        if type(Utility.DestroyFakePosERealToolGlue) == "function" then
            Utility.DestroyFakePosERealToolGlue()
        end
        Utility.FakePosENativeToolMode = false
        Utility.FakePosENativeTool = nil
        Utility.FakePosENativeToolStatus = "idle"
        Utility.FakePosOriginHoldUntil = 0
        Utility.FakePosOriginHoldReason = "idle"
    else
        Utility.FakePosEThawActive = false
        Utility.FakePosEThawToken = 0
        Utility.FakePosEThawStartedAt = 0
        Utility.FakePosEThawReadyAt = 0
        Utility.FakePosEThawStatus = "idle"
        Utility.FakePosEThawSenderRestored = false
        Utility.FakePosEThawSenderVerified = false
        Utility.FakePosEThawReapplySender = false
        Utility.FakePosEHardSuspendActive = false
        if type(Utility.DestroyFakePosERealToolGlue) == "function" then
            Utility.DestroyFakePosERealToolGlue()
        end
        Utility.FakePosENativeToolMode = false
        Utility.FakePosENativeTool = nil
        Utility.FakePosENativeToolStatus = "idle"
        Utility.FakePosOriginHoldUntil = 0
        Utility.FakePosOriginHoldReason = "idle"
    end

    if state then
        if Utility.FakePosFlagApplied then
            Utility.SetFakePosStatus("active", "sender flag + replication-root writes active")
        else
            Utility.SetFakePosStatus("partial", "replication-root fallback active; sender flag unavailable")
        end
        Utility.CreateFakePosGhost()
        Utility.RunFakePosLoop(Utility.FakePosGeneration)
        if Utility.UpdateFakePosToolCarrier then
            Utility.UpdateFakePosToolCarrier(true)
        end
    else
        if Utility.ReleaseFakePosToolCarrier then
            Utility.ReleaseFakePosToolCarrier(true)
        end
        Utility.RestoreFakePosRoot()
        Utility.FakePosRoot = nil
        Utility.DestroyFakePosGhost()
        if Utility.FakePosOriginalSenderRateKnown and type(setfflag) == "function" then
            pcall(setfflag, "S2PhysicsSenderRate", Utility.FakePosOriginalSenderRate)
        end
        Utility.FakePosFlagApplied = false
        Utility.SetFakePosStatus("off", "fake pos disabled")
    end

    if not silent then
        if Utility.FakePosEnabled then
            if Utility.FakePosFlagApplied then
                notify("FAKE POS", "ON | full compatibility", "lock", 2.6)
            else
                notify("FAKE POS", "ON | fallback mode (sender flag unavailable)", "warning", 3.0)
            end
        else
            notify("FAKE POS", "OFF", "lock", 2.2)
        end
    end

    return true
end

local function setSpeedFromPointer(bar, fill, knob, valueLabel, fieldName, screenX)
    local width = math.max(1, bar.AbsoluteSize.X)
    local alpha = math.clamp((screenX - bar.AbsolutePosition.X) / width, 0, 1)
    local speed = math.floor(Utility.MinSpeed + (Utility.MaxSpeed - Utility.MinSpeed) * alpha + 0.5)
    Utility[fieldName] = speed
    fill.Size = UDim2.new(alpha, 0, 1, 0)
    knob.Position = UDim2.new(alpha, 0, 0.5, 0)
    valueLabel.Text = tostring(speed)
end

local CFrameSpeedDragging = false
local FlySpeedDragging = false

track(CFrameSpeedHitbox.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        CFrameSpeedDragging = true
        setSpeedFromPointer(CFrameSpeedBar, CFrameSpeedFill, CFrameSpeedKnob, CFrameSpeedValue, "CFrameSpeed", input.Position.X)
    end
end))

track(FlySpeedHitbox.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        FlySpeedDragging = true
        setSpeedFromPointer(FlySpeedBar, FlySpeedFill, FlySpeedKnob, FlySpeedValue, "FlySpeed", input.Position.X)
    end
end))

track(UserInputService.InputChanged:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseMovement then
        return
    end
    if CFrameSpeedDragging then
        setSpeedFromPointer(CFrameSpeedBar, CFrameSpeedFill, CFrameSpeedKnob, CFrameSpeedValue, "CFrameSpeed", input.Position.X)
    elseif FlySpeedDragging then
        setSpeedFromPointer(FlySpeedBar, FlySpeedFill, FlySpeedKnob, FlySpeedValue, "FlySpeed", input.Position.X)
    end
end))

track(UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        CFrameSpeedDragging = false
        FlySpeedDragging = false
    end
end))

local function getFlyDirection()
    if Utility.InputBlocked() then
        return Vector3.zero
    end

    local camera = Workspace.CurrentCamera
    if not camera then
        return Vector3.zero
    end

    local direction = Vector3.zero
    local look = camera.CFrame.LookVector
    local right = camera.CFrame.RightVector
    local flatLook = Vector3.new(look.X, 0, look.Z)
    local flatRight = Vector3.new(right.X, 0, right.Z)
    if flatLook.Magnitude > 0.001 then
        flatLook = flatLook.Unit
    end
    if flatRight.Magnitude > 0.001 then
        flatRight = flatRight.Unit
    end

    if UserInputService:IsKeyDown(Enum.KeyCode.W) then direction = direction + flatLook end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then direction = direction - flatLook end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then direction = direction + flatRight end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then direction = direction - flatRight end
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then direction = direction + Vector3.yAxis end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl) then
        direction = direction - Vector3.yAxis
    end

    return direction.Magnitude > 0 and direction.Unit or Vector3.zero
end

local function updateUtilityMovement(deltaTime)
    -- E/H and H's void/search phases own the HRP. Keep CFrame/Fly toggles enabled
    -- in UI/state, but do not let their render-step writes fight those phases.
    if AllIn1.Busy or MultiTarget.Running then
        return
    end

    if not Utility.CFrameEnabled and not Utility.FlyEnabled then
        return
    end

    if Utility.InputBlocked() then
        return
    end

    local _, root, humanoid = getLocalCharacterParts()
    if not root or not humanoid or humanoid.Health <= 0 then
        return
    end

    local dt = math.clamp(deltaTime or 0.016, 0, 0.05)

    if Utility.CFrameEnabled then
        local direction = humanoid.MoveDirection
        if direction.Magnitude > 0.001 then
            root.CFrame = root.CFrame + direction.Unit * Utility.CFrameSpeed * dt
        end
        -- Do not alter the Animator/Animate script or tool joints. Roblox keeps
        -- the player's currently equipped avatar and gun animations running.
        return
    end

    if Utility.FlyEnabled then
        local direction = getFlyDirection()
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        if direction.Magnitude > 0.001 then
            root.CFrame = root.CFrame + direction * Utility.FlySpeed * dt
            -- Feed horizontal movement to Humanoid so the user's own Animate
            -- script keeps its normal casual/tool movement animation.
            humanoid:Move(Vector3.new(direction.X, 0, direction.Z), false)
        else
            humanoid:Move(Vector3.zero, false)
        end
    end
end

-- ============================================================
-- State / toggles
-- ============================================================

local function setToggleVisual(box, stroke, enabled, onColor)
    local color = onColor or Theme.Accent
    box.BackgroundColor3 = enabled and color or Color3.fromRGB(24, 24, 24)
    stroke.Color = enabled and color or Color3.fromRGB(68, 68, 68)
end


local function updateMenuState()
    local lockOn = Aim.Toggled
    setToggleVisual(LockBox, LockStroke, lockOn, Theme.Accent)
    LockStatus.Text = lockOn and (Aim.CurrentTarget and ("locked: " .. Aim.CurrentTarget.DisplayName) or "status: ARMED") or "status: OFF"
    LockStatus.TextColor3 = lockOn and Theme.Accent or Theme.RedBright

    setToggleVisual(VoidSpamBox, VoidSpamStroke, VoidSpam.Enabled, Theme.Accent)
    setToggleVisual(AllIn1.Box, AllIn1.Stroke, AllIn1.Busy, Theme.Accent)
    if MultiTarget.UpdateUI then
        MultiTarget.UpdateUI()
    end
    setToggleVisual(TeleportBox, TeleportStroke, false, Theme.Accent)
    setToggleVisual(Utility.FakePosBox, Utility.FakePosStroke, Utility.FakePosEnabled, Theme.Accent)
    setToggleVisual(CFrameBox, CFrameStroke, Utility.CFrameEnabled, Theme.Accent)
    setToggleVisual(FlyBox, FlyStroke, Utility.FlyEnabled, Theme.Accent)

    local espOn = Config.ESP.Enabled
    setToggleVisual(ESPBox, ESPStroke, espOn, Theme.ESP)
    setToggleVisual(ESPHealthBox, ESPHealthStroke, Config.ESP.ShowHealthBar, Theme.ESP)
    setToggleVisual(ESPOffscreenBox, ESPOffscreenStroke, Config.ESP.ShowOffscreen, Theme.ESP)
    setToggleVisual(ESPTargetBox, ESPTargetStroke, Config.ESP.HighlightTarget, Theme.ESP)
    ESPStatus.Text = espOn and (hasPresentBlacklistedTargets() and "status: ON  |  blacklist only" or "status: ON  |  all players") or "status: OFF"
    ESPStatus.TextColor3 = espOn and Theme.Accent or Theme.RedBright
end

MultiTarget.RefreshMenu = updateMenuState

local function setAimToggled(state, silent)
    if Unloaded then
        return
    end

    Aim.Toggled = state == true
    Aim.Active = false
    if not Aim.Toggled then
        clearTarget()
    elseif not Aim.CurrentTarget then
        -- Immediate acquisition removes the extra render-frame wait when C is
        -- pressed. This reuses the existing C target rules and adds NO raycast.
        local acquired = getBestTarget()
        if acquired then
            Aim.CurrentTarget = acquired
            Aim.LockedUserId = acquired.UserId
            Aim.SmoothedVelocity = Vector3.zero
            updateTargetThumbnail(acquired)
        end
    end

    updateMenuState()
    updateTargetHUD()

    if not silent then
        local lockedNow = Aim.Toggled and Aim.CurrentTarget ~= nil
        notify(
            Aim.Toggled and (lockedNow and "TARGET LOCKED" or "LOCK ARMED") or "LOCK OFF",
            Aim.Toggled and (lockedNow and Aim.CurrentTarget.DisplayName or "C is waiting for a target") or "lock disabled",
            "lock",
            2.7
        )
    end
end

local function setESPEnabled(state, silent)
    if Unloaded then
        return
    end

    Config.ESP.Enabled = state == true
    updateMenuState()
    ESPLayer.Visible = Config.ESP.Enabled
    updateESP()

    if not silent then
        notify(
            Config.ESP.Enabled and "ESP ON" or "ESP OFF",
            Config.ESP.Enabled and "ESP active through walls" or "visuals disabled",
            "visual",
            2.7
        )
    end
end

local function setESPOption(optionName, state)
    if Config.ESP[optionName] == nil then
        return
    end
    Config.ESP[optionName] = state == true
    updateMenuState()
end

track(LockHitbox.MouseButton1Click:Connect(function()
    setAimToggled(not Aim.Toggled, false)
end))

track(VoidSpamHitbox.MouseButton1Click:Connect(function()
    setVoidSpamEnabled(not VoidSpam.Enabled)
    updateMenuState()
end))

track(AllIn1.Hitbox.MouseButton1Click:Connect(function()
    AllIn1.Run()
end))

track(MultiTarget.Hitbox.MouseButton1Click:Connect(function()
    MultiTarget.SetEnabled(not MultiTarget.Enabled)
end))

track(MultiTarget.BlacklistHitbox.Activated:Connect(function()
    MultiTarget.BlacklistOnly = not MultiTarget.BlacklistOnly
    MultiTarget.QueueDirty = true
    MultiTarget.UpdateUI()
end))

track(MultiTarget.SelectedHitbox.MouseButton1Click:Connect(function()
    MultiTarget.SelectedOnly = not MultiTarget.SelectedOnly
    MultiTarget.QueueDirty = true
    MultiTarget.UpdateUI()
end))

track(MultiTarget.SafeHitbox.MouseButton1Click:Connect(function()
    MultiTarget.SafeMode = not MultiTarget.SafeMode
    MultiTarget.UpdateUI()
end))

track(MultiTarget.ForceFieldHitbox.MouseButton1Click:Connect(function()
    MultiTarget.ForceFieldCheck = not MultiTarget.ForceFieldCheck
    if not MultiTarget.ForceFieldCheck then
        table.clear(MultiTarget.ForceFieldSince)
        MultiTarget.ForceFieldWaitingUserId = nil
    end
    MultiTarget.QueueDirty = true
    MultiTarget.UpdateUI()
end))

track(MultiTarget.ReturnHitbox.MouseButton1Click:Connect(function()
    MultiTarget.ReturnBetweenTargets = not MultiTarget.ReturnBetweenTargets
    MultiTarget.UpdateUI()
end))

track(MultiTarget.PriorityButton.MouseButton1Click:Connect(function()
    if MultiTarget.Priority == "nearest" then
        MultiTarget.Priority = "lowest hp"
    elseif MultiTarget.Priority == "lowest hp" then
        MultiTarget.Priority = "threat"
    else
        MultiTarget.Priority = "nearest"
    end
    MultiTarget.QueueDirty = true
    MultiTarget.UpdateUI()
end))

track(TeleportHitbox.MouseButton1Click:Connect(function()
    teleportToTarget()
end))

track(Utility.FakePosHitbox.MouseButton1Click:Connect(function()
    Utility.SetFakePosEnabled(not Utility.FakePosEnabled, false)
    updateMenuState()
end))

track(CFrameHitbox.MouseButton1Click:Connect(function()
    setCFrameEnabled(not Utility.CFrameEnabled, false)
    updateMenuState()
end))

track(FlyHitbox.MouseButton1Click:Connect(function()
    setFlyEnabled(not Utility.FlyEnabled, false)
    updateMenuState()
end))

track(ESPHitbox.MouseButton1Click:Connect(function()
    setESPEnabled(not Config.ESP.Enabled, false)
end))


track(ESPHealthHitbox.MouseButton1Click:Connect(function()
    setESPOption("ShowHealthBar", not Config.ESP.ShowHealthBar)
end))

track(ESPOffscreenHitbox.MouseButton1Click:Connect(function()
    setESPOption("ShowOffscreen", not Config.ESP.ShowOffscreen)
end))

track(ESPTargetHitbox.MouseButton1Click:Connect(function()
    setESPOption("HighlightTarget", not Config.ESP.HighlightTarget)
end))

updateMenuState()
MultiTarget.UpdateUI()

-- ============================================================
-- Drag / resize / Insert show-hide animation
-- ============================================================

local Dragging = false
local DragStart = nil
local DragStartPosition = nil
local DragInput = nil
local Resizing = false
local ResizeStartMouse = nil
local ResizeStartSize = nil
local MenuShown = true
local MenuAnimationBusy = false

track(Header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        Dragging = true
        DragStart = input.Position
        DragStartPosition = Menu.Position
    end
end))

track(Header.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement then
        DragInput = input
    end
end))

track(ResizeHandle.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        Resizing = true
        ResizeStartMouse = input.Position
        ResizeStartSize = Menu.AbsoluteSize
    end
end))

track(UserInputService.InputChanged:Connect(function(input)
    if Dragging and input == DragInput and DragStart and DragStartPosition then
        local delta = input.Position - DragStart
        Menu.Position = UDim2.new(
            DragStartPosition.X.Scale,
            DragStartPosition.X.Offset + delta.X,
            DragStartPosition.Y.Scale,
            DragStartPosition.Y.Offset + delta.Y
        )
    end

    if Resizing and input.UserInputType == Enum.UserInputType.MouseMovement and ResizeStartMouse and ResizeStartSize then
        local delta = input.Position - ResizeStartMouse
        local newWidth = math.clamp(ResizeStartSize.X + delta.X, 440, 900)
        local newHeight = math.clamp(ResizeStartSize.Y + delta.Y, 330, 720)
        Menu.Size = UDim2.fromOffset(newWidth, newHeight)
    end
end))

track(UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        Dragging = false
        Resizing = false
    end
end))

local function setMenuShown(show)
    if Unloaded or MenuAnimationBusy or MenuShown == show then
        return
    end

    MenuShown = show
    MenuAnimationBusy = true

    if show then
        Menu.Visible = true
        PageHolder.Visible = true
        setTab(ActiveTab)
        MenuScale.Scale = 0.72
        Menu.Rotation = -5
        TweenService:Create(MenuScale, TweenInfo.new(0.30, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Scale = 1,
        }):Play()
        local rotateTween = TweenService:Create(Menu, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Rotation = 0,
        })
        rotateTween:Play()
        task.delay(0.31, function()
            MenuAnimationBusy = false
        end)
    else
        -- Hide the page holder first so Visuals/blacklist cannot render outside
        -- the shrinking menu during the Insert close animation.
        PageHolder.Visible = false
        local scaleTween = TweenService:Create(MenuScale, TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {
            Scale = 0.72,
        })
        local rotateTween = TweenService:Create(Menu, TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {
            Rotation = 6,
        })
        scaleTween:Play()
        rotateTween:Play()
        task.delay(0.19, function()
            if not Unloaded and Menu.Parent and not MenuShown then
                Menu.Visible = false
                Menu.Rotation = 0
                MenuScale.Scale = 1
            end
            MenuAnimationBusy = false
        end)
    end
end

-- ============================================================
-- Full unload / uninjection
-- ============================================================

local function unloadAll()
    if Unloaded then
        return
    end

    Unloaded = true

    -- If unload happens during SEARCH or the 100k safety hold, release
    -- both movement anchors before any return/cleanup work.
    MultiTarget.ReleaseSearchAnchor()
    MultiTarget.ReleaseHideAnchor()
    AllIn1.ShotAimPosition = nil
    AllIn1.ShotTargetPart = nil
    AllIn1.ShotGeometryReady = false
    AllIn1.HealthArmorBeforeShot = nil
    AllIn1.ReleaseAttackAnchor()

    -- QOL safety: unloading while MultiTarget is hidden must never strand the
    -- character 50k-250k studs away. Return to the exact H-start pivot first.
    if MultiTarget.StartPivot then
        local unloadCharacter = LocalPlayer.Character
        local unloadRoot = unloadCharacter and unloadCharacter:FindFirstChild("HumanoidRootPart")
        if unloadCharacter and unloadRoot then
            pcall(function()
                unloadCharacter:PivotTo(MultiTarget.StartPivot)
                unloadRoot.CFrame = MultiTarget.StartPivot
                unloadRoot.AssemblyLinearVelocity = Vector3.zero
                unloadRoot.AssemblyAngularVelocity = Vector3.zero
            end)
        end
    end
    MultiTarget.StopHide("idle")

    Aim.Toggled = false
    Aim.Active = false
    Config.ESP.Enabled = false
    MultiTarget.Enabled = false
    MultiTarget.Token = MultiTarget.Token + 1
    MultiTarget.Running = false
    MultiTarget.RespawnRecovering = false
    MultiTarget.MissRecovering = false
    MultiTarget.CurrentUserId = nil
    table.clear(MultiTarget.Queue)
    table.clear(MultiTarget.QueueSet)
    AllIn1.Token = AllIn1.Token + 1
    AllIn1.StompToken = (AllIn1.StompToken or 0) + 1
    AllIn1.ToolRecoveryToken = (AllIn1.ToolRecoveryToken or 0) + 1
    AllIn1.ToolRecoveryBusy = false
    AllIn1.Busy = false
    AllIn1.Stomping = false
    AllIn1.Firing = false
    AllIn1.FiringUntil = 0
    AllIn1.ReloadToken = AllIn1.ReloadToken + 1
    AllIn1.Reloading = false
    AllIn1.ReloadTool = nil
    setVoidSpamEnabled(false)
    Utility.SetFakePosEnabled(false, true)
    if AllIn1.RestoreMapIgnore then
        AllIn1.RestoreMapIgnore()
    end
    if AllIn1.RestoreGrassIgnore then
        AllIn1.RestoreGrassIgnore()
    end
    setCFrameEnabled(false, true)
    setFlyEnabled(false, true)
    clearTarget()

    HitSound.Alive = false
    HitSound.Enabled = false
    if HitSound.Sound then
        pcall(function()
            HitSound.Sound:Stop()
            HitSound.Sound:Destroy()
        end)
        HitSound.Sound = nil
    end

    pcall(function()
        RunService:UnbindFromRenderStep(RENDER_BIND_NAME)
    end)

    if SilentMouseInstalled and OriginalMouseIndex and type(hookmetamethod) == "function" then
        pcall(function()
            hookmetamethod(game, "__index", OriginalMouseIndex)
        end)
        SilentMouseInstalled = false
    end

    for _, connection in ipairs(Connections) do
        safeDisconnect(connection)
    end
    table.clear(Connections)

    local espIds = {}
    for userId in pairs(ESPEntries) do
        table.insert(espIds, userId)
    end
    for _, userId in ipairs(espIds) do
        destroyESPEntry(userId)
    end

    if RootGui and RootGui.Parent then
        RootGui:Destroy()
    end

    if VisualWorldFolder and VisualWorldFolder.Parent then
        VisualWorldFolder:Destroy()
    end

    if ENV.__ALEXK_UNLOAD == unloadAll then
        ENV.__ALEXK_UNLOAD = nil
    end
    if ENV.__HARD_STICKY_HRP_UNLOAD == unloadAll then
        ENV.__HARD_STICKY_HRP_UNLOAD = nil
    end
    if ENV["alex.ftn_HitSound"] == HitSound then
        ENV["alex.ftn_HitSound"] = nil
    end
end

ENV.__ALEXK_UNLOAD = unloadAll
ENV["alex.ftn_HitSound"] = HitSound
track(UnloadButton.MouseButton1Click:Connect(unloadAll))
track(RunService.Heartbeat:Connect(function()
    VoidSpam.Step(false)
    AllIn1.AutoReloadStep()
    -- Repair the armed Fake Pos chain BEFORE reading any origin-error UI so a
    -- one-frame Tool reparent cannot become a persistent stale-origin state.
    if Utility.FakePosEnabled and Utility.UpdateFakePosToolCarrier then
        Utility.UpdateFakePosToolCarrier(false)
    end
    AllIn1.ScanOriginLimitError()
    AllIn1.ToolRecoveryStep()

    -- H reliability: the run loop is allowed to yield for queue/FF/reload checks,
    -- but VOID HIDE movement must never stop just because that coroutine yielded.
    if MultiTarget.Running and MultiTarget.Enabled and not AllIn1.Busy then
        if MultiTarget.HideMode == "search" then
            if not MultiTarget.HideActive then
                MultiTarget.BeginRandomHide(false)
            else
                MultiTarget.StepHide(false)
            end
        elseif MultiTarget.HideActive then
            MultiTarget.StepHide(false)
        end
    end
end))

-- ============================================================
-- Keyboard input
-- ============================================================

track(UserInputService.WindowFocused:Connect(function()
    Utility.WindowFocused = true
end))

track(UserInputService.WindowFocusReleased:Connect(function()
    Utility.WindowFocused = false

    if Config.Aimbot.KeyMode == "hold" and Aim.Active then
        Aim.Active = false
        clearTarget()
    end
end))

track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if Unloaded or Utility.InputBlocked() then
        return
    end

    -- T/E/F/H/J may be marked processed by game controls. The chat/textbox/window
    -- focus safety gate above still wins, so these never fire while typing or tabbed out.
    if gameProcessed
        and input.KeyCode ~= Enum.KeyCode.T
        and input.KeyCode ~= Enum.KeyCode.E
        and input.KeyCode ~= Utility.FakePosKey
        and input.KeyCode ~= MultiTarget.ActivationKey
        and input.KeyCode ~= MultiTarget.AbortKey
    then
        return
    end

    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        spawnShotTracer()
    end

    if input.KeyCode == Enum.KeyCode.Insert then
        setMenuShown(not MenuShown)
        return
    end

    if Config.Aimbot.Enabled and input.KeyCode == Config.Aimbot.ActivationKey then
        if Config.Aimbot.KeyMode == "toggle" then
            setAimToggled(not Aim.Toggled, false)
        elseif Config.Aimbot.KeyMode == "hold" then
            Aim.Active = true
        end
        return
    end

    if input.KeyCode == Enum.KeyCode.V then
        setVoidSpamEnabled(not VoidSpam.Enabled)
        updateMenuState()
        return
    end

    if input.KeyCode == Enum.KeyCode.T then
        teleportToTarget()
        return
    end

    if input.KeyCode == Enum.KeyCode.E then
        AllIn1.Run()
        return
    end

    if input.KeyCode == Utility.FakePosKey then
        Utility.SetFakePosEnabled(not Utility.FakePosEnabled, false)
        updateMenuState()
        return
    end

    if input.KeyCode == MultiTarget.ActivationKey then
        MultiTarget.SetEnabled(not MultiTarget.Enabled)
        return
    end

    if input.KeyCode == MultiTarget.AbortKey then
        if MultiTarget.Enabled or MultiTarget.Running then
            MultiTarget.SetEnabled(false)
            notify("MULTITARGET", "ABORTED", "warning", 2.0)
        end
        return
    end

    if input.KeyCode == Enum.KeyCode.Z then
        setCFrameEnabled(not Utility.CFrameEnabled, false)
        updateMenuState()
        return
    end

    if input.KeyCode == Enum.KeyCode.X then
        setFlyEnabled(not Utility.FlyEnabled, false)
        updateMenuState()
        return
    end

    if input.KeyCode == Config.ESP.ActivationKey then
        setESPEnabled(not Config.ESP.Enabled, false)
    end
end))

track(UserInputService.InputEnded:Connect(function(input)
    if Unloaded then
        return
    end

    if input.KeyCode == Config.Aimbot.ActivationKey and Config.Aimbot.KeyMode == "hold" then
        Aim.Active = false
        clearTarget()
    end
end))

local function isAimbotActive()
    if not Config.Aimbot.Enabled then
        return false
    end
    if Config.Aimbot.KeyMode == "always" then
        return true
    end
    if Config.Aimbot.KeyMode == "toggle" then
        return Aim.Toggled
    end
    if Config.Aimbot.KeyMode == "hold" then
        return Aim.Active
    end
    return false
end

-- Video-style mouse lock: spoof the Mouse hit/target used by many Roblox gun
-- clients. The real camera and visible cursor/crosshair are never forced onto
-- the target, matching the supplied clip.
local function getSilentLockPartAndPosition()
    if not isAimbotActive() then
        return nil, nil
    end
    local target = Aim.CurrentTarget
    if not target or isKnockedOut(target) then
        return nil, nil
    end
    local part = getTargetPart(target)
    if not part then
        return nil, nil
    end
    -- During AllIn1, keep the gun's silent-mouse hit pinned to the exact locked HRP.
    -- Normal C behavior stays unchanged outside this short E-action window.
    if AllIn1.Firing and os.clock() <= (AllIn1.FiringUntil or 0) then
        return AllIn1.ShotTargetPart or part,
            AllIn1.ShotAimPosition or getPredictedPosition(part) or part.Position
    end
    return part, getPredictedPosition(part) or part.Position
end

if type(hookmetamethod) == "function" and type(newcclosure) == "function" and AimMouse then
    local ok, original = pcall(function()
        local oldIndex
        oldIndex = hookmetamethod(game, "__index", newcclosure(function(self, key)
            local internalCaller = type(checkcaller) == "function" and checkcaller()
            if not internalCaller and not Unloaded and self == AimMouse then
                local part, position = getSilentLockPartAndPosition()
                if part and position then
                    if key == "Hit" then
                        return CFrame.new(position)
                    elseif key == "Target" then
                        return part
                    elseif key == "UnitRay" then
                        local origin = nil
                        if AllIn1.Firing and os.clock() <= (AllIn1.FiringUntil or 0) then
                            -- During E/H the character can move many studs before the
                            -- camera catches up. A camera-origin UnitRay can therefore
                            -- fire from the OLD position even while ammo is consumed.
                            -- Use the actual live weapon muzzle (or HRP fallback) so
                            -- Hit/Target/UnitRay all describe the same shot geometry.
                            local liveCharacter = LocalPlayer.Character
                            local liveTool = AllIn1.GetEquippedTool(liveCharacter)
                            local _, muzzlePosition = getWeaponMuzzle(liveTool)
                            local liveRoot = liveCharacter and liveCharacter:FindFirstChild("HumanoidRootPart")
                            origin = muzzlePosition or (liveRoot and liveRoot.Position)
                        end
                        origin = origin or (Camera and Camera.CFrame.Position) or position
                        local delta = position - origin
                        if delta.Magnitude > 0.001 then
                            return Ray.new(origin, delta.Unit * 10000)
                        end
                    end
                end
            end
            return oldIndex(self, key)
        end))
        return oldIndex
    end)
    if ok and original then
        OriginalMouseIndex = original
        SilentMouseInstalled = true
    end
end

-- ============================================================
-- FOV (preserved, disabled by default)
-- ============================================================

local FOVLayer = new("Frame", {
    Name = "FOVLayer",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Visible = false,
}, RootGui)

local FOVDots = {}
for i = 1, 64 do
    FOVDots[i] = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(2, 2),
        BackgroundColor3 = Theme.Accent,
        BorderSizePixel = 0,
        Visible = false,
    }, FOVLayer)
end

local function updateFOV()
    FOVLayer.Visible = Config.Aimbot.DrawFOV
    if not Config.Aimbot.DrawFOV then
        return
    end

    local mouse = UserInputService:GetMouseLocation()
    local thickness = math.max(1, math.floor(Config.Aimbot.FOVThickness))

    for index, dot in ipairs(FOVDots) do
        local angle = (index / #FOVDots) * math.pi * 2
        dot.Position = UDim2.fromOffset(
            mouse.X + math.cos(angle) * Config.Aimbot.Radius,
            mouse.Y + math.sin(angle) * Config.Aimbot.Radius
        )
        dot.Size = UDim2.fromOffset(thickness, thickness)
        dot.BackgroundTransparency = 1 - Config.Aimbot.FOVTransparency
        dot.Visible = true
    end
end

-- ============================================================
-- Aimview / mod detection preserved, using the custom popups
-- ============================================================

if Config.Aimview_Notifier then
    -- Keep this on Config instead of allocating another main-chunk local.
    -- This script is intentionally close to Luau's 200 active-local limit.
    Config.AimviewerRequests = ReplicatedStorage:FindFirstChild("AIMVIEWER_REQUESTS")
    if Config.AimviewerRequests then
        track(Config.AimviewerRequests.ChildAdded:Connect(function(child)
            if Unloaded or child.Name ~= LocalPlayer.Name then
                return
            end

            task.delay(0.1, function()
                if Unloaded then
                    return
                end
                local success, result = pcall(function()
                    return child.Value
                end)
                if success and result and result ~= "" and result ~= LocalPlayer.Name then
                    notify("AIMVIEW DETECTED", "aimviewed by " .. tostring(result), "warning", 5)
                else
                    notify("AIMVIEW DETECTED", "someone is aimviewing you", "warning", 5)
                end
            end)
        end))

        track(Config.AimviewerRequests.ChildRemoved:Connect(function(child)
            if not Unloaded and child.Name == LocalPlayer.Name then
                notify("AIMVIEW ENDED", "you are no longer being aimviewed", "lock", 4)
            end
        end))
    end
    Config.AimviewerRequests = nil
end

Config.ModNotified = Config.ModNotified or {}
Config.OnModDetected = function(player)
    if Unloaded or not player or Config.ModNotified[player.UserId] then
        return
    end
    Config.ModNotified[player.UserId] = true

    if Config.Mod_Detection == "Notify" then
        notify("MOD IN SERVER", player.Name .. " (" .. player.DisplayName .. ")", "mod", 6)
    elseif Config.Mod_Detection == "Kick" then
        LocalPlayer:Kick("Mod detected: " .. player.Name)
    end
end

Config.WatchMod = function(player)
    if not player or Config.Mod_Detection == "None" or player == LocalPlayer then
        return
    end

    if player:FindFirstChild("IS_MOD") then
        Config.OnModDetected(player)
    end

    track(player.ChildAdded:Connect(function(child)
        if child and child.Name == "IS_MOD" then
            Config.OnModDetected(player)
        end
    end))
end

if Config.Mod_Detection ~= "None" then
    -- Avoid introducing more main-chunk locals here: the original generic-for
    -- crossed Lua/Luau's 200-active-local parser limit at this exact section.
    Config.ModScanPlayers = Players:GetPlayers()
    Config.ModScanIndex = 1
    while Config.ModScanIndex <= #Config.ModScanPlayers do
        Config.WatchMod(Config.ModScanPlayers[Config.ModScanIndex])
        Config.ModScanIndex = Config.ModScanIndex + 1
    end
    Config.ModScanPlayers = nil
    Config.ModScanIndex = nil

    track(Players.PlayerAdded:Connect(Config.WatchMod))
    track(Players.PlayerRemoving:Connect(function(player)
        if player then
            Config.ModNotified[player.UserId] = nil
        end
    end))
end

-- ============================================================
-- Final render loop
-- ============================================================

pcall(function()
    RunService:UnbindFromRenderStep(RENDER_BIND_NAME)
end)

Config.ESP.Accumulator = 0
Config.ESP.HUDAccumulator = 0

RunService:BindToRenderStep(RENDER_BIND_NAME, Enum.RenderPriority.Last.Value, function(deltaTime)
    if Unloaded then
        return
    end

    Camera = Workspace.CurrentCamera or Camera
    if not Camera then
        return
    end

    updateUtilityMovement(deltaTime)

    if Config.Aimbot.DrawFOV then
        updateFOV()
    end

    Config.ESP.Accumulator = (Config.ESP.Accumulator or 0) + (deltaTime or 0.016)
    Config.ESP.HUDAccumulator = (Config.ESP.HUDAccumulator or 0) + (deltaTime or 0.016)

    local espInterval = 1 / math.max(10, tonumber(Config.ESP.UpdateRate) or 20)
    if Config.ESP.Enabled and (Config.ESP.Accumulator >= espInterval or Config.ESP.HealthDirty) then
        Config.ESP.Accumulator = 0
        Config.ESP.HealthDirty = false
        updateESP()
    end

    if Config.ESP.HUDAccumulator >= (1 / 60) or Config.ESP.HUDHealthDirty then
        Config.ESP.HUDAccumulator = 0
        Config.ESP.HUDHealthDirty = false
        -- Target HP is cheap to read, so the popup refreshes every rendered
        -- 60 Hz frame and health signals can also force an immediate refresh.
        updateTargetHUD()
    end

    updateCursorTracer()
    Utility.UpdateFakePosProxy()
    Utility.UpdateFakePosGhostTracer()

    if not isAimbotActive() then
        return
    end

    if Config.Aimbot.StickyAim then
        -- Keep target identity by UserId. Character respawns or a brief Player
        -- reference gap will not make the lock jump to somebody else.
        if Aim.LockedUserId and (not Aim.CurrentTarget or Aim.CurrentTarget.Parent == nil) then
            Aim.CurrentTarget = findPlayerByUserId(Aim.LockedUserId)
        end

        if Aim.CurrentTarget then
            local target = Aim.CurrentTarget

            -- Keep the same locked UserId through KO/death. Aim output pauses
            -- while the target is down, then automatically resumes on this same
            -- Player after their Character/HRP comes back. Pressing C still lets
            -- the user manually unlock/switch normally.
            local targetHumanoid = getHumanoid(target)
            if isKnockedOut(target)
                or (Config.Aimbot.DeadCheck and (not targetHumanoid or targetHumanoid.Health <= 0))
            then
                Aim.SmoothedVelocity = Vector3.zero
                return
            end

            -- If blacklist-only mode is active, an existing lock is valid only
            -- when that player is one of the selected blacklisted targets.
            if not MultiTarget.Running
                and hasPresentBlacklistedTargets()
                and not isBlacklisted(target)
            then
                setAimToggled(false, true)
                return
            end

            if target.Parent == nil then
                Aim.CurrentTarget = nil
                Aim.SmoothedVelocity = Vector3.zero
                return
            end
        elseif Aim.LockedUserId then
            -- Same user is temporarily absent: stay armed for that identity
            -- instead of acquiring a random replacement.
            return
        else
            local acquired = getBestTarget()
            if not acquired then
                return
            end

            Aim.CurrentTarget = acquired
            Aim.LockedUserId = acquired.UserId
            Aim.SmoothedVelocity = Vector3.zero
            notify("TARGET LOCKED", acquired.DisplayName, "lock", 2.8)
            updateTargetThumbnail(acquired)
            updateMenuState()
        end

        if Config.Aimbot.RequireFovWhileSticky and Aim.CurrentTarget and not isInFov(Aim.CurrentTarget) then
            return
        end
    else
        Aim.CurrentTarget = getBestTarget()
        Aim.LockedUserId = Aim.CurrentTarget and Aim.CurrentTarget.UserId or nil
    end

    local target = Aim.CurrentTarget
    local targetPart = getTargetPart(target)
    if not targetPart then
        -- Keep the Player sticky across a temporary character/HRP gap.
        return
    end

    if not Camera or not Camera.Parent then
        return
    end

    local predicted = getPredictedPosition(targetPart)
    if not predicted then
        return
    end

    if Config.Aimbot.Mode == "SilentMouse" then
        -- Preferred path is the Mouse.Hit/Target hook above. It leaves camera and
        -- crosshair untouched. Fallback only when the executor has no hook API.
        if not SilentMouseInstalled and type(mousemoverel) == "function" then
            local screenPos, onScreen = Camera:WorldToViewportPoint(predicted)
            if onScreen and screenPos.Z > 0 then
                local mouse = UserInputService:GetMouseLocation()
                local dx = (screenPos.X - mouse.X) * 1.000
                local dy = (screenPos.Y - mouse.Y) * 1.000
                if math.abs(dx) > 0.01 or math.abs(dy) > 0.01 then
                    mousemoverel(dx, dy)
                end
            end
        end
    end
end)

notify("alex.ftn LOADED", "client ready", "lock", 3)
