Assets = {
    Asset("ATLAS", "images/bihud_hud.xml"),
    Asset("IMAGE", "images/bihud_hud.tex"),
    Asset("ATLAS", "images/bihud_mouth.xml"),
    Asset("IMAGE", "images/bihud_mouth.tex"),
}

local BadgeHUD = require("widgets/badgehud")
local GetTaskRemaining = GLOBAL.GetTaskRemaining

AddPrefabPostInit("beefalo", function(inst)
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
    inst.bihud_ridingtime_netvar = GLOBAL.net_float(inst.GUID, "bihud_ridingtime", "bihud_ridingtime_dirty")
end)

--无鞍=0：无鞍骑不了(rideable.canride 仅挂鞍时为 true，见 rideable.lua)
local function get_saddle_uses(saddle_item)
    local finiteuses = saddle_item ~= nil and saddle_item.components ~= nil and saddle_item.components.finiteuses or nil
    return finiteuses ~= nil and finiteuses:GetUses() or 0
end

local function sync_all(inst)
    if inst.components.health then
        inst.bihud_health_c_netvar:set(inst.components.health.currenthealth)
        inst.bihud_health_m_netvar:set(inst.components.health.maxhealth)
    end
    if inst.components.hunger then
        inst.bihud_hunger_c_netvar:set(inst.components.hunger.current)
        inst.bihud_hunger_m_netvar:set(inst.components.hunger.max)
    end
    if inst.components.domesticatable then
        local d = inst.components.domesticatable
        inst.bihud_domestication_netvar:set(d:GetDomestication())
        inst.bihud_obedience_netvar:set(d:GetObedience())
        inst.bihud_tendency_netvar:set(inst.tendency or "DEFAULT")
    end
    local saddle = inst.components.rideable and inst.components.rideable.saddle
    inst.bihud_saddle_use_netvar:set(get_saddle_uses(saddle))
end

local function on_healthdelta(inst)
    if not inst.components.health then return end
    inst.bihud_health_c_netvar:set(inst.components.health.currenthealth)
    inst.bihud_health_m_netvar:set(inst.components.health.maxhealth)
end

local function on_hungerdelta(inst)
    if not inst.components.hunger then return end
    inst.bihud_hunger_c_netvar:set(inst.components.hunger.current)
    inst.bihud_hunger_m_netvar:set(inst.components.hunger.max)
end

local function on_domesticationdelta(inst)
    if not inst.components.domesticatable then return end
    local d = inst.components.domesticatable
    inst.bihud_domestication_netvar:set(d:GetDomestication())
    inst.bihud_tendency_netvar:set(inst.tendency or "DEFAULT")--官方在 domesticationdelta 里 SetTendency，此处同步
end

local function on_obediencedelta(inst)
    if inst.components.domesticatable then
        inst.bihud_obedience_netvar:set(inst.components.domesticatable:GetObedience())
    end
end

local function on_saddlechanged(inst, data)
    inst.bihud_saddle_use_netvar:set(get_saddle_uses(data and data.saddle))
end

local function add_data_listeners(inst)
    inst:ListenForEvent("healthdelta", on_healthdelta)
    inst:ListenForEvent("hungerdelta", on_hungerdelta)
    inst:ListenForEvent("domesticationdelta", on_domesticationdelta)
    inst:ListenForEvent("obediencedelta", on_obediencedelta)
    inst:ListenForEvent("saddlechanged", on_saddlechanged)
end

local function remove_data_listeners(inst)
    inst:RemoveEventCallback("healthdelta", on_healthdelta)
    inst:RemoveEventCallback("hungerdelta", on_hungerdelta)
    inst:RemoveEventCallback("domesticationdelta", on_domesticationdelta)
    inst:RemoveEventCallback("obediencedelta", on_obediencedelta)
    inst:RemoveEventCallback("saddlechanged", on_saddlechanged)
    if inst.bihud_buck_timer then--骑乘结束的统一收摊入口(含计时器)
        inst.bihud_buck_timer:Cancel()
        inst.bihud_buck_timer = nil
    end
end

local function set_riding_time(inst, time)
    if time == nil or time < 0 then
        time = 0
    end
    if inst.bihud_ridingtime_netvar:value() ~= time then
        inst.bihud_ridingtime_netvar:set(time)
    end
end

local function start_buck_timer(inst)
    if not inst._bucktask then
        set_riding_time(inst, 0)
        return
    end
    set_riding_time(inst, GetTaskRemaining(inst._bucktask))
    if inst.bihud_buck_timer then inst.bihud_buck_timer:Cancel() end
    inst.bihud_buck_timer = inst:DoPeriodicTask(1, function()
        --骑手断开收不到 dismounted：自检并收摊，避免残留 1s 任务
        local rider = inst.components.rideable and inst.components.rideable.rider
        if rider == nil or not rider:IsValid() then
            remove_data_listeners(inst)
            return
        end
        if inst._bucktask then
            set_riding_time(inst, GetTaskRemaining(inst._bucktask))
        else
            set_riding_time(inst, 0)
        end
    end)
end

local function on_mounted(player, data)
    local mount = data and data.target
    if not (mount and mount:HasTag("beefalo")) then return end
    sync_all(mount)
    add_data_listeners(mount)
    start_buck_timer(mount)
end

local function on_dismounted(player, data)
    local mount = data and data.target
    if not mount then return end
    remove_data_listeners(mount)--已含取消计时器
    set_riding_time(mount, 0)
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
local ALLOW_DOUBLE_CLICK_ATTACK = GetModConfigData("ALLOW_DOUBLE_CLICK_ATTACK")

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
    --挂官方扩展点 CanBeAlly(非 IsAlly)：IsAlly=CanBeAlly 且对方没在打我，故自家牛攻击你时仍可反手
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
