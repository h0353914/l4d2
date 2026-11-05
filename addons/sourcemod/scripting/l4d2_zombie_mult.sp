#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "1.0.0"
#define TARGET_COUNT   4

public Plugin myinfo =
{
	name        = "[L4D2] Zombie Count Multiplier",
	author      = "h0353914",
	description = "Multiply the zombie spawn counts (mob sizes and common zombie limit) by a factor",
	version     = PLUGIN_VERSION,
	url         = ""
};

// 要乘上倍率的遊戲 cvar:一波屍潮的最小/最大數量、大群屍潮數量、同時存在的普通殭屍上限
static const char TARGET_CVARS[TARGET_COUNT][] =
{
	"z_mob_spawn_min_size",
	"z_mob_spawn_max_size",
	"z_mega_mob_size",
	"z_common_limit"
};

ConVar g_cvMult;

int  g_iBase[TARGET_COUNT]; // 設定檔或其他地方設的原始值(我們乘上倍率的基準)
int  g_iSet[TARGET_COUNT];  // 我們上次實際設定的值,用來分辨「是不是我們自己改的」
bool g_bApplying;           // 我們自己正在改值時,不要觸發變更掛鉤

public void OnPluginStart()
{
	CreateConVar("l4d2_zombie_mult_version", PLUGIN_VERSION, "Plugin version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvMult = CreateConVar("l4d2_zombie_mult", "3.0", "Multiplier for the zombie spawn counts (mob sizes, common zombie limit). 1.0 = vanilla.", _, true, 0.1, true, 10.0);

	g_cvMult.AddChangeHook(OnMultChanged);

	// 目標被別的設定檔或插件改掉時,以新的值為基準重新乘上倍率
	for (int i = 0; i < TARGET_COUNT; i++)
	{
		ConVar cv = FindConVar(TARGET_CVARS[i]);
		if (cv != null)
			cv.AddChangeHook(OnTargetChanged);
	}

	Apply();
}

public void OnMapStart()
{
	Apply();
}

public void OnConfigsExecuted()
{
	// 設定檔跑完後,可能把值蓋回原始值,所以再套用一次
	Apply();
}

public void OnMultChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	Apply();
}

public void OnTargetChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (!g_bApplying)
		Apply();
}

void Apply()
{
	float mult = g_cvMult.FloatValue;

	g_bApplying = true;

	for (int i = 0; i < TARGET_COUNT; i++)
	{
		ConVar cv = FindConVar(TARGET_CVARS[i]);
		if (cv == null)
			continue;

		int cur = cv.IntValue;

		// 目前的值不是我們上次設的,代表是別人改的(或第一次載入),當作新的原始值
		if (cur != g_iSet[i])
			g_iBase[i] = cur;

		int want = RoundToNearest(float(g_iBase[i]) * mult);
		if (want < 1)
			want = 1;

		if (cur != want)
			cv.SetInt(want, false, false);

		g_iSet[i] = want;
	}

	g_bApplying = false;
}
