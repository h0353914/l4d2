#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.0.0"
#define TEAM_SURVIVOR  2

#define WEAPON_M60     "weapon_rifle_m60"
#define WEAPON_GL      "weapon_grenade_launcher"
#define WEAPON_SAW     "weapon_chainsaw"
#define WEAPON_MEDKIT  "weapon_first_aid_kit"

public Plugin myinfo =
{
	name        = "[L4D2] Saferoom Heavy Weapon Drop",
	author      = "h0353914",
	description = "At round start, randomly pick survivors and drop M60s / grenade launchers at their feet",
	version     = PLUGIN_VERSION,
	url         = ""
};

// 彈夾容量(來自遊戲的武器腳本 scripts/weapon_rifle_m60.txt、weapon_grenade_launcher.txt 的 clip_size)
#define CLIP_M60       150
#define CLIP_GL        1
#define CLIP_SAW       30

ConVar g_cvEnable;
ConVar g_cvDelay;
ConVar g_cvM60;
ConVar g_cvGL;
ConVar g_cvSaw;
ConVar g_cvMedkit;
ConVar g_cvRefill;
ConVar g_cvM60Reserve;
ConVar g_cvGLReserve;
ConVar g_cvM60Max;
ConVar g_cvGLMax;
ConVar g_cvSawReserve;
ConVar g_cvSawMax;

int  g_iRound;     // 每回合遞增,用來讓上一回合還沒跑完的計時器失效
bool g_bApplying;  // 我們自己正在改 ammo cvar 時,不要觸發「被改掉就改回來」
int  g_iLastButtons[MAXPLAYERS + 1];

public void OnPluginStart()
{
	CreateConVar("l4d2_saferoom_heavy_version", PLUGIN_VERSION, "Plugin version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvEnable = CreateConVar("l4d2_saferoom_heavy_enable", "1",    "Enable the saferoom heavy weapon drop.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDelay  = CreateConVar("l4d2_saferoom_heavy_delay",  "5.0",  "Seconds between the first living human survivor showing up and the weapons being dropped.", _, true, 1.0, true, 60.0);
	g_cvM60    = CreateConVar("l4d2_saferoom_heavy_m60",    "2",    "How many M60s to drop (one per randomly picked survivor).", _, true, 0.0, true, 4.0);
	g_cvGL     = CreateConVar("l4d2_saferoom_heavy_gl",     "2",    "How many grenade launchers to drop (one per randomly picked survivor).", _, true, 0.0, true, 4.0);

	g_cvSaw    = CreateConVar("l4d2_saferoom_heavy_chainsaw", "1", "How many chainsaws to drop.", _, true, 0.0, true, 4.0);
	g_cvMedkit = CreateConVar("l4d2_saferoom_heavy_medkit",   "2", "How many first aid kits to drop.", _, true, 0.0, true, 8.0);

	g_cvRefill     = CreateConVar("l4d2_saferoom_heavy_refill",    "1",  "1 = using an ammo pile while holding an M60 / grenade launcher refills it.", _, true, 0.0, true, 1.0);
	g_cvM60Reserve = CreateConVar("l4d2_saferoom_heavy_m60_reserve", "-1", "Reserve ammo set on a dropped / refilled M60. -1 = ammo_m60_max minus the clip size.", _, true, -1.0);
	g_cvGLReserve  = CreateConVar("l4d2_saferoom_heavy_gl_reserve",  "-1", "Reserve ammo set on a dropped / refilled grenade launcher. -1 = ammo_grenadelauncher_max minus the clip size.", _, true, -1.0);

	g_cvM60Max = CreateConVar("l4d2_saferoom_heavy_m60_max", "600", "Force the game's ammo_m60_max to this value (-1 = do not touch it).", _, true, -1.0);
	g_cvGLMax  = CreateConVar("l4d2_saferoom_heavy_gl_max",  "65",  "Force the game's ammo_grenadelauncher_max to this value (-1 = do not touch it).", _, true, -1.0);
	g_cvSawReserve = CreateConVar("l4d2_saferoom_heavy_chainsaw_reserve", "-1", "Reserve fuel set on a refilled chainsaw. -1 = ammo_chainsaw_max minus the clip size.", _, true, -1.0);
	g_cvSawMax     = CreateConVar("l4d2_saferoom_heavy_chainsaw_max",     "60","Force the game's ammo_chainsaw_max to this value (-1 = do not touch it).", _, true, -1.0);

	RegAdminCmd("sm_heavyammo_info", Cmd_Info, ADMFLAG_CONFIG, "Print the ammo cvars of the M60 / grenade launcher and the ammo of the weapon you are holding");

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("ammo_pickup", Event_AmmoPickup);

	g_cvM60Max.AddChangeHook(OnAmmoSettingChanged);
	g_cvGLMax.AddChangeHook(OnAmmoSettingChanged);
	g_cvSawMax.AddChangeHook(OnAmmoSettingChanged);

	// 監聽遊戲本身的 cvar,被工作坊插件或設定檔改掉時改回來
	ConVar cv = FindConVar("ammo_m60_max");
	if (cv != null)
		cv.AddChangeHook(OnAmmoCvarChanged);

	cv = FindConVar("ammo_grenadelauncher_max");
	if (cv != null)
		cv.AddChangeHook(OnAmmoCvarChanged);

	cv = FindConVar("ammo_chainsaw_max");
	if (cv != null)
		cv.AddChangeHook(OnAmmoCvarChanged);

	ApplyAmmoCvars();
}

public void OnMapStart()
{
	PrecacheModel("models/w_models/weapons/w_m60.mdl", true);
	PrecacheModel("models/w_models/weapons/w_grenade_launcher.mdl", true);
	PrecacheModel("models/weapons/melee/w_chainsaw.mdl", true);
	PrecacheModel("models/w_models/weapons/w_eq_medkit.mdl", true);
	ApplyAmmoCvars();
}

public void OnConfigsExecuted()
{
	// 設定檔跑完後再套用一次,避免被蓋回去
	ApplyAmmoCvars();
}

public void OnAmmoSettingChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ApplyAmmoCvars();
}

public void OnAmmoCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (!g_bApplying)
		ApplyAmmoCvars();
}

void ApplyAmmoCvars()
{
	g_bApplying = true;
	ForceCvar("ammo_m60_max", g_cvM60Max.IntValue);
	ForceCvar("ammo_grenadelauncher_max", g_cvGLMax.IntValue);
	ForceCvar("ammo_chainsaw_max", g_cvSawMax.IntValue);
	g_bApplying = false;
}

void ForceCvar(const char[] name, int value)
{
	if (value < 0)
		return;

	ConVar cv = FindConVar(name);
	if (cv == null)
		return;

	if (cv.IntValue != value)
		cv.SetInt(value, false, false);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_iRound++;
	// 專用伺服器沒人時場上沒有倖存者,所以不直接倒數,
	// 而是每秒檢查,等到有真玩家活著之後才開始算 delay 秒
	CreateTimer(1.0, Timer_WaitPlayer, g_iRound, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_WaitPlayer(Handle timer, any round)
{
	if (round != g_iRound || !g_cvEnable.BoolValue)
		return Plugin_Stop;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
		{
			CreateTimer(g_cvDelay.FloatValue, Timer_Drop, round, TIMER_FLAG_NO_MAPCHANGE);
			return Plugin_Stop;
		}
	}

	return Plugin_Continue;
}

public Action Timer_Drop(Handle timer, any round)
{
	// 回合已經換過了,這個計時器作廢
	if (round != g_iRound || !g_cvEnable.BoolValue)
		return Plugin_Stop;

	// 收集所有活著的倖存者(真玩家和 bot 都算)
	int list[MAXPLAYERS + 1];
	int count = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
			list[count++] = i;
	}

	if (count == 0)
		return Plugin_Stop;

	// 洗牌,前面的人就是被抽中的
	for (int i = count - 1; i > 0; i--)
	{
		int j = GetRandomInt(0, i);
		int tmp = list[i];
		list[i] = list[j];
		list[j] = tmp;
	}

	int m60   = g_cvM60.IntValue;
	int gl    = g_cvGL.IntValue;
	int saw   = g_cvSaw.IntValue;
	int total = m60 + gl + saw + g_cvMedkit.IntValue;

	// 依序發 M60、榴彈發射器、電鋸、醫療包。東西比人數多時從頭再輪一遍,
	// 這樣有人會同時被抽到兩件,但每件都會掉
	for (int k = 0; k < total; k++)
	{
		char classname[32], label[16];
		if (k < m60)
		{
			strcopy(classname, sizeof classname, WEAPON_M60);
			strcopy(label, sizeof label, "M60");
		}
		else if (k < m60 + gl)
		{
			strcopy(classname, sizeof classname, WEAPON_GL);
			strcopy(label, sizeof label, "榴彈發射器");
		}
		else if (k < m60 + gl + saw)
		{
			strcopy(classname, sizeof classname, WEAPON_SAW);
			strcopy(label, sizeof label, "電鋸");
		}
		else
		{
			strcopy(classname, sizeof classname, WEAPON_MEDKIT);
			strcopy(label, sizeof label, "醫療包");
		}

		int target = list[k % count];
		if (SpawnWeaponAt(target, classname))
			PrintToChatAll("\x04[安全室] \x01%N 腳邊掉了 \x05%s", target, label);
		else
			LogError("Failed to create %s", classname);
	}

	LogMessage("Dropped %d heavy weapon(s) among %d survivor(s).", total, count);

	return Plugin_Stop;
}

// 在指定玩家腳邊生成一把武器,成功回傳 true
bool SpawnWeaponAt(int client, const char[] classname)
{
	int ent = CreateEntityByName(classname);
	if (ent == -1)
		return false;

	float pos[3];
	GetClientAbsOrigin(client, pos);
	pos[2] += 10.0; // 稍微抬高,避免卡進地板

	TeleportEntity(ent, pos, NULL_VECTOR, NULL_VECTOR);
	DispatchSpawn(ent);

	// 武器本身帶的備用彈藥(撿起來時會給玩家)
	int reserve = GetReserveTarget(classname);
	if (reserve >= 0 && HasEntProp(ent, Prop_Send, "m_iExtraPrimaryAmmo"))
		SetEntProp(ent, Prop_Send, "m_iExtraPrimaryAmmo", reserve);

	return true;
}

// ---------------------------------------------------------------------------
// 補彈
// ---------------------------------------------------------------------------

// 有些武器(例如電鋸)拿在手上用彈藥堆時,遊戲不會發出 ammo_pickup 事件,
// 所以另外偵測:按下使用鍵、準心對著附近的彈藥堆,就當作補彈
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	int pressed = buttons & ~g_iLastButtons[client];
	g_iLastButtons[client] = buttons;

	if (!(pressed & IN_USE) || !g_cvRefill.BoolValue || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;

	int target = GetClientAimTarget(client, false);
	if (target <= MaxClients || !IsValidEntity(target))
		return Plugin_Continue;

	char classname[32];
	GetEntityClassname(target, classname, sizeof classname);
	if (!StrEqual(classname, "weapon_ammo_spawn"))
		return Plugin_Continue;

	float a[3], b[3];
	GetClientAbsOrigin(client, a);
	GetEntPropVector(target, Prop_Send, "m_vecOrigin", b);
	if (GetVectorDistance(a, b) > 130.0)
		return Plugin_Continue;

	CreateTimer(0.1, Timer_Refill, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Continue;
}

public void Event_AmmoPickup(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvRefill.BoolValue)
		return;

	// 等遊戲自己處理完這次補彈,再由我們把 M60 / 榴彈發射器 / 電鋸補滿
	CreateTimer(0.1, Timer_Refill, event.GetInt("userid"), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Refill(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client < 1 || !IsClientInGame(client) || !IsPlayerAlive(client))
		return Plugin_Stop;

	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (weapon <= MaxClients || !IsValidEntity(weapon))
		return Plugin_Stop;

	char classname[64];
	GetEntityClassname(weapon, classname, sizeof classname);

	int clip = GetClipSize(classname);
	if (clip == 0)
		return Plugin_Stop; // 不是 M60 / 榴彈發射器 / 電鋸

	SetEntProp(weapon, Prop_Send, "m_iClip1", clip);

	int reserve = GetReserveTarget(classname);
	if (reserve >= 0)
		SetEntProp(client, Prop_Send, "m_iAmmo", reserve, _, GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType"));

	return Plugin_Stop;
}

// 這把武器的彈夾容量,不是我們處理的武器回傳 0
int GetClipSize(const char[] classname)
{
	if (StrEqual(classname, WEAPON_M60))
		return CLIP_M60;
	if (StrEqual(classname, WEAPON_GL))
		return CLIP_GL;
	if (StrEqual(classname, WEAPON_SAW))
		return CLIP_SAW;
	return 0;
}

// 這把武器該有的備用彈藥數,-1 表示不去動(交給遊戲)
int GetReserveTarget(const char[] classname)
{
	int  reserve;
	char cvName[32];

	if (StrEqual(classname, WEAPON_M60))
	{
		reserve = g_cvM60Reserve.IntValue;
		strcopy(cvName, sizeof cvName, "ammo_m60_max");
	}
	else if (StrEqual(classname, WEAPON_GL))
	{
		reserve = g_cvGLReserve.IntValue;
		strcopy(cvName, sizeof cvName, "ammo_grenadelauncher_max");
	}
	else if (StrEqual(classname, WEAPON_SAW))
	{
		reserve = g_cvSawReserve.IntValue;
		strcopy(cvName, sizeof cvName, "ammo_chainsaw_max");
	}
	else
	{
		return -1;
	}

	if (reserve >= 0)
		return reserve;

	// 沒手動指定時,用 ammo_*_max(我們強制設定的值,沒強制時用遊戲目前的值)。
	// 實測 ammo_grenadelauncher_max=65 時,榴彈發射器是彈夾 1 + 備彈 64,
	// 也就是 cvar 的數字包含彈夾,所以備彈要扣掉彈夾容量
	ConVar cv = FindConVar(cvName);
	if (cv == null)
		return -1;

	reserve = cv.IntValue - GetClipSize(classname);
	return (reserve > 0) ? reserve : 0;
}

// ---------------------------------------------------------------------------
// 查詢原始彈藥數
// ---------------------------------------------------------------------------

public Action Cmd_Info(int client, int args)
{
	static const char names[][] = { "ammo_m60_max", "ammo_grenadelauncher_max", "ammo_chainsaw_max" };

	for (int i = 0; i < sizeof names; i++)
	{
		ConVar cv = FindConVar(names[i]);
		if (cv == null)
		{
			ReplyToCommand(client, "[HeavyAmmo] %s: cvar not found", names[i]);
			continue;
		}

		char value[32], def[32];
		cv.GetString(value, sizeof value);
		cv.GetDefault(def, sizeof def);
		ReplyToCommand(client, "[HeavyAmmo] %s = %s (default %s)", names[i], value, def);
	}

	ReplyToCommand(client, "[HeavyAmmo] clip_size from weapon scripts: M60=%d, grenade launcher=%d, chainsaw=%d", CLIP_M60, CLIP_GL, CLIP_SAW);

	if (client < 1 || !IsClientInGame(client) || !IsPlayerAlive(client))
		return Plugin_Handled;

	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (weapon <= MaxClients || !IsValidEntity(weapon))
		return Plugin_Handled;

	char classname[64];
	GetEntityClassname(weapon, classname, sizeof classname);

	int type    = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
	int clip    = GetEntProp(weapon, Prop_Send, "m_iClip1");
	int reserve = (type >= 0) ? GetEntProp(client, Prop_Send, "m_iAmmo", _, type) : -1;
	int extra   = HasEntProp(weapon, Prop_Send, "m_iExtraPrimaryAmmo") ? GetEntProp(weapon, Prop_Send, "m_iExtraPrimaryAmmo") : -1;

	ReplyToCommand(client, "[HeavyAmmo] holding %s: clip=%d reserve=%d (ammo type %d) weapon extra=%d", classname, clip, reserve, type, extra);
	return Plugin_Handled;
}
