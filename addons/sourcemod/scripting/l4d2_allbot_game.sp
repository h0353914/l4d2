#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "1.0.0"

public Plugin myinfo =
{
	name        = "[L4D2] All-Bot Game",
	author      = "h0353914",
	description = "Keep the server alive when every survivor is a bot (fixes 'server shut down because all players were idle')",
	version     = PLUGIN_VERSION,
	url         = ""
};

// 需要強制設成 1 的 cvar(新版遊戲可能已不存在其中某些,找不到就略過)
static const char TARGET_CVARS[][] =
{
	"sb_all_bot_game",
	"allow_all_bot_survivor_team"
};

ConVar g_cvEnable;
ConVar g_cvLock;

bool g_bApplying; // 我們自己正在改值時,不要觸發「被改掉就改回來」

public void OnPluginStart()
{
	CreateConVar("l4d2_allbot_game_version", PLUGIN_VERSION, "Plugin version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvEnable = CreateConVar("l4d2_allbot_game_enable", "1", "1 = force sb_all_bot_game / allow_all_bot_survivor_team to 1, 0 = do nothing.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvLock   = CreateConVar("l4d2_allbot_game_lock",   "1", "1 = set the cvars back to 1 whenever something changes them, 0 = only set them on load / map change.", _, true, 0.0, true, 1.0);

	g_cvEnable.AddChangeHook(OnSettingChanged);

	// 監聽目標 cvar,被別的設定檔或插件改掉時可以改回來
	for (int i = 0; i < sizeof TARGET_CVARS; i++)
	{
		ConVar cv = FindConVar(TARGET_CVARS[i]);
		if (cv != null)
			cv.AddChangeHook(OnTargetChanged);
	}

	ApplyCvars();
}

public void OnMapStart()
{
	ApplyCvars();
}

public void OnConfigsExecuted()
{
	// 競技模式的設定檔常在這個時間點把值蓋回 0,所以設定檔跑完後再套用一次
	ApplyCvars();
}

public void OnSettingChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ApplyCvars();
}

public void OnTargetChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (g_bApplying || !g_cvEnable.BoolValue || !g_cvLock.BoolValue)
		return;

	if (convar.IntValue != 1)
		ApplyCvars();
}

void ApplyCvars()
{
	if (!g_cvEnable.BoolValue)
		return;

	g_bApplying = true;

	for (int i = 0; i < sizeof TARGET_CVARS; i++)
	{
		ConVar cv = FindConVar(TARGET_CVARS[i]);
		if (cv == null)
			continue;

		// 這些 cvar 帶有作弊旗標,不移掉的話從主控台 / rcon 手動輸入會被擋
		cv.Flags &= ~FCVAR_CHEAT;
		cv.SetInt(1, false, false);
	}

	g_bApplying = false;
}
