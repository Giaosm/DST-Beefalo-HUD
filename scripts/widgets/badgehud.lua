local Widget = require "widgets/widget"
local Image = require "widgets/image"
local Badge = require "widgets/badge"
local Text = require "widgets/text"

--上限取官方 TUNING，游戏调数值自动跟随
local RIDINGTIME_MAX = TUNING.BEEFALO_MAX_BUCK_TIME

--x = 徽章展开后的位置(改布局只改这一处)
local BADGE_CONFIGS = {
    {key = "domestication", x = -200, max = 100, colour = WEBCOLOURS.PURPLE, hide_time = .3,
        atlas = "images/bihud_mouth.xml", image = "Default.tex", scale = 0.1},
    {key = "ridingtime",   x = -100, max = RIDINGTIME_MAX, colour = WEBCOLOURS.ORANGE, circular = true,
        image = "saddle_basic.tex", scale = 0.6},
    {key = "health",       x = 0, max = TUNING.BEEFALO_HEALTH, colour = WEBCOLOURS.FIREBRICK, anim = "status_health"},
    {key = "obedience",    x = 100, max = 100, colour = WEBCOLOURS.GREEN,
        image = "whip.tex", scale = 0.6},
    {key = "hunger",       x = 200, max = TUNING.BEEFALO_HUNGER, colour = WEBCOLOURS.GOLDENROD, hide_time = .3,
        anim = "status_hunger"},
}

--文案集中在这里，便于修改/翻译
local TEXT = {
    max_prefix = "Max\n",
    saddle_prefix = "鞍\n",
}
--官方倾向 → 图标名(bihud_mouth.xml 内) + 显示名
local TENDENCY_INFO = {
    RIDER   = { icon = "Rider",   name = "骑行" },
    ORNERY  = { icon = "Ornery",  name = "战斗" },
    PUDGY   = { icon = "Pudgy",   name = "肥胖" },
    DEFAULT = { icon = "Default", name = "普通" },
}

local function make_badge_num_text(badge)
    local txt = badge:AddChild(Text(NUMBERFONT, 22, "0"))
    txt:SetPosition(2.5, -40.5)
    txt:SetColour(1, 1, 1, .8)
    return txt
end

local function make_badge_info(badge)
    local txt = badge:AddChild(Text(BODYTEXTFONT, 22, ""))
    txt:SetPosition(2.5, 0)
    txt:Hide()
    return txt
end

local function create_badge_icon(badge, cfg)
    if not cfg.image then return end
    --物品图集运行时解析，不硬编码 inventoryimagesN；mod 自绘图集走 cfg.atlas
    local atlas = cfg.atlas or GetInventoryItemAtlas(cfg.image)
    if not atlas then return end--解析不到就不画，避免 Image(nil, ...) 报错
    local icon = badge.underNumber:AddChild(Image(atlas, cfg.image))
    icon:SetScale(cfg.scale)
    return icon
end

--只处理带 anim 的徽章；无 anim/环形由官方 ctor 的 tint 上色
local function set_colours(badge, cfg)
    badge.anim:GetAnimState():SetMultColour(cfg.colour[1], cfg.colour[2], cfg.colour[3], 1)
end

local function get_key_values(mount)
    local v = {}
    if mount.bihud_domestication_netvar then
        v.domestication = mount.bihud_domestication_netvar:value()
        v.tendency = mount.bihud_tendency_netvar:value()
        v.obedience = mount.bihud_obedience_netvar:value()
    end
    if mount.bihud_health_c_netvar then
        v.health = mount.bihud_health_c_netvar:value()
        v.health_max = mount.bihud_health_m_netvar:value()
    end
    if mount.bihud_hunger_c_netvar then
        v.hunger = mount.bihud_hunger_c_netvar:value()
        v.hunger_max = mount.bihud_hunger_m_netvar:value()
    end
    if mount.bihud_ridingtime_netvar then
        v.ridingtime = mount.bihud_ridingtime_netvar:value()
    end
    if mount.bihud_saddle_use_netvar then
        v.saddle_use = mount.bihud_saddle_use_netvar:value()
    end
    return v
end

local function safe_json_decode(str)
    if str == nil or str == "" then return nil end
    local ok, res = pcall(json.decode, str)
    return ok and res or nil
end

local BadgeHUD = Class(Widget, function(self, owner)
    Widget._ctor(self, "BadgeHUD")
    self.owner = owner

    local w, h = TheSim:GetScreenSize()
    self._target_y = h * 0.1 + 63
    self:SetPosition(w/2, self._target_y)

    self.badge_root = self:AddChild(Widget("BadgeRoot"))
    self.badges = {}
    self._cache = {}

    for _, cfg in ipairs(BADGE_CONFIGS) do
        local badge = self.badge_root:AddChild(
            Badge(nil, owner, { cfg.colour[1], cfg.colour[2], cfg.colour[3], 1 }, cfg.anim, cfg.circular, true, true)
        )
        badge:SetPosition(0, 0)
        badge:SetPercent(1, cfg.max)
        badge:SetScale(1)

        set_colours(badge, cfg)

        badge.bg = badge:AddChild(Image("images/bihud_hud.xml", "num_bg.tex"))
        badge.bg:SetPosition(0.5, -40)
        badge.bg:SetScale(.4, .4, 1)

        badge.bg.num = make_badge_num_text(badge)

        --官方 Badge 自带悬浮文字(num/maxnum)与我们 info 同位置会重叠：Show 空实现 + Hide，只留我们的
        for _, w in ipairs({ badge.num, badge.maxnum }) do
            w.Show = function() end
            w:Hide()
        end

        badge.icon = create_badge_icon(badge, cfg)
        badge.info = make_badge_info(badge)

        badge:SetOnGainFocus(function()
            badge:SetScale(1.1)
            badge.info:Show()
            --可能构造后才建出来，悬浮时按老版本做法再压一次
            if badge.num then badge.num:Hide() end
            if badge.maxnum then badge.maxnum:Hide() end
        end)
        badge:SetOnLoseFocus(function()
            badge:SetScale(1)
            badge.info:Hide()
        end)

        self.badges[cfg.key] = badge
    end

    self._shown = false
    self._animating = false
    self._follow_started = false
    self._follow_task = nil
    self.badge_root:Hide()
    Widget.Hide(self)
    self:load_data()
    self:StartUpdating()
end)

function BadgeHUD:save_data()
    local w, h = TheSim:GetScreenSize()
    local x, y, z = self:GetPositionXYZ()
    self._target_y = y
    TheSim:SetPersistentString("bihud_badge_data", json.encode({
        pos = {x = math.floor(x / w * 100) / 100, y = math.floor(y / h * 100) / 100},
    }))
end

function BadgeHUD:load_data()
    TheSim:GetPersistentString("bihud_badge_data", function(success, str)
        if success and str ~= "" then
            local data = safe_json_decode(str)
            if data and data.pos then
                local w, h = TheSim:GetScreenSize()
                self:SetPosition(w * data.pos.x, h * data.pos.y)
                self._target_y = h * data.pos.y
            end
        end
    end)
end

function BadgeHUD:OnMouseButton(button, down, x, y)
    if button == MOUSEBUTTON_LEFT then
        if down then
            self._follow_started = true
            self._follow_task = self.inst:DoTaskInTime(.15, function()
                if self._follow_started then
                    self._followed = true
                    self:FollowMouse()
                end
            end)
        else
            self._follow_started = false
            if self._follow_task then
                self._follow_task:Cancel()
                self._follow_task = nil
            end
            if self._followed then
                self._followed = false
                self:StopFollowMouse()
                self:save_data()
            end
        end
        return true
    end
    return false
end

function BadgeHUD:Show()
    if self._shown or self._animating then return end
    self._animating = true

    local cur_x, _, _ = self:GetPositionXYZ()
    local target_y = self._target_y
    local start_y = target_y - 80

    for _, badge in pairs(self.badges) do
        badge:SetPosition(0, 0)
    end

    Widget.Show(self)
    self.badge_root:Show()
    self:SetPosition(cur_x, start_y)

    self:MoveTo({x=cur_x, y=start_y, z=0}, {x=cur_x, y=target_y, z=0}, .35, function()
        self._spread_task = self.inst:DoTaskInTime(.4, function()
            self._spread_task = nil
            for _, cfg in ipairs(BADGE_CONFIGS) do
                if cfg.x ~= 0 then
                    self.badges[cfg.key]:MoveTo({x=0,y=0,z=0}, {x=cfg.x,y=0,z=0}, cfg.show_time or .5)
                end
            end
        end)
        self._done_task = self.inst:DoTaskInTime(.9, function()
            self._done_task = nil
            self._shown = true
            self._animating = false
        end)
    end)
end

function BadgeHUD:Hide()
    if self._hide_task then return end--收起已在跑，忽略重复(OnUpdate 每帧都调)
    --展示动画未完成(_shown 未置位)时下牛也要收起，否则残留旧数值
    if not self._shown and not self._animating then return end
    if self._spread_task then self._spread_task:Cancel(); self._spread_task = nil end
    if self._done_task then self._done_task:Cancel(); self._done_task = nil end
    self._shown = false
    self._animating = true

    local cur_x, cur_y, _ = self:GetPositionXYZ()
    local target_y = self._target_y
    local end_y = target_y - 80

    for _, cfg in ipairs(BADGE_CONFIGS) do
        if cfg.x ~= 0 then
            local badge = self.badges[cfg.key]
            local badge_x = badge:GetPositionXYZ()--从当前位置收起，避免动画中途下牛时跳到展开位
            badge:MoveTo({x=badge_x, y=0, z=0}, {x=0, y=0, z=0}, cfg.hide_time or .4)
        end
    end

    self._hide_task = self.inst:DoTaskInTime(.4, function()
        self._hide_task = nil
        self:MoveTo({x=cur_x, y=cur_y, z=0}, {x=cur_x, y=end_y, z=0}, .35, function()
            self.badge_root:Hide()
            Widget.Hide(self)
            self._animating = false
            self._cache = {}
        end)
    end)
end

function BadgeHUD:RefreshDomestication(mount)
    local v = get_key_values(mount)
    local c = self._cache
    if v.domestication ~= c.domestication then
        c.domestication = v.domestication
        local pct = v.domestication * 100
        self.badges.domestication.bg.num:SetString(string.format("%.2f", pct))
        self.badges.domestication:SetPercent(v.domestication, 100)
    end
end

function BadgeHUD:RefreshTendency(mount)
    local v = get_key_values(mount)
    local c = self._cache
    if v.tendency ~= c.tendency then
        c.tendency = v.tendency
        local info = TENDENCY_INFO[v.tendency] or TENDENCY_INFO.DEFAULT
        self.badges.domestication.icon:SetTexture("images/bihud_mouth.xml", info.icon .. ".tex")
        self.badges.domestication.info:SetString(info.name)
    end
end

function BadgeHUD:RefreshObedience(mount)
    local v = get_key_values(mount)
    local c = self._cache
    if v.obedience ~= c.obedience then
        c.obedience = v.obedience
        local pct = math.floor(v.obedience * 100)
        self.badges.obedience.bg.num:SetString(tostring(pct))
        self.badges.obedience:SetPercent(v.obedience, 100)
        self.badges.obedience.info:SetString(TEXT.max_prefix .. "100")
    end
end

function BadgeHUD:RefreshHealth(mount)
    local v = get_key_values(mount)
    local c = self._cache
    if v.health ~= c.health or v.health_max ~= c.health_max then
        c.health = v.health
        c.health_max = v.health_max
        self.badges.health.bg.num:SetString(tostring(math.floor(v.health)))
        self.badges.health:SetPercent(v.health / v.health_max, v.health_max)
        self.badges.health.info:SetString(TEXT.max_prefix .. math.floor(v.health_max))
    end
end

function BadgeHUD:RefreshHunger(mount)
    local v = get_key_values(mount)
    local c = self._cache
    if v.hunger ~= c.hunger or v.hunger_max ~= c.hunger_max then
        c.hunger = v.hunger
        c.hunger_max = v.hunger_max
        self.badges.hunger.bg.num:SetString(tostring(math.floor(v.hunger)))
        self.badges.hunger:SetPercent(v.hunger / v.hunger_max, v.hunger_max)
        self.badges.hunger.info:SetString(TEXT.max_prefix .. math.floor(v.hunger_max))
    end
end

function BadgeHUD:RefreshRidingTime(mount)
    local v = get_key_values(mount)
    local c = self._cache
    if v.ridingtime ~= c.ridingtime then
        c.ridingtime = v.ridingtime
        local time = math.floor(v.ridingtime)
        self.badges.ridingtime.bg.num:SetString(tostring(time))
        self.badges.ridingtime:SetPercent(v.ridingtime / RIDINGTIME_MAX, RIDINGTIME_MAX)
    end
end

function BadgeHUD:RefreshSaddle(mount)
    local v = get_key_values(mount)
    local c = self._cache
    if v.saddle_use ~= c.saddle_use then
        c.saddle_use = v.saddle_use
        self.badges.ridingtime.info:SetString(TEXT.saddle_prefix .. (v.saddle_use or 0))
    end
end

function BadgeHUD:RefreshSaddleIcon(rider)
    local c = self._cache
    local saddle = rider and rider:GetSaddle()
    local saddle_key = saddle and saddle.GUID or "none"
    if saddle_key ~= c.saddle_key then
        c.saddle_key = saddle_key
        local inv = saddle and saddle.replica and saddle.replica.inventoryitem
        if inv then
            local atlas = inv:GetAtlas()
            local image = inv:GetImage()
            if atlas and image then
                self.badges.ridingtime.icon:SetTexture(atlas, image)
            end
        end
    end
end

function BadgeHUD:RefreshAll(mount)
    self:RefreshDomestication(mount)
    self:RefreshTendency(mount)
    self:RefreshObedience(mount)
    self:RefreshHealth(mount)
    self:RefreshHunger(mount)
    self:RefreshRidingTime(mount)
    self:RefreshSaddle(mount)
    if self.owner and self.owner.owner then
        self:RefreshSaddleIcon(self.owner.owner.replica.rider)
    end
end

local MOUNT_DIRTY_EVENTS = {
    { "bihud_health_c_dirty", "RefreshHealth" },
    { "bihud_health_m_dirty", "RefreshHealth" },
    { "bihud_hunger_c_dirty", "RefreshHunger" },
    { "bihud_hunger_m_dirty", "RefreshHunger" },
    { "bihud_domestication_dirty", "RefreshDomestication" },
    { "bihud_obedience_dirty", "RefreshObedience" },
    { "bihud_tendency_dirty", "RefreshTendency" },
    { "bihud_saddle_use_dirty", "RefreshSaddle" },
    { "bihud_ridingtime_dirty", "RefreshRidingTime" },
}

function BadgeHUD:AttachMount(mount)
    if self._mount == mount then return end
    self:DetachMount()
    self._mount = mount
    self._cache = {}
    self._update_accum = 0

    if mount.bihud_health_c_netvar then
        local fns = {}
        for _, ev in ipairs(MOUNT_DIRTY_EVENTS) do
            local fn = function() self[ev[2]](self, mount) end
            fns[ev[1]] = fn
            mount:ListenForEvent(ev[1], fn)
        end
        self._mount_listeners = fns
    end

    self:RefreshAll(mount)
end

function BadgeHUD:DetachMount()
    if not self._mount then return end
    if self._mount_listeners then
        for ev, fn in pairs(self._mount_listeners) do
            self._mount:RemoveEventCallback(ev, fn)
        end
        self._mount_listeners = nil
    end
    self._mount = nil
    self._cache = {}
end

local UPDATE_INTERVAL = 0.5 -- 兜底轮询间隔，dirty 事件负责即时刷新

function BadgeHUD:OnUpdate(dt)
    if self._followed then
        local player = self.owner and self.owner.owner
        if not (player and player.replica and player.replica.rider and player.replica.rider:IsRiding()) then
            self._follow_started = false
            self._followed = false
            if self._follow_task then self._follow_task:Cancel(); self._follow_task = nil end
            self:StopFollowMouse()
            self:Hide()
            return
        end
    end

    local player = self.owner and self.owner.owner
    if not (player and player.replica and player.replica.rider) then
        self:Hide()
        return
    end

    local rider = player.replica.rider
    if not rider:IsRiding() then
        self:DetachMount()
        self:Hide()
        return
    end

    local mount = rider:GetMount()
    if not (mount and mount:HasTag("beefalo")) then
        self:DetachMount()
        self:Hide()
        return
    end

    self:Show()

    if self._mount ~= mount then
        self:AttachMount(mount)
        return
    end

    self._update_accum = (self._update_accum or 0) + dt
    if self._update_accum >= UPDATE_INTERVAL then
        self._update_accum = 0
        self:RefreshAll(mount)
    end
end

--Kill 是引擎销毁入口：摘监听 + 取消未完成任务
function BadgeHUD:Kill()
    self:DetachMount()
    if self._follow_task then self._follow_task:Cancel(); self._follow_task = nil end
    if self._spread_task then self._spread_task:Cancel(); self._spread_task = nil end
    if self._done_task then self._done_task:Cancel(); self._done_task = nil end
    if self._hide_task then self._hide_task:Cancel(); self._hide_task = nil end
    Widget.Kill(self)
end

return BadgeHUD
