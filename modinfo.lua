name = "我的牛牛HUD[服务器]"
author = "哇唧唧哇"
version = "1.0.2"

description = version .. "\n" .. [[
    一个轻量的训牛显示器！！！

    骑上牛后，屏幕会显示5个圆形徽章，实时展示爱牛的
    驯服度 | 骑行时间 | 血量 | 顺从度 | 饥饿值
    
    UI 支持鼠标拖动，可自由摆放到你喜欢的位置，
    拖拽后的位置会自动保存，下次游玩无需重新调整。
    
    附加功能：防止 Ctrl+点击 误伤已绑定的皮弗娄牛
    （该开关是客户端配置，每个玩家自己在"模组设置"里调整，互不影响）
]]

dst_compatible = true
forge_compatible = false
gorge_compatible = false
dont_starve_compatible = false

client_only_mod = false
all_clients_require_mod = true

icon_atlas = "modicon.xml"
icon = "modicon.tex"

forumthread = ""
api_version_dst = 10
priority = 0
mod_dependencies = {}

server_filter_tags = {"我的牛牛HUD", "beefalo badge", "badgehud"}

configuration_options =
{
    {
        name = "ALLOW_DOUBLE_CLICK_ATTACK",
        label = "允许双击攻击",
        hover = "启用后可用 Ctrl + 双击 强制攻击已绑定的皮弗娄牛。",
        options =
        {
            {description = "开", data = true, hover = "客户端设置，每个玩家独立生效。"},
            {description = "关", data = false, hover = "客户端设置，每个玩家独立生效。"},
        },
        default = false,
        client = true,
    },
}
