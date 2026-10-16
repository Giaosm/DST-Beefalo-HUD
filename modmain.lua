local BadgeHUD = require("widgets/badgehud")
local GetTaskRemaining = GLOBAL.GetTaskRemaining

--骑牛数据挂在 player_classified(每玩家一份)，不给世界里每头牛挂 netvar
AddPrefabPostInit("player_classified", function(inst)
    if inst.bihud_health_c_netvar then return end
    inst.bihud_health_c_netvar = GLOBAL.net_float(inst.GUID, "bihud_health_c", "bihud_health_c_dirty")
    inst.bihud_health_m_netvar = GLOBAL.net_float(inst.GUID, "bihud_health_m", "bihud_health_m_dirty")
    inst.bihud_hunger_c_netvar = GLOBAL.net_float(inst.GUID, "bihud_hunger_c", "bihud_hunger_c_dirty")
    inst.bihud_hunger_m_netvar = GLOBAL.net_float(inst.GUID, "bihud_hunger_m", "bihud_hunger_m_dirty")
    inst.bihud_domestication_netvar = GLOBAL.net_float(inst.GUID, "bihud_domestication", "bihud_domestication_dirty")
    inst.bihud_obedience_netvar = GLOBAL.net_float(inst.GUID, "bihud_obedience", "bihud_obedience_dirty")
    --倾向用官方权威值 inst.tendency，勿自己算
    inst.bihud_tendency_netvar = GLOBAL.net_string(inst.GUID, "bihud_tendency", "bihud_tendency_dirty")
    inst.bihud_saddle_use_netvar = GLOBAL.net_ushortint(inst.GUID, "bihud_saddle_use", "bihud_saddle_use_dirty")
    --只推"本次骑行剩余秒数"：上牛、以及喂食重置倒计时时各推一次
    inst.bihud_ridetime_netvar = GLOBAL.net_float(inst.GUID, "bihud_ridetime", "bihud_ridetime_dirty")
end)

--无鞍=0：rideable.canride 仅挂鞍时为 true(见 rideable.lua)
local function get_saddle_uses(saddle_item)
    local finiteuses = saddle_item ~= nil and saddle_item.components ~= nil and saddle_item.components.finiteuses or nil
    return finiteuses ~= nil and finiteuses:GetUses() or 0
end

local function get_classified(player)
    return player ~= nil and player.player_classified or nil
end

--rider.lua 先 SetRider(建计时器)再推 mounted，故此处拿到的是新总时长
local function push_ridetime(player, mount)
    local c = get_classified(player)
    if c == nil or mount == nil or not mount:IsValid() then return end
    local rideable = mount.components.rideable
    if rideable ~= nil and rideable.rider ~= player then return end--已下牛/换骑手，别再推旧数据
    local task = mount._bucktask
    c.bihud_ridetime_netvar:set(task ~= nil and GetTaskRemaining(task) or 0)
end

local function on_healthdelta(player, mount)
    local c = get_classified(player)
    if c == nil or mount.components.health == nil then return end
    c.bihud_health_c_netvar:set(mount.components.health.currenthealth)
    c.bihud_health_m_netvar:set(mount.components.health.maxhealth)
end

local function on_hungerdelta(player, mount)
    local c = get_classified(player)
    if c == nil or mount.components.hunger == nil then return end
    c.bihud_hunger_c_netvar:set(mount.components.hunger.current)
    c.bihud_hunger_m_netvar:set(mount.components.hunger.max)
end

local function on_domesticationdelta(player, mount)
    local c = get_classified(player)
    if c == nil or mount.components.domesticatable == nil then return end
    local d = mount.components.domesticatable
    c.bihud_domestication_netvar:set(d:GetDomestication())
    c.bihud_tendency_netvar:set(mount.tendency or "DEFAULT")--官方在 domesticationdelta 里 SetTendency，此处同步
end

local function on_obediencedelta(player, mount, data)
    local c = get_classified(player)
    if c == nil then return end
    if mount.components.domesticatable then
        c.bihud_obedience_netvar:set(mount.components.domesticatable:GetObedience())
    end
    if data ~= nil and data.new > data.old then
        --喂食等加顺从度会让官方重算倒计时(beefalo.lua OnObedienceDelta)，但同一事件的官方 handler
        --与我们是并列监听、执行顺序不确定，故延到下一帧再读，确保拿到的是重算后的新任务
        player:DoTaskInTime(0, function() push_ridetime(player, mount) end)
    end
end

local function on_saddlechanged(player, mount, data)
    local c = get_classified(player)
    if c == nil then return end
    c.bihud_saddle_use_netvar:set(get_saddle_uses(data and data.saddle))
end

--上牛时整包同步：复用上面的增量 handler，字段只在一处维护
local function sync_all(player, mount)
    on_healthdelta(player, mount)
    on_hungerdelta(player, mount)
    on_domesticationdelta(player, mount)
    local rideable = mount.components.rideable
    on_saddlechanged(player, mount, { saddle = rideable and rideable.saddle })
end

local MOUNT_EVENTS = {
    healthdelta = on_healthdelta,
    hungerdelta = on_hungerdelta,
    domesticationdelta = on_domesticationdelta,
    obediencedelta = on_obediencedelta,
    saddlechanged = on_saddlechanged,
}

--监听挂玩家身上、用坐骑作来源过滤：下牛整批摘掉，玩家一走随之销毁
local function remove_data_listeners(player)
    local binds = player._bihud_binds
    if binds == nil then return end
    --摘除时的来源过滤必须与注册时一致，统一用记下来的坐骑
    local mount = player._bihud_mount
    for event, cb in pairs(binds) do
        player:RemoveEventCallback(event, cb, mount)
    end
    player._bihud_binds = nil
    player._bihud_mount = nil
end

local function add_data_listeners(player, mount)
    remove_data_listeners(player)--保险：mounted 万一没配对上 dismounted，先把上一头牛的监听摘干净
    local binds = {}
    for event, fn in pairs(MOUNT_EVENTS) do
        local cb = function(_, data) fn(player, mount, data) end
        binds[event] = cb
        player:ListenForEvent(event, cb, mount)
    end
    player._bihud_binds = binds
    player._bihud_mount = mount
end

local function on_mounted(player, data)
    local mount = data and data.target
    if not (mount and mount:HasTag("beefalo")) then return end
    sync_all(player, mount)
    push_ridetime(player, mount)
    add_data_listeners(player, mount)
end

local function on_dismounted(player, data)
    if not (data and data.target) then return end
    remove_data_listeners(player)
    local c = get_classified(player)
    if c ~= nil then
        c.bihud_ridetime_netvar:set(0)
    end
end

AddPlayerPostInit(function(inst)
    if not GLOBAL.TheNet:GetIsServer() then return end
    inst:ListenForEvent("mounted", on_mounted)
    inst:ListenForEvent("dismounted", on_dismounted)
end)

AddClassPostConstruct("screens/playerhud", function(self)
    self.BadgeHUD = self.root:AddChild(BadgeHUD(self))
    self.BadgeHUD:Hide()
end)

-- 防止误伤已驯服的皮弗娄牛
local DEFAULT_BEEFALO_NAME = GLOBAL.STRINGS.NAMES.BEEFALO
--拦的是客户端点击，故取客户端配置：每个玩家自己决定
local ALLOW_DOUBLE_CLICK_ATTACK = GetModConfigData("ALLOW_DOUBLE_CLICK_ATTACK", true)

local function IsPetBeefalo(entity)
    if entity == nil or entity.prefab ~= "beefalo" then
        return false
    end
    local follower_replica = entity.replica ~= nil and entity.replica.follower
    local owner = follower_replica ~= nil and follower_replica:GetLeader() or nil
    if owner ~= nil and owner:HasTag("player") then
        return true
    end
    return entity.name ~= DEFAULT_BEEFALO_NAME
end

AddClassPostConstruct("components/combat_replica", function(self)
    --挂官方扩展点 CanBeAlly(非 IsAlly)：牛主动打你时仍可反手
    local oldCanBeAlly = self.CanBeAlly
    self.CanBeAlly = function(inst, entity, ...)
        if IsPetBeefalo(entity) then
            return true
        end
        return oldCanBeAlly(inst, entity, ...)
    end
end)

AddComponentPostInit("playercontroller", function(self)
    local oldOnLeftClick = self.OnLeftClick
    self.OnLeftClick = function(inst, down, ...)
        if not GLOBAL.TheInput then
            return oldOnLeftClick(inst, down, ...)
        end
        local target = GLOBAL.TheInput:GetWorldEntityUnderMouse()
        if down and GLOBAL.TheInput:IsKeyDown(GLOBAL.KEY_CTRL) and IsPetBeefalo(target) then
            if not ALLOW_DOUBLE_CLICK_ATTACK then
                return
            end
            local is_double_click = target.replica._petbeefalo_startdoubleclicktime ~= nil and (GLOBAL.GetTime() - target.replica._petbeefalo_startdoubleclicktime) < GLOBAL.DOUBLE_CLICK_TIMEOUT
            target.replica._petbeefalo_startdoubleclicktime = GLOBAL.GetTime()
            if not is_double_click then
                return
            end
        end
        return oldOnLeftClick(inst, down, ...)
    end
end)
