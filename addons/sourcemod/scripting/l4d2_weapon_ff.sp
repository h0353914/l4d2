#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "1.1.0"
#define CONFIG_PATH    "configs/l4d2_weapon_ff.cfg"
#define TEAM_SURVIVOR  2

public Plugin myinfo =
{
	name        = "[L4D2] Per-Weapon Friendly Fire",
	author      = "h0353914",
	description = "Scale survivor friendly-fire damage per weapon (defaults to vanilla)",
	version     = PLUGIN_VERSION,
	url         = ""
};

StringMap g_Scales;
float     g_fDefaultScale = 1.0;
float     g_fSelfScale    = 1.0;

// 依「攻擊者 → 受害者」是真玩家還是 bot 再額外乘上的倍率
float g_fPlayerToPlayer = 1.0;
float g_fPlayerToBot    = 1.0;

ConVar g_cvEnable;
ConVar g_cvDebug;

public void OnPluginStart()
{
	CreateConVar("l4d2_weapon_ff_version", PLUGIN_VERSION, "Plugin version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvEnable = CreateConVar("l4d2_weapon_ff_enable", "1", "Enable per-weapon friendly fire scaling.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDebug  = CreateConVar("l4d2_weapon_ff_debug",  "0", "Print the weapon key of every friendly-fire hit to the server console (use it to discover keys for the config).", _, true, 0.0, true, 1.0);

	RegAdminCmd("sm_ffreload", Cmd_Reload, ADMFLAG_CONFIG, "Reload configs/l4d2_weapon_ff.cfg");
	RegAdminCmd("sm_fflist",   Cmd_List,   ADMFLAG_CONFIG, "List the current friendly-fire scales");
	RegAdminCmd("sm_ffscale",  Cmd_Scale,  ADMFLAG_CONFIG, "sm_ffscale <weapon key> <scale> - change a scale until the next reload or map change");

	g_Scales = new StringMap();
	LoadScales();

	// 支援插件中途載入(已在線的玩家也要掛鉤)
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			SDKHook(i, SDKHook_OnTakeDamage, OnTakeDamage);
	}
}

public void OnMapStart()
{
	LoadScales();
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

// ---------------------------------------------------------------------------
// 傷害掛鉤
// ---------------------------------------------------------------------------

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype,
                           int &weapon, float damageForce[3], float damagePosition[3])
{
	if (!g_cvEnable.BoolValue)
		return Plugin_Continue;

	if (!IsSurvivor(victim) || !IsSurvivor(attacker))
		return Plugin_Continue;

	char key[64];
	float scale = ResolveScale(attacker, inflictor, weapon, key, sizeof key);

	if (attacker == victim)
		scale *= g_fSelfScale;
	else
		scale *= GetPairScale(attacker, victim);

	if (g_cvDebug.BoolValue)
	{
		PrintToServer("[WeaponFF] %N -> %N | key='%s' scale=%.2f dmg=%.1f type=0x%X",
			attacker, victim, key, scale, damage, damagetype);
	}

	if (scale == 1.0)
		return Plugin_Continue; // 倍率為 1.0 = 原版行為,完全不動傷害

	damage *= scale;
	return Plugin_Changed;
}

/**
 * 判斷這次傷害對應設定檔裡的哪個 key,並回傳該倍率。
 * 查找順序:近戰腳本名稱 -> 實體 classname -> default_scale
 */
float ResolveScale(int attacker, int inflictor, int weapon, char[] key, int maxlen)
{
	int ent = -1;

	if (weapon > MaxClients && IsValidEntity(weapon))
		ent = weapon;
	else if (inflictor > MaxClients && IsValidEntity(inflictor))
		ent = inflictor; // 火焰、手榴彈、爆炸等
	else if (attacker >= 1 && attacker <= MaxClients && IsClientInGame(attacker))
		ent = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");

	if (ent <= MaxClients || !IsValidEntity(ent))
	{
		strcopy(key, maxlen, "unknown");
		return g_fDefaultScale;
	}

	char classname[64];
	GetEntityClassname(ent, classname, sizeof classname);
	StringToLower(classname);

	float scale;

	if (StrEqual(classname, "weapon_melee"))
	{
		char melee[64];
		if (HasEntProp(ent, Prop_Data, "m_strMapSetScriptName"))
		{
			GetEntPropString(ent, Prop_Data, "m_strMapSetScriptName", melee, sizeof melee);
			StringToLower(melee);
			if (melee[0] != '\0' && g_Scales.GetValue(melee, scale))
			{
				strcopy(key, maxlen, melee);
				return scale;
			}
		}
	}

	strcopy(key, maxlen, classname);
	if (g_Scales.GetValue(classname, scale))
		return scale;

	return g_fDefaultScale;
}

// ---------------------------------------------------------------------------
// 設定檔
// ---------------------------------------------------------------------------

bool LoadScales()
{
	g_Scales.Clear();
	g_fDefaultScale = 1.0;
	g_fSelfScale    = 1.0;
	g_fPlayerToPlayer = 1.0;
	g_fPlayerToBot    = 1.0;

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof path, CONFIG_PATH);

	if (!FileExists(path))
	{
		LogMessage("Config %s not found, using vanilla friendly fire.", path);
		return false;
	}

	KeyValues kv = new KeyValues("WeaponFF");
	if (!kv.ImportFromFile(path))
	{
		LogError("Failed to parse %s", path);
		delete kv;
		return false;
	}

	if (kv.JumpToKey("Options"))
	{
		g_fDefaultScale = kv.GetFloat("default_scale", 1.0);
		g_fSelfScale    = kv.GetFloat("self_scale", 1.0);
		g_fPlayerToPlayer = kv.GetFloat("player_to_player", 1.0);
		g_fPlayerToBot    = kv.GetFloat("player_to_bot", 1.0);
		kv.GoBack();
	}

	if (kv.JumpToKey("Weapons"))
	{
		if (kv.GotoFirstSubKey(false))
		{
			do
			{
				char name[64];
				kv.GetSectionName(name, sizeof name);
				StringToLower(name);
				g_Scales.SetValue(name, kv.GetFloat(NULL_STRING, 1.0));
			}
			while (kv.GotoNextKey(false));
		}
	}

	delete kv;
	return true;
}

// ---------------------------------------------------------------------------
// 指令
// ---------------------------------------------------------------------------

public Action Cmd_Reload(int client, int args)
{
	if (LoadScales())
		ReplyToCommand(client, "[WeaponFF] Config reloaded (%d weapon entries).", g_Scales.Size);
	else
		ReplyToCommand(client, "[WeaponFF] Reload failed, see the error log.");
	return Plugin_Handled;
}

public Action Cmd_List(int client, int args)
{
	ReplyToCommand(client, "[WeaponFF] default_scale=%.2f self_scale=%.2f", g_fDefaultScale, g_fSelfScale);
	ReplyToCommand(client, "[WeaponFF] player_to_player=%.2f player_to_bot=%.2f", g_fPlayerToPlayer, g_fPlayerToBot);

	StringMapSnapshot snap = g_Scales.Snapshot();
	for (int i = 0; i < snap.Length; i++)
	{
		char name[64];
		float scale;
		snap.GetKey(i, name, sizeof name);
		g_Scales.GetValue(name, scale);
		ReplyToCommand(client, "  %-32s %.2f", name, scale);
	}
	delete snap;
	return Plugin_Handled;
}

public Action Cmd_Scale(int client, int args)
{
	if (args < 2)
	{
		ReplyToCommand(client, "Usage: sm_ffscale <weapon key> <scale>   (edit the .cfg to make it permanent)");
		return Plugin_Handled;
	}

	char name[64], val[16];
	GetCmdArg(1, name, sizeof name);
	GetCmdArg(2, val, sizeof val);
	StringToLower(name);

	float scale = StringToFloat(val);
	if (scale < 0.0)
	{
		ReplyToCommand(client, "[WeaponFF] Scale must be >= 0.");
		return Plugin_Handled;
	}

	g_Scales.SetValue(name, scale);
	ReplyToCommand(client, "[WeaponFF] %s = %.2f", name, scale);
	return Plugin_Handled;
}

// ---------------------------------------------------------------------------
// 輔助函式
// ---------------------------------------------------------------------------

// 依攻擊者與受害者是真玩家還是 bot,回傳對應的額外倍率
// 攻擊者是 bot 時:原版預設就不造成友軍傷害(sb_friendlyfire 為 0),所以不另外提供倍率,維持 1.0
float GetPairScale(int attacker, int victim)
{
	if (IsFakeClient(attacker))
		return 1.0;

	return IsFakeClient(victim) ? g_fPlayerToBot : g_fPlayerToPlayer;
}

bool IsSurvivor(int client)
{
	return client >= 1 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == TEAM_SURVIVOR;
}

void StringToLower(char[] str)
{
	for (int i = 0; str[i] != '\0'; i++)
		str[i] = CharToLower(str[i]);
}
