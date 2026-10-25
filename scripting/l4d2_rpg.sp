/**
 * ============================================================================
 *  L4D2 RPG 系统  v3.0.0   (SourceMod 1.11+ / Left 4 Dead 2)
 * ============================================================================
 *
 *  功能:
 *    1. 账号系统   玩家自定义 ID(账号) + 密码 注册 / 登录, 密码加盐 SHA-256 存储
 *    2. 经验升级   击杀普通感染者 / 特感 / Tank / Witch, 治疗队友, 救人 获得经验
 *    3. 金钱系统   击杀 / 治疗 / 升级 奖励金钱, 商店消费
 *    4. 物资商店   !shop 兑换 医疗包 / 药品 / 投掷物 / 武器 / 弹药 / 属性点
 *    5. 属性点     升级获得属性点, !stats 分配 敏捷 / 力量 / 耐力 / 防御
 *    6. 数据存档   SQLite(默认) 或 MySQL, 断线 / 换图 / 定时自动保存
 *    7. 排行榜     !top 查看等级排行
 *
 *  玩家命令:
 *    !register  注册账号          !login    登录          !logout  退出登录
 *    !passwd    修改密码          !rpg      查看信息      !stats   属性分配
 *    !shop      物资商店          !top      等级排行      !help    帮助
 *
 *  管理员命令 (ROOT):
 *    sm_rpg_givexp     <玩家> <数量>     加经验
 *    sm_rpg_givemoney  <玩家> <数量>     加金钱
 *    sm_rpg_givepoints <玩家> <数量>     加属性点
 *    sm_rpg_reset      <玩家>            重置该玩家数据
 *    sm_rpg_setpass    <玩家> <新密码>   重置密码
 *    sm_rpg_unbind     <玩家>            解绑 SteamID (允许账号在其它机器登录)
 *
 *  存储:
 *    默认使用 SQLite: addons/sourcemod/data/l4d2_rpg.sqlite
 *    若 configs/databases.cfg 中存在名为 "l4d2_rpg" 的条目, 则自动改用 MySQL。
 *
 *  依赖: SourceMod 1.11+ (仅支持 Left 4 Dead 2)
 * ============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "3.0.0"
#define CHAT_PREFIX    " \x04[RPG]\x01 "

#define MAX_ACCOUNT_LEN    16
#define MIN_ACCOUNT_LEN    3
#define MAX_PASSWORD_LEN   32
#define MIN_PASSWORD_LEN   4
#define SALT_LEN           16
#define HASH_LEN           64

#define STAT_COUNT 4
#define STAT_AGI   0
#define STAT_STR   1
#define STAT_STA   2
#define STAT_DEF   3

#define KILL_COMMON  0
#define KILL_SPECIAL 1
#define KILL_TANK    2
#define KILL_WITCH   3
#define KILL_COUNT   4

// 账号状态
#define AUTH_NONE          0
#define AUTH_LOADING       1
#define AUTH_NEED_REGISTER 2
#define AUTH_NEED_LOGIN    3
#define AUTH_LOGGED_IN     4

// 聊天输入捕获状态
#define INPUT_NONE           0
#define INPUT_REG_ACCOUNT    1
#define INPUT_REG_PASSWORD   2
#define INPUT_LOGIN_BOTH     3
#define INPUT_LOGIN_PASSWORD 4
#define INPUT_PASS_OLD       5
#define INPUT_PASS_NEW       6

// 商店发放方式
#define SHOP_GIVE_ENTITY 0
#define SHOP_GIVE_COMMAND 1
#define SHOP_HEAL        2
#define SHOP_STATPOINT   3

// 商店分类
#define SHOP_CAT_CONSUMABLE 0
#define SHOP_CAT_WEAPON     1
#define SHOP_CAT_SUPPLY     2

// 物品发放结果
#define GIVE_FAILED  0
#define GIVE_DIRECT  1
#define GIVE_CHEATED 2

#define SQL_PLAYER_COLUMNS "account, salt, passhash, level, xp, total_xp, money, points, stat_agi, stat_str, stat_sta, stat_def, kill_common, kill_special, kill_tank, kill_witch, heals, deaths, playtime, last_seen, steamid, hash_rounds"

enum
{
	COL_ACCOUNT = 0,
	COL_SALT,
	COL_PASSHASH,
	COL_LEVEL,
	COL_XP,
	COL_TOTALXP,
	COL_MONEY,
	COL_POINTS,
	COL_STAT_AGI,
	COL_STAT_STR,
	COL_STAT_STA,
	COL_STAT_DEF,
	COL_KILL_COMMON,
	COL_KILL_SPECIAL,
	COL_KILL_TANK,
	COL_KILL_WITCH,
	COL_HEALS,
	COL_DEATHS,
	COL_PLAYTIME,
	COL_LAST_SEEN,
	COL_STEAMID,
	COL_HASH_ROUNDS,
	COL_COUNT
};

// ==================== 商店定义 ====================
enum struct ShopItem
{
	char key[16];
	char name[48];
	char give[40];
	int  price;
	int  category;
	int  kind;
}

ShopItem g_Shop[] =
{
	{ "medkit",   "急救包",        "weapon_first_aid_kit",       1500, SHOP_CAT_CONSUMABLE, SHOP_GIVE_ENTITY  },
	{ "pills",    "止痛药",        "weapon_pain_pills",           800, SHOP_CAT_CONSUMABLE, SHOP_GIVE_ENTITY  },
	{ "adren",    "肾上腺素",      "weapon_adrenaline",          1000, SHOP_CAT_CONSUMABLE, SHOP_GIVE_ENTITY  },
	{ "molotov",  "燃烧瓶",        "weapon_molotov",             1200, SHOP_CAT_CONSUMABLE, SHOP_GIVE_ENTITY  },
	{ "pipebomb", "土制炸弹",      "weapon_pipe_bomb",           1200, SHOP_CAT_CONSUMABLE, SHOP_GIVE_ENTITY  },
	{ "vomitjar", "胆汁瓶",        "weapon_vomitjar",            1200, SHOP_CAT_CONSUMABLE, SHOP_GIVE_ENTITY  },
	{ "defib",    "除颤器",        "weapon_defibrillator",       2500, SHOP_CAT_CONSUMABLE, SHOP_GIVE_ENTITY  },
	{ "smg",      "消音冲锋枪",    "weapon_smg_silenced",        3000, SHOP_CAT_WEAPON,     SHOP_GIVE_ENTITY  },
	{ "pump",     "木制霰弹枪",    "weapon_pumpshotgun",         3200, SHOP_CAT_WEAPON,     SHOP_GIVE_ENTITY  },
	{ "chrome",   "Chrome霰弹枪",  "weapon_shotgun_chrome",      3500, SHOP_CAT_WEAPON,     SHOP_GIVE_ENTITY  },
	{ "hunting",  "猎枪",          "weapon_hunting_rifle",       3000, SHOP_CAT_WEAPON,     SHOP_GIVE_ENTITY  },
	{ "ak47",     "AK-47 步枪",    "weapon_rifle_ak47",          5000, SHOP_CAT_WEAPON,     SHOP_GIVE_ENTITY  },
	{ "m4",       "M4 步枪",       "weapon_rifle",               5000, SHOP_CAT_WEAPON,     SHOP_GIVE_ENTITY  },
	{ "scar",     "战斗步枪",      "weapon_rifle_desert",        5200, SHOP_CAT_WEAPON,     SHOP_GIVE_ENTITY  },
	{ "spas",     "战术霰弹枪",    "weapon_shotgun_spas",        5500, SHOP_CAT_WEAPON,     SHOP_GIVE_ENTITY  },
	{ "sniper",   "军用狙击枪",    "weapon_sniper_military",     6000, SHOP_CAT_WEAPON,     SHOP_GIVE_ENTITY  },
	{ "awp",      "AWP 狙击枪",    "weapon_sniper_awp",          7000, SHOP_CAT_WEAPON,     SHOP_GIVE_ENTITY  },
	{ "m60",      "M60 机枪",      "weapon_rifle_m60",           8000, SHOP_CAT_WEAPON,     SHOP_GIVE_ENTITY  },
	{ "grenade",  "榴弹发射器",    "weapon_grenade_launcher",    9000, SHOP_CAT_WEAPON,     SHOP_GIVE_ENTITY  },
	{ "ammo",     "补满弹药",      "ammo",                        500, SHOP_CAT_SUPPLY,     SHOP_GIVE_COMMAND },
	{ "heal",     "回满生命",      "",                            800, SHOP_CAT_SUPPLY,     SHOP_HEAL         },
	{ "statpoint","购买属性点",    "",                           1000, SHOP_CAT_SUPPLY,     SHOP_STATPOINT    }
};

char g_sStatNames[STAT_COUNT][] = { "敏捷", "力量", "耐力", "防御" };
char g_sStatDescs[STAT_COUNT][] = { "移速", "伤害", "生命", "减伤" };
char g_sShopCatNames[][] = { "消耗品", "武器", "补给" };

// ==================== 玩家数据 ====================
int  g_iAuth[MAXPLAYERS + 1];
int  g_iInput[MAXPLAYERS + 1];
char g_sSteamID[MAXPLAYERS + 1][32];
char g_sAccount[MAXPLAYERS + 1][MAX_ACCOUNT_LEN + 1];
char g_sSalt[MAXPLAYERS + 1][SALT_LEN + 1];
char g_sPassHash[MAXPLAYERS + 1][HASH_LEN + 1];
char g_sPendingAccount[MAXPLAYERS + 1][MAX_ACCOUNT_LEN + 1];
char g_sPendingPassword[MAXPLAYERS + 1][MAX_PASSWORD_LEN + 1];

int  g_iLevel[MAXPLAYERS + 1];
int  g_iXP[MAXPLAYERS + 1];
int  g_iTotalXP[MAXPLAYERS + 1];
int  g_iMoney[MAXPLAYERS + 1];
int  g_iPoints[MAXPLAYERS + 1];
int  g_iStats[MAXPLAYERS + 1][STAT_COUNT];
int  g_iKills[MAXPLAYERS + 1][KILL_COUNT];
int  g_iHeals[MAXPLAYERS + 1];
int  g_iDeaths[MAXPLAYERS + 1];
int  g_iPlaytime[MAXPLAYERS + 1];
int  g_iSessionStart[MAXPLAYERS + 1];
int  g_iConnectTime[MAXPLAYERS + 1];
bool g_bDirty[MAXPLAYERS + 1];
int  g_iLastSeen[MAXPLAYERS + 1];
int  g_iLoadStart[MAXPLAYERS + 1];
int  g_iNextLoadTry[MAXPLAYERS + 1];  // AUTH_NONE 状态下下次重试账号读取的时间
int  g_iHashRounds[MAXPLAYERS + 1];   // 该账号存下来的哈希迭代次数(0=尚未读到)
// 应用 RPG 加成之前玩家身上原本的移速/最大生命。登出时还原到这两个基准值,
// 而不是硬写 1.0/100 —— 否则会覆盖其它插件设置的数值。
float g_fBaseSpeed[MAXPLAYERS + 1];
int   g_iBaseMaxHealth[MAXPLAYERS + 1];
bool  g_bBaseCaptured[MAXPLAYERS + 1];
bool g_bStatsApplied[MAXPLAYERS + 1];
bool g_bNoDBWarned[MAXPLAYERS + 1];
bool g_bLoginPending[MAXPLAYERS + 1]; // 登录查询在途, 防止并发登录互相踩对方的密码缓冲

// 失败次数/锁定时间按 SteamID 记录 —— 按 client 槽位记录时, 玩家断线重连就能清零,
// 等于给暴力破解开了后门。
StringMap g_hFailCount;
StringMap g_hLockUntil;
StringMap g_hRegisterAt;   // "reg:<steamid>" -> 上次注册尝试时间 (注册限速)

// ==================== 数据库 ====================
Database g_hDB;
bool     g_bDBReady;
bool     g_bSQLite;
// 最近一次数据库操作是否失败过。用来决定玩家断线时要不要走同步保存 ——
// 数据库健康时同步保存是毫秒级的, 能保证"最后一份存档"确实落库;
// 一旦发现数据库出问题就退回异步, 避免主线程被连接超时卡死。
bool     g_bDBAttemptFailed;
StringMap g_hSessions;     // SteamID -> 上次登录时间 (自动登录用)
StringMap g_hAccountOwner; // 账号 -> 当前在线 client (单点登录用)

// ==================== 配置 ====================
ConVar g_cvXpCommon, g_cvXpSpecial, g_cvXpTank, g_cvXpWitch, g_cvXpHeal, g_cvXpRevive;
ConVar g_cvMoneyCommon, g_cvMoneySpecial, g_cvMoneyTank, g_cvMoneyWitch, g_cvMoneyHeal, g_cvMoneyRevive;
ConVar g_cvMoneyLevelup, g_cvStartMoney;
ConVar g_cvXpBase, g_cvXpStep, g_cvMaxLevel;
ConVar g_cvPointsPerLevel, g_cvSpeedPerAgi, g_cvDmgPerStr, g_cvHpPerSta, g_cvDefPerPoint, g_cvDefMax, g_cvStatMax;
ConVar g_cvSessionMinutes, g_cvMaxAttempts, g_cvLockSeconds, g_cvSingleSession, g_cvBindSteamID;
ConVar g_cvHashRounds, g_cvLoginTimeout, g_cvRemindInterval, g_cvRegisterCooldown, g_cvDBRetrySeconds;
ConVar g_cvHudEnabled, g_cvHudInterval, g_cvAllowCheatCmd;
ConVar g_cvCheats;

// 临时给客户端命令去掉 FCVAR_CHEAT 时, 用来延后还原的现场
char g_sCheatCmd[64];
int  g_iCheatFlags;
bool g_bCheatPending;
bool g_bCheatWasCheats;   // 提权之前 sv_cheats 的原始值, 还原时用

// ==================== 插件信息 ====================
public Plugin myinfo =
{
	name        = "L4D2 RPG System",
	author      = "RPG Dev",
	description = "账号登录 / 经验升级 / 属性点 / 金钱 / 物资商店 / 数据存档",
	version     = PLUGIN_VERSION,
	url         = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "本插件仅支持 Left 4 Dead 2");
		return APLRes_SilentFailure;
	}
	return APLRes_Success;
}

// ==================== 插件初始化 ====================
public void OnPluginStart()
{
	CreateConVar("l4d2_rpg_version", PLUGIN_VERSION, "L4D2 RPG 版本",
		FCVAR_SPONLY | FCVAR_NOTIFY | FCVAR_DONTRECORD);

	g_cvXpCommon  = CreateConVar("l4d2_rpg_xp_common",  "5",   "击杀普通感染者经验", FCVAR_NONE, true, 0.0);
	g_cvXpSpecial = CreateConVar("l4d2_rpg_xp_special", "50",  "击杀特感经验",       FCVAR_NONE, true, 0.0);
	g_cvXpTank    = CreateConVar("l4d2_rpg_xp_tank",    "300", "击杀 Tank 经验",     FCVAR_NONE, true, 0.0);
	g_cvXpWitch   = CreateConVar("l4d2_rpg_xp_witch",   "200", "击杀 Witch 经验",    FCVAR_NONE, true, 0.0);
	g_cvXpHeal    = CreateConVar("l4d2_rpg_xp_heal",    "30",  "治疗队友经验",       FCVAR_NONE, true, 0.0);
	g_cvXpRevive  = CreateConVar("l4d2_rpg_xp_revive",  "40",  "救起倒地队友经验",   FCVAR_NONE, true, 0.0);

	g_cvMoneyCommon  = CreateConVar("l4d2_rpg_money_common",  "15",  "击杀普通感染者金钱", FCVAR_NONE, true, 0.0);
	g_cvMoneySpecial = CreateConVar("l4d2_rpg_money_special", "80",  "击杀特感金钱",       FCVAR_NONE, true, 0.0);
	g_cvMoneyTank    = CreateConVar("l4d2_rpg_money_tank",    "300", "击杀 Tank 金钱",     FCVAR_NONE, true, 0.0);
	g_cvMoneyWitch   = CreateConVar("l4d2_rpg_money_witch",   "200", "击杀 Witch 金钱",    FCVAR_NONE, true, 0.0);
	g_cvMoneyHeal    = CreateConVar("l4d2_rpg_money_heal",    "50",  "治疗队友金钱",       FCVAR_NONE, true, 0.0);
	g_cvMoneyRevive  = CreateConVar("l4d2_rpg_money_revive",  "60",  "救起倒地队友金钱",   FCVAR_NONE, true, 0.0);
	g_cvMoneyLevelup = CreateConVar("l4d2_rpg_money_levelup", "500", "每次升级奖励金钱",   FCVAR_NONE, true, 0.0);
	g_cvStartMoney   = CreateConVar("l4d2_rpg_start_money",   "500", "新账号初始金钱",     FCVAR_NONE, true, 0.0);

	g_cvXpBase  = CreateConVar("l4d2_rpg_xp_base",  "100", "升级所需经验基础值 (1级)", FCVAR_NONE, true, 1.0);
	g_cvXpStep  = CreateConVar("l4d2_rpg_xp_step",  "50",  "每级递增的升级经验",       FCVAR_NONE, true, 0.0);
	g_cvMaxLevel = CreateConVar("l4d2_rpg_max_level", "100", "最高等级", FCVAR_NONE, true, 1.0, true, 1000.0);

	g_cvPointsPerLevel = CreateConVar("l4d2_rpg_points_per_level", "1",     "每次升级获得属性点", FCVAR_NONE, true, 0.0);
	g_cvSpeedPerAgi    = CreateConVar("l4d2_rpg_speed_per_agi",    "0.015", "每点敏捷移速加成",   FCVAR_NONE, true, 0.0);
	g_cvDmgPerStr      = CreateConVar("l4d2_rpg_dmg_per_str",      "0.03",  "每点力量伤害加成",   FCVAR_NONE, true, 0.0);
	g_cvHpPerSta       = CreateConVar("l4d2_rpg_hp_per_sta",       "3",     "每点耐力生命加成",   FCVAR_NONE, true, 0.0);
	g_cvDefPerPoint    = CreateConVar("l4d2_rpg_def_per_point",    "0.02",  "每点防御减伤",       FCVAR_NONE, true, 0.0);
	g_cvDefMax         = CreateConVar("l4d2_rpg_def_max",          "0.60",  "减伤上限",           FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvStatMax        = CreateConVar("l4d2_rpg_stat_max",         "50",    "单项属性上限",       FCVAR_NONE, true, 1.0);

	g_cvSessionMinutes  = CreateConVar("l4d2_rpg_session_minutes",  "30",  "登录状态记忆时间(分钟, 0=每次都要输密码)", FCVAR_NONE, true, 0.0);
	g_cvMaxAttempts     = CreateConVar("l4d2_rpg_max_attempts",     "5",   "连续输错密码次数上限", FCVAR_NONE, true, 1.0);
	g_cvLockSeconds     = CreateConVar("l4d2_rpg_lock_seconds",     "300", "密码错误过多后锁定时长(秒)", FCVAR_NONE, true, 0.0);
	g_cvSingleSession   = CreateConVar("l4d2_rpg_single_session",   "1",   "同一账号是否只允许一个玩家在线 (1=是)", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvBindSteamID     = CreateConVar("l4d2_rpg_bind_steamid",     "1",   "账号是否绑定首次登录的 SteamID (1=绑定, 换机器需管理员 sm_rpg_unbind)", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvHashRounds      = CreateConVar("l4d2_rpg_hash_rounds",      "100", "密码哈希迭代次数 (改动会让已存在的密码失效, 除非库里有 hash_rounds 列)", FCVAR_NONE, true, 1.0);
	g_cvRegisterCooldown = CreateConVar("l4d2_rpg_register_cooldown", "5", "同一 SteamID 两次注册尝试的最小间隔(秒), 防刷", FCVAR_NONE, true, 0.0);
	g_cvDBRetrySeconds   = CreateConVar("l4d2_rpg_db_retry",        "15",  "账号读取失败后自动重试的间隔(秒)", FCVAR_NONE, true, 5.0);
	g_cvLoginTimeout    = CreateConVar("l4d2_rpg_login_timeout",    "0",   "未登录多久后踢出(秒, 0=不踢)", FCVAR_NONE, true, 0.0);
	g_cvRemindInterval  = CreateConVar("l4d2_rpg_remind_interval",  "60",  "未登录提醒间隔(秒, 0=关闭)", FCVAR_NONE, true, 0.0);

	g_cvHudEnabled   = CreateConVar("l4d2_rpg_hud",           "1",   "是否显示 HUD 信息", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvHudInterval  = CreateConVar("l4d2_rpg_hud_interval",  "10.0","HUD 刷新间隔(秒)",  FCVAR_NONE, true, 3.0);
	g_cvAllowCheatCmd = CreateConVar("l4d2_rpg_allow_cheat_cmd", "1", "允许插件临时提权执行 give 指令(补满弹药)", FCVAR_NONE, true, 0.0, true, 1.0);

	AutoExecConfig(true, "l4d2_rpg");

	RegConsoleCmd("sm_rpg",      Cmd_Info,     "查看 RPG 信息");
	RegConsoleCmd("sm_lvl",      Cmd_Info,     "查看 RPG 信息");
	RegConsoleCmd("sm_stats",    Cmd_Stats,    "属性分配菜单");
	RegConsoleCmd("sm_points",   Cmd_Stats,    "属性分配菜单");
	RegConsoleCmd("sm_shop",     Cmd_Shop,     "物资商店");
	RegConsoleCmd("sm_buy",      Cmd_Shop,     "物资商店");
	RegConsoleCmd("sm_register", Cmd_Register, "注册账号: sm_register <账号> <密码>");
	RegConsoleCmd("sm_login",    Cmd_Login,    "登录账号: sm_login [账号] <密码>");
	RegConsoleCmd("sm_logout",   Cmd_Logout,   "退出登录");
	RegConsoleCmd("sm_passwd",   Cmd_Passwd,   "修改密码: sm_passwd <旧密码> <新密码>");
	RegConsoleCmd("sm_top",      Cmd_Top,      "等级排行榜");
	RegConsoleCmd("sm_help",     Cmd_Help,     "RPG 帮助");
	RegConsoleCmd("sm_cancel",   Cmd_Cancel,   "取消当前输入");

	RegAdminCmd("sm_rpg_givexp",     Cmd_GiveXP,     ADMFLAG_ROOT, "sm_rpg_givexp <玩家> <数量>");
	RegAdminCmd("sm_rpg_givemoney",  Cmd_GiveMoney,  ADMFLAG_ROOT, "sm_rpg_givemoney <玩家> <数量>");
	RegAdminCmd("sm_rpg_givepoints", Cmd_GivePoints, ADMFLAG_ROOT, "sm_rpg_givepoints <玩家> <数量>");
	RegAdminCmd("sm_rpg_reset",      Cmd_Reset,      ADMFLAG_ROOT, "sm_rpg_reset <玩家>");
	RegAdminCmd("sm_rpg_setpass",    Cmd_SetPass,    ADMFLAG_ROOT, "sm_rpg_setpass <玩家> <新密码>");
	RegAdminCmd("sm_rpg_unbind",     Cmd_Unbind,     ADMFLAG_ROOT, "sm_rpg_unbind <玩家>");

	// 击杀相关: 普通感染者只能通过 infected_hurt 拿到实体, Tank/Witch 有专门事件
	HookEvent("infected_hurt", Event_InfectedHurt, EventHookMode_Pre);
	HookEvent("tank_killed",   Event_TankKilled);
	HookEvent("witch_killed",  Event_WitchKilled);

	HookEvent("player_death",   Event_PlayerDeath);
	HookEvent("heal_success",   Event_HealSuccess);
	HookEvent("revive_success", Event_ReviveSuccess);
	HookEvent("round_start",    Event_RoundStart);
	HookEvent("player_team",    Event_PlayerTeam);

	g_cvCheats = FindConVar("sv_cheats");

	// 这些表在插件进程存活期间必须一直有效。加 null 守卫是为了幂等 ——
	// 万一 OnPluginStart 被再次触发(重载), 直接覆盖会泄漏旧的 StringMap 句柄,
	// 而且会把爆破次数/锁定时间/自动登录记录全部清空。
	if (g_hSessions == null)     g_hSessions     = new StringMap();
	if (g_hAccountOwner == null) g_hAccountOwner = new StringMap();
	if (g_hFailCount == null)    g_hFailCount    = new StringMap();
	if (g_hLockUntil == null)    g_hLockUntil    = new StringMap();
	if (g_hRegisterAt == null)   g_hRegisterAt   = new StringMap();

	InitDatabase();

	// 数据库没就绪时开一个唯一的重试定时器(只在这里创建, 避免重复叠加)
	// 注意: 这几个都是**跨换图**的循环定时器, 绝对不能带 TIMER_FLAG_NO_MAPCHANGE ——
	// 带了这个标志的定时器会在换图时被销毁, 而 SourceMod 插件换图时不会重新加载,
	// OnPluginStart 也不会再跑 → 第一张图之后 HUD/自动保存/属性重算/DB 重连会全部静默消失。
	if (!g_bDBReady)
	{
		CreateTimer(30.0, Timer_RetryDB, _, TIMER_REPEAT);
	}

	// 定时任务
	CreateTimer(120.0, Timer_AutoSave, _, TIMER_REPEAT);
	CreateTimer(5.0,   Timer_ReapplyStats, _, TIMER_REPEAT);
	CreateTimer(1.0,   Timer_HudTick, _, TIMER_REPEAT);

	// 插件热加载: 补处理已在线的玩家
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			// 这些人的账号映射已经丢了, 先清掉可能残留的占用记录
			if (IsClientAuthorized(i) && g_iAuth[i] == AUTH_NONE)
			{
				OnClientAuthorized(i, "");
			}
		}
	}
}

public void OnPluginEnd()
{
	// 兜底: 插件被卸载时如果正好处于临时提权窗口, 必须把 sv_cheats / FCVAR_CHEAT 还原,
	// 否则服务器会一直开着作弊开关。
	RestoreCheatState();
	SaveAllClients(true);
	if (g_hDB != null)
	{
		delete g_hDB;
	}
}

public void OnMapEnd()
{
	RestoreCheatState();
	SaveAllClients();
}

public void OnClientPutInServer(int client)
{
	// 不覆盖正在进行的账号读取(否则回调会因为状态不是 AUTH_LOADING 而丢弃结果)
	if (g_iAuth[client] != AUTH_LOADING)
	{
		g_iAuth[client] = AUTH_NONE;
	}
	g_iConnectTime[client] = GetTime();
	g_bNoDBWarned[client]  = false;
	SDKHook(client, SDKHook_OnTakeDamageAlive, OnTakeDamageAlive);
	TryStartLoad(client);
}

public void OnClientAuthorized(int client, const char[] auth)
{
	TryStartLoad(client);
}

// OnClientAuthorized 与 OnClientPutInServer 的先后顺序不固定(授权票据可能早于入服),
// 所以两个回调都试着启动加载, 谁最后满足条件谁生效, 避免玩家卡在 AUTH_NONE。
void TryStartLoad(int client)
{
	if (client < 1 || client > MaxClients)
	{
		return;
	}
	if (IsFakeClient(client) || !IsClientInGame(client) || !IsClientAuthorized(client))
	{
		return;
	}
	if (g_iAuth[client] != AUTH_NONE)
	{
		return;
	}
	if (!GetClientAuthId(client, AuthId_SteamID64, g_sSteamID[client], sizeof(g_sSteamID[]), true))
	{
		return;
	}
	if (!g_bDBReady)
	{
		if (!g_bNoDBWarned[client])
		{
			g_bNoDBWarned[client] = true;
			PrintToChat(client, "%s数据库尚未就绪, 数据将在恢复后自动加载", CHAT_PREFIX);
		}
		return;
	}
	LoadAccountBySteamID(client);
}

public void OnClientDisconnect(int client)
{
	if (g_iAuth[client] == AUTH_LOGGED_IN)
	{
		// 这是玩家离服前的最后一次保存, 之后内存副本会被 ResetClientData 清掉,
		// 异步保存失败就再也补不回来了。所以数据库健康(SQLite 或从未出错)时走
		// 同步保存, 确保真的落库; 一旦数据库出过问题就退回异步, 避免主线程被卡住。
		SaveClient(client, g_bSQLite || !g_bDBAttemptFailed);

		// 释放账号占用, 否则该账号会被判定为"仍在线"而永远无法再登录
		int ownerUid = 0;
		if (g_hAccountOwner.GetValue(g_sAccount[client], ownerUid) && ownerUid == GetClientUserId(client))
		{
			g_hAccountOwner.Remove(g_sAccount[client]);
		}
	}
	ResetClientData(client);
}

// ==================== 数据库 ====================
void InitDatabase()
{
	char error[256];
	g_hDB = null;

	if (SQL_CheckConfig("l4d2_rpg"))
	{
		g_hDB = SQL_Connect("l4d2_rpg", true, error, sizeof(error));
		if (g_hDB == null)
		{
			LogError("[RPG] 连接 MySQL (databases.cfg: l4d2_rpg) 失败: %s", error);
		}
	}
	else
	{
		g_hDB = SQLite_UseDatabase("l4d2_rpg", error, sizeof(error));
		if (g_hDB == null)
		{
			LogError("[RPG] 打开 SQLite 数据库失败: %s", error);
		}
	}

	if (g_hDB == null)
	{
		g_bDBReady = false;
		// 注意: 重试定时器只在 OnPluginStart 里创建一次。
		// 以前在这里再 CreateTimer 会导致每次失败都多出一个循环定时器, 数量翻倍增长。
		return;
	}

	char driver[16];
	SQL_ReadDriver(g_hDB, driver, sizeof(driver));
	g_bSQLite = StrEqual(driver, "sqlite", false);

	// 建表失败时不能标记为就绪, 否则之后所有查询都会 "no such table" 且永不重试
	if (!CreateTables())
	{
		g_bDBReady = false;
		delete g_hDB;
		g_hDB = null;
		return;
	}

	g_bDBReady = true;
}

public Action Timer_RetryDB(Handle timer)
{
	if (g_bDBReady)
	{
		return Plugin_Stop;
	}
	InitDatabase();
	if (g_bDBReady)
	{
		LogMessage("[RPG] 数据库重连成功");
		// 重连后为在线玩家补加载
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && !IsFakeClient(i) && IsClientAuthorized(i) && g_iAuth[i] == AUTH_NONE)
			{
				OnClientAuthorized(i, "");
			}
		}
		return Plugin_Stop;
	}
	return Plugin_Continue;
}

// 幂等补列: 老版本建出来的表里可能缺列, 而 CREATE TABLE IF NOT EXISTS 对已存在的表
// 什么都不做, 于是新加的列永远补不上, 之后所有 SELECT 都会失败、每个玩家都读不到存档。
// 先试着 SELECT 一下这个列: 能查通说明已存在; 查不通就 ALTER TABLE 补上再确认。
bool EnsureColumn(const char[] column, const char[] columnDef)
{
	char q[512];
	char error[256];

	Format(q, sizeof(q), "SELECT %s FROM rpg_players LIMIT 1", column);
	DBResultSet rs = SQL_Query(g_hDB, q);
	if (rs != null)
	{
		delete rs;
		return true;
	}

	Format(q, sizeof(q), "ALTER TABLE rpg_players ADD COLUMN %s", columnDef);
	if (!SQL_FastQuery(g_hDB, q))
	{
		SQL_GetError(g_hDB, error, sizeof(error));
		LogError("[RPG] 为旧数据库补列 %s 失败: %s", column, error);
		return false;
	}

	Format(q, sizeof(q), "SELECT %s FROM rpg_players LIMIT 1", column);
	rs = SQL_Query(g_hDB, q);
	if (rs == null)
	{
		SQL_GetError(g_hDB, error, sizeof(error));
		LogError("[RPG] 补列 %s 之后仍然查询失败: %s", column, error);
		return false;
	}
	delete rs;

	LogMessage("[RPG] 已为旧数据库补上缺失的列: %s", column);
	return true;
}

bool CreateTables()
{
	char query[2048];
	char error[256];

	if (g_bSQLite)
	{
		Format(query, sizeof(query),
			"CREATE TABLE IF NOT EXISTS rpg_players ("
			... "account TEXT NOT NULL PRIMARY KEY, "
			... "steamid TEXT NOT NULL DEFAULT '', "
			... "salt TEXT NOT NULL, "
			... "passhash TEXT NOT NULL, "
			... "level INTEGER NOT NULL DEFAULT 1, "
			... "xp INTEGER NOT NULL DEFAULT 0, "
			... "total_xp INTEGER NOT NULL DEFAULT 0, "
			... "money INTEGER NOT NULL DEFAULT 0, "
			... "points INTEGER NOT NULL DEFAULT 0, "
			... "stat_agi INTEGER NOT NULL DEFAULT 0, "
			... "stat_str INTEGER NOT NULL DEFAULT 0, "
			... "stat_sta INTEGER NOT NULL DEFAULT 0, "
			... "stat_def INTEGER NOT NULL DEFAULT 0, "
			... "kill_common INTEGER NOT NULL DEFAULT 0, "
			... "kill_special INTEGER NOT NULL DEFAULT 0, "
			... "kill_tank INTEGER NOT NULL DEFAULT 0, "
			... "kill_witch INTEGER NOT NULL DEFAULT 0, "
			... "heals INTEGER NOT NULL DEFAULT 0, "
			... "deaths INTEGER NOT NULL DEFAULT 0, "
			... "playtime INTEGER NOT NULL DEFAULT 0, "
			... "created_at INTEGER NOT NULL DEFAULT 0, "
			... "hash_rounds INTEGER NOT NULL DEFAULT 0, "
			... "last_seen INTEGER NOT NULL DEFAULT 0)");

		if (!SQL_FastQuery(g_hDB, query))
		{
			SQL_GetError(g_hDB, error, sizeof(error));
			LogError("[RPG] 创建 SQLite 数据表失败: %s", error);
			return false;
		}
		SQL_FastQuery(g_hDB, "CREATE INDEX IF NOT EXISTS idx_rpg_steamid ON rpg_players (steamid)");
	}
	else
	{
		Format(query, sizeof(query),
			"CREATE TABLE IF NOT EXISTS rpg_players ("
			... "account VARCHAR(32) NOT NULL, "
			... "steamid VARCHAR(32) NOT NULL DEFAULT '', "
			... "salt VARCHAR(32) NOT NULL, "
			... "passhash VARCHAR(128) NOT NULL, "
			... "level INT NOT NULL DEFAULT 1, "
			... "xp INT NOT NULL DEFAULT 0, "
			... "total_xp INT NOT NULL DEFAULT 0, "
			... "money INT NOT NULL DEFAULT 0, "
			... "points INT NOT NULL DEFAULT 0, "
			... "stat_agi INT NOT NULL DEFAULT 0, "
			... "stat_str INT NOT NULL DEFAULT 0, "
			... "stat_sta INT NOT NULL DEFAULT 0, "
			... "stat_def INT NOT NULL DEFAULT 0, "
			... "kill_common INT NOT NULL DEFAULT 0, "
			... "kill_special INT NOT NULL DEFAULT 0, "
			... "kill_tank INT NOT NULL DEFAULT 0, "
			... "kill_witch INT NOT NULL DEFAULT 0, "
			... "heals INT NOT NULL DEFAULT 0, "
			... "deaths INT NOT NULL DEFAULT 0, "
			... "playtime INT NOT NULL DEFAULT 0, "
			... "created_at INT NOT NULL DEFAULT 0, "
			... "hash_rounds INT NOT NULL DEFAULT 0, "
			... "last_seen INT NOT NULL DEFAULT 0, "
			... "PRIMARY KEY (account), "
			... "KEY idx_rpg_steamid (steamid)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");

		if (!SQL_FastQuery(g_hDB, query))
		{
			SQL_GetError(g_hDB, error, sizeof(error));
			LogError("[RPG] 创建 MySQL 数据表失败: %s", error);
			return false;
		}
	}

	// 旧库补列 (新装时这几列已经存在, 这里直接通过)
	if (!EnsureColumn("last_seen",
		g_bSQLite ? "last_seen INTEGER NOT NULL DEFAULT 0" : "last_seen INT NOT NULL DEFAULT 0"))
	{
		return false;
	}
	if (!EnsureColumn("created_at",
		g_bSQLite ? "created_at INTEGER NOT NULL DEFAULT 0" : "created_at INT NOT NULL DEFAULT 0"))
	{
		return false;
	}
	// hash_rounds: 每个账号自己的哈希迭代次数。不存这一列的话, 管理员改一次
	// l4d2_rpg_hash_rounds 就会让所有已有账号的密码全部失效
	// (验证时会用新轮数去比对旧轮数算出来的哈希)。
	if (!EnsureColumn("hash_rounds",
		g_bSQLite ? "hash_rounds INTEGER NOT NULL DEFAULT 0" : "hash_rounds INT NOT NULL DEFAULT 0"))
	{
		return false;
	}

	LogMessage("[RPG] 数据表就绪 (%s)", g_bSQLite ? "SQLite" : "MySQL");
	return true;
}

// ==================== 账号: 读取 / 注册 / 登录 ====================
void LoadAccountBySteamID(int client)
{
	g_iAuth[client]      = AUTH_LOADING;
	g_iLoadStart[client] = GetTime();

	char sid[80];
	SQL_EscapeString(g_hDB, g_sSteamID[client], sid, sizeof(sid));

	char query[1024];
	Format(query, sizeof(query),
		"SELECT %s FROM rpg_players WHERE steamid = '%s' ORDER BY last_seen DESC LIMIT 1",
		SQL_PLAYER_COLUMNS, sid);

	SQL_TQuery(g_hDB, OnLoadBySteamID, query, GetClientUserId(client));
}

public void OnLoadBySteamID(Database db, DBResultSet results, const char[] error, any data)
{
	int client = GetClientOfUserId(data);
	if (client < 1 || !IsClientInGame(client) || g_iAuth[client] != AUTH_LOADING)
	{
		return;
	}

	if (results == null)
	{
		LogError("[RPG] 查询绑定账号失败: %s", error);
		g_iAuth[client] = AUTH_NONE;
		// 别让玩家卡死在"请重新连接": 排一个重试时间, Timer_HudTick 会重新读账号。
		g_iNextLoadTry[client] = GetTime() + g_cvDBRetrySeconds.IntValue;
		PrintToChat(client, "%s读取账号数据失败, 稍后会自动重试 (也可输入 !login 手动重试)", CHAT_PREFIX);
		return;
	}

	if (!results.FetchRow())
	{
		// 该 SteamID 还没有绑定任何账号
		SetDefaultData(client);
		g_iAuth[client] = AUTH_NEED_REGISTER;
		PromptAccount(client);
		return;
	}

	ReadRow(results, client);

	// 同一 SteamID 在记忆时间内可免密码自动登录
	if (AutoLoginAllowed(client))
	{
		LoginSuccess(client, true);
		return;
	}

	g_iAuth[client] = AUTH_NEED_LOGIN;
	PromptAccount(client);
}

void ReadRow(DBResultSet results, int client)
{
	results.FetchString(COL_ACCOUNT,  g_sAccount[client],  MAX_ACCOUNT_LEN + 1);
	results.FetchString(COL_SALT,     g_sSalt[client],     SALT_LEN + 1);
	results.FetchString(COL_PASSHASH, g_sPassHash[client], HASH_LEN + 1);

	g_iLevel[client]      = results.FetchInt(COL_LEVEL);
	g_iXP[client]         = results.FetchInt(COL_XP);
	g_iTotalXP[client]    = results.FetchInt(COL_TOTALXP);
	g_iMoney[client]      = results.FetchInt(COL_MONEY);
	g_iPoints[client]     = results.FetchInt(COL_POINTS);
	g_iStats[client][STAT_AGI] = results.FetchInt(COL_STAT_AGI);
	g_iStats[client][STAT_STR] = results.FetchInt(COL_STAT_STR);
	g_iStats[client][STAT_STA] = results.FetchInt(COL_STAT_STA);
	g_iStats[client][STAT_DEF] = results.FetchInt(COL_STAT_DEF);
	g_iKills[client][KILL_COMMON]  = results.FetchInt(COL_KILL_COMMON);
	g_iKills[client][KILL_SPECIAL] = results.FetchInt(COL_KILL_SPECIAL);
	g_iKills[client][KILL_TANK]    = results.FetchInt(COL_KILL_TANK);
	g_iKills[client][KILL_WITCH]   = results.FetchInt(COL_KILL_WITCH);
	g_iHeals[client]      = results.FetchInt(COL_HEALS);
	g_iDeaths[client]     = results.FetchInt(COL_DEATHS);
	g_iPlaytime[client]   = results.FetchInt(COL_PLAYTIME);
	g_iLastSeen[client]   = results.FetchInt(COL_LAST_SEEN);
	g_iHashRounds[client] = results.FetchInt(COL_HASH_ROUNDS);

	SanitizeData(client);
}

void SetDefaultData(int client)
{
	g_sAccount[client][0]  = '\0';
	g_sSalt[client][0]     = '\0';
	g_sPassHash[client][0] = '\0';

	g_iLevel[client]    = 1;
	g_iXP[client]       = 0;
	g_iTotalXP[client]  = 0;
	g_iMoney[client]    = g_cvStartMoney.IntValue;
	g_iPoints[client]   = 0;
	g_iHeals[client]    = 0;
	g_iDeaths[client]   = 0;
	g_iPlaytime[client] = 0;
	g_iLastSeen[client] = 0;
	g_iHashRounds[client] = 0;

	for (int s = 0; s < STAT_COUNT; s++)
	{
		g_iStats[client][s] = 0;
	}
	for (int k = 0; k < KILL_COUNT; k++)
	{
		g_iKills[client][k] = 0;
	}
}

// 只重置数值, 保留账号身份(account/salt/passhash)与登录状态.
// 管理员 sm_rpg_reset 必须用这个: 用 SetDefaultData 会把 account 清空,
// 而 g_iAuth 仍是 AUTH_LOGGED_IN -> SaveClient 因账号为空直接 return,
// 之后该玩家所有经验/金钱永不落库, !passwd 也会变成 WHERE account = '' 改 0 行.
void ResetStatsKeepAuth(int client)
{
	g_iLevel[client]    = 1;
	g_iXP[client]       = 0;
	g_iTotalXP[client]  = 0;
	g_iMoney[client]    = g_cvStartMoney.IntValue;
	g_iPoints[client]   = 0;
	g_iHeals[client]    = 0;
	g_iDeaths[client]   = 0;
	g_iPlaytime[client] = 0;

	for (int s = 0; s < STAT_COUNT; s++)
	{
		g_iStats[client][s] = 0;
	}
	for (int k = 0; k < KILL_COUNT; k++)
	{
		g_iKills[client][k] = 0;
	}
}

void SanitizeData(int client)
{
	int maxLevel = g_cvMaxLevel.IntValue;
	int statMax  = g_cvStatMax.IntValue;

	if (g_iLevel[client] < 1)        g_iLevel[client] = 1;
	if (g_iLevel[client] > maxLevel) g_iLevel[client] = maxLevel;
	if (g_iXP[client] < 0)           g_iXP[client] = 0;
	if (g_iMoney[client] < 0)        g_iMoney[client] = 0;
	if (g_iPoints[client] < 0)       g_iPoints[client] = 0;
	if (g_iTotalXP[client] < g_iXP[client]) g_iTotalXP[client] = g_iXP[client];

	for (int s = 0; s < STAT_COUNT; s++)
	{
		if (g_iStats[client][s] < 0)          g_iStats[client][s] = 0;
		if (g_iStats[client][s] > statMax)    g_iStats[client][s] = statMax;
	}
}

bool AutoLoginAllowed(int client)
{
	int minutes = g_cvSessionMinutes.IntValue;
	if (minutes <= 0 || !g_sAccount[client][0])
	{
		return false;
	}

	// 用数据库里的 last_seen 判断, 而不是内存里的 StringMap:
	// L4D2 换图会重连所有玩家并重跑 OnPluginStart, 内存会话表每次换图都是空的。
	int lastLogin = g_iLastSeen[client];
	if (lastLogin <= 0)
	{
		g_hSessions.GetValue(g_sSteamID[client], lastLogin);
	}
	if (lastLogin <= 0)
	{
		return false;
	}

	return (GetTime() - lastLogin) <= minutes * 60;
}

void LoginSuccess(int client, bool autoLogin)
{
	if (!g_sAccount[client][0])
	{
		g_iAuth[client] = AUTH_NEED_REGISTER;
		PromptAccount(client);
		return;
	}

	// 单点登录: 顶掉同一账号的其它在线会话
	// 注意 map 里存的是 userid 而不是 client index —— client index 会被新连接复用,
	// 存 index 会把"刚好占了同一个槽位的另一个人"踢下线。
	if (g_cvSingleSession.BoolValue)
	{
		int otherUid = 0;
		if (g_hAccountOwner.GetValue(g_sAccount[client], otherUid))
		{
			int other = GetClientOfUserId(otherUid);
			if (other > 0 && other != client && IsClientInGame(other))
			{
				PrintToChat(other, "%s你的账号 \x04%s\x01 已在其它客户端登录, 你已被强制下线",
					CHAT_PREFIX, g_sAccount[client]);
				LogoutClient(other, true);
			}
		}
	}

	g_hAccountOwner.SetValue(g_sAccount[client], GetClientUserId(client));
	g_hSessions.SetValue(g_sSteamID[client], GetTime());

	g_iAuth[client]        = AUTH_LOGGED_IN;
	g_iInput[client]       = INPUT_NONE;
	g_iSessionStart[client] = GetTime();
	g_iConnectTime[client] = GetTime();
	SetFailCount(client, 0);
	SetLockUntil(client, 0);
	g_bStatsApplied[client] = false;

	// 记录本次登录的 SteamID 与时间。
	// g_sSteamID 为空(拿不到 SteamID 的非 Steam 客户端 / 授权未完成)时**不写** steamid ——
	// 否则一次这样的登录就会把账号已有的绑定抹成空串, 等于让任何人拿到密码就能解绑。
	char sid[80], acc[64];
	SQL_EscapeString(g_hDB, g_sSteamID[client], sid, sizeof(sid));
	SQL_EscapeString(g_hDB, g_sAccount[client], acc, sizeof(acc));

	char query[512];
	if (g_sSteamID[client][0] != '\0')
	{
		Format(query, sizeof(query),
			"UPDATE rpg_players SET steamid = '%s', last_seen = %d WHERE account = '%s'",
			sid, GetTime(), acc);
	}
	else
	{
		Format(query, sizeof(query),
			"UPDATE rpg_players SET last_seen = %d WHERE account = '%s'",
			GetTime(), acc);
	}
	SQL_TQuery(g_hDB, OnSaveDone, query, 0);

	if (autoLogin)
	{
		PrintToChat(client, "%s自动登录成功, 欢迎回来 \x04%s\x01", CHAT_PREFIX, g_sAccount[client]);
	}
	else
	{
		PrintToChat(client, "%s登录成功, 欢迎 \x04%s\x01", CHAT_PREFIX, g_sAccount[client]);
	}

	ApplyAllStats(client);
	ShowWelcome(client, autoLogin);
}

void DoLogin(int client, const char[] account, const char[] password)
{
	if (g_iAuth[client] == AUTH_LOGGED_IN)
	{
		PrintToChat(client, "%s你已经登录了 (\x04%s\x01)", CHAT_PREFIX, g_sAccount[client]);
		return;
	}
	if (!g_bDBReady)
	{
		PrintToChat(client, "%s数据库未就绪, 请稍后重试", CHAT_PREFIX);
		return;
	}
	if (g_bLoginPending[client])
	{
		PrintToChat(client, "%s上一次登录验证还在处理中, 请稍等一下", CHAT_PREFIX);
		return;
	}
	if (IsLocked(client))
	{
		PrintToChat(client, "%s密码错误次数过多, 请 %d 秒后再试", CHAT_PREFIX,
			GetLockUntil(client) - GetTime());
		return;
	}
	if (!IsValidAccountName(account))
	{
		PrintToChat(client, "%s账号格式不正确 (3-16位, 字母/数字/下划线)", CHAT_PREFIX);
		return;
	}
	if (!IsValidPassword(password))
	{
		PrintToChat(client, "%s密码格式不正确 (4-32位, 不能含空格)", CHAT_PREFIX);
		return;
	}

	strcopy(g_sPendingAccount[client],  MAX_ACCOUNT_LEN + 1, account);
	strcopy(g_sPendingPassword[client], MAX_PASSWORD_LEN + 1, password);
	g_bLoginPending[client] = true;

	char acc[64];
	SQL_EscapeString(g_hDB, account, acc, sizeof(acc));

	char query[1024];
	Format(query, sizeof(query),
		"SELECT %s FROM rpg_players WHERE account = '%s' LIMIT 1",
		SQL_PLAYER_COLUMNS, acc);

	SQL_TQuery(g_hDB, OnLoginQuery, query, GetClientUserId(client));
}

public void OnLoginQuery(Database db, DBResultSet results, const char[] error, any data)
{
	int client = GetClientOfUserId(data);
	if (client < 1 || !IsClientInGame(client) || g_iAuth[client] == AUTH_LOGGED_IN)
	{
		// 早退也必须解除"在途"标记并清掉明文密码缓冲。
		// 典型触发: 玩家的登录查询还在飞的时候, 进服时的自动加载先返回并把他登录了 ——
		// 这之后如果标记没清掉, !logout 再 !login 会永远被"上一次登录验证还在处理中"
		// 挡住, 直到断线重连为止。
		if (client >= 1 && client <= MaxClients)
		{
			g_bLoginPending[client]    = false;
			g_sPendingPassword[client][0] = '\0';
		}
		return;
	}

	// 本次登录查询已经回来了, 解除"在途"标记 —— 之后才允许再发起一次登录。
	// 没有这个标记的话, 玩家连按两次 !login 会让先发出去的那个查询用后写入的
	// g_sPendingPassword 去校验, 于是把正确密码判成错误, 还白扣一次机会。
	g_bLoginPending[client] = false;

	if (results == null)
	{
		LogError("[RPG] 登录查询失败: %s", error);
		PrintToChat(client, "%s登录失败 (数据库错误), 请稍后重试", CHAT_PREFIX);
		return;
	}

	if (!results.FetchRow())
	{
		FailLogin(client, "账号或密码错误");
		return;
	}

	// 先在临时变量里校验密码 —— 校验通过才把整行数据写进该客户端的存档,
	// 否则一次失败的登录就会用别人的资料覆盖自己的内存数据。
	char salt[SALT_LEN + 1], stored[HASH_LEN + 1];
	results.FetchString(COL_SALT, salt, sizeof(salt));
	results.FetchString(COL_PASSHASH, stored, sizeof(stored));

	// 用该账号自己的迭代次数验证。老账号这一列可能是 0(补列前注册的),
	// 那就退回 ConVar 的当前值 —— 这正好是它们当初注册时用的轮数。
	int rowRounds = results.FetchInt(COL_HASH_ROUNDS);

	char computed[HASH_LEN + 1];
	HashPassword(g_sPendingPassword[client], salt, computed, sizeof(computed), rowRounds);

	if (!StrEqual(computed, stored, false))
	{
		FailLogin(client, "账号或密码错误");
		return;
	}

	// SteamID 绑定校验: 账号第一次登录时绑定当时的 SteamID, 之后只有同一个
	// SteamID 能登录。没有这一条, 密码一旦泄露, 拿到密码的人从自己的机器登录
	// 就会把绑定改写成自己, 并且凭 last_seen 获得免密自动登录 —— 原主人被永久踢出。
	if (g_cvBindSteamID.BoolValue)
	{
		// 本机拿不到 SteamID 时直接拒绝登录: 否则下面的比较会因为 g_sSteamID 为空
		// 而整块跳过, 拿到密码的人只要用一个"无 SteamID"的客户端登录, 就能
		// 把这个账号的绑定清掉, 反顶号设计形同虚设。
		if (g_sSteamID[client][0] == '\0')
		{
			g_sPendingPassword[client][0] = '\0';
			PrintToChat(client, "%s拿不到你的 SteamID, 暂时无法登录", CHAT_PREFIX);
			PrintToChat(client, "%s请重连服务器; 若一直在用非 Steam 客户端, 请让管理员把 \x04l4d2_rpg_bind_steamid\x01 设为 0", CHAT_PREFIX);
			LogMessage("[RPG] 拒绝登录: 客户端没有 SteamID (account=%s)", g_sPendingAccount[client]);
			g_iInput[client] = INPUT_NONE;
			return;
		}

		char bound[80];
		results.FetchString(COL_STEAMID, bound, sizeof(bound));

		if (bound[0] != '\0' && !StrEqual(bound, g_sSteamID[client], false))
		{
			g_sPendingPassword[client][0] = '\0';
			PrintToChat(client, "%s该账号已绑定其它 SteamID, 无法在此机器登录", CHAT_PREFIX);
			PrintToChat(client, "%s如果这是你自己的账号, 请联系管理员执行 \x04sm_rpg_unbind\x01 解绑", CHAT_PREFIX);
			LogMessage("[RPG] 拒绝跨 SteamID 登录: account=%s bound=%s current=%s",
				g_sPendingAccount[client], bound, g_sSteamID[client]);
			g_iInput[client] = INPUT_NONE;
			return;
		}
	}

	g_sPendingPassword[client][0] = '\0';
	ReadRow(results, client);
	LoginSuccess(client, false);
}

void FailLogin(int client, const char[] reason)
{
	// 统一话术, 不区分"账号不存在"和"密码错误", 避免被用来枚举有效账号名
	PrintToChat(client, "%s登录失败: \x04%s\x01", CHAT_PREFIX, reason);

	int fails = GetFailCount(client) + 1;
	int maxAttempts = g_cvMaxAttempts.IntValue;

	if (fails >= maxAttempts)
	{
		SetFailCount(client, 0);
		SetLockUntil(client, GetTime() + g_cvLockSeconds.IntValue);
		PrintToChat(client, "%s尝试次数过多, 已锁定 %d 秒", CHAT_PREFIX, g_cvLockSeconds.IntValue);
		return;
	}

	SetFailCount(client, fails);

	// 重新进入等待输入状态, 方便玩家直接再输一次
	g_sPendingPassword[client][0] = '\0';
	g_iInput[client] = INPUT_LOGIN_BOTH;
	PrintToChat(client, "%s还剩 \x04%d\x01 次机会, 请重新输入 \x04账号 密码\x01 (或 \x04!login\x01 重新开始)",
		CHAT_PREFIX, maxAttempts - fails);
}

// 锁定/失败计数以 SteamID 为键(未授权时退回 userid), 断线重连不会清零
void LockKey(int client, char[] key, int maxlen)
{
	if (g_sSteamID[client][0])
	{
		strcopy(key, maxlen, g_sSteamID[client]);
	}
	else
	{
		Format(key, maxlen, "uid:%d", GetClientUserId(client));
	}
}

int GetFailCount(int client)
{
	char key[80];
	LockKey(client, key, sizeof(key));

	int v = 0;
	g_hFailCount.GetValue(key, v);
	return v;
}

void SetFailCount(int client, int v)
{
	char key[80];
	LockKey(client, key, sizeof(key));

	if (v <= 0)
	{
		g_hFailCount.Remove(key);
	}
	else
	{
		g_hFailCount.SetValue(key, v);
	}
}

int GetLockUntil(int client)
{
	char key[80];
	LockKey(client, key, sizeof(key));

	int v = 0;
	g_hLockUntil.GetValue(key, v);
	return v;
}

void SetLockUntil(int client, int v)
{
	char key[80];
	LockKey(client, key, sizeof(key));

	if (v <= 0)
	{
		g_hLockUntil.Remove(key);
	}
	else
	{
		g_hLockUntil.SetValue(key, v);
	}
}

bool IsLocked(int client)
{
	int until = GetLockUntil(client);
	if (until <= 0)
	{
		return false;
	}
	if (GetTime() >= until)
	{
		SetLockUntil(client, 0);
		return false;
	}
	return true;
}

// 注册限速: 注册路径要跑同步 SHA-256 迭代, 而登录的失败锁定管不到它。
// 按 SteamID(未授权时退回 userid) 记时间戳, 同一个键在 l4d2_rpg_register_cooldown
// 秒内只允许一次, 避免玩家用 !register 循环把服务器主线程卡住。
bool CheckRegisterRate(int client)
{
	char key[80];
	LockKey(client, key, sizeof(key));

	int now  = GetTime();
	int last = 0;
	char mapKey[96];
	Format(mapKey, sizeof(mapKey), "reg:%s", key);

	if (g_hRegisterAt != null && g_hRegisterAt.GetValue(mapKey, last))
	{
		if (now - last < g_cvRegisterCooldown.IntValue)
		{
			return false;
		}
	}

	if (g_hRegisterAt == null)
	{
		g_hRegisterAt = new StringMap();
	}
	g_hRegisterAt.SetValue(mapKey, now, true);
	return true;
}

void DoRegister(int client, const char[] account, const char[] password)
{
	// 只允许"这个 SteamID 还没有绑定账号"的玩家注册。
	// 否则处于 AUTH_NEED_LOGIN(已有绑定账号) 的玩家可以无限注册新账号,
	// 每注册一次就白拿一份初始金钱(默认 $500) —— 等于刷经济。
	if (g_iAuth[client] == AUTH_LOGGED_IN)
	{
		PrintToChat(client, "%s你已经登录了 (\x04%s\x01), 无需注册", CHAT_PREFIX, g_sAccount[client]);
		return;
	}
	if (g_iAuth[client] == AUTH_NEED_LOGIN)
	{
		PrintToChat(client, "%s你这个 SteamID 已经绑定账号 \x04%s\x01, 请直接 \x04!login\x01 登录",
			CHAT_PREFIX, g_sAccount[client]);
		PrintToChat(client, "%s(要换新账号请先让管理员 \x04sm_rpg_unbind\x01 解绑)", CHAT_PREFIX);
		return;
	}
	if (g_iAuth[client] == AUTH_LOADING || g_iAuth[client] == AUTH_NONE)
	{
		PrintToChat(client, "%s账号数据还在读取中, 请稍等几秒再试", CHAT_PREFIX);
		return;
	}
	if (!g_bDBReady)
	{
		PrintToChat(client, "%s数据库未就绪, 请稍后重试", CHAT_PREFIX);
		return;
	}
	// 注册要跑同步哈希, 单独限速 —— 登录的失败锁定管不到这条路径。
	// 否则玩家循环 !register 就能用 SHA-256 迭代把服务器主线程卡住。
	if (!CheckRegisterRate(client))
	{
		PrintToChat(client, "%s注册太频繁了, 请稍等几秒再试", CHAT_PREFIX);
		return;
	}

	char acc[64], sid[80];
	SQL_EscapeString(g_hDB, account, acc, sizeof(acc));
	SQL_EscapeString(g_hDB, g_sSteamID[client], sid, sizeof(sid));

	char salt[SALT_LEN + 1];
	GenerateSalt(salt, sizeof(salt));

	char hash[HASH_LEN + 1];
	int  rounds = g_cvHashRounds.IntValue;
	if (rounds < 1)    rounds = 1;
	if (rounds > 1000) rounds = 1000;
	HashPassword(password, salt, hash, sizeof(hash), rounds);

	g_iHashRounds[client] = rounds;

	strcopy(g_sPendingAccount[client], MAX_ACCOUNT_LEN + 1, account);

	int now = GetTime();
	char query[1024];
	Format(query, sizeof(query),
		"INSERT INTO rpg_players (account, steamid, salt, passhash, level, xp, total_xp, money, points, created_at, last_seen, hash_rounds) "
		... "VALUES ('%s', '%s', '%s', '%s', 1, 0, 0, %d, 0, %d, %d, %d)",
		acc, sid, salt, hash, g_cvStartMoney.IntValue, now, now, rounds);

	SQL_TQuery(g_hDB, OnRegisterDone, query, GetClientUserId(client));
}

public void OnRegisterDone(Database db, DBResultSet results, const char[] error, any data)
{
	int client = GetClientOfUserId(data);
	if (client < 1 || !IsClientInGame(client))
	{
		return;
	}

	if (error[0] != '\0')
	{
		LogError("[RPG] 注册失败 (%s): %s", g_sPendingAccount[client], error);
		PrintToChat(client, "%s注册失败: 账号 \x04%s\x01 可能已被注册, 请换一个", CHAT_PREFIX,
			g_sPendingAccount[client]);
		g_iAuth[client] = AUTH_NEED_REGISTER;
		PromptAccount(client);
		return;
	}

	// 注册成功: 以新账号身份登录
	SetDefaultData(client);
	strcopy(g_sAccount[client], MAX_ACCOUNT_LEN + 1, g_sPendingAccount[client]);
	strcopy(g_sPassHash[client], HASH_LEN + 1, "");

	// 重新从数据库读取(含 salt / hash / 初始金钱), 确保内存与数据库一致
	char acc[64];
	SQL_EscapeString(g_hDB, g_sAccount[client], acc, sizeof(acc));

	char query[1024];
	Format(query, sizeof(query),
		"SELECT %s FROM rpg_players WHERE account = '%s' LIMIT 1",
		SQL_PLAYER_COLUMNS, acc);

	SQL_TQuery(g_hDB, OnRegisteredLoad, query, GetClientUserId(client));
}

public void OnRegisteredLoad(Database db, DBResultSet results, const char[] error, any data)
{
	int client = GetClientOfUserId(data);
	if (client < 1 || !IsClientInGame(client))
	{
		return;
	}
	if (results == null || !results.FetchRow())
	{
		LogError("[RPG] 注册后读取账号失败: %s", error);
		g_iAuth[client] = AUTH_NEED_REGISTER;
		PrintToChat(client, "%s注册后读取数据失败, 请重新连接", CHAT_PREFIX);
		return;
	}

	ReadRow(results, client);
	PrintToChat(client, "%s注册成功! 你的账号是 \x04%s\x01, 请牢记密码 (可用 !passwd 修改)", CHAT_PREFIX,
		g_sAccount[client]);
	LoginSuccess(client, false);
}

void LogoutClient(int client, bool save)
{
	if (g_iAuth[client] == AUTH_LOGGED_IN)
	{
		// clearLastSeen=true: last_seen 是免密自动登录的依据, 主动登出必须把它归零,
		// 否则玩家 !logout 之后在 l4d2_rpg_session_minutes 之内重连会被自动登录回来。
		// 这里用**同步**保存: 异步一旦失败, 回调会因为状态已经切成未登录而不立 dirty,
		// 也没人会重试 —— last_seen 就永远是旧值, 承诺的"登出后不再自动登录"失效。
		if (save)
		{
			if (!SaveClient(client, true, true) && g_hDB != null && g_bDBReady
				&& g_sAccount[client][0] != '\0')
			{
				// 同步保存失败(数据库抖动): 再尽力异步把 last_seen 清零兜底
				char acc[64], query[256];
				SQL_EscapeString(g_hDB, g_sAccount[client], acc, sizeof(acc));
				Format(query, sizeof(query),
					"UPDATE rpg_players SET last_seen = 0 WHERE account = '%s'", acc);
				SQL_TQuery(g_hDB, OnSaveDone, query, 0);
			}
		}
		else
		{
			char acc[64], query[256];
			SQL_EscapeString(g_hDB, g_sAccount[client], acc, sizeof(acc));
			Format(query, sizeof(query),
				"UPDATE rpg_players SET last_seen = 0 WHERE account = '%s'", acc);
			SQL_TQuery(g_hDB, OnSaveDone, query, 0);
		}

		int ownerUid = 0;
		if (g_hAccountOwner.GetValue(g_sAccount[client], ownerUid) && ownerUid == GetClientUserId(client))
		{
			g_hAccountOwner.Remove(g_sAccount[client]);
		}
	}

	// 关键: 先把状态切成"未登录", 再让 ApplyAllStats 走还原分支收回属性加成,
	// 最后才清掉 g_bStatsApplied —— 否则移速/血量加成会永久留在玩家身上。
	g_iAuth[client]  = g_sAccount[client][0] ? AUTH_NEED_LOGIN : AUTH_NEED_REGISTER;
	g_iInput[client] = INPUT_NONE;
	ApplyAllStats(client);
	g_bStatsApplied[client] = false;

	g_sPendingPassword[client][0] = '\0';
	// 登出时把"登录查询在途"标记也清掉, 避免它泄漏之后 !login 恒被拒绝
	g_bLoginPending[client] = false;
	SetDefaultData(client);
}

void ResetClientData(int client)
{
	g_iAuth[client]  = AUTH_NONE;
	g_iInput[client] = INPUT_NONE;
	g_sSteamID[client][0]          = '\0';
	g_sPendingAccount[client][0]   = '\0';
	g_sPendingPassword[client][0]  = '\0';
	// 注意: 失败次数/锁定不在这里清 —— 它们按 SteamID 记录, 断线重连不能解锁
	g_iSessionStart[client] = 0;
	g_iConnectTime[client]  = 0;
	g_iLoadStart[client]    = 0;
	g_iNextLoadTry[client]  = 0;
	g_bLoginPending[client] = false;
	g_bDirty[client]        = false;
	g_bStatsApplied[client] = false;
	g_bBaseCaptured[client] = false;
	SetDefaultData(client);
}

void PromptAccount(int client)
{
	if (g_iAuth[client] == AUTH_NEED_REGISTER)
	{
		PrintToChat(client, "%s===== \x03RPG 账号\x01 =====", CHAT_PREFIX);
		PrintToChat(client, "%s你还没有 RPG 账号, 输入 \x04!register\x01 注册 (按提示输入账号和密码)", CHAT_PREFIX);
		PrintToChat(client, "%s如果已有账号, 输入 \x04!login\x01 登录", CHAT_PREFIX);
		PrintHintText(client, "还没有 RPG 账号!\n输入 !register 注册 / !login 登录");
	}
	else if (g_iAuth[client] == AUTH_NEED_LOGIN)
	{
		PrintToChat(client, "%s检测到你的账号 \x04%s\x01, 输入 \x04!login\x01 并输入密码登录", CHAT_PREFIX,
			g_sAccount[client]);
		PrintHintText(client, "账号 %s 待登录\n输入 !login 登录", g_sAccount[client]);
	}
}

void ShowWelcome(int client, bool autoLogin)
{
	char xpText[32];
	XPTextTo(xpText, sizeof(xpText), client);

	PrintToChat(client, "%s等级 \x04%d\x01 | 经验 \x03%s\x01 | 金钱 \x03$%d\x01 | 未分配点数 \x04%d\x01",
		CHAT_PREFIX, g_iLevel[client], xpText, g_iMoney[client], g_iPoints[client]);
	PrintToChat(client, "%s属性: 敏捷\x05%d\x01 力量\x05%d\x01 耐力\x05%d\x01 防御\x05%d\x01",
		CHAT_PREFIX, g_iStats[client][STAT_AGI], g_iStats[client][STAT_STR],
		g_iStats[client][STAT_STA], g_iStats[client][STAT_DEF]);
	PrintToChat(client, "%s输入 \x04!shop\x01 兑换物资, \x04!stats\x01 分配属性, \x04!help\x01 查看帮助",
		CHAT_PREFIX);

	if (g_iPoints[client] > 0)
	{
		PrintToChat(client, "%s你有 \x04%d\x01 点属性未分配, 输入 \x04!stats\x01 分配!", CHAT_PREFIX, g_iPoints[client]);
	}

	if (!autoLogin)
	{
		CreateTimer(6.0, Timer_Welcome, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_Welcome(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client < 1 || !IsClientInGame(client) || g_iAuth[client] != AUTH_LOGGED_IN)
	{
		return Plugin_Stop;
	}

	char xpText[32];
	XPTextTo(xpText, sizeof(xpText), client);
	PrintHintText(client, "等级 %d  |  XP %s  |  $%d\n输入 !shop 商店 / !stats 属性",
		g_iLevel[client], xpText, g_iMoney[client]);
	return Plugin_Stop;
}

// ==================== 账号: 聊天输入捕获 ====================
public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	if (client < 1 || client > MaxClients)
	{
		return Plugin_Continue;
	}

	int state = g_iInput[client];
	if (state == INPUT_NONE)
	{
		return Plugin_Continue;
	}

	// 以 ! 或 / 开头视为命令: 取消当前输入, 让命令正常执行
	if (sArgs[0] == '!' || sArgs[0] == '/' || sArgs[0] == '\0')
	{
		g_iInput[client] = INPUT_NONE;
		return Plugin_Continue;
	}

	HandleChatInput(client, state, sArgs);

	// 拦截消息, 避免密码出现在公共聊天框
	return Plugin_Handled;
}

void HandleChatInput(int client, int state, const char[] text)
{
	char input[128];
	strcopy(input, sizeof(input), text);
	TrimString(input);

	if (input[0] == '\0')
	{
		return;
	}

	switch (state)
	{
		case INPUT_REG_ACCOUNT:
		{
			if (!IsValidAccountName(input))
			{
				PrintToChat(client, "%s账号格式不正确: 3-16位, 只能使用字母/数字/下划线", CHAT_PREFIX);
				return;
			}
			strcopy(g_sPendingAccount[client], MAX_ACCOUNT_LEN + 1, input);
			g_iInput[client] = INPUT_REG_PASSWORD;
			PrintToChat(client, "%s账号 \x04%s\x01 可用, 请在聊天框输入 \x04密码\x01 (4-32位)", CHAT_PREFIX, input);
		}

		case INPUT_REG_PASSWORD:
		{
			if (!IsValidPassword(input))
			{
				PrintToChat(client, "%s密码格式不正确: 4-32位, 不能包含空格", CHAT_PREFIX);
				return;
			}
			g_iInput[client] = INPUT_NONE;
			DoRegister(client, g_sPendingAccount[client], input);
		}

		case INPUT_LOGIN_BOTH:
		{
			// 格式: 账号 密码
			char account[MAX_ACCOUNT_LEN + 1], passBuf[128];
			int pos = SplitString(input, " ", account, sizeof(account));
			if (pos <= 0)
			{
				PrintToChat(client, "%s格式: \x04账号 密码\x01 (中间用空格隔开)", CHAT_PREFIX);
				return;
			}
			// 先拷进大缓冲再校验, 否则超长密码会被静默截断成 32 位
			strcopy(passBuf, sizeof(passBuf), input[pos]);
			TrimString(passBuf);

			if (!IsValidAccountName(account))
			{
				PrintToChat(client, "%s账号格式不正确: 3-16位, 只能使用字母/数字/下划线", CHAT_PREFIX);
				return;
			}
			if (!IsValidPassword(passBuf))
			{
				PrintToChat(client, "%s密码格式不正确: 4-32位, 不能包含空格", CHAT_PREFIX);
				return;
			}

			g_iInput[client] = INPUT_NONE;
			DoLogin(client, account, passBuf);
		}

		case INPUT_LOGIN_PASSWORD:
		{
			g_iInput[client] = INPUT_NONE;
			// 玩家如果先输入了 "!login 账号", 用他输入的账号; 否则用 SteamID 绑定的账号
			DoLogin(client, g_sPendingAccount[client][0] ? g_sPendingAccount[client] : g_sAccount[client], input);
		}

		case INPUT_PASS_OLD:
		{
			char computed[HASH_LEN + 1];
			HashPassword(input, g_sSalt[client], computed, sizeof(computed), g_iHashRounds[client]);
			if (!StrEqual(computed, g_sPassHash[client], false))
			{
				g_iInput[client] = INPUT_NONE;
				PrintToChat(client, "%s旧密码错误, 修改密码已取消", CHAT_PREFIX);
				return;
			}
			// 旧密码校验通过即可, 不保留明文
			g_iInput[client] = INPUT_PASS_NEW;
			PrintToChat(client, "%s旧密码正确, 请输入 \x04新密码\x01 (4-32位)", CHAT_PREFIX);
		}

		case INPUT_PASS_NEW:
		{
			if (!IsValidPassword(input))
			{
				PrintToChat(client, "%s密码格式不正确: 4-32位, 不能包含空格", CHAT_PREFIX);
				return;
			}
			g_iInput[client] = INPUT_NONE;

			char salt[SALT_LEN + 1], hash[HASH_LEN + 1];
			GenerateSalt(salt, sizeof(salt));

			// 沿用该账号原本的迭代次数, 保证换密码后仍然能验证
			int rounds = g_iHashRounds[client] > 0 ? g_iHashRounds[client] : g_cvHashRounds.IntValue;
			if (rounds < 1)    rounds = 1;
			if (rounds > 1000) rounds = 1000;
			HashPassword(input, salt, hash, sizeof(hash), rounds);

			g_iHashRounds[client] = rounds;
			strcopy(g_sSalt[client], sizeof(g_sSalt[]), salt);
			strcopy(g_sPassHash[client], sizeof(g_sPassHash[]), hash);

			char acc[64], q[512];
			SQL_EscapeString(g_hDB, g_sAccount[client], acc, sizeof(acc));
			Format(q, sizeof(q),
				"UPDATE rpg_players SET salt = '%s', passhash = '%s', hash_rounds = %d WHERE account = '%s'",
				salt, hash, rounds, acc);
			SQL_TQuery(g_hDB, OnSaveDone, q, 0);

			PrintToChat(client, "%s密码修改成功, 下次登录请使用新密码", CHAT_PREFIX);
		}
	}
}

bool IsValidAccountName(const char[] name)
{
	int len = strlen(name);
	if (len < MIN_ACCOUNT_LEN || len > MAX_ACCOUNT_LEN)
	{
		return false;
	}
	for (int i = 0; i < len; i++)
	{
		char c = name[i];
		bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
		if (!ok)
		{
			return false;
		}
	}
	return true;
}

bool IsValidPassword(const char[] pass)
{
	int len = strlen(pass);
	if (len < MIN_PASSWORD_LEN || len > MAX_PASSWORD_LEN)
	{
		return false;
	}
	for (int i = 0; i < len; i++)
	{
		if (pass[i] == ' ' || pass[i] == '\t')
		{
			return false;
		}
	}
	return true;
}

// ============================================================================
//                        密码哈希 (纯 SourcePawn SHA-256)
// ============================================================================
static int SHA_ROTR(int x, int n)
{
	return (x >>> n) | (x << (32 - n));
}

void GenerateSalt(char[] buffer, int maxlen)
{
	static const char charset[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
	int len = maxlen - 1;
	if (len > SALT_LEN) len = SALT_LEN;
	if (len < 1) len = 1;

	for (int i = 0; i < len; i++)
	{
		buffer[i] = charset[GetRandomInt(0, sizeof(charset) - 2)];
	}
	buffer[len] = '\0';
}

void Sha256Hex(const char[] input, char[] output, int maxlen)
{
	int state[8];
	state[0] = 0x6a09e667;
	state[1] = 0xbb67ae85;
	state[2] = 0x3c6ef372;
	state[3] = 0xa54ff53a;
	state[4] = 0x510e527f;
	state[5] = 0x9b05688c;
	state[6] = 0x1f83d9ab;
	state[7] = 0x5be0cd19;

	static const int K[64] =
	{
		0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
		0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
		0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
		0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
		0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
		0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
		0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
		0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
	};

	int data[320];
	int msgLen = strlen(input);
	if (msgLen > 200)
	{
		msgLen = 200;
	}

	for (int i = 0; i < msgLen; i++)
	{
		data[i] = input[i] & 0xFF;
	}

	int bitLen   = msgLen * 8;
	int totalLen = msgLen + 1;
	while ((totalLen % 64) != 56)
	{
		totalLen++;
	}

	data[msgLen] = 0x80;
	for (int i = msgLen + 1; i < totalLen + 8; i++)
	{
		data[i] = 0;
	}

	// 长度字段 (64 位大端, 高 32 位在此场景恒为 0)
	data[totalLen]     = 0;
	data[totalLen + 1] = 0;
	data[totalLen + 2] = 0;
	data[totalLen + 3] = 0;
	data[totalLen + 4] = (bitLen >>> 24) & 0xFF;
	data[totalLen + 5] = (bitLen >>> 16) & 0xFF;
	data[totalLen + 6] = (bitLen >>> 8)  & 0xFF;
	data[totalLen + 7] = bitLen & 0xFF;
	totalLen += 8;

	int w[64];
	for (int block = 0; block < totalLen; block += 64)
	{
		for (int i = 0; i < 16; i++)
		{
			int o = block + i * 4;
			w[i] = (data[o] << 24) | (data[o + 1] << 16) | (data[o + 2] << 8) | data[o + 3];
		}
		for (int i = 16; i < 64; i++)
		{
			int s0 = SHA_ROTR(w[i - 15], 7) ^ SHA_ROTR(w[i - 15], 18) ^ (w[i - 15] >>> 3);
			int s1 = SHA_ROTR(w[i - 2], 17) ^ SHA_ROTR(w[i - 2], 19) ^ (w[i - 2] >>> 10);
			w[i] = w[i - 16] + s0 + w[i - 7] + s1;
		}

		int a = state[0], b = state[1], c = state[2], d = state[3];
		int e = state[4], f = state[5], g = state[6], h = state[7];

		for (int i = 0; i < 64; i++)
		{
			int S1    = SHA_ROTR(e, 6) ^ SHA_ROTR(e, 11) ^ SHA_ROTR(e, 25);
			int ch    = (e & f) ^ ((~e) & g);
			int temp1 = h + S1 + ch + K[i] + w[i];
			int S0    = SHA_ROTR(a, 2) ^ SHA_ROTR(a, 13) ^ SHA_ROTR(a, 22);
			int maj   = (a & b) ^ (a & c) ^ (b & c);
			int temp2 = S0 + maj;

			h = g;
			g = f;
			f = e;
			e = d + temp1;
			d = c;
			c = b;
			b = a;
			a = temp1 + temp2;
		}

		state[0] += a;
		state[1] += b;
		state[2] += c;
		state[3] += d;
		state[4] += e;
		state[5] += f;
		state[6] += g;
		state[7] += h;
	}

	static const char hexchars[] = "0123456789abcdef";
	int pos = 0;
	for (int i = 0; i < 8; i++)
	{
		int v = state[i];
		for (int j = 28; j >= 0; j -= 4)
		{
			if (pos >= maxlen - 1)
			{
				output[pos] = '\0';
				return;
			}
			output[pos++] = hexchars[(v >>> j) & 0xF];
		}
	}
	output[pos] = '\0';
}

void HashPassword(const char[] password, const char[] salt, char[] output, int maxlen, int rounds = 0)
{
	// rounds <= 0 时用 ConVar 的值(注册/改密码时)；验证已有账号时必须传入
	// 该账号自己存下来的轮数, 否则改一次 ConVar 全体密码就失效。
	if (rounds <= 0)
	{
		rounds = g_cvHashRounds.IntValue;
	}
	if (rounds < 1)    rounds = 1;
	if (rounds > 1000) rounds = 1000;

	char buffer[192];
	char digest[HASH_LEN + 1];

	Format(buffer, sizeof(buffer), "%s|%s", salt, password);
	Sha256Hex(buffer, digest, sizeof(digest));

	for (int i = 1; i < rounds; i++)
	{
		Format(buffer, sizeof(buffer), "%s%s", digest, salt);
		Sha256Hex(buffer, digest, sizeof(digest));
	}

	strcopy(output, maxlen, digest);
}

// ============================================================================
//                            经验 / 金钱 / 升级
// ============================================================================
int RequiredXP(int level)
{
	int need = g_cvXpBase.IntValue + (level - 1) * g_cvXpStep.IntValue;
	if (need < 1)
	{
		need = 1;
	}
	return need;
}

void XPTextTo(char[] buffer, int size, int client)
{
	if (g_iLevel[client] >= g_cvMaxLevel.IntValue)
	{
		strcopy(buffer, size, "MAX");
		return;
	}
	Format(buffer, size, "%d/%d", g_iXP[client], RequiredXP(g_iLevel[client]));
}

bool IsRPGActive(int client)
{
	return (client > 0 && client <= MaxClients && IsClientInGame(client)
		&& !IsFakeClient(client) && g_iAuth[client] == AUTH_LOGGED_IN);
}

void AddXP(int client, int amount)
{
	if (amount <= 0 || !IsRPGActive(client))
	{
		return;
	}

	int maxLevel = g_cvMaxLevel.IntValue;
	g_iTotalXP[client] += amount;

	if (g_iLevel[client] < maxLevel)
	{
		g_iXP[client] += amount;

		int levelsGained = 0;
		int guard = 0;

		// RequiredXP() 保证 >= 1, 且每轮 g_iLevel 必然 +1, 所以循环最多执行
		// (maxLevel - 当前等级) 次, 不可能死循环; guard 只是最后一道保险。
		// 原来的 guard 上限是 200 并且会静默丢弃多余经验 —— 管理员一次性发大量
		// 经验时会悄悄少给, 而且一帧内刷 200 条升级提示。
		while (g_iLevel[client] < maxLevel)
		{
			int need = RequiredXP(g_iLevel[client]);
			if (g_iXP[client] < need)
			{
				break;
			}
			if (guard++ >= 10000)
			{
				LogError("[RPG] 升级循环异常中止: client=%d level=%d xp=%d", client, g_iLevel[client], g_iXP[client]);
				break;
			}

			g_iXP[client] -= need;
			g_iLevel[client]++;
			OnLevelUp(client, false);   // 先静默结算, 提示在下面统一发
			levelsGained++;
		}

		if (levelsGained > 0)
		{
			int pts  = g_cvPointsPerLevel.IntValue;
			int cash = g_cvMoneyLevelup.IntValue;

			if (levelsGained == 1)
			{
				PrintToChat(client, "%s\x05★ 升级! \x01你现在是 \x04%d 级\x01, 获得 \x04%d\x01 属性点 + \x03$%d\x01",
					CHAT_PREFIX, g_iLevel[client], pts, cash);
				PrintHintText(client, "★ 升级到 %d 级!\n获得 %d 属性点 (输入 !stats 分配)", g_iLevel[client], pts);
			}
			else
			{
				// 连升多级只发一条汇总, 避免刷屏
				PrintToChat(client, "%s\x05★ 连升 \x04%d\x01 级! 你现在是 \x04%d 级\x01, 共获得 \x04%d\x01 属性点 + \x03$%d\x01",
					CHAT_PREFIX, levelsGained, g_iLevel[client], levelsGained * pts, levelsGained * cash);
				PrintHintText(client, "★ 连升 %d 级到 %d 级!\n共获得 %d 属性点 (输入 !stats 分配)",
					levelsGained, g_iLevel[client], levelsGained * pts);
			}
		}

		if (g_iLevel[client] >= maxLevel)
		{
			g_iXP[client] = 0;
			PrintToChat(client, "%s\x05恭喜! 你已达到最高等级 %d\x01", CHAT_PREFIX, maxLevel);
		}
	}

	g_bDirty[client] = true;
}

void AddMoney(int client, int amount)
{
	if (amount == 0 || !IsRPGActive(client))
	{
		return;
	}
	g_iMoney[client] += amount;
	if (g_iMoney[client] < 0)
	{
		g_iMoney[client] = 0;
	}
	g_bDirty[client] = true;
}

void OnLevelUp(int client, bool announce = true)
{
	int pts = g_cvPointsPerLevel.IntValue;
	int cash = g_cvMoneyLevelup.IntValue;

	g_iPoints[client] += pts;
	g_iMoney[client]  += cash;

	ApplyAllStats(client);

	// announce=false 时只结算不提示 —— 连升多级由 AddXP 统一发一条汇总,
	// 否则一次给 200 级会刷 200 条聊天。
	if (!announce)
	{
		return;
	}

	PrintToChat(client, "%s\x05★ 升级! \x01你现在是 \x04%d 级\x01, 获得 \x04%d\x01 属性点 + \x03$%d\x01",
		CHAT_PREFIX, g_iLevel[client], pts, cash);
	PrintHintText(client, "★ 升级到 %d 级!\n获得 %d 属性点 (输入 !stats 分配)", g_iLevel[client], pts);
}

// ============================================================================
//                            事件: 击杀 / 治疗 / 救人
// ============================================================================
int EntIndexToClient(int ent)
{
	if (ent <= 0)
	{
		return 0;
	}
	if (ent <= MaxClients)
	{
		if (IsClientInGame(ent) && !IsFakeClient(ent))
		{
			return ent;
		}
		return 0;
	}
	if (IsValidEntity(ent))
	{
		int owner = GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity");
		if (owner > 0 && owner <= MaxClients && IsClientInGame(owner) && !IsFakeClient(owner))
		{
			return owner;
		}
	}
	return 0;
}
// 普通感染者 / 特感(AI): 只能从 infected_hurt 拿到实体, 在 Pre 模式下判断是否致死
public Action Event_InfectedHurt(Event event, const char[] name, bool dontBroadcast)
{
	int ent = event.GetInt("entityid");
	if (ent <= 0 || !IsValidEntity(ent))
	{
		return Plugin_Continue;
	}
	// 玩家控制的特感(对抗模式)走 player_death, 这里跳过避免重复计数
	if (ent <= MaxClients)
	{
		return Plugin_Continue;
	}

	char cls[64];
	if (!GetEdictClassname(ent, cls, sizeof(cls)))
	{
		return Plugin_Continue;
	}

	int kind = -1;
	if (StrEqual(cls, "infected", false))
	{
		kind = KILL_COMMON;
	}
	else if (StrEqual(cls, "smoker", false) || StrEqual(cls, "boomer", false)
		|| StrEqual(cls, "hunter", false) || StrEqual(cls, "spitter", false)
		|| StrEqual(cls, "jockey", false) || StrEqual(cls, "charger", false))
	{
		kind = KILL_SPECIAL;
	}

	// Witch / Tank 有专门事件, 这里不处理, 避免重复计数
	if (kind == -1)
	{
		return Plugin_Continue;
	}

	// 致死判定: Pre 模式下生命值还是受伤前的
	int amount = event.GetInt("amount");
	if (amount <= 0)
	{
		return Plugin_Continue;
	}
	if (GetEntProp(ent, Prop_Data, "m_iHealth") > amount)
	{
		return Plugin_Continue;
	}

	int client = GetClientOfUserId(event.GetInt("attacker"));
	if (!IsRPGActive(client))
	{
		return Plugin_Continue;
	}

	AwardKill(client, kind);
	return Plugin_Continue;
}

public void Event_TankKilled(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("attacker"));
	if (IsRPGActive(client))
	{
		AwardKill(client, KILL_TANK);
	}
}

public void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (IsRPGActive(client))
	{
		AwardKill(client, KILL_WITCH);
	}
}

void AwardKill(int client, int kind)
{
	g_iKills[client][kind]++;
	g_bDirty[client] = true;

	switch (kind)
	{
		case KILL_COMMON:
		{
			AddXP(client, g_cvXpCommon.IntValue);
			AddMoney(client, g_cvMoneyCommon.IntValue);
		}
		case KILL_SPECIAL:
		{
			AddXP(client, g_cvXpSpecial.IntValue);
			AddMoney(client, g_cvMoneySpecial.IntValue);
		}
		case KILL_TANK:
		{
			AddXP(client, g_cvXpTank.IntValue);
			AddMoney(client, g_cvMoneyTank.IntValue);
			PrintToChat(client, "%s\x05你击杀了 Tank!\x01 \x03+%d XP  +$%d",
				CHAT_PREFIX, g_cvXpTank.IntValue, g_cvMoneyTank.IntValue);
		}
		case KILL_WITCH:
		{
			AddXP(client, g_cvXpWitch.IntValue);
			AddMoney(client, g_cvMoneyWitch.IntValue);
			PrintToChat(client, "%s\x05你击杀了 Witch!\x01 \x03+%d XP  +$%d",
				CHAT_PREFIX, g_cvXpWitch.IntValue, g_cvMoneyWitch.IntValue);
		}
	}
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim < 1 || !IsClientInGame(victim))
	{
		return;
	}

	// 3 队 = 感染者。AI 特感是假客户端, **也会**走 player_death —— 所以这里不能先
	// 过滤 IsFakeClient, 否则战役模式里打死 Hunter/Smoker/Charger 等 AI 特感
	// 永远拿不到经验金钱。(infected_hurt 只覆盖"非可玩类"的 Common Infected / Witch,
	// 特感对应的是 player_hurt, 而 player_hurt 不能可靠判断致死。)
	if (GetClientTeam(victim) == 3)
	{
		// 玩家控制的 Tank 由 tank_killed 单独结算, 这里跳过避免拿到双份经验金钱。
		// 注意: victim 是 client index, 它的 edict classname 恒为 "player",
		// 用 GetEdictClassname 判断 "tank" 是永远不成立的死代码 —— 必须读 m_zombieClass
		// (L4D2 ZC_TANK = 8)。AI Tank 同样走 tank_killed, 一并跳过。
		// 双重判定: 万一 m_zombieClass 在死亡瞬间已被清零, 再用 Tank 模型名兜底,
		// 确保 Tank 绝不会同时拿到 KILL_SPECIAL + KILL_TANK 两份奖励。
		bool isTank = (GetEntProp(victim, Prop_Send, "m_zombieClass") == 8);
		if (!isTank)
		{
			char vmodel[128];
			if (GetClientModel(victim, vmodel, sizeof(vmodel)) && StrContains(vmodel, "hulk", false) != -1)
			{
				isTank = true;
			}
		}
		if (isTank)
		{
			return;
		}

		int killer = GetClientOfUserId(event.GetInt("attacker"));
		if (killer < 1)
		{
			killer = EntIndexToClient(event.GetInt("attackerentid"));
		}
		if (IsRPGActive(killer) && GetClientTeam(killer) == 2 && killer != victim)
		{
			AwardKill(killer, KILL_SPECIAL);
		}
		return;
	}

	// 剩下的只有幸存者。假客户端(空位机器人)不统计
	if (IsFakeClient(victim))
	{
		return;
	}

	// 只统计玩家(幸存者)死亡
	if (GetClientTeam(victim) != 2)
	{
		return;
	}

	if (g_iAuth[victim] == AUTH_LOGGED_IN)
	{
		g_iDeaths[victim]++;
		g_bDirty[victim] = true;
	}
}

public void Event_HealSuccess(Event event, const char[] name, bool dontBroadcast)
{
	int healer = GetClientOfUserId(event.GetInt("userid"));
	int target = GetClientOfUserId(event.GetInt("subject"));

	if (healer < 1 || target < 1 || healer == target)
	{
		return;
	}
	if (!IsRPGActive(healer))
	{
		return;
	}

	g_iHeals[healer]++;
	AddXP(healer, g_cvXpHeal.IntValue);
	AddMoney(healer, g_cvMoneyHeal.IntValue);

	PrintToChat(healer, "%s治疗队友 \x04+%d XP\x01  \x03+$%d", CHAT_PREFIX,
		g_cvXpHeal.IntValue, g_cvMoneyHeal.IntValue);
}

public void Event_ReviveSuccess(Event event, const char[] name, bool dontBroadcast)
{
	int reviver = GetClientOfUserId(event.GetInt("userid"));
	int target  = GetClientOfUserId(event.GetInt("subject"));

	if (reviver < 1 || target < 1 || reviver == target)
	{
		return;
	}
	if (!IsRPGActive(reviver))
	{
		return;
	}

	AddXP(reviver, g_cvXpRevive.IntValue);
	AddMoney(reviver, g_cvMoneyRevive.IntValue);

	PrintToChat(reviver, "%s救起队友 \x04+%d XP\x01  \x03+$%d", CHAT_PREFIX,
		g_cvXpRevive.IntValue, g_cvMoneyRevive.IntValue);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
		{
			continue;
		}
		g_bStatsApplied[i] = false;
		CreateTimer(2.0, Timer_ApplyOne, GetClientUserId(i), TIMER_FLAG_NO_MAPCHANGE);
	}
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client < 1 || !IsClientInGame(client) || IsFakeClient(client))
	{
		return;
	}
	g_bStatsApplied[client] = false;
	CreateTimer(1.5, Timer_ApplyOne, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ApplyOne(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && IsClientInGame(client))
	{
		ApplyAllStats(client);
	}
	return Plugin_Stop;
}

// ============================================================================
//                              属性效果
// ============================================================================
void ApplyAllStats(int client)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
	{
		return;
	}

	if (g_iAuth[client] != AUTH_LOGGED_IN)
	{
		// 未登录 / 已登出: 还原默认值
		// 注意: 这个分支必须在"存活/队伍"判断之前 —— 否则玩家死亡时登出会跳过还原,
		// 而 LogoutClient 随后就把 g_bStatsApplied 置 false, 加成永远收不回来。
		// 门控用 g_bStatsApplied || g_bBaseCaptured: 换图/换队时 Event_RoundStart 会
		// 先把 g_bStatsApplied 置 false(等 1.5 秒后重算), 玩家正好在这个窗口里登出的话,
		// 只看 g_bStatsApplied 就会跳过还原, 加成留在未登录的玩家身上。
		if (g_bStatsApplied[client] || g_bBaseCaptured[client])
		{
			// 还原到"加成之前的基准值", 而不是硬编码的 1.0/100 ——
			// 硬编码会顺手抹掉其它插件设置的移速和最大生命。
			float baseSpeed = g_bBaseCaptured[client] ? g_fBaseSpeed[client] : 1.0;
			int   baseMax   = g_bBaseCaptured[client] ? g_iBaseMaxHealth[client] : 100;
			if (baseSpeed <= 0.0) baseSpeed = 1.0;
			if (baseMax < 1)      baseMax = 100;

			SetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue", baseSpeed);
			SetEntProp(client, Prop_Send, "m_iMaxHealth", baseMax);
			if (IsPlayerAlive(client) && GetClientHealth(client) > baseMax)
			{
				SetEntityHealth(client, baseMax);
			}
			g_bStatsApplied[client] = false;
			g_bBaseCaptured[client] = false;
		}
		return;
	}

	if (!IsPlayerAlive(client) || GetClientTeam(client) != 2)
	{
		return;
	}

	// 第一次应用加成时记下玩家原本的数值, 登出时才能准确还原
	if (!g_bBaseCaptured[client])
	{
		g_fBaseSpeed[client]     = GetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue");
		g_iBaseMaxHealth[client] = GetEntProp(client, Prop_Send, "m_iMaxHealth");
		if (g_fBaseSpeed[client] <= 0.0) g_fBaseSpeed[client] = 1.0;
		if (g_iBaseMaxHealth[client] < 1) g_iBaseMaxHealth[client] = 100;
		g_bBaseCaptured[client] = true;
	}

	// 敏捷 -> 移动速度 (以基准值为底)
	float speed = g_fBaseSpeed[client] * (1.0 + float(g_iStats[client][STAT_AGI]) * g_cvSpeedPerAgi.FloatValue);
	if (speed > 2.0)  speed = 2.0;
	if (speed < 0.5)  speed = 0.5;
	if (GetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue") != speed)
	{
		SetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue", speed);
	}

	// 耐力 -> 最大生命 (以基准值为底, 并且在提升上限时把当前血量一起补上)
	int newMax = g_iBaseMaxHealth[client] + RoundToNearest(float(g_iStats[client][STAT_STA]) * g_cvHpPerSta.FloatValue);
	if (newMax < g_iBaseMaxHealth[client]) newMax = g_iBaseMaxHealth[client];
	if (newMax > 1000) newMax = 1000;

	int oldMax = GetEntProp(client, Prop_Send, "m_iMaxHealth");
	if (oldMax != newMax)
	{
		SetEntProp(client, Prop_Send, "m_iMaxHealth", newMax);
		int hp = GetClientHealth(client);
		if (hp > newMax)
		{
			SetEntityHealth(client, newMax);
		}
		else if (newMax > oldMax && hp >= oldMax)
		{
			// 只有本来就是满血(hp >= 旧上限)的玩家才补差额, 否则 !logout + !login
			// 可以无限"免费回血"(登出时只把超过基准的部分压回去, 没满的部分会留着)。
			// 上限提高时把多出来的血量补给玩家(原地变肉, 不是只提高上限)
			SetEntityHealth(client, hp + (newMax - oldMax));
		}
	}

	g_bStatsApplied[client] = true;
}

public Action OnTakeDamageAlive(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	bool changed = false;

	// 防御 -> 减伤
	if (victim > 0 && victim <= MaxClients && IsRPGActive(victim) && GetClientTeam(victim) == 2)
	{
		float reduce = float(g_iStats[victim][STAT_DEF]) * g_cvDefPerPoint.FloatValue;
		float cap    = g_cvDefMax.FloatValue;
		if (reduce > cap) reduce = cap;
		if (reduce > 0.0)
		{
			damage *= (1.0 - reduce);
			changed = true;
		}
	}

	// 力量 -> 对感染者的伤害加成
	// 只在"打的确实是感染者"时生效: 要么是对抗模式里 3 队的玩家特感,
	// 要么是非玩家实体且 classname 在感染者列表里。原来只判断
	// victim > MaxClients, 会把油桶/可破坏物/其它世界实体也算成感染者。
	bool victimIsInfected = false;
	if (victim > MaxClients)
	{
		char vcls[64];
		GetEdictClassname(victim, vcls, sizeof(vcls));
		victimIsInfected = IsInfectedClassname(vcls);
	}
	else if (victim > 0)
	{
		victimIsInfected = (GetClientTeam(victim) == 3);
	}

	if (attacker > 0 && attacker <= MaxClients && attacker != victim
		&& IsRPGActive(attacker) && GetClientTeam(attacker) == 2
		&& victimIsInfected)
	{
		float bonus = float(g_iStats[attacker][STAT_STR]) * g_cvDmgPerStr.FloatValue;
		if (bonus > 0.0)
		{
			damage *= (1.0 + bonus);
			changed = true;
		}
	}

	return changed ? Plugin_Changed : Plugin_Continue;
}

// 把伤害回调挂到感染者身上, 否则"力量"属性在战役模式里永远不会生效
// (SDKHook_OnTakeDamageAlive 只在被挂的实体受伤时触发, 之前只挂了玩家)
// 判断一个实体 classname 是否是 L4D2 的感染者(含普通感染者和特殊感染者)。
// OnEntityCreated 挂伤害钩子、力量加成判定都复用这一份列表, 保持一致。
bool IsInfectedClassname(const char[] classname)
{
	if (classname[0] == '\0')
	{
		return false;
	}
	return (StrEqual(classname, "infected", false)
		|| StrEqual(classname, "smoker", false)
		|| StrEqual(classname, "boomer", false)
		|| StrEqual(classname, "hunter", false)
		|| StrEqual(classname, "spitter", false)
		|| StrEqual(classname, "jockey", false)
		|| StrEqual(classname, "charger", false)
		|| StrEqual(classname, "tank", false)
		|| StrEqual(classname, "witch", false));
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (entity <= 0 || entity <= MaxClients)
	{
		return;
	}

	if (IsInfectedClassname(classname))
	{
		SDKHook(entity, SDKHook_OnTakeDamageAlive, OnTakeDamageAlive);
	}
}

public Action Timer_ReapplyStats(Handle timer)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			ApplyAllStats(i);
		}
	}
	return Plugin_Continue;
}

// ============================================================================
//                              商店
// ============================================================================
public Action Cmd_Shop(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[RPG] 该命令只能在游戏内使用");
		return Plugin_Handled;
	}
	if (!RequireLogin(client))
	{
		return Plugin_Handled;
	}
	ShowShopMenu(client);
	return Plugin_Handled;
}

void ShowShopMenu(int client)
{
	Menu menu = new Menu(MenuHandler_Shop);
	menu.SetTitle("RPG 商店    等级 %d    金钱 $%d", g_iLevel[client], g_iMoney[client]);

	for (int i = 0; i < sizeof(g_Shop); i++)
	{
		char info[16], display[128];
		IntToString(i, info, sizeof(info));
		Format(display, sizeof(display), "[$%d] %s  (%s)", g_Shop[i].price, g_Shop[i].name,
			g_sShopCatNames[g_Shop[i].category]);
		menu.AddItem(info, display);
	}

	menu.ExitButton = true;
	// Display 失败(例如玩家正在看别的菜单/已断开)时不会触发 MenuAction_End,
	// 菜单句柄就泄漏了 —— 所以这里必须自己删。
	if (!menu.Display(client, MENU_TIME_FOREVER))
	{
		delete menu;
	}
}

public int MenuHandler_Shop(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[16];
			menu.GetItem(param2, info, sizeof(info));
			int idx = StringToInt(info);
			if (idx >= 0 && idx < sizeof(g_Shop))
			{
				BuyItem(param1, idx);
			}
			ShowShopMenu(param1);
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	return 0;
}

void BuyItem(int client, int idx)
{
	if (!IsRPGActive(client))
	{
		return;
	}

	int price = g_Shop[idx].price;
	if (g_iMoney[client] < price)
	{
		PrintToChat(client, "%s金钱不足! 需要 \x03$%d\x01, 你只有 \x03$%d\x01",
			CHAT_PREFIX, price, g_iMoney[client]);
		return;
	}

	if (!IsPlayerAlive(client))
	{
		PrintToChat(client, "%s你需要存活才能兑换该物品", CHAT_PREFIX);
		return;
	}

	bool ok = false;
	bool needsVerify = false;
	switch (g_Shop[idx].kind)
	{
		case SHOP_GIVE_ENTITY:
		{
			int giveResult = GiveItemToClient(client, g_Shop[idx].give);
			ok = (giveResult != GIVE_FAILED);
			needsVerify = (giveResult == GIVE_CHEATED);
		}
		case SHOP_GIVE_COMMAND:
		{
			ok = RefillAmmo(client);
		}
		case SHOP_HEAL:
		{
			int maxHealth = GetEntProp(client, Prop_Send, "m_iMaxHealth");
			if (maxHealth < 100)
			{
				maxHealth = 100;
			}
			SetEntityHealth(client, maxHealth);
			ok = true;
		}
		case SHOP_STATPOINT:
		{
			g_iPoints[client]++;
			ok = true;
		}
	}

	if (!ok)
	{
		PrintToChat(client, "%s兑换失败, 请稍后再试", CHAT_PREFIX);
		return;
	}

	g_iMoney[client] -= price;
	g_bDirty[client] = true;

	// 走 give 兜底时东西是异步到手的, 派个定时器事后确认, 没到手就退款
	if (needsVerify)
	{
		CreateTimer(0.8, Timer_VerifyGive, (client & 0xFF) | ((idx & 0xFF) << 8), TIMER_FLAG_NO_MAPCHANGE);
	}

	PrintToChat(client, "%s已兑换 \x04%s\x01, 花费 \x03$%d\x01, 余额 \x03$%d\x01",
		CHAT_PREFIX, g_Shop[idx].name, price, g_iMoney[client]);
}

// 返回值: GIVE_FAILED=0 失败 / GIVE_DIRECT=1 已直接发放 / GIVE_CHEATED=2 已用 give 派发 (需事后确认)
int GiveItemToClient(int client, const char[] classname)
{
	if (classname[0] == '\0')
	{
		return GIVE_FAILED;
	}

	int ent = GivePlayerItem(client, classname);
	if (ent > 0)
	{
		return GIVE_DIRECT;
	}

	// 兜底: 通过 give 指令
	if (g_cvAllowCheatCmd.BoolValue && RunClientCheatCommand(client, "give", classname))
	{
		return GIVE_CHEATED;
	}
	return GIVE_FAILED;
}

bool RefillAmmo(int client)
{
	if (g_cvAllowCheatCmd.BoolValue && RunClientCheatCommand(client, "give", "ammo"))
	{
		// give ammo 由引擎异步执行, 这里无法同步确认; 已成功派发即视为完成
		return true;
	}

	// 兜底 (未开 cheats, 或上一次提权还没还原): 直接补备用弹药和弹夹
	bool did = false;

	int weapon = GetPlayerWeaponSlot(client, 0);
	if (weapon <= 0)
	{
		weapon = GetPlayerWeaponSlot(client, 1);
	}
	if (weapon <= 0)
	{
		return false;
	}

	int ammoType = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
	if (ammoType >= 0 && ammoType < 32)
	{
		SetEntProp(client, Prop_Send, "m_iAmmo", 999, ammoType);
		did = true;
	}

	int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
	if (clip > 0)
	{
		SetEntProp(weapon, Prop_Send, "m_iClip1", clip * 2);
		did = true;
	}

	return did;
}

// 在玩家的武器列表里找某把武器。
// 返回  1 = 确认有
//       0 = 确认没有
//      -1 = 无法判定 (读不到武器列表, 此时绝不可退款)
// 为什么要区分 "确认没有" 和 "无法判定": 退错款比不退更糟 —— 东西已经到手又退了钱
// 等于白送, 会被人刷经济。所以只有在真的能枚举完武器列表、且里面确实没有时才退款。
int ClientWeaponState(int client, const char[] classname)
{
	if (classname[0] == '\0')
	{
		return -1;
	}

	char cls[64];
	int slots = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	if (slots <= 0)
	{
		// 属性不可读: 退化成武器槽位检查, 但槽位找不到不能证明"没有"
		for (int s = 0; s <= 4; s++)
		{
			int w = GetPlayerWeaponSlot(client, s);
			if (w <= 0)
			{
				continue;
			}
			GetEdictClassname(w, cls, sizeof(cls));
			if (StrEqual(cls, classname, false))
			{
				return 1;
			}
		}
		return -1;
	}

	for (int i = 0; i < slots; i++)
	{
		int w = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
		if (w <= 0)
		{
			continue;
		}
		GetEdictClassname(w, cls, sizeof(cls));
		if (StrEqual(cls, classname, false))
		{
			return 1;
		}
	}
	return 0;
}

// 兜底发放是把希望寄托在引擎的 "give" 上: 0.8 秒后回来看看东西到底有没有到手,
// 确认没到手才把钱退给玩家。这是"绝不扣了钱不给货"这条硬要求的最后一道保险。
public Action Timer_VerifyGive(Handle timer, any data)
{
	int client = data & 0xFF;
	int idx    = (data >> 8) & 0xFF;

	if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
	{
		return Plugin_Stop;
	}
	if (idx < 0 || idx >= sizeof(g_Shop))
	{
		return Plugin_Stop;
	}
	if (g_Shop[idx].kind != SHOP_GIVE_ENTITY)
	{
		return Plugin_Stop;
	}

	int state = ClientWeaponState(client, g_Shop[idx].give);
	if (state != 0)
	{
		if (state < 0)
		{
			LogError("[RPG] 无法确认物品是否发放 (%s), 保守起见不退款: account=%s",
				g_Shop[idx].give, g_sAccount[client]);
		}
		return Plugin_Stop;
	}

	// 确认没拿到东西 -> 退钱
	g_iMoney[client] += g_Shop[idx].price;
	g_bDirty[client] = true;

	PrintToChat(client, "%s\x07兑换 %s 失败 (服务器未能发放该物品), 已退还 \x03$%d\x01",
		CHAT_PREFIX, g_Shop[idx].name, g_Shop[idx].price);
	LogError("[RPG] 发放物品失败并已退款: client=%d account=%s item=%s",
		client, g_sAccount[client], g_Shop[idx].give);
	return Plugin_Stop;
}

// 返回值: 命令是否真的发出去了。调用方必须检查 —— 返回 false 时什么都没发生,
// 不能当作"已发放"处理 (否则玩家会被扣钱却拿不到东西)。
bool RunClientCheatCommand(int client, const char[] cmd, const char[] arg)
{
	if (g_cvCheats == null || cmd[0] == '\0')
	{
		return false;
	}
	// 上一次的临时提权还没还原: 跳过, 避免两个命令的标志/开关互相覆盖
	if (g_bCheatPending)
	{
		return false;
	}

	bool cheats = g_cvCheats.BoolValue;
	g_iCheatFlags = GetCommandFlags(cmd);
	strcopy(g_sCheatCmd, sizeof(g_sCheatCmd), cmd);
	g_bCheatPending = true;
	g_bCheatWasCheats = cheats;

	if (!cheats)
	{
		g_cvCheats.SetInt(1);
	}
	SetCommandFlags(cmd, g_iCheatFlags & ~FCVAR_CHEAT);
	FakeClientCommand(client, "%s %s", cmd, arg);

	// 关键: FakeClientCommand 只是把命令塞进客户端缓冲区, 要下一帧才真正执行。
	// 如果在这里立刻还原 FCVAR_CHEAT / 关掉 sv_cheats, 命令执行时就会被拒绝,
	// 于是"扣了钱却没给东西"。所以延后还原。
	//
	// 注意: 这里故意【不】加 TIMER_FLAG_NO_MAPCHANGE。换图会销毁 NO_MAPCHANGE 定时器,
	// 而这是唯一负责还原的地方 —— 于是 sv_cheats 会永久停在 1、give 永久失去
	// FCVAR_CHEAT, 任何玩家都能 noclip/god。所以定时器必须跨换图存活,
	// 并且在 OnMapEnd / OnPluginEnd 里也各兜一次底。
	CreateTimer(0.25, Timer_RestoreCheatFlags, _);
	return true;
}

// 幂等地还原临时提权。定时器到期、换图、插件卸载三条路径都会调用。
// g_bCheatPending 同时充当"我们确实改动过 sv_cheats / FCVAR_CHEAT"的标志,
// 没改动过就什么都不做 —— 绝不能把服务器原本就开着的 sv_cheats 关掉。
void RestoreCheatState()
{
	if (!g_bCheatPending)
	{
		return;
	}

	if (g_sCheatCmd[0] != '\0')
	{
		SetCommandFlags(g_sCheatCmd, g_iCheatFlags);
		g_sCheatCmd[0] = '\0';
	}
	if (!g_bCheatWasCheats && g_cvCheats != null)
	{
		g_cvCheats.SetInt(0);
	}
	g_bCheatPending = false;
}

public Action Timer_RestoreCheatFlags(Handle timer, any data)
{
	RestoreCheatState();
	return Plugin_Stop;
}

// ============================================================================
//                              属性菜单
// ============================================================================
public Action Cmd_Stats(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[RPG] 该命令只能在游戏内使用");
		return Plugin_Handled;
	}
	if (!RequireLogin(client))
	{
		return Plugin_Handled;
	}
	ShowStatsMenu(client);
	return Plugin_Handled;
}

void ShowStatsMenu(int client)
{
	Menu menu = new Menu(MenuHandler_Stats);
	menu.SetTitle("RPG 属性    可分配点数: %d    等级 %d", g_iPoints[client], g_iLevel[client]);

	for (int s = 0; s < STAT_COUNT; s++)
	{
		char info[8], display[128];
		IntToString(s, info, sizeof(info));
		Format(display, sizeof(display), "%s  [%d/%d]   (+%s)", g_sStatNames[s],
			g_iStats[client][s], g_cvStatMax.IntValue, g_sStatDescs[s]);
		menu.AddItem(info, display);
	}

	menu.ExitButton = true;
	if (!menu.Display(client, MENU_TIME_FOREVER))
	{
		delete menu;
	}
}

public int MenuHandler_Stats(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[8];
			menu.GetItem(param2, info, sizeof(info));
			SpendPoint(param1, StringToInt(info));
			ShowStatsMenu(param1);
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	return 0;
}

void SpendPoint(int client, int stat)
{
	if (!IsRPGActive(client) || stat < 0 || stat >= STAT_COUNT)
	{
		return;
	}
	if (g_iPoints[client] <= 0)
	{
		PrintToChat(client, "%s你没有可分配的属性点 (升级可获得)", CHAT_PREFIX);
		return;
	}
	if (g_iStats[client][stat] >= g_cvStatMax.IntValue)
	{
		PrintToChat(client, "%s%s 已达到上限 %d", CHAT_PREFIX, g_sStatNames[stat], g_cvStatMax.IntValue);
		return;
	}

	g_iPoints[client]--;
	g_iStats[client][stat]++;
	g_bDirty[client] = true;

	ApplyAllStats(client);

	PrintToChat(client, "%s\x04%s +1\x01  (当前 %d, 剩余点数 %d)", CHAT_PREFIX,
		g_sStatNames[stat], g_iStats[client][stat], g_iPoints[client]);
}

// ============================================================================
//                          信息 / 帮助 / 排行榜
// ============================================================================
bool RequireLogin(int client)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		return false;
	}
	if (g_iAuth[client] == AUTH_LOGGED_IN)
	{
		return true;
	}
	if (g_iAuth[client] == AUTH_LOADING)
	{
		PrintToChat(client, "%s正在读取账号数据, 请稍候...", CHAT_PREFIX);
		return false;
	}
	if (g_iAuth[client] == AUTH_NEED_REGISTER)
	{
		PrintToChat(client, "%s你还未注册, 输入 \x04!register\x01 注册账号", CHAT_PREFIX);
	}
	else
	{
		PrintToChat(client, "%s请先输入 \x04!login\x01 登录账号", CHAT_PREFIX);
	}
	return false;
}

public Action Cmd_Info(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[RPG] 该命令只能在游戏内使用");
		return Plugin_Handled;
	}
	if (!RequireLogin(client))
	{
		return Plugin_Handled;
	}

	char xpText[32];
	XPTextTo(xpText, sizeof(xpText), client);

	PrintToChat(client, "%s===== \x03RPG 个人信息\x01 =====", CHAT_PREFIX);
	PrintToChat(client, "%s账号 \x04%s\x01   等级 \x04%d\x01   经验 \x03%s\x01   总经验 %d",
		CHAT_PREFIX, g_sAccount[client], g_iLevel[client], xpText, g_iTotalXP[client]);
	PrintToChat(client, "%s金钱 \x03$%d\x01   未分配点数 \x04%d\x01   游戏时长 \x05%d 分钟",
		CHAT_PREFIX, g_iMoney[client], g_iPoints[client], g_iPlaytime[client] / 60);
	PrintToChat(client, "%s敏捷 \x05%d\x01  力量 \x05%d\x01  耐力 \x05%d\x01  防御 \x05%d\x01",
		CHAT_PREFIX, g_iStats[client][STAT_AGI], g_iStats[client][STAT_STR],
		g_iStats[client][STAT_STA], g_iStats[client][STAT_DEF]);
	PrintToChat(client, "%s击杀: 普通 \x04%d\x01  特感 \x04%d\x01  Tank \x04%d\x01  Witch \x04%d\x01  治疗 \x04%d\x01  死亡 \x04%d\x01",
		CHAT_PREFIX, g_iKills[client][KILL_COMMON], g_iKills[client][KILL_SPECIAL],
		g_iKills[client][KILL_TANK], g_iKills[client][KILL_WITCH],
		g_iHeals[client], g_iDeaths[client]);
	return Plugin_Handled;
}

public Action Cmd_Help(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[RPG] 该命令只能在游戏内使用");
		return Plugin_Handled;
	}

	PrintToChat(client, "%s===== \x03RPG 帮助\x01 =====", CHAT_PREFIX);
	PrintToChat(client, "%s\x04!register\x01 注册账号   \x04!login\x01 登录   \x04!logout\x01 退出", CHAT_PREFIX);
	PrintToChat(client, "%s\x04!passwd\x01 改密码   \x04!rpg\x01 个人信息   \x04!top\x01 排行榜", CHAT_PREFIX);
	PrintToChat(client, "%s\x04!stats\x01 分配属性点   \x04!shop\x01 兑换物资", CHAT_PREFIX);
	PrintToChat(client, "%s击杀感染者获得经验和金钱, 升级获得属性点", CHAT_PREFIX);
	return Plugin_Handled;
}

public Action Cmd_Top(int client, int args)
{
	if (!g_bDBReady)
	{
		ReplyToCommand(client, "[RPG] 数据库未就绪");
		return Plugin_Handled;
	}

	char query[256];
	Format(query, sizeof(query),
		"SELECT account, level, total_xp, money FROM rpg_players ORDER BY level DESC, total_xp DESC LIMIT 10");

	SQL_TQuery(g_hDB, OnTopResult, query, client > 0 ? GetClientUserId(client) : 0);
	return Plugin_Handled;
}

public void OnTopResult(Database db, DBResultSet results, const char[] error, any data)
{
	if (results == null)
	{
		LogError("[RPG] 排行榜查询失败: %s", error);
		return;
	}

	int client = GetClientOfUserId(data);
	bool toChat = (client > 0 && IsClientInGame(client));

	if (toChat)
	{
		PrintToChat(client, "%s===== \x03等级排行榜 TOP 10\x01 =====", CHAT_PREFIX);
	}
	else
	{
		PrintToServer("[RPG] ===== 等级排行榜 TOP 10 =====");
	}

	int rank = 0;
	while (results.FetchRow() && rank < 10)
	{
		rank++;

		char account[MAX_ACCOUNT_LEN + 1];
		results.FetchString(0, account, sizeof(account));
		int level   = results.FetchInt(1);
		int totalXp = results.FetchInt(2);
		int money   = results.FetchInt(3);

		if (toChat)
		{
			PrintToChat(client, "%s%2d. \x04%s\x01   Lv.%d   总经验 %d   $%d",
				CHAT_PREFIX, rank, account, level, totalXp, money);
		}
		else
		{
			PrintToServer("[RPG] %2d. %s  Lv.%d  总经验 %d  $%d", rank, account, level, totalXp, money);
		}
	}

	if (rank == 0)
	{
		if (toChat)
		{
			PrintToChat(client, "%s暂无排行数据", CHAT_PREFIX);
		}
		else
		{
			PrintToServer("[RPG] 暂无排行数据");
		}
	}
}

// ============================================================================
//                          账号相关命令
// ============================================================================
public Action Cmd_Register(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[RPG] 该命令只能在游戏内使用");
		return Plugin_Handled;
	}
	if (g_iAuth[client] == AUTH_LOGGED_IN)
	{
		PrintToChat(client, "%s你已经登录了 (\x04%s\x01)", CHAT_PREFIX, g_sAccount[client]);
		return Plugin_Handled;
	}
	if (IsLocked(client))
	{
		PrintToChat(client, "%s操作过于频繁, 请 %d 秒后再试", CHAT_PREFIX, GetLockUntil(client) - GetTime());
		return Plugin_Handled;
	}

	if (args >= 2)
	{
		// 用 128 字节缓冲接收, 否则超长密码会被 GetCmdArg 静默截断成 32 位
		char account[MAX_ACCOUNT_LEN + 1], passBuf[128];
		GetCmdArg(1, account, sizeof(account));
		GetCmdArg(2, passBuf, sizeof(passBuf));

		if (!IsValidAccountName(account))
		{
			PrintToChat(client, "%s账号格式不正确: 3-16位, 只能使用字母/数字/下划线", CHAT_PREFIX);
			return Plugin_Handled;
		}
		if (!IsValidPassword(passBuf))
		{
			PrintToChat(client, "%s密码格式不正确: 4-32位, 不能包含空格", CHAT_PREFIX);
			return Plugin_Handled;
		}
		PrintToChat(client, "%s\x07警告: 密码写在命令里会显示在控制台, 建议直接用 \x04!register\x01 按提示输入",
			CHAT_PREFIX);
		DoRegister(client, account, passBuf);
		return Plugin_Handled;
	}

	g_iInput[client] = INPUT_REG_ACCOUNT;
	PrintToChat(client, "%s===== \x03注册账号\x01 =====", CHAT_PREFIX);
	PrintToChat(client, "%s请在聊天框输入 \x04账号\x01 (3-16位, 字母/数字/下划线)", CHAT_PREFIX);
	PrintToChat(client, "%s输入内容不会显示给其他玩家; 输入 \x04!cancel\x01 取消", CHAT_PREFIX);
	return Plugin_Handled;
}

public Action Cmd_Login(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[RPG] 该命令只能在游戏内使用");
		return Plugin_Handled;
	}
	if (g_iAuth[client] == AUTH_LOGGED_IN)
	{
		PrintToChat(client, "%s你已经登录了 (\x04%s\x01)", CHAT_PREFIX, g_sAccount[client]);
		return Plugin_Handled;
	}
	if (IsLocked(client))
	{
		PrintToChat(client, "%s密码错误次数过多, 请 %d 秒后再试", CHAT_PREFIX, GetLockUntil(client) - GetTime());
		return Plugin_Handled;
	}

	if (args >= 2)
	{
		char account[MAX_ACCOUNT_LEN + 1], passBuf[128];
		GetCmdArg(1, account, sizeof(account));
		GetCmdArg(2, passBuf, sizeof(passBuf));
		// 直接写在命令里的密码会留在控制台历史里, 提醒一下
		PrintToChat(client, "%s提示: 密码写在命令里会留在控制台, 建议改用 \x04!login\x01 交互输入", CHAT_PREFIX);
		DoLogin(client, account, passBuf);
		return Plugin_Handled;
	}

	if (args == 1)
	{
		char account[MAX_ACCOUNT_LEN + 1];
		GetCmdArg(1, account, sizeof(account));
		if (!IsValidAccountName(account))
		{
			PrintToChat(client, "%s账号格式不正确", CHAT_PREFIX);
			return Plugin_Handled;
		}
		strcopy(g_sPendingAccount[client], MAX_ACCOUNT_LEN + 1, account);
		g_iInput[client] = INPUT_LOGIN_PASSWORD;
		PrintToChat(client, "%s账号 \x04%s\x01, 请在聊天框输入 \x04密码\x01", CHAT_PREFIX, account);
		return Plugin_Handled;
	}

	g_sPendingAccount[client][0] = '\0';
	g_iInput[client] = INPUT_LOGIN_BOTH;
	PrintToChat(client, "%s===== \x03登录账号\x01 =====", CHAT_PREFIX);
	if (g_sAccount[client][0])
	{
		PrintToChat(client, "%s检测到你的账号是 \x04%s\x01", CHAT_PREFIX, g_sAccount[client]);
	}
	PrintToChat(client, "%s请在聊天框输入 \x04账号 密码\x01 (中间用空格隔开)", CHAT_PREFIX);
	PrintToChat(client, "%s输入内容不会显示给其他玩家; 输入 \x04!cancel\x01 取消", CHAT_PREFIX);
	return Plugin_Handled;
}

public Action Cmd_Logout(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[RPG] 该命令只能在游戏内使用");
		return Plugin_Handled;
	}
	if (g_iAuth[client] != AUTH_LOGGED_IN)
	{
		PrintToChat(client, "%s你还没有登录", CHAT_PREFIX);
		return Plugin_Handled;
	}

	char account[MAX_ACCOUNT_LEN + 1];
	strcopy(account, sizeof(account), g_sAccount[client]);

	LogoutClient(client, true);
	PrintToChat(client, "%s已退出账号 \x04%s\x01, 数据已保存", CHAT_PREFIX, account);
	return Plugin_Handled;
}

public Action Cmd_Passwd(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[RPG] 该命令只能在游戏内使用");
		return Plugin_Handled;
	}
	if (!RequireLogin(client))
	{
		return Plugin_Handled;
	}

	if (args >= 2)
	{
		char oldPass[128], newPass[128];
		GetCmdArg(1, oldPass, sizeof(oldPass));
		GetCmdArg(2, newPass, sizeof(newPass));

		char computed[HASH_LEN + 1];
		HashPassword(oldPass, g_sSalt[client], computed, sizeof(computed), g_iHashRounds[client]);
		if (!StrEqual(computed, g_sPassHash[client], false))
		{
			PrintToChat(client, "%s旧密码错误", CHAT_PREFIX);
			return Plugin_Handled;
		}
		if (!IsValidPassword(newPass))
		{
			PrintToChat(client, "%s新密码格式不正确: 4-32位, 不能包含空格", CHAT_PREFIX);
			return Plugin_Handled;
		}
		ApplyNewPassword(client, newPass);
		return Plugin_Handled;
	}

	g_iInput[client] = INPUT_PASS_OLD;
	PrintToChat(client, "%s===== \x03修改密码\x01 =====", CHAT_PREFIX);
	PrintToChat(client, "%s请在聊天框输入 \x04旧密码\x01", CHAT_PREFIX);
	return Plugin_Handled;
}

void ApplyNewPassword(int client, const char[] newPass)
{
	if (g_hDB == null || !g_bDBReady || g_sAccount[client][0] == '\0')
	{
		PrintToChat(client, "%s数据库未就绪, 密码修改失败", CHAT_PREFIX);
		return;
	}

	char salt[SALT_LEN + 1], hash[HASH_LEN + 1];
	GenerateSalt(salt, sizeof(salt));

	// 沿用该账号原本的迭代次数, 保证换密码后仍然能验证
	int rounds = g_iHashRounds[client] > 0 ? g_iHashRounds[client] : g_cvHashRounds.IntValue;
	if (rounds < 1)    rounds = 1;
	if (rounds > 1000) rounds = 1000;
	HashPassword(newPass, salt, hash, sizeof(hash), rounds);

	g_iHashRounds[client] = rounds;
	strcopy(g_sSalt[client], sizeof(g_sSalt[]), salt);
	strcopy(g_sPassHash[client], sizeof(g_sPassHash[]), hash);

	char acc[64];
	SQL_EscapeString(g_hDB, g_sAccount[client], acc, sizeof(acc));

	char q[512];
	Format(q, sizeof(q),
		"UPDATE rpg_players SET salt = '%s', passhash = '%s', hash_rounds = %d WHERE account = '%s'",
		salt, hash, rounds, acc);
	SQL_TQuery(g_hDB, OnSaveDone, q, 0);

	PrintToChat(client, "%s密码修改成功, 下次登录请使用新密码", CHAT_PREFIX);
}

public Action Cmd_Cancel(int client, int args)
{
	if (client > 0 && client <= MaxClients)
	{
		g_iInput[client] = INPUT_NONE;
		g_sPendingPassword[client][0] = '\0';
		PrintToChat(client, "%s已取消当前输入", CHAT_PREFIX);
	}
	return Plugin_Handled;
}

// ============================================================================
//                          管理员命令
// ============================================================================
int ResolveTargets(int admin, const char[] pattern, int[] targets, char[] name, int nameLen)
{
	bool multiple;
	return ProcessTargetString(pattern, admin, targets, MAXPLAYERS + 1,
		COMMAND_FILTER_CONNECTED | COMMAND_FILTER_NO_BOTS, name, nameLen, multiple);
}

public Action Cmd_GiveXP(int client, int args)
{
	if (args < 2)
	{
		ReplyToCommand(client, "[RPG] 用法: sm_rpg_givexp <玩家> <数量>");
		return Plugin_Handled;
	}

	char pattern[64], num[16], tname[MAX_TARGET_LENGTH];
	GetCmdArg(1, pattern, sizeof(pattern));
	GetCmdArg(2, num, sizeof(num));

	int targets[MAXPLAYERS + 1];
	int count = ResolveTargets(client, pattern, targets, tname, sizeof(tname));
	if (count <= 0)
	{
		ReplyToCommand(client, "[RPG] 找不到目标玩家");
		return Plugin_Handled;
	}

	int amount = StringToInt(num);
	int done = 0;
	for (int i = 0; i < count; i++)
	{
		if (IsRPGActive(targets[i]))
		{
			AddXP(targets[i], amount);
			done++;
			PrintToChat(targets[i], "%s管理员给你增加了 \x04%d\x01 点经验", CHAT_PREFIX, amount);
		}
	}

	ReplyToCommand(client, "[RPG] 已为 %d 名玩家增加 %d 点经验", done, amount);
	return Plugin_Handled;
}

public Action Cmd_GiveMoney(int client, int args)
{
	if (args < 2)
	{
		ReplyToCommand(client, "[RPG] 用法: sm_rpg_givemoney <玩家> <数量>");
		return Plugin_Handled;
	}

	char pattern[64], num[16], tname[MAX_TARGET_LENGTH];
	GetCmdArg(1, pattern, sizeof(pattern));
	GetCmdArg(2, num, sizeof(num));

	int targets[MAXPLAYERS + 1];
	int count = ResolveTargets(client, pattern, targets, tname, sizeof(tname));
	if (count <= 0)
	{
		ReplyToCommand(client, "[RPG] 找不到目标玩家");
		return Plugin_Handled;
	}

	int amount = StringToInt(num);
	int done = 0;
	for (int i = 0; i < count; i++)
	{
		if (IsRPGActive(targets[i]))
		{
			AddMoney(targets[i], amount);
			done++;
			PrintToChat(targets[i], "%s管理员给你 \x03$%d\x01", CHAT_PREFIX, amount);
		}
	}

	ReplyToCommand(client, "[RPG] 已为 %d 名玩家增加 $%d", done, amount);
	return Plugin_Handled;
}

public Action Cmd_GivePoints(int client, int args)
{
	if (args < 2)
	{
		ReplyToCommand(client, "[RPG] 用法: sm_rpg_givepoints <玩家> <数量>");
		return Plugin_Handled;
	}

	char pattern[64], num[16], tname[MAX_TARGET_LENGTH];
	GetCmdArg(1, pattern, sizeof(pattern));
	GetCmdArg(2, num, sizeof(num));

	int targets[MAXPLAYERS + 1];
	int count = ResolveTargets(client, pattern, targets, tname, sizeof(tname));
	if (count <= 0)
	{
		ReplyToCommand(client, "[RPG] 找不到目标玩家");
		return Plugin_Handled;
	}

	int amount = StringToInt(num);
	int done = 0;
	for (int i = 0; i < count; i++)
	{
		if (IsRPGActive(targets[i]))
		{
			g_iPoints[targets[i]] += amount;
			if (g_iPoints[targets[i]] < 0)
			{
				g_iPoints[targets[i]] = 0;
			}
			g_bDirty[targets[i]] = true;
			done++;
			PrintToChat(targets[i], "%s管理员给你 \x04%d\x01 点属性点", CHAT_PREFIX, amount);
		}
	}

	ReplyToCommand(client, "[RPG] 已为 %d 名玩家增加 %d 属性点", done, amount);
	return Plugin_Handled;
}

public Action Cmd_Reset(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[RPG] 用法: sm_rpg_reset <玩家>");
		return Plugin_Handled;
	}

	char pattern[64], tname[MAX_TARGET_LENGTH];
	GetCmdArg(1, pattern, sizeof(pattern));

	int targets[MAXPLAYERS + 1];
	int count = ResolveTargets(client, pattern, targets, tname, sizeof(tname));
	if (count <= 0)
	{
		ReplyToCommand(client, "[RPG] 找不到目标玩家");
		return Plugin_Handled;
	}

	for (int i = 0; i < count; i++)
	{
		int target = targets[i];
		if (!IsRPGActive(target) || g_sAccount[target][0] == '\0')
		{
			continue;
		}

		if (g_hDB == null || !g_bDBReady)
		{
			ReplyToCommand(client, "[RPG] 数据库未就绪, 无法重置");
			return Plugin_Handled;
		}

		char acc[64];
		SQL_EscapeString(g_hDB, g_sAccount[target], acc, sizeof(acc));

		char q[512];
		Format(q, sizeof(q),
			"UPDATE rpg_players SET level = 1, xp = 0, total_xp = 0, money = %d, points = 0, "
			... "stat_agi = 0, stat_str = 0, stat_sta = 0, stat_def = 0, "
			... "kill_common = 0, kill_special = 0, kill_tank = 0, kill_witch = 0, "
			... "heals = 0, deaths = 0, playtime = 0 WHERE account = '%s'",
			g_cvStartMoney.IntValue, acc);
		SQL_TQuery(g_hDB, OnSaveDone, q, 0);

		// 保留 account/salt/passhash, 否则玩家会卡在"已登录但账号为空"的状态
		ResetStatsKeepAuth(target);
		g_bStatsApplied[target] = false;
		ApplyAllStats(target);

		PrintToChat(target, "%s你的 RPG 数据已被管理员重置", CHAT_PREFIX);
	}

	ReplyToCommand(client, "[RPG] 已重置 %d 名玩家的数据", count);
	return Plugin_Handled;
}

public Action Cmd_SetPass(int client, int args)
{
	if (args < 2)
	{
		ReplyToCommand(client, "[RPG] 用法: sm_rpg_setpass <玩家> <新密码>");
		return Plugin_Handled;
	}

	char pattern[64], newPass[128], tname[MAX_TARGET_LENGTH];
	GetCmdArg(1, pattern, sizeof(pattern));
	GetCmdArg(2, newPass, sizeof(newPass));

	if (!IsValidPassword(newPass))
	{
		ReplyToCommand(client, "[RPG] 新密码格式不正确: 4-32位, 不能包含空格");
		return Plugin_Handled;
	}

	int targets[MAXPLAYERS + 1];
	int count = ResolveTargets(client, pattern, targets, tname, sizeof(tname));
	if (count <= 0)
	{
		ReplyToCommand(client, "[RPG] 找不到目标玩家");
		return Plugin_Handled;
	}

	int done = 0;
	for (int i = 0; i < count; i++)
	{
		if (IsRPGActive(targets[i]))
		{
			ApplyNewPassword(targets[i], newPass);
			done++;
		}
	}

	ReplyToCommand(client, "[RPG] 已重置 %d 名玩家的密码", done);
	return Plugin_Handled;
}

public Action Cmd_Unbind(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[RPG] 用法: sm_rpg_unbind <玩家>");
		return Plugin_Handled;
	}
	if (g_hDB == null || !g_bDBReady)
	{
		ReplyToCommand(client, "[RPG] 数据库未就绪, 无法解绑");
		return Plugin_Handled;
	}

	char pattern[64], tname[MAX_TARGET_LENGTH];
	GetCmdArg(1, pattern, sizeof(pattern));

	int targets[MAXPLAYERS + 1];
	int count = ResolveTargets(client, pattern, targets, tname, sizeof(tname));
	if (count <= 0)
	{
		ReplyToCommand(client, "[RPG] 找不到目标玩家");
		return Plugin_Handled;
	}

	int done = 0;
	for (int i = 0; i < count; i++)
	{
		int target = targets[i];
		if (!IsRPGActive(target) || g_sAccount[target][0] == '\0')
		{
			continue;
		}

		char acc[64];
		SQL_EscapeString(g_hDB, g_sAccount[target], acc, sizeof(acc));

		char q[256];
		Format(q, sizeof(q), "UPDATE rpg_players SET steamid = '' WHERE account = '%s'", acc);
		SQL_TQuery(g_hDB, OnSaveDone, q, 0);

		// 同时清掉内存里的免密会话记录, 否则解绑后本机依旧能自动登录
		g_hSessions.Remove(g_sSteamID[target]);
		g_iLastSeen[target] = 0;

		PrintToChat(target, "%s你的账号已解除 SteamID 绑定, 可在其它机器登录", CHAT_PREFIX);
		done++;
	}

	ReplyToCommand(client, "[RPG] 已解绑 %d 名玩家的账号", done);
	return Plugin_Handled;
}

// ============================================================================
//                              数据保存
// ============================================================================
// 返回 true 表示这次数据确实写进了数据库(同步成功, 或异步已派发)。
// 调用方(尤其是登出)可以用它判断是否需要兜底。
bool SaveClient(int client, bool sync = false, bool clearLastSeen = false)
{
	if (client < 1 || client > MaxClients)
	{
		return false;
	}
	if (g_iAuth[client] != AUTH_LOGGED_IN || g_sAccount[client][0] == '\0')
	{
		return false;
	}
	if (!g_bDBReady || g_hDB == null)
	{
		return false;
	}

	// 累计本次在线时长
	if (g_iSessionStart[client] > 0)
	{
		int delta = GetTime() - g_iSessionStart[client];
		if (delta > 0)
		{
			g_iPlaytime[client] += delta;
		}
		g_iSessionStart[client] = GetTime();
	}

	char acc[64];
	SQL_EscapeString(g_hDB, g_sAccount[client], acc, sizeof(acc));

	// last_seen 是免密自动登录的依据。登出时要在同一条 UPDATE 里把它写成 0 ——
	// 单独再发一条 UPDATE 会和这条竞争, MySQL 多线程下完成顺序不保证。
	int stamp = clearLastSeen ? 0 : GetTime();

	// 注意: 这里**故意不写 steamid**。
	// 绑定关系只在"登录成功"(LoginSuccess)和"注册"(INSERT)时写入。
	// 如果存档也写 steamid, 管理员用 sm_rpg_unbind 把绑定清空之后,
	// 这个玩家的下一次自动保存/断线保存就会把绑定原样写回去 —— 解绑等于没做。
	char query[1024];
	Format(query, sizeof(query),
		"UPDATE rpg_players SET level = %d, xp = %d, total_xp = %d, money = %d, points = %d, "
		... "stat_agi = %d, stat_str = %d, stat_sta = %d, stat_def = %d, "
		... "kill_common = %d, kill_special = %d, kill_tank = %d, kill_witch = %d, "
		... "heals = %d, deaths = %d, playtime = %d, last_seen = %d WHERE account = '%s'",
		g_iLevel[client], g_iXP[client], g_iTotalXP[client], g_iMoney[client], g_iPoints[client],
		g_iStats[client][STAT_AGI], g_iStats[client][STAT_STR], g_iStats[client][STAT_STA],
		g_iStats[client][STAT_DEF], g_iKills[client][KILL_COMMON], g_iKills[client][KILL_SPECIAL],
		g_iKills[client][KILL_TANK], g_iKills[client][KILL_WITCH], g_iHeals[client],
		g_iDeaths[client], g_iPlaytime[client], stamp, acc);

	// 保存失败时必须保留 dirty 标记, 否则 Timer_AutoSave 永远不会重试,
	// 而玩家断线后内存副本会被清掉 —— 数据就永久丢了。
	// 做法: 派发的同时就清 dirty (这次快照已经被派出去了), 失败回调里再把 dirty 立回来。
	// 这样"保存飞行途中又打死一只僵尸"(dirty 再次置 true)不会被成功回调误清。
	if (sync)
	{
		char error[256];
		if (SQL_FastQuery(g_hDB, query))
		{
			g_bDirty[client] = false;
			g_bDBAttemptFailed = false;
			return true;
		}

		SQL_GetError(g_hDB, error, sizeof(error));
		g_bDBAttemptFailed = true;
		g_bDirty[client] = true;
		LogError("[RPG] 同步保存玩家 %s 失败: %s", g_sAccount[client], error);
		return false;
	}

	g_bDirty[client] = false;
	SQL_TQuery(g_hDB, OnSaveDone, query, GetClientUserId(client));
	return true;
}

void SaveAllClients(bool sync = false)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && g_iAuth[i] == AUTH_LOGGED_IN)
		{
			SaveClient(i, sync);
		}
	}
}

public void OnSaveDone(Database db, DBResultSet results, const char[] error, any data)
{
	if (error[0] != '\0')
	{
		g_bDBAttemptFailed = true;
		LogError("[RPG] 保存数据失败: %s", error);

		// data != 0 说明这是一次玩家存档。把 dirty 重新立起来, 让自动保存定时器重试。
		if (data != 0)
		{
			int client = GetClientOfUserId(data);
			if (client > 0 && g_iAuth[client] == AUTH_LOGGED_IN)
			{
				g_bDirty[client] = true;
			}
		}
		return;
	}

	g_bDBAttemptFailed = false;

	// 成功时**不动** dirty: 派发那一刻已经清过一次, 如果这之后玩家又有新的击杀/消费,
	// dirty 已经被重新置 true, 这里再清一次就会把那份增量丢掉。
}

public Action Timer_AutoSave(Handle timer)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && g_bDirty[i] && g_iAuth[i] == AUTH_LOGGED_IN)
		{
			SaveClient(i);
		}
	}
	return Plugin_Continue;
}

// ============================================================================
//                          HUD / 未登录提醒 / 超时踢出
// ============================================================================
int g_iHudCounter;
int g_iRemindCounter;

public Action Timer_HudTick(Handle timer)
{
	int hudInterval = RoundToNearest(g_cvHudInterval.FloatValue);
	if (hudInterval < 3)
	{
		hudInterval = 3;
	}

	int remindInterval = g_cvRemindInterval.IntValue;
	int timeout       = g_cvLoginTimeout.IntValue;

	g_iHudCounter++;
	g_iRemindCounter++;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
		{
			continue;
		}

		if (g_iAuth[i] == AUTH_LOGGED_IN)
		{
			if (g_cvHudEnabled.BoolValue && (g_iHudCounter % hudInterval) == 0)
			{
				char xpText[32];
				XPTextTo(xpText, sizeof(xpText), i);
				PrintHintText(i, "Lv.%d   XP %s   $%d   Pts %d\n!shop 商店    !stats 属性    !rpg 信息",
					g_iLevel[i], xpText, g_iMoney[i], g_iPoints[i]);
			}
			continue;
		}

		if (g_iAuth[i] == AUTH_LOADING)
		{
			// 查询回调万一没回来(数据库句柄失效等), 不能把玩家永远卡在这里
			if (g_iLoadStart[i] > 0 && (GetTime() - g_iLoadStart[i]) > 15)
			{
				LogError("[RPG] 客户端 %d 的账号读取超时, 重新尝试", i);
				g_iAuth[i]      = AUTH_NONE;
				g_iLoadStart[i] = 0;
				TryStartLoad(i);
			}
			continue;
		}

		// AUTH_NONE 是"账号读取失败"留下的状态。不重试的话玩家就卡在
		// "请先输入 !login" 上, 而 !login 又依赖已经失败的读取流程 —— 死路。
		// 这里按 l4d2_rpg_db_retry 的节奏重新发起读取。
		if (g_iAuth[i] == AUTH_NONE)
		{
			if (g_iNextLoadTry[i] > 0 && GetTime() >= g_iNextLoadTry[i])
			{
				g_iNextLoadTry[i] = GetTime() + g_cvDBRetrySeconds.IntValue;
				TryStartLoad(i);
			}
			continue;
		}

		// 未登录: 定时提醒
		if (remindInterval > 0 && (g_iRemindCounter % remindInterval) == 0)
		{
			if (g_iAuth[i] == AUTH_NEED_REGISTER)
			{
				PrintHintText(i, "你还没有 RPG 账号!\n输入 !register 注册");
			}
			else if (g_iAuth[i] == AUTH_NEED_LOGIN)
			{
				PrintHintText(i, "账号 %s 未登录\n输入 !login 登录", g_sAccount[i]);
			}
		}

		// 未登录超时踢出
		if (timeout > 0 && g_iConnectTime[i] > 0)
		{
			if ((GetTime() - g_iConnectTime[i]) > timeout)
			{
				KickClient(i, "未在 %d 秒内登录 RPG 账号", timeout);
			}
		}
	}

	if ((g_iHudCounter % 3600) == 0)
	{
		g_iHudCounter = 0;
	}
	if ((g_iRemindCounter % 3600) == 0)
	{
		g_iRemindCounter = 0;
	}

	return Plugin_Continue;
}

