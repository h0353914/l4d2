#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "1.0.0"
#define TEAM_SURVIVOR  2

#define WEAPON_M60     "weapon_rifle_m60"
#define WEAPON_GL      "weapon_grenade_launcher"
#define WEAPON_SAW     "weapon_chainsaw"
#define WEAPON_MEDKIT  "weapon_first_aid_kit"
#define UPGRADE_LASER  "upgrade_laser_sight" // 雷射瞄準器補給箱(不是武器,是可以按使用鍵的實體)
#define WEAPON_KATANA  "weapon_melee_katana" // 假的 classname,實際生成 weapon_melee 並指定腳本名稱 katana
#define WEAPON_CHROME  "weapon_shotgun_chrome" // 霰彈槍(單發每顆彈丸傷害最高:31)
#define WEAPON_AWP     "weapon_sniper_awp"     // 狙擊槍(單發傷害最高:115)
#define WEAPON_AMMO    "weapon_ammo_spawn"     // 補彈藥點(彈藥堆)
#define WEAPON_DEFIB   "weapon_defibrillator"  // 電擊器
#define MAG_CHROME     50 // 霰彈槍的彈夾(原版 8 發)
#define CHROME_RELOAD_MAX 8 // 霰彈槍彈夾要少於這個數才能換彈(R)
#define MAG_AWP        50 // 狙擊槍的彈夾(原版 20 發)

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
ConVar g_cvLaser;
ConVar g_cvKatana;
ConVar g_cvKatanaDelay;
ConVar g_cvChromeDelay;
ConVar g_cvAWPDelay;
int g_iFireRef[MAXPLAYERS + 1];  // 上次看到手上的霰彈槍 / 狙擊槍(偵測開火用)
int g_iFireClip[MAXPLAYERS + 1]; // 上次看到的彈夾數
int   g_iShotRef[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... }; // 上次看到主武器欄的霰彈槍 / 狙擊槍
int   g_iShotClip[MAXPLAYERS + 1];   // 上次看到的彈夾數(偵測變化)
bool  g_bShotEmpty[MAXPLAYERS + 1];  // 彈夾打空了,等換彈完成後補到設定的彈夾數
float g_flShotChanged[MAXPLAYERS + 1]; // 彈夾最後一次變化的時間

ConVar g_cvChrome;
ConVar g_cvAWP;
ConVar g_cvAmmo;
ConVar g_cvDefib;
ConVar g_cvChromeRes;
ConVar g_cvAWPRes;

ConVar g_cvKeepM60;
ConVar g_cvDebug;
ConVar g_cvAutoReload;
ConVar g_cvReloadAt;
ConVar g_cvReloadAnim;
ConVar g_cvRefill;
ConVar g_cvM60Reserve;
ConVar g_cvGLReserve;
ConVar g_cvM60Max;
ConVar g_cvGLMax;
ConVar g_cvGLMag;
ConVar g_cvM60Mag;
ConVar g_cvSawReserve;
ConVar g_cvSawMax;
ConVar g_cvShotgunMax;
ConVar g_cvSniperMax;

int  g_iRound;     // 每回合遞增,用來讓上一回合還沒跑完的計時器失效
bool g_bApplying;  // 我們自己正在改 ammo cvar 時,不要觸發「被改掉就改回來」
int  g_iLastButtons[MAXPLAYERS + 1];
float g_flReloadSince[MAXPLAYERS + 1];    // 開始替玩家按換彈鍵的時間,0 表示沒在按
float g_flReloadCooldown[MAXPLAYERS + 1]; // 換彈一直沒成功時,這個時間之前不再替玩家按
int  g_iLastReserve[MAXPLAYERS + 1] = { -1, ... }; // 除錯用:上次看到的備彈數
int  g_iMagRef[MAXPLAYERS + 1]      = { INVALID_ENT_REFERENCE, ... }; // 上次看到的主武器(榴彈發射器)
int  g_iMagPrevClip[MAXPLAYERS + 1] = { -1, ... };                    // 上次看到的榴彈發射器彈夾
public void OnPluginStart()
{
	CreateConVar("l4d2_saferoom_heavy_version", PLUGIN_VERSION, "Plugin version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvEnable = CreateConVar("l4d2_saferoom_heavy_enable", "1",    "Enable the saferoom heavy weapon drop.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDelay  = CreateConVar("l4d2_saferoom_heavy_delay",  "5.0",  "Seconds between the first living human survivor showing up and the weapons being dropped.", _, true, 1.0, true, 60.0);
	g_cvM60    = CreateConVar("l4d2_saferoom_heavy_m60",    "4","How many M60s to drop (one per randomly picked survivor).", _, true, 0.0, true, 4.0);
	g_cvGL     = CreateConVar("l4d2_saferoom_heavy_gl",     "4","How many grenade launchers to drop (one per randomly picked survivor).", _, true, 0.0, true, 4.0);

	g_cvSaw    = CreateConVar("l4d2_saferoom_heavy_chainsaw", "4","How many chainsaws to drop.", _, true, 0.0, true, 4.0);
	g_cvMedkit = CreateConVar("l4d2_saferoom_heavy_medkit",  "16","How many first aid kits to drop.", _, true, 0.0, true, 16.0);
	g_cvLaser  = CreateConVar("l4d2_saferoom_heavy_laser",    "1", "How many laser sight boxes to drop.", _, true, 0.0, true, 4.0);
	g_cvKatana = CreateConVar("l4d2_saferoom_heavy_katana",   "4", "How many katanas to drop.", _, true, 0.0, true, 8.0);
	g_cvKatanaDelay = CreateConVar("l4d2_saferoom_heavy_katana_delay", "0.35", "Seconds between two katana swings (vanilla 0.8, cannot be set slower than that).", _, true, 0.1, true, 0.8);
	g_cvChromeDelay = CreateConVar("l4d2_saferoom_heavy_chrome_delay", "0.15", "Seconds between two chrome shotgun shots (vanilla 0.5, cannot be set slower than that).", _, true, 0.1, true, 0.5);
	g_cvAWPDelay    = CreateConVar("l4d2_saferoom_heavy_awp_delay",    "0.15", "Seconds between two AWP shots (vanilla 1.05, cannot be set slower than that).", _, true, 0.1, true, 1.05);
	g_cvChrome = CreateConVar("l4d2_saferoom_heavy_chrome", "4", "How many chrome shotguns (highest damage per pellet) to drop.", _, true, 0.0, true, 8.0);
	g_cvAmmo   = CreateConVar("l4d2_saferoom_heavy_ammo", "2", "How many ammo piles (補彈藥點) to drop.", _, true, 0.0, true, 8.0);
	g_cvDefib  = CreateConVar("l4d2_saferoom_heavy_defib", "4", "How many defibrillators to drop.", _, true, 0.0, true, 8.0);
	g_cvAWP    = CreateConVar("l4d2_saferoom_heavy_awp",    "4", "How many AWP sniper rifles (highest single-shot damage) to drop.", _, true, 0.0, true, 8.0);
	g_cvChromeRes = CreateConVar("l4d2_saferoom_heavy_chrome_reserve", "40", "Reserve rounds given when picking up a dropped chrome shotgun.", _, true, 0.0, true, 999.0);
	g_cvAWPRes    = CreateConVar("l4d2_saferoom_heavy_awp_reserve",    "40", "Reserve rounds given when picking up a dropped AWP.", _, true, 0.0, true, 999.0);

	g_cvRefill     = CreateConVar("l4d2_saferoom_heavy_refill",    "1",  "1 = using an ammo pile while holding an M60 / grenade launcher refills it.", _, true, 0.0, true, 1.0);
	g_cvM60Reserve = CreateConVar("l4d2_saferoom_heavy_m60_reserve", "-1", "Reserve ammo set on a dropped / refilled M60. -1 = ammo_m60_max minus the clip size.", _, true, -1.0);
	g_cvGLReserve  = CreateConVar("l4d2_saferoom_heavy_gl_reserve",  "-1", "Reserve ammo set on a dropped / refilled grenade launcher. -1 = ammo_grenadelauncher_max minus the clip size.", _, true, -1.0);

	g_cvM60Max = CreateConVar("l4d2_saferoom_heavy_m60_max", "1200", "Force the game's ammo_m60_max to this value (-1 = do not touch it).", _, true, -1.0);
	g_cvGLMax  = CreateConVar("l4d2_saferoom_heavy_gl_max",  "120", "Force the game's ammo_grenadelauncher_max to this value (-1 = do not touch it).", _, true, -1.0);
	g_cvM60Mag = CreateConVar("l4d2_saferoom_heavy_m60_mag", "254", "M60 magazine size: rounds in the clip after a reload (150 = vanilla, 255 = the most the game can network). Counted inside ammo_m60_max.", _, true, 1.0, true, 255.0);
	g_cvGLMag  = CreateConVar("l4d2_saferoom_heavy_gl_mag",  "10",  "Grenade launcher magazine size: shots fired before it needs a reload (1 = vanilla, one shot per reload).", _, true, 1.0, true, 65.0);
	g_cvSawReserve = CreateConVar("l4d2_saferoom_heavy_chainsaw_reserve", "-1", "Reserve fuel set on a refilled chainsaw. -1 = ammo_chainsaw_max minus the clip size.", _, true, -1.0);
	g_cvSawMax     = CreateConVar("l4d2_saferoom_heavy_chainsaw_max",     "60","Force the game's ammo_chainsaw_max to this value (-1 = do not touch it).", _, true, -1.0);
	g_cvShotgunMax = CreateConVar("l4d2_saferoom_heavy_shotgun_max", "240", "Force the game's ammo_shotgun_max to this value (-1 = do not touch it).", _, true, -1.0);
	g_cvSniperMax  = CreateConVar("l4d2_saferoom_heavy_sniper_max",  "500", "Force the game's ammo_sniperrifle_max to this value (-1 = do not touch it).", _, true, -1.0);

	RegAdminCmd("sm_heavyammo_info", Cmd_Info, ADMFLAG_CONFIG, "Print the ammo cvars of the M60 / grenade launcher and the ammo of the weapon you are holding");

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("ammo_pickup", Event_AmmoPickup);

	// 武士刀 / 霰彈槍 / 狙擊槍的攻擊間隔,每 0.02 秒檢查一次(跨地圖一直跑)
	CreateTimer(0.02, Timer_FireRate, _, TIMER_REPEAT);

	g_cvReloadAnim = CreateConVar("l4d2_saferoom_heavy_m60_reload_anim", "1", "1 = press the reload key for the player so the game plays its own reload (with animation), 0 = top the clip up instantly.", _, true, 0.0, true, 1.0);
	g_cvReloadAt = CreateConVar("l4d2_saferoom_heavy_m60_reload_at", "3", "Reload the M60 from the reserve once its clip drops to this many rounds or fewer.", _, true, 0.0, true, 50.0);
	g_cvAutoReload = CreateConVar("l4d2_saferoom_heavy_m60_autoreload", "1", "1 = when the M60 clip runs dry, reload it from the reserve ammo the game would otherwise wipe.", _, true, 0.0, true, 1.0);
	g_cvDebug = CreateConVar("l4d2_saferoom_heavy_debug", "0", "1 = print every change of the M60 / grenade launcher reserve ammo to the server console.", _, true, 0.0, true, 1.0);
	g_cvKeepM60 = CreateConVar("l4d2_saferoom_heavy_keep_m60", "1", "1 = an empty M60 is no longer thrown away by the game, so it can be refilled at an ammo pile.", _, true, 0.0, true, 1.0);

	// 支援插件中途載入(已在線的玩家也要掛鉤)
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			HookClient(i);
	}

	g_cvM60Max.AddChangeHook(OnAmmoSettingChanged);
	g_cvGLMax.AddChangeHook(OnAmmoSettingChanged);
	g_cvSawMax.AddChangeHook(OnAmmoSettingChanged);
	g_cvShotgunMax.AddChangeHook(OnAmmoSettingChanged);
	g_cvSniperMax.AddChangeHook(OnAmmoSettingChanged);

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

	cv = FindConVar("ammo_shotgun_max");
	if (cv != null)
		cv.AddChangeHook(OnAmmoCvarChanged);

	cv = FindConVar("ammo_sniperrifle_max");
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
	PrecacheModel("models/w_models/weapons/w_laser_sights.mdl", true);

	// 武士刀:不是每張地圖都有載入,不預先快取的話生成出來會是看不見、撿不起來的空殼
	PrecacheModel("models/weapons/melee/v_katana.mdl", true);
	PrecacheModel("models/weapons/melee/w_katana.mdl", true);
	PrecacheGeneric("scripts/melee/katana.txt", true);

	// 霰彈槍與狙擊槍的世界模型,不是每張地圖都會載入,先預載才不會掉出來是空的
	PrecacheModel("models/w_models/weapons/w_pumpshotgun_A.mdl", true);
	PrecacheModel("models/w_models/weapons/w_sniper_awp.mdl", true);

	// 電擊器的世界模型同樣不是每張地圖都會載入
	PrecacheModel("models/w_models/weapons/w_defibrillator.mdl", true);
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
	ForceCvar("ammo_shotgun_max", g_cvShotgunMax.IntValue);
	ForceCvar("ammo_sniperrifle_max", g_cvSniperMax.IntValue);
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
	int medkit = g_cvMedkit.IntValue;
	int laser  = g_cvLaser.IntValue;
	int katana = g_cvKatana.IntValue;
	int chrome = g_cvChrome.IntValue;
	int awp    = g_cvAWP.IntValue;
	int ammo   = g_cvAmmo.IntValue;
	int defib  = g_cvDefib.IntValue;
	int total  = m60 + gl + saw + medkit + laser + katana + chrome + awp + defib + ammo;

	// 依序發 M60、榴彈發射器、電鋸、醫療包、雷射瞄準器、武士刀、霰彈槍、狙擊槍。東西比人數多時從頭再輪一遍,
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
		else if (k < m60 + gl + saw + medkit)
		{
			strcopy(classname, sizeof classname, WEAPON_MEDKIT);
			strcopy(label, sizeof label, "醫療包");
		}
		else if (k < m60 + gl + saw + medkit + laser)
		{
			strcopy(classname, sizeof classname, UPGRADE_LASER);
			strcopy(label, sizeof label, "雷射瞄準器");
		}
		else if (k < m60 + gl + saw + medkit + laser + katana)
		{
			strcopy(classname, sizeof classname, WEAPON_KATANA);
			strcopy(label, sizeof label, "武士刀");
		}
		else if (k < m60 + gl + saw + medkit + laser + katana + chrome)
		{
			strcopy(classname, sizeof classname, WEAPON_CHROME);
			strcopy(label, sizeof label, "霰彈槍");
		}
		else if (k < m60 + gl + saw + medkit + laser + katana + chrome + awp)
		{
			strcopy(classname, sizeof classname, WEAPON_AWP);
			strcopy(label, sizeof label, "狙擊槍");
		}
		else if (k < m60 + gl + saw + medkit + laser + katana + chrome + awp + defib)
		{
			strcopy(classname, sizeof classname, WEAPON_DEFIB);
			strcopy(label, sizeof label, "電擊器");
		}
		else
		{
			strcopy(classname, sizeof classname, WEAPON_AMMO);
			strcopy(label, sizeof label, "補彈藥點");
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
	bool katana = StrEqual(classname, WEAPON_KATANA);

	int ent = CreateEntityByName(katana ? "weapon_melee" : classname);
	if (ent == -1)
		return false;

	// 近戰武器要在生成前指定是哪一把
	if (katana)
		DispatchKeyValue(ent, "melee_script_name", "katana");

	float pos[3];
	GetClientAbsOrigin(client, pos);
	pos[2] += 10.0; // 稍微抬高,避免卡進地板

	TeleportEntity(ent, pos, NULL_VECTOR, NULL_VECTOR);
	DispatchSpawn(ent);

	// 武器本身帶的備用彈藥(撿起來時會給玩家)
	int reserve = GetReserveTarget(classname);
	if (reserve >= 0 && HasEntProp(ent, Prop_Send, "m_iExtraPrimaryAmmo"))
		SetEntProp(ent, Prop_Send, "m_iExtraPrimaryAmmo", reserve);

	// 霰彈槍 / 狙擊槍:撿起來時給的備用彈藥
	if (StrEqual(classname, WEAPON_CHROME) && HasEntProp(ent, Prop_Send, "m_iExtraPrimaryAmmo"))
		SetEntProp(ent, Prop_Send, "m_iExtraPrimaryAmmo", g_cvChromeRes.IntValue);
	else if (StrEqual(classname, WEAPON_AWP) && HasEntProp(ent, Prop_Send, "m_iExtraPrimaryAmmo"))
		SetEntProp(ent, Prop_Send, "m_iExtraPrimaryAmmo", g_cvAWPRes.IntValue);

	int mag = GetShotMag(classname);
	if (mag > 0)
		SetEntProp(ent, Prop_Send, "m_iClip1", mag);

	return true;
}

// ---------------------------------------------------------------------------
// 補彈
// ---------------------------------------------------------------------------

// 有些武器(例如電鋸)拿在手上用彈藥堆時,遊戲不會發出 ammo_pickup 事件,
// 所以另外偵測:按下使用鍵、準心對著附近的彈藥堆,就當作補彈
// 追蹤主武器欄 M60 / 榴彈發射器的備彈:
// 1. M60 的彈夾一打到 0,遊戲會連備彈一起清成 0(它原本「打完就丟」的邏輯),備彈永遠用不到。
//    偵測到這個瞬間,就用被清掉前的備彈自動補一個彈夾,等於幫它換彈
// 2. 除錯開啟時,備彈一有變動就印出來
void TrackAmmo(int client, int &buttons)
{
	int weapon = GetPlayerWeaponSlot(client, 0);
	if (weapon <= MaxClients || !IsValidEntity(weapon))
	{
		g_iLastReserve[client] = -1;
		g_iMagRef[client]       = INVALID_ENT_REFERENCE;
		g_iMagPrevClip[client]  = -1;
		return;
	}

	char classname[64];
	GetEntityClassname(weapon, classname, sizeof classname);
	if (GetClipSize(classname) == 0)
	{
		g_iLastReserve[client] = -1;
		g_iMagRef[client]       = INVALID_ENT_REFERENCE;
		g_iMagPrevClip[client]  = -1;
		return;
	}

	int type = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
	if (type < 0)
		return;

	int clip    = GetEntProp(weapon, Prop_Send, "m_iClip1");
	int reserve = GetEntProp(client, Prop_Send, "m_iAmmo", _, type);

	bool isM60 = StrEqual(classname, WEAPON_M60);

	// 子彈快用完(剩 reload_at 發以下)但還有備彈時,就先把彈夾補滿,
	// 這樣彈夾永遠不會真的歸 0,遊戲也就沒機會清掉備彈或丟掉武器
	if (g_cvAutoReload.BoolValue && isM60 && clip <= g_cvReloadAt.IntValue && reserve > 0)
	{
		bool holding = (GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") == weapon);

		if (holding && g_cvReloadAnim.BoolValue)
		{
			// 替玩家按下換彈鍵,讓遊戲自己換彈(有換彈動畫)。
			// 遊戲在開火鍵按住且彈夾還有子彈時會優先開火、不處理換彈,所以要同時鬆開開火鍵
			float now      = GetGameTime();
			bool  inReload = HasEntProp(weapon, Prop_Send, "m_bInReload") && GetEntProp(weapon, Prop_Send, "m_bInReload") != 0;

			if (inReload)
			{
				g_flReloadSince[client] = 0.0;
			}
			else if (now >= g_flReloadCooldown[client])
			{
				buttons &= ~IN_ATTACK;
				buttons |= IN_RELOAD;

				if (g_flReloadSince[client] == 0.0)
				{
					g_flReloadSince[client] = now;
				}
				else if (now - g_flReloadSince[client] > 0.5)
				{
					// 半秒了遊戲還是沒開始換彈,先放棄,隔 3 秒再試,免得一直吃掉玩家的開火鍵
					g_flReloadCooldown[client] = now + 3.0;
					g_flReloadSince[client]    = 0.0;
				}
			}
		}
		else
		{
			// 沒拿在手上,或關掉動畫模式:直接補彈,沒有動畫
			int give = (GetMagSize(classname) - clip < reserve) ? (GetMagSize(classname) - clip) : reserve;
			clip    += give;
			reserve -= give;
			SetEntProp(weapon, Prop_Send, "m_iClip1", clip);
			SetEntProp(client, Prop_Send, "m_iAmmo", reserve, _, type);
		}
	}

	// 保險:如果還是來不及,彈夾已經歸 0 且備彈剛被清掉,就用清掉前的備彈補回
	if (g_cvAutoReload.BoolValue && isM60 && clip <= 0 && reserve == 0 && g_iLastReserve[client] > 0)
	{
		int give = (g_iLastReserve[client] < GetMagSize(classname)) ? g_iLastReserve[client] : GetMagSize(classname);
		reserve  = g_iLastReserve[client] - give;
		clip     = give;
		SetEntProp(weapon, Prop_Send, "m_iClip1", clip);
		SetEntProp(client, Prop_Send, "m_iAmmo", reserve, _, type);
	}

	// M60 / 榴彈發射器的彈夾比遊戲原本的容量大(M60 預設 254、榴彈發射器預設 10)。
	// 遊戲換彈只會補到原本的容量,所以把「換彈完成」的瞬間(彈夾剛補到原容量,或剛拿到這把槍)
	// 視為換彈,再從備彈補到我們設定的彈夾容量
	int base = GetClipSize(classname);
	int mag  = GetMagSize(classname);
	if (mag > base)
	{
		int  ref      = EntIndexToEntRef(weapon);
		bool newGun   = (ref != g_iMagRef[client]);
		bool reloaded = (g_iMagPrevClip[client] >= 0 && g_iMagPrevClip[client] < base && clip == base);

		if ((newGun || reloaded) && clip == base && reserve > 0)
		{
			int give = mag - base;
			if (give > reserve)
				give = reserve;

			clip    += give;
			reserve -= give;
			SetEntProp(weapon, Prop_Send, "m_iClip1", clip);
			SetEntProp(client, Prop_Send, "m_iAmmo", reserve, _, type);
		}

		g_iMagRef[client]      = ref;
		g_iMagPrevClip[client] = clip;
	}
	else
	{
		g_iMagRef[client]      = INVALID_ENT_REFERENCE;
		g_iMagPrevClip[client] = -1;
	}

	if (reserve != g_iLastReserve[client])
	{
		if (g_cvDebug.BoolValue)
			PrintToServer("[HeavyAmmo] %N %s reserve %d -> %d (clip=%d)", client, classname, g_iLastReserve[client], reserve, clip);
		g_iLastReserve[client] = reserve;
	}
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	if (!IsFakeClient(client) && IsPlayerAlive(client))
	{
		TrackAmmo(client, buttons);
		TrackShotMag(client);

		// 霰彈槍:彈夾 8 發以上按 R 時,遊戲原本不會換彈,所以先把彈夾多出來的子彈還給備彈,只留 7 發,
		// 讓遊戲以為是「少於 8 發」而正常播放換彈動畫(遊戲會補到原版 8 發,之後由 TrackShotMag 補到 MAG_CHROME)
		int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		if ((buttons & IN_RELOAD) && active > MaxClients && IsValidEntity(active))
		{
			char cls[32];
			GetEntityClassname(active, cls, sizeof cls);
			int type = GetEntProp(active, Prop_Send, "m_iPrimaryAmmoType");
			int clip = GetEntProp(active, Prop_Send, "m_iClip1");
			if (StrEqual(cls, WEAPON_CHROME) && clip >= CHROME_RELOAD_MAX && type >= 0)
			{
				int reserve = GetEntProp(client, Prop_Send, "m_iAmmo", _, type);
				if (reserve > 0)
				{
					SetEntProp(client, Prop_Send, "m_iAmmo", reserve + clip - 7, _, type);
					SetEntProp(active, Prop_Send, "m_iClip1", 7);
					g_bShotEmpty[client] = true; // 換彈完成後要補到設定值(TrackShotMag 會處理)
				}
			}
		}
	}

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

	// 不只看手上拿的,而是把主武器欄(0)和副武器欄(1)都檢查一遍:
	// 榴彈發射器打空後遊戲不讓你切換過去,但它還在背包裡,所以不用切過去也能補彈
	for (int slot = 0; slot <= 1; slot++)
	{
		int weapon = GetPlayerWeaponSlot(client, slot);
		if (weapon <= MaxClients || !IsValidEntity(weapon))
			continue;

		char classname[64];
		GetEntityClassname(weapon, classname, sizeof classname);

		int clip = GetClipSize(classname);
		if (clip == 0)
			continue; // 不是 M60 / 榴彈發射器 / 電鋸

		int reserve = GetReserveTarget(classname);

		// M60 / 榴彈發射器補彈後直接給滿設定的彈夾容量,總彈量(彈夾 + 備彈)不變
		int mag = GetMagSize(classname);
		if (reserve >= 0 && mag > clip)
		{
			int total = reserve + clip;
			clip      = (mag < total) ? mag : total;
			reserve   = total - clip;
		}

		SetEntProp(weapon, Prop_Send, "m_iClip1", clip);

		if (reserve >= 0)
			SetEntProp(client, Prop_Send, "m_iAmmo", reserve, _, GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType"));
	}

	return Plugin_Stop;
}

// ---------------------------------------------------------------------------
// 防止 M60 打空後被遊戲自動丟掉
// ---------------------------------------------------------------------------

public void OnClientPutInServer(int client)
{
	HookClient(client);
}

void HookClient(int client)
{
	SDKHook(client, SDKHook_WeaponDrop, OnWeaponDrop);
	SDKHook(client, SDKHook_WeaponCanSwitchTo, OnWeaponSwitchCheck);
	SDKHook(client, SDKHook_WeaponSwitch, OnWeaponSwitchCheck);
}

// 切換到彈夾為 0 的 M60 時,遊戲會直接把它丟掉,所以乾脆不讓你切過去
// (跟打空的榴彈發射器一樣,留在背包裡,靠彈藥堆補彈)
public Action OnWeaponSwitchCheck(int client, int weapon)
{
	if (!g_cvKeepM60.BoolValue || weapon <= MaxClients || !IsValidEntity(weapon))
		return Plugin_Continue;

	char classname[64];
	GetEntityClassname(weapon, classname, sizeof classname);
	if (!StrEqual(classname, WEAPON_M60))
		return Plugin_Continue;

	return (GetEntProp(weapon, Prop_Send, "m_iClip1") <= 0) ? Plugin_Handled : Plugin_Continue;
}

public Action OnWeaponDrop(int client, int weapon)
{
	if (!g_cvKeepM60.BoolValue || weapon <= MaxClients || !IsValidEntity(weapon))
		return Plugin_Continue;

	char classname[64];
	GetEntityClassname(weapon, classname, sizeof classname);
	if (!StrEqual(classname, WEAPON_M60))
		return Plugin_Continue;

	// 只擋「打空後被丟掉」,彈夾還有子彈時照舊
	if (GetEntProp(weapon, Prop_Send, "m_iClip1") > 0)
		return Plugin_Continue;

	return Plugin_Handled;
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

// 這把武器我們設定的彈夾容量(比遊戲原本大時,換彈後會再補滿到這個數),沒設定就等於原本容量
int GetMagSize(const char[] classname)
{
	if (StrEqual(classname, WEAPON_M60))
		return (g_cvM60Mag.IntValue > CLIP_M60) ? g_cvM60Mag.IntValue : CLIP_M60;
	if (StrEqual(classname, WEAPON_GL))
		return (g_cvGLMag.IntValue > CLIP_GL) ? g_cvGLMag.IntValue : CLIP_GL;
	return GetClipSize(classname);
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
// 近戰 / 霰彈槍 / 狙擊槍攻擊間隔
// ---------------------------------------------------------------------------

// 遊戲每次攻擊後都會把下一次可以攻擊的時間設成原版的間隔(武士刀 0.8 秒),
// 所以每 0.02 秒檢查一次,手上是武士刀且剩餘等待時間超過設定值的,就拉回到設定值
// 霰彈槍 / 狙擊槍換彈時,遊戲會把換彈的等待時間設成原版長度,這裡把它縮短成 1/l4d2_saferoom_heavy_shot_reload_speed
public Action Timer_FireRate(Handle timer)
{
	float now   = GetGameTime();
	float delay = g_cvKatanaDelay.FloatValue;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i))
			continue;

		int weapon = GetEntPropEnt(i, Prop_Send, "m_hActiveWeapon");
		if (weapon <= MaxClients || !IsValidEntity(weapon))
			continue;

		if (IsKatana(weapon))
		{
			float next = GetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack");
			if (next - now > delay)
				SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", now + delay);
		}
		else if (IsShotgunOrSniper(weapon))
		{
			// 彈夾變少才代表真的開了一槍,這時把下一次攻擊的等待時間縮短成設定值
			int ref  = EntIndexToEntRef(weapon);
			int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
			bool shot = (ref == g_iFireRef[i] && clip < g_iFireClip[i]);
			g_iFireRef[i]  = ref;
			g_iFireClip[i] = clip;

			if (shot)
			{
				float fire = GetShotDelay(weapon);
				float next = GetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack");
				if (next - now > fire)
					SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", now + fire);
			}
		}
	}

	return Plugin_Continue;
}

bool IsShotgunOrSniper(int weapon)
{
	char classname[32];
	GetEntityClassname(weapon, classname, sizeof classname);
	return StrEqual(classname, WEAPON_CHROME) || StrEqual(classname, WEAPON_AWP);
}

// 霰彈槍 / 狙擊槍的彈夾固定為 MAG_CHROME / MAG_AWP 發
// 規則:彈夾打空後,等遊戲的換彈完成(彈夾穩定不變一小段時間)再補到設定值;拿到槍時也補一次
void TrackShotMag(int client)
{
	int weapon = GetPlayerWeaponSlot(client, 0);
	if (weapon <= MaxClients || !IsValidEntity(weapon))
	{
		g_iShotRef[client] = INVALID_ENT_REFERENCE;
		return;
	}

	char classname[32];
	GetEntityClassname(weapon, classname, sizeof classname);
	int mag = GetShotMag(classname);
	if (mag == 0)
	{
		g_iShotRef[client] = INVALID_ENT_REFERENCE;
		return;
	}

	int type = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
	if (type < 0)
		return;

	float now = GetGameTime();
	int   clip = GetEntProp(weapon, Prop_Send, "m_iClip1");

	// 剛拿到這把槍:補到設定值
	int ref = EntIndexToEntRef(weapon);
	if (ref != g_iShotRef[client])
	{
		g_iShotRef[client]      = ref;
		g_iShotClip[client]     = clip;
		g_bShotEmpty[client]    = false;
		g_flShotChanged[client] = now;
		FillShot(client, weapon, type, mag);
		return;
	}

	if (clip != g_iShotClip[client])
	{
		g_iShotClip[client]     = clip;
		g_flShotChanged[client] = now;
	}

	if (clip <= 0)
		g_bShotEmpty[client] = true;

	if (g_bShotEmpty[client] && clip > 0 && now - g_flShotChanged[client] >= 0.3)
	{
		g_bShotEmpty[client] = false;
		FillShot(client, weapon, type, mag);
	}
}

// 從備彈補到彈夾的設定值
void FillShot(int client, int weapon, int type, int mag)
{
	int clip    = GetEntProp(weapon, Prop_Send, "m_iClip1");
	int reserve = GetEntProp(client, Prop_Send, "m_iAmmo", _, type);

	int give = mag - clip;
	if (give > reserve)
		give = reserve;
	if (give <= 0)
		return;

	SetEntProp(weapon, Prop_Send, "m_iClip1", clip + give);
	SetEntProp(client, Prop_Send, "m_iAmmo", reserve - give, _, type);
}

// 這把武器的彈夾設定值,不是霰彈槍 / 狙擊槍回傳 0
int GetShotMag(const char[] classname)
{
	if (StrEqual(classname, WEAPON_CHROME))
		return MAG_CHROME;
	if (StrEqual(classname, WEAPON_AWP))
		return MAG_AWP;
	return 0;
}

float GetShotDelay(int weapon)
{
	char classname[32];
	GetEntityClassname(weapon, classname, sizeof classname);
	return StrEqual(classname, WEAPON_CHROME) ? g_cvChromeDelay.FloatValue : g_cvAWPDelay.FloatValue;
}

bool IsKatana(int weapon)
{
	char classname[32];
	GetEntityClassname(weapon, classname, sizeof classname);
	if (!StrEqual(classname, "weapon_melee") || !HasEntProp(weapon, Prop_Data, "m_strMapSetScriptName"))
		return false;

	char script[32];
	GetEntPropString(weapon, Prop_Data, "m_strMapSetScriptName", script, sizeof script);
	return StrEqual(script, "katana", false);
}

// ---------------------------------------------------------------------------
// 查詢原始彈藥數
// ---------------------------------------------------------------------------

public Action Cmd_Info(int client, int args)
{
	static const char names[][] = { "ammo_m60_max", "ammo_grenadelauncher_max", "ammo_chainsaw_max", "ammo_shotgun_max", "ammo_sniperrifle_max" };

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
