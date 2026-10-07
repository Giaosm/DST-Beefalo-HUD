local Widget = require "widgets/widget"
local Image = require "widgets/image"
local Badge = require "widgets/badge"
local Text = require "widgets/text"

--仅作徽章构造时的初始上限；实际总时长由服务端推送(见 RefreshRidingTime)
local RIDINGTIME_MAX = TUNING.BEEFALO_MAX_BUCK_TIME

--x = 徽章展开后的位置(改布局只改这一处)
--图标：minimap = true 走 GetMinimapAtlas，其余走 GetInventoryItemAtlas
local BADGE_CONFIGS = {
    {key = "domestication", x = -200, max = 100, colour = WEBCOLOURS.PURPLE, hide_time = .3,
        image = "beefalo_domesticated.png", minimap = true, scale = 0.55},
    {key = "ridingtime",   x = -100, max = RIDINGTIME_MAX, colour = WEBCOLOURS.ORANGE, circular = true,
        image = "saddle_basic.tex", scale = 0.6},
    {key = "health",       x = 0, max = TUNING.BEEFALO_HEALTH, colour = WEBCOLOURS.FIREBRICK, anim = "status_health"},
    {key = "obedience",    x = 100, max = 100, colour = WEBCOLOURS.GREEN,
        image = "whip.tex", scale = 0.6},
    {key = "hunger",       x = 200, max = TUNING.BEEFALO_HUNGER, colour = WEBCOLOURS.GOLDENROD, hide_time = .3,
        anim = "status_hunger"},
}

--文案集中在这里
local TEXT = {
    max_prefix = "Max\n",
    saddle_prefix = "鞍\n",
}
--官方倾向 → 悬浮显示名
local TENDENCY_NAMES = {
    RIDER   = "骑行",
    ORNERY  = "战斗",
    PUDGY   = "肥胖",
    DEFAULT = "普通",
}

--悬浮提示文字：显示在徽章正中的图标上
local function make_badge_info(badge)
    local txt = badge:AddChild(Text(BODYTEXTFONT, 22, ""))
    txt:SetPosition(2.5, 0)
    txt:Hide()
    return txt
end

local function create_badge_icon(badge, cfg)
    if not cfg.image then return end
    --官方图集运行时解析
    local atlas = cfg.minimap and GetMinimapAtlas(cfg.image) or GetInventoryItemAtlas(cfg.image)
    if not atlas then return end--解析不到就不画，避免 Image 报错
    local icon = badge.underNumber:AddChild(Image(atlas, cfg.image))
    icon:SetScale(cfg.scale)
    return icon
end

--表盘颜色统一走 cfg.colour
local function set_colours(badge, cfg)
    badge.anim:GetAnimState():SetMultColour(cfg.colour[1], cfg.colour[2], cfg.colour[3], 1)
end

--数值全部来自本玩家的 player_classified(服务端同步)
local function get_key_values(classified)
    local v = {}
    if classified == nil then return v end
    if classified.bihud_domestication_netvar then
        v.domestication = classified.bihud_domestication_netvar:value()
        v.tendency = classified.bihud_tendency_netvar:value()
        v.obedience = classified.bihud_obedience_netvar:value()
    end
    if classified.bihud_health_c_netvar then
        v.health = classified.bihud_health_c_netvar:value()
        v.health_max = classified.bihud_health_m_netvar:value()
    end
    if classified.bihud_hunger_c_netvar then
        v.hunger = classified.bihud_hunger_c_netvar:value()
        v.hunger_max = classified.bihud_hunger_m_netvar:value()
    end
    if classified.bihud_ridetime_netvar then
        v.ridetime = classified.bihud_ridetime_netvar:value()
    end
    if classified.bihud_saddle_use_netvar then
        v.saddle_use = classified.bihud_saddle_use_netvar:value()
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

        --官方数字常显：Badge 的焦点回调会 Hide 它，这里屏蔽
        badge.num.Hide = function() end
        badge.num:Show()

        --官方 maxnum 悬浮时会弹出"Max:xxx"，屏蔽掉
        if badge.maxnum then
            badge.maxnum.Show = function() end
            badge.maxnum:Hide()
        end

        badge.icon = create_badge_icon(badge, cfg)
        badge.info = make_badge_info(badge)

        badge:SetOnGainFocus(function()
            badge:SetScale(1.1)
            badge.info:Show()
            --maxnum 可能构造后才建出来，悬浮时再压一次
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

function BadgeHUD:RefreshDomestication(v)
    v = v or get_key_values(self.player_classified)
    local c = self._cache
    if v.domestication ~= c.domestication then
        c.domestication = v.domestication
        --先 SetPercent(官方会写一次 num)，再覆盖成我们的格式
        self.badges.domestication:SetPercent(v.domestication, 100)
        self.badges.domestication.num:SetString(string.format("%.1f", v.domestication * 100))
    end
end

function BadgeHUD:RefreshTendency(v)
    v = v or get_key_values(self.player_classified)
    local c = self._cache
    if v.tendency ~= c.tendency then
        c.tendency = v.tendency
        self.badges.domestication.info:SetString(TENDENCY_NAMES[v.tendency] or TENDENCY_NAMES.DEFAULT)
    end
end

function BadgeHUD:RefreshObedience(v)
    v = v or get_key_values(self.player_classified)
    local c = self._cache
    if v.obedience ~= c.obedience then
        c.obedience = v.obedience
        local pct = math.floor(v.obedience * 100)
        self.badges.obedience:SetPercent(v.obedience, 100)
        self.badges.obedience.num:SetString(tostring(pct))
        self.badges.obedience.info:SetString(TEXT.max_prefix .. "100")
    end
end

--上限还没到位(或组件缺失)时跳过，避免 0/0 算出 NaN
function BadgeHUD:RefreshHealth(v)
    v = v or get_key_values(self.player_classified)
    local c = self._cache
    if (v.health ~= c.health or v.health_max ~= c.health_max) and (v.health_max or 0) > 0 then
        c.health = v.health
        c.health_max = v.health_max
        self.badges.health:SetPercent(v.health / v.health_max, v.health_max)
        self.badges.health.num:SetString(tostring(math.floor(v.health)))
        self.badges.health.info:SetString(TEXT.max_prefix .. math.floor(v.health_max))
    end
end

--上限还没到位时跳过，避免 0/0 算出 NaN
function BadgeHUD:RefreshHunger(v)
    v = v or get_key_values(self.player_classified)
    local c = self._cache
    if (v.hunger ~= c.hunger or v.hunger_max ~= c.hunger_max) and (v.hunger_max or 0) > 0 then
        c.hunger = v.hunger
        c.hunger_max = v.hunger_max
        self.badges.hunger:SetPercent(v.hunger / v.hunger_max, v.hunger_max)
        self.badges.hunger.num:SetString(tostring(math.floor(v.hunger)))
        self.badges.hunger.info:SetString(TEXT.max_prefix .. math.floor(v.hunger_max))
    end
end

function BadgeHUD:RefreshRidingTime(v)
    v = v or get_key_values(self.player_classified)
    local c = self._cache
    --服务端只在上牛/喂食重置时推一次；值变了才重新锚定，兜底轮询不会打乱倒计时
    if v.ridetime ~= c.ridetime then
        c.ridetime = v.ridetime
        if v.ridetime > 0 then
            self._ride_total = v.ridetime
            self._ride_deadline = GetTime() + v.ridetime
        else--下牛推 0：不锚定，免得算出 0/0
            self._ride_total = nil
            self._ride_deadline = nil
        end
        self._ride_shown = nil
        self:UpdateRideCountdown()
    end
end

--倒计时本地逐帧算；上限用服务端推来的真实总时长
function BadgeHUD:UpdateRideCountdown()
    local deadline, total = self._ride_deadline, self._ride_total
    if deadline == nil or total == nil or total <= 0 then return end
    local remain = deadline - GetTime()
    if remain < 0 then remain = 0 end
    local sec = math.floor(remain)
    if sec ~= self._ride_shown then
        self._ride_shown = sec
        self.badges.ridingtime:SetPercent(remain / total, total)
        self.badges.ridingtime.num:SetString(tostring(sec))
    end
end

function BadgeHUD:RefreshSaddle(v)
    v = v or get_key_values(self.player_classified)
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

function BadgeHUD:RefreshAll()
    --整包只读一次再分发；dirty 事件回调走无参路径(各自读一次)
    local v = get_key_values(self.player_classified)
    if next(v) == nil then return end--数据源还没就绪(classified 未挂上)，别拿 nil 去算
    self:RefreshDomestication(v)
    self:RefreshTendency(v)
    self:RefreshObedience(v)
    self:RefreshHealth(v)
    self:RefreshHunger(v)
    self:RefreshRidingTime(v)
    self:RefreshSaddle(v)
    if self.owner and self.owner.owner then
        self:RefreshSaddleIcon(self.owner.owner.replica.rider)
    end
end

--这些 dirty 事件都来自本玩家的 player_classified
local CLASSIFIED_DIRTY_EVENTS = {
    { "bihud_health_c_dirty", "RefreshHealth" },
    { "bihud_health_m_dirty", "RefreshHealth" },
    { "bihud_hunger_c_dirty", "RefreshHunger" },
    { "bihud_hunger_m_dirty", "RefreshHunger" },
    { "bihud_domestication_dirty", "RefreshDomestication" },
    { "bihud_obedience_dirty", "RefreshObedience" },
    { "bihud_tendency_dirty", "RefreshTendency" },
    { "bihud_saddle_use_dirty", "RefreshSaddle" },
    { "bihud_ridetime_dirty", "RefreshRidingTime" },
}

--只挂一次，数据源不随上下牛变化
function BadgeHUD:AttachClassified(classified)
    if self.player_classified == classified then return end
    self:DetachClassified()
    if classified == nil then return end
    self.player_classified = classified

    local fns = {}
    for _, ev in ipairs(CLASSIFIED_DIRTY_EVENTS) do
        local fn = function() self[ev[2]](self) end
        fns[ev[1]] = fn
        classified:ListenForEvent(ev[1], fn)
    end
    self._classified_listeners = fns
end

function BadgeHUD:DetachClassified()
    if self.player_classified == nil then return end
    if self._classified_listeners then
        for ev, fn in pairs(self._classified_listeners) do
            self.player_classified:RemoveEventCallback(ev, fn)
        end
        self._classified_listeners = nil
    end
    self.player_classified = nil
end

--下牛/换牛：清缓存 + 丢弃本地倒计时，下次上牛重新锚定
function BadgeHUD:DetachRide()
    self._ride_mount = nil
    self._ride_deadline = nil
    self._ride_total = nil
    self._ride_shown = nil
    self._cache = {}
    self._update_accum = 0
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
        self:DetachRide()
        self:Hide()
        return
    end

    --player_classified 与 HUD 的构造顺序不保证，这里懒挂一次
    self:AttachClassified(player.player_classified)

    local rider = player.replica.rider
    if not rider:IsRiding() then
        self:DetachRide()
        self:Hide()
        return
    end

    local mount = rider:GetMount()
    if not (mount and mount:HasTag("beefalo")) then
        self:DetachRide()
        self:Hide()
        return
    end

    self:Show()

    if self._ride_mount ~= mount then
        self:DetachRide()
        self._ride_mount = mount
        self:RefreshAll()
        return
    end

    self:UpdateRideCountdown()

    self._update_accum = (self._update_accum or 0) + dt
    if self._update_accum >= UPDATE_INTERVAL then
        self._update_accum = 0
        self:RefreshAll()
    end
end

--Kill 是引擎销毁入口：摘监听 + 取消未完成任务
function BadgeHUD:Kill()
    self:DetachClassified()
    if self._follow_task then self._follow_task:Cancel(); self._follow_task = nil end
    if self._spread_task then self._spread_task:Cancel(); self._spread_task = nil end
    if self._done_task then self._done_task:Cancel(); self._done_task = nil end
    if self._hide_task then self._hide_task:Cancel(); self._hide_task = nil end
    Widget.Kill(self)
end

return BadgeHUD
