# L4D2 RPG 插件 v3.0.0 (SourceMod)

《求生之路2》RPG 系统：**账号密码登录** + 经验升级 + 属性点 + 金钱 + 物资商店 + 数据库存档。

> 与旧版最大区别：**每个玩家用自己设定的 ID（账号）+ 密码登录**，而不是直接认 SteamID。
> 密码加盐 SHA-256 迭代哈希后入库，**聊天框输入的内容不会显示给其他玩家**。

---

## 一、功能一览

| 功能 | 说明 |
|------|------|
| **账号系统** | 玩家自定义账号（3-16 位）+ 密码（4-32 位），`!register` 注册、`!login` 登录、`!passwd` 改密码 |
| **密码安全** | 随机 16 位盐 + SHA-256 迭代哈希（默认 100 轮），数据库里**不存明文密码**；每账号独立记录迭代轮数 |
| **账号保护** | 账号绑定首次登录的 SteamID（防止密码泄露后被别人接管）；注册限流；连续错密码锁定 |
| 经验升级 | 击杀普通感染者 / 特感 / Tank / Witch、治疗队友、救起队友获得经验 |
| 属性点 | 每次升级获得属性点，`!stats` 菜单分配到 敏捷 / 力量 / 耐力 / 防御 |
| 金钱 | 击杀、治疗、升级获得金钱 |
| 兑换物资 | `!shop` 商店：医疗包、药、投掷物、各类武器、补满弹药、回血、买属性点 |
| 数据保存 | SQLite（默认）或 MySQL；断线 / 换图 / 关服 / 每 2 分钟自动保存 |
| 排行榜 | `!top` 查看全服等级 TOP 10 |
| 反刷号 | 密码错误次数上限 + 锁定时长（按 **SteamID** 记录，断线重连不会重置锁定）；同一账号单点登录（顶号）；注册冷却 |
| HUD | 屏幕下方常驻显示 等级 / 经验 / 金钱 / 未分配点数 |

> 本版经过**三轮**独立代码审查（登录状态机、聊天输入拦截、属性/伤害、击杀结算、商店扣款、
> 存档失败处理、菜单句柄、换图后的定时器存活），共修掉 7 个严重问题（管理员重置导致数据
> 永不落库、`sv_cheats` 可能被永久留在 1、SteamID 绑定未强制、换图后 HUD/自动保存/重连全部
> 失效、`sm_rpg_unbind` 实际无效、空 SteamID 可绕过绑定、战役里打 AI 特感完全不给经验）
> 与二十余个中低危问题，明细见文末「v3.0.0 修复清单」。
> 已确认无法离线验证的 5 点如实列在「开发者备注」里。

---

## 二、玩家命令

| 命令 | 说明 |
|------|------|
| `!register` | 注册账号（按提示在聊天框输入账号、密码，其他人看不到） |
| `!login` | 登录（按提示输入 `账号 密码`，或直接 `!login 账号 密码`） |
| `!logout` | 退出登录（数据立即保存，并清除本机的免密自动登录记录） |
| `!passwd` | 修改密码（先验证旧密码） |
| `!rpg` / `!lvl` | 查看个人信息（等级、经验、金钱、属性、击杀统计） |
| `!stats` / `!points` | 属性点分配菜单 |
| `!shop` / `!buy` | 物资商店 |
| `!top` | 等级排行榜 |
| `!help` | 帮助 |
| `!cancel` | 取消当前正在进行的输入（例如输到一半的密码） |

### 登录流程示例

```
玩家进服
  ├─ 该 SteamID 之前绑定过账号 → 提示「检测到你的账号 xxx，输入 !login 登录」
  └─ 没有账号 → 提示「输入 !register 注册」

注册：
  玩家输入 !register
  屏幕提示：请在聊天框输入账号
  玩家在聊天框打字：myaccount        ← 这条消息被插件吞掉，别人看不到
  屏幕提示：请在聊天框输入密码
  玩家在聊天框打字：mypassword       ← 同样别人看不到
  → 注册成功并自动登录
```

**登录相关的几条硬规则**

- **一个 SteamID 一个账号**：注册后账号即与当前 SteamID 绑定，别人拿你的密码
  在别的 Steam 账号上登不进来（默认开启，见 `l4d2_rpg_bind_steamid`）。
- **注册要等状态就绪**：账号数据还在从数据库读取时（或已经登录了、已有绑定账号时）
  输入 `!register` 会被拒绝，不会覆盖已有账号，也不会刷出新账号白拿初始金钱。
- **同一 SteamID 两次注册要间隔 5 秒**（`l4d2_rpg_register_cooldown`），
  防止有人循环注册刷初始钱、或用哈希计算拖慢服务器。
- **`!logout` 之后不会再自动登录**：登出会把数据库里的 `last_seen` 清零。
- **连续输错密码会锁定**，锁定按 SteamID 记录，重连/换图都不会重置。

> **为什么用聊天框而不是 `!login 账号 密码`？**
> 因为写在命令里的密码会进入服务器控制台日志和玩家自己的控制台历史。
> 聊天框输入会被插件拦截（`OnClientSayCommand` 返回 `Plugin_Handled`），消息不会广播、不会进聊天记录。
> 直接带参数的形式仍然保留（方便绑定控制台别名），但会提示风险。
>
> ⚠️ 聊天框输入的密码**不要以 `!` 或 `/` 开头**（那会被当成命令、取消输入）。
> 需要以这两个字符开头时，用 `!login 账号 密码` 形式。

---

## 三、属性系统

升级每级获得 1 点属性（可配置），`!stats` 分配，单项上限 50：

| 属性 | 效果 | 默认每点 |
|------|------|---------|
| 敏捷 | 移动速度提升 | +1.5% |
| 力量 | 对感染者伤害提升（不影响打队友） | +3% |
| 耐力 | 生命上限提升 | +3 HP |
| 防御 | 受到伤害按比例降低 | -2%，最高叠到 60% |

---

## 四、管理员命令（需要 ROOT 权限，`z` 组）

| 命令 | 说明 |
|------|------|
| `sm_rpg_givexp <玩家> <数量>` | 加经验（会自动触发升级） |
| `sm_rpg_givemoney <玩家> <数量>` | 加金钱 |
| `sm_rpg_givepoints <玩家> <数量>` | 加属性点 |
| `sm_rpg_reset <玩家>` | 重置该玩家全部数据（等级/经验/金钱/属性/统计） |
| `sm_rpg_setpass <玩家> <新密码>` | 强制重置密码（玩家忘记密码时用） |
| `sm_rpg_unbind <玩家>` | 解绑 SteamID（让该账号能在别的机器/账号上登录）。解绑后玩家需重新 `!login` 一次，账号会重新绑定到那时的 SteamID |

`<玩家>` 支持 `@all`、`@me`、`#userid`、名字片段等 SourceMod 标准目标语法。

> `sm_rpg_reset` 只清零数值（等级/经验/金钱/属性/统计），**保留账号和密码**，
> 玩家不会被踢出登录状态；重置后新的经验金钱会正常写回数据库。

---

## 五、安装

> **最省事的方式**：在本仓库的 **Releases** 页面下载 `l4d2_rpg_v3.0.0.zip`，直接解压到服务器的
> `left4dead2/` 目录（zip 的根就是 `addons/` 和 `README.md`），然后重启服务器即可。
> 下面是从源码开始的做法。

1. 服务器已装 **MetaMod:Source** + **SourceMod 1.11 或更高**。
2. 编译（本仓库已带编译好的 `scripting/l4d2_rpg.smx`，可直接用）：
   - **用仓库里的脚本**（推荐，自动找路径）：
     ```powershell
     .\build.ps1
     # 自定义路径：
     .\build.ps1 -Compiler "D:\sm\addons\sourcemod\scripting\spcomp.exe" -Include "D:\sm\addons\sourcemod\scripting\include"
     ```
   - **手动调用 spcomp**：
     ```
     spcomp.exe scripting\l4d2_rpg.sp -oscripting\l4d2_rpg.smx -i<SourceMod>\addons\sourcemod\scripting\include
     ```
     > 注意：`-o` / `-i` 要和参数**连成一个 token**（中间不留空格），这是 SourcePawn 编译器的要求。
3. 把 `scripting/l4d2_rpg.smx` 放到服务器的 `addons/sourcemod/plugins/`。
4. 重启服务器，或控制台执行 `sm plugins load l4d2_rpg`。
5. 首次运行自动生成 `cfg/sourcemod/l4d2_rpg.cfg`。

> 插件只支持 Left 4 Dead 2，其它引擎会拒绝加载。

### 仓库目录结构

```
l4d2_rpg/
├── README.md
├── build.ps1                            # 一键编译脚本
└── scripting/
    ├── l4d2_rpg.sp                      # 完整源码（约 3700 行）
    └── l4d2_rpg.smx                     # 已编译插件（SourceMod 1.11）
```

### 服务器上的运行目录结构

```
addons/sourcemod/
├── plugins/l4d2_rpg.smx
├── scripting/l4d2_rpg.sp
├── cfg/sourcemod/l4d2_rpg.cfg          # 首次运行自动生成
└── data/sqlite/l4d2_rpg.sq3            # SQLite 存档（自动创建）
```

---

## 六、数据库

### 默认：SQLite（零配置）

不需要任何配置，插件自动在 `addons/sourcemod/data/sqlite/l4d2_rpg.sq3` 建库建表。

### 可选：MySQL（多服共享数据）

在 `addons/sourcemod/configs/databases.cfg` 里加一段**名为 `l4d2_rpg`** 的条目：

```ini
"Databases"
{
	"l4d2_rpg"
	{
		"driver"			"mysql"
		"host"				"127.0.0.1"
		"database"			"l4d2_rpg"
		"user"				"l4d2"
		"pass"				"你的密码"
		//"timeout"			"60"
		//"port"			"3306"
	}
}
```

插件检测到这个条目就会自动改用 MySQL（表也会自动建）。

### 表结构 `rpg_players`

| 字段 | 类型 | 说明 |
|------|------|------|
| `account` | TEXT/VARCHAR(32) **主键** | 玩家账号 |
| `steamid` | TEXT | 绑定的 SteamID64（用于免密自动登录；登录时会校验，见下） |
| `salt` | TEXT | 随机盐 |
| `passhash` | TEXT | 加盐迭代 SHA-256 结果（64 位十六进制） |
| `hash_rounds` | INT | 该账号自己的哈希迭代次数（改 `l4d2_rpg_hash_rounds` 不会让已注册账号失效） |
| `level` / `xp` / `total_xp` | INT | 等级 / 当前经验 / 总经验 |
| `money` / `points` | INT | 金钱 / 未分配属性点 |
| `stat_agi` / `stat_str` / `stat_sta` / `stat_def` | INT | 四维属性 |
| `kill_common` / `kill_special` / `kill_tank` / `kill_witch` | INT | 击杀统计 |
| `heals` / `deaths` / `playtime` | INT | 治疗次数 / 死亡次数 / 在线秒数 |
| `created_at` / `last_seen` | INT | 注册时间 / 最后在线时间（Unix 时间戳） |

> **升级兼容**：插件启动时会自动检测并补齐旧版本缺少的列（`last_seen`、
> `created_at`、`hash_rounds`），所以从旧版直接覆盖升级不会丢数据、也不会
> 因为缺列导致所有人登录失败。补列失败时插件会拒绝进入"就绪"状态并每 30
> 秒重试，而不是带着残缺的表继续跑。

> **SteamID 绑定**：默认开启（`l4d2_rpg_bind_steamid 1`）。账号首次登录后即
> 绑定该 SteamID，之后只有同一个 SteamID 能登录该账号 —— 这样即使密码泄露，
> 别人也无法用自己的 Steam 账号登进来接管你的角色（并且拿不到免密自动登录）。
> 玩家换机器/换 Steam 账号时，由管理员执行 `sm_rpg_unbind <玩家>` 解绑，
> 或把 `l4d2_rpg_bind_steamid` 设为 `0` 关闭该限制。

---

## 七、ConVar 配置（`cfg/sourcemod/l4d2_rpg.cfg`）

### 经验与金钱

| ConVar | 默认 | 说明 |
|--------|------|------|
| `l4d2_rpg_xp_common` | 5 | 击杀普通感染者经验 |
| `l4d2_rpg_xp_special` | 50 | 击杀特感经验 |
| `l4d2_rpg_xp_tank` | 300 | 击杀 Tank 经验 |
| `l4d2_rpg_xp_witch` | 200 | 击杀 Witch 经验 |
| `l4d2_rpg_xp_heal` | 30 | 治疗队友经验 |
| `l4d2_rpg_xp_revive` | 40 | 救起队友经验 |
| `l4d2_rpg_money_common` | 15 | 击杀普通感染者金钱 |
| `l4d2_rpg_money_special` | 80 | 击杀特感金钱 |
| `l4d2_rpg_money_tank` | 300 | 击杀 Tank 金钱 |
| `l4d2_rpg_money_witch` | 200 | 击杀 Witch 金钱 |
| `l4d2_rpg_money_heal` | 50 | 治疗队友金钱 |
| `l4d2_rpg_money_revive` | 60 | 救起队友金钱 |
| `l4d2_rpg_money_levelup` | 500 | 每次升级奖励金钱 |
| `l4d2_rpg_start_money` | 500 | 新账号初始金钱 |

### 升级曲线

| ConVar | 默认 | 说明 |
|--------|------|------|
| `l4d2_rpg_xp_base` | 100 | 1 级升 2 级所需经验 |
| `l4d2_rpg_xp_step` | 50 | 每级递增（n 级需要 `base + (n-1)*step`） |
| `l4d2_rpg_max_level` | 100 | 最高等级 |
| `l4d2_rpg_points_per_level` | 1 | 每次升级给几点属性 |

### 属性效果

| ConVar | 默认 | 说明 |
|--------|------|------|
| `l4d2_rpg_speed_per_agi` | 0.015 | 每点敏捷移速加成 |
| `l4d2_rpg_dmg_per_str` | 0.03 | 每点力量伤害加成 |
| `l4d2_rpg_hp_per_sta` | 3 | 每点耐力生命加成 |
| `l4d2_rpg_def_per_point` | 0.02 | 每点防御减伤 |
| `l4d2_rpg_def_max` | 0.60 | 减伤上限 |
| `l4d2_rpg_stat_max` | 50 | 单项属性上限 |

### 账号与安全

| ConVar | 默认 | 说明 |
|--------|------|------|
| `l4d2_rpg_session_minutes` | 30 | 免密自动登录的记忆时长（分钟，0 = 每次都要输密码）。时间戳存在数据库 `last_seen` 字段里，所以**换图、重连都不会丢失**；主动输入 `!logout` 会把 `last_seen` 清零，登出后不会再自动登录 |
| `l4d2_rpg_max_attempts` | 5 | 连续输错几次密码后锁定 |
| `l4d2_rpg_lock_seconds` | 300 | 锁定时长（秒） |
| `l4d2_rpg_single_session` | 1 | 同账号只允许一个玩家在线（1=是，顶号） |
| `l4d2_rpg_hash_rounds` | 100 | 新账号的密码哈希迭代次数（越高越安全也越慢，1-1000）。**只影响此后新注册/改密的账号**，已注册账号用自己存下来的轮数验证 |
| `l4d2_rpg_bind_steamid` | 1 | 账号是否绑定首次登录的 SteamID（1=绑定，别人拿到密码也登不进去；换机器需管理员 `sm_rpg_unbind`） |
| `l4d2_rpg_register_cooldown` | 5 | 同一 SteamID 两次 `!register` 之间至少间隔多少秒（防注册刷初始钱 / 防刷哈希卡服） |
| `l4d2_rpg_db_retry` | 15 | 账号数据读取失败后自动重试的间隔（秒，最小 5） |
| `l4d2_rpg_login_timeout` | 0 | 未登录多少秒后踢出（0 = 不踢） |
| `l4d2_rpg_remind_interval` | 60 | 未登录提醒间隔（秒，0 = 关闭） |

### 显示

| ConVar | 默认 | 说明 |
|--------|------|------|
| `l4d2_rpg_hud` | 1 | 是否显示 HUD |
| `l4d2_rpg_hud_interval` | 10.0 | HUD 刷新间隔（秒） |
| `l4d2_rpg_allow_cheat_cmd` | 1 | 允许插件临时提权执行 `give`（补满弹药 / 兜底发武器） |

---

## 八、商店价格

改源码里的 `g_Shop[]` 数组即可增删商品（`key / 显示名 / classname / 价格 / 分类 / 发放方式`）。

| 分类 | 商品 |
|------|------|
| 消耗品 | 急救包 $1500、止痛药 $800、肾上腺素 $1000、燃烧瓶 $1200、土制炸弹 $1200、胆汁瓶 $1200、除颤器 $2500 |
| 武器 | 消音冲锋枪 $3000、木制霰弹枪 $3200、Chrome 霰弹枪 $3500、猎枪 $3000、AK-47 $5000、M4 $5000、战斗步枪 $5200、战术霰弹枪 $5500、军用狙击 $6000、AWP $7000、M60 $8000、榴弹发射器 $9000 |
| 补给 | 补满弹药 $500、回满生命 $800、购买属性点 $1000 |

---

## 九、常见问题

**Q：玩家不想注册，能不能直接用 SteamID？**
A：可以。`l4d2_rpg_session_minutes` 设成 0 就是每次都要输密码；把它设大（比如 10080 = 7 天）就是同 SteamID 免密自动登录。
但首次仍然需要注册一次账号。

**Q：玩家忘记密码怎么办？**
A：管理员用 `sm_rpg_setpass <玩家> <新密码>` 直接重置。

**Q：玩家换号了 / 想在新电脑上玩？**
A：账号绑定了首次登录的 SteamID（`l4d2_rpg_bind_steamid` 默认 1），所以换 Steam 账号后
需要在服务器上让管理员执行 `sm_rpg_unbind <玩家>` 解绑，之后用 `!login 账号 密码` 登录，
账号会重新绑定到新 SteamID。只是换电脑、Steam 账号没变的话不受影响。
如果把 `l4d2_rpg_bind_steamid` 设成 `0`，则任何 SteamID 都能用密码登录该账号（不推荐）。

**Q：改了 `l4d2_rpg_hash_rounds` 会让老账号登不上吗？**
A：不会。每个账号注册/改密时用的轮数会存进 `hash_rounds` 字段，验证时用该账号自己的
轮数。这个 ConVar 只影响**之后**新注册或改密的账号。
> 唯一的例外：从**本版之前的旧版本**升级上来的账号，`hash_rounds` 补列后是 `0`，
> 插件会退回"用当前 ConVar 值验证"。所以升级后请**保持 `l4d2_rpg_hash_rounds`
> 不变**（旧版默认也是 100），等玩家改过密码后就会写入各自的轮数。若你之前在旧版
> 把该 ConVar 改成了别的值，升级后请继续保持那个值。

**Q：经验/金钱不发？**
A：确认已登录（`!rpg` 能显示信息）、在幸存者队伍（队伍 2）、存活状态。
未登录玩家不会获得任何经验金钱，这是设计如此。

**Q：买武器没反应？**
A：必须存活才能购买。补满弹药依赖 `give ammo`，插件会临时提权执行再还原 `sv_cheats`；
派发后 0.8 秒会复查背包，没拿到会自动退款。

**Q：换图数据会丢吗？**
A：不会。换图 / 关服 / 断线都会保存；另外每 2 分钟自动保存有变更的玩家。
单次保存失败时插件会保留待保存标记并在下一轮自动保存重试。

**Q：SQLite 和 MySQL 能混用吗？**
A：不能直接迁移，但都是同一张 `rpg_players` 表，可以用工具导出导入。

**Q：密码到底怎么存的？**
A：`passhash = SHA256( SHA256(salt|password) 再迭代 (rounds-1) 次 "digest|salt" )`，
`salt` 是每人独立的 16 位随机字符串。数据库泄露也无法直接还原明文密码。

> ⚠️ 诚实的强度说明：这是**防君子不防小人**的强度。
> 盐用的是 SourceMod 的 `GetRandomInt`（不是密码学随机源），迭代次数默认 100（SourcePawn 跑纯软件
> SHA-256 很慢，调太高会卡服）。防得住彩虹表和顺手翻数据库的人，
> **防不住**已经拿到数据库、又愿意对单个目标做定向暴力破解的人。
> 如果玩家的密码和 Steam 账号密码一样，请提醒他这是游戏插件、不要复用重要密码。
> 真要更强，把 `l4d2_rpg_hash_rounds` 调到 500~1000（登录会明显变慢）。

**Q：多人共用一个账号？**
A：默认禁止（`l4d2_rpg_single_session 1`），后登录的会把前一个顶下线。

---

## 十、开发者备注

- 事件钩子：`infected_hurt`（Pre 模式，用 `m_iHealth <= amount` 判定致死，统计**普通感染者**击杀）、
  `tank_killed`、`witch_killed`、`player_death`（特感击杀，**AI 特感与对抗模式玩家特感都走这里**）、
  `heal_success`、`revive_success`。
  为什么特感不用 `infected_hurt`：按官方事件文档，`infected_hurt` 只对"非可玩类"
  （Common Infected / Witch）触发，特感属于"可玩类"，其伤害走 `player_hurt`；而 AI 特感
  是假客户端、会正常触发 `player_death`，所以击杀统一在 `player_death` 里按 3 队 + `attacker` 统计。
  `tank_killed` 的击杀者字段是 `attacker`、`witch_killed` 的击杀者字段是 `userid`（已按官方文档核对）。
- SourceMod 1.11 **没有** 内置 MD5/SHA 原生函数，所以 `Sha256Hex()` 是纯 SourcePawn 实现
  （已用空串 / 55 / 56 / 64 / 200 字节边界用例对齐 `hashlib.sha256` 验证）。
- 属性生效靠 `m_flLaggedMovementValue`（移速）、`m_iMaxHealth`（血量）、
  `SDKHook_OnTakeDamageAlive`（减伤 / 增伤），每 5 秒重挂一次防止被游戏逻辑覆盖。
- 应用加成前会记下玩家原本的移速/最大生命作为**基准值**，登出时还原到基准值而不是
  硬编码的 `1.0/100`，避免覆盖其它插件的设置；耐力提升上限时会把当前血量一并补上。
- 力量增伤只对 `infected/smoker/boomer/hunter/spitter/jockey/charger/tank/witch`
  这 9 类感染者实体生效（对抗模式里 3 队的玩家特感也算），不会把油桶、可破坏物
  等世界实体算成感染者。
- 商店发物品有两条路径：直接 `GivePlayerItem`，或临时提权执行 `give`。临时提权会在
  0.25 秒后（以及换图 / 插件卸载时）无条件还原 `sv_cheats` 与命令的 `FCVAR_CHEAT`，
  绝不会把服务器留在 `sv_cheats 1` 的状态。
- 买东西只在**确实发到手**时才扣钱：提权派发后 0.8 秒复查背包，确认没拿到就退款
  （无法判定时不退款 —— 退错款等于白送，会被刷经济）。
- 存档失败不会静默丢数据：`UPDATE` 的错误回调里会把 dirty 标记重新立起来，等下一次
  自动保存重试；玩家断开时若数据库曾经出过错就走异步保存，避免主线程被连接超时卡死。
- 登录失败次数与锁定**按 SteamID 记录**，换图/断线重连都不会重置。
- 插件的 `OnPluginEnd` 与 `OnMapEnd` 都会兜底还原 `sv_cheats`，并给所有在线玩家补一次保存。

### 需在实机上确认的几点（无法离线验证，如实列出）

1. **`infected_hurt` 钩子读取的血量时机**：代码用 `GetEntProp(ent, Prop_Data, "m_iHealth") <= amount`
   判定"这一击是否致死"，前提是 Pre 钩子里读到的是**受伤前**血量（社区通行写法）。
   若某些版本读到的是受伤后血量，低血量感染者被非致命一击时也会多算一次击杀。
   *验证方法*：手枪打一只 50 HP 的普通感染者（单发 10 伤害），看第一枪是否就给了击杀经验。
2. **伤害被其它插件拦截时仍会发经验**：`infected_hurt` 是 Pre 钩子，给经验时还不知道
   这一击最终是否生效。装了其它改伤害的插件时可能出现"打了没过伤也加经验"。
3. **控制台里的密码**：`sm_login <账号> <密码>` / `sm_rpg_setpass <玩家> <密码>` 的参数
   可能被 SourceMod 写进 `addons/sourcemod/logs/`。插件已提示玩家改用 `!login` 交互输入，
   但管理员使用 `sm_rpg_setpass` 时请自行注意。
4. **MySQL 并发保存**：同一玩家的两条异步保存理论上可能乱序完成。插件已把"登出清零
   `last_seen`"合并进同一条 `UPDATE`（而不是另发一条），避免最要紧的那一次被覆盖。
5. **AI 特感击杀依赖 `player_death`**：按官方文档 AI 特感是假客户端、会触发 `player_death`，
   插件据此统计特感击杀（Tank 除外，走 `tank_killed`）。
   *验证方法*：战役模式里用控制台 `z_spawn hunter` 生成一只 AI Hunter 打死，看是否 +50 XP。
   若某个版本不触发，可再把 `infected_hurt` 的特感分支打开（代码里保留着，默认被
   `ent <= MaxClients` 跳过）。

---

## 十一、v3.0.0 修复清单

三个独立的审查代理对该文件做了全量对抗式审查（第二、第三个还复核了前一轮的修复本身），
随后修掉了下列问题。带 ★ 的是会导致数据丢失、安全被绕过或功能整体失效的严重项。

### 严重

| # | 问题 | 修复 |
|---|------|------|
| ★1 | `sm_rpg_reset` 调用 `SetDefaultData()` 清空了内存里的账号，但登录状态仍是"已登录"，导致此后该玩家的经验/金钱**永远不再写回数据库**，改密码也变成改了个空账号 | 新增 `ResetStatsKeepAuth()`，只清数值、保留 account/salt/passhash；并补上数据库就绪与空账号守卫 |
| ★2 | 临时提权执行 `give` 的还原定时器带 `TIMER_FLAG_NO_MAPCHANGE`，换图时被销毁 → `sv_cheats` 永久停在 `1`、`give` 永久失去 `FCVAR_CHEAT`，任何玩家都能 noclip/god | 定时器去掉该标志、缩短到 0.25 秒；抽出幂等的 `RestoreCheatState()`，在定时器 / `OnMapEnd` / `OnPluginEnd` 三条路径都会还原 |
| ★3 | 登录只按账号查询、从不校验 SteamID，密码泄露一次即可被永久接管（攻击者还会拿到免密自动登录） | 新增 `l4d2_rpg_bind_steamid`（默认开启），登录时校验该行的 `steamid`，不匹配则拒绝并提示管理员 `sm_rpg_unbind` |
| ★4 | 数据库表只有 `CREATE TABLE IF NOT EXISTS`，从旧版升级时缺少 `last_seen` 等列 → 读取账号报错 → 全服玩家无法登录 | 新增 `EnsureColumn()` 自动探测并 `ALTER TABLE` 补列；补列失败则拒绝进入"就绪"状态并每 30 秒重试 |

### 中等

| # | 问题 | 修复 |
|---|------|------|
| 5 | `!logout` 写入新的 `last_seen`，登出后 30 分钟内重连会被自动登录回来 | 登出时在同一条 `UPDATE` 里把 `last_seen` 写成 0 |
| 6 | 存档 `UPDATE` 一发出就清 `dirty`，失败后永不重试；玩家断开又清掉内存副本 → 数据永久丢失 | 异步保存把 userid 传进回调，只有回调确认成功才清 `dirty`；失败则重新立起标记等待重试 |
| 7 | 对抗模式里玩家操控的 Tank 被击杀会同时结算 KILL_SPECIAL 与 KILL_TANK（双份经验金钱） | `GetEdictClassname` 死代码改为读 `m_zombieClass == 8`（ZC_TANK） |
| 8 | 处于"已绑定账号"状态的玩家可以反复 `!register` 建新号，每次都白拿初始金钱 | 只有状态为 `AUTH_NEED_REGISTER` 时才允许注册，其余状态给出明确提示 |
| 9 | 注册路径的哈希运算是同步的且没有限流，循环 `!register` 可拖慢服务器主线程 | 新增 `l4d2_rpg_register_cooldown`（默认 5 秒，按 SteamID 计） |
| 10 | 改 `l4d2_rpg_hash_rounds` 会让所有已注册账号的密码失效 | 新增 `hash_rounds` 列，按账号存自己的轮数 |
| 11 | 两次快速 `!login` 会让先发的异步查询用后一个密码去校验，误判密码错误并浪费一次机会 | 新增 `g_bLoginPending`，上一次校验未回来时拒绝新的登录请求 |
| 12 | 账号数据读取失败后进入 `AUTH_NONE`，而重试逻辑只覆盖 `AUTH_LOADING` → 玩家卡死 | 新增 `l4d2_rpg_db_retry`（默认 15 秒），HUD 定时器自动重试读取 |
| 13 | 登出还原属性时把移速/血量硬写成 `1.0/100`，会覆盖其它插件的设置 | 应用加成前捕获基准值，还原到基准值；耐力提升上限时同时补当前血量 |
| 14 | 购物扣了钱却没拿到东西（提权指令下一帧才执行，还原动作却已生效） | 提权派发后 0.8 秒复查背包，未到手自动退款；无法判定时不退款（避免被刷经济） |

### 轻微

| # | 问题 | 修复 |
|---|------|------|
| 15 | `Menu.Display` 失败时不会触发 `MenuAction_End`，菜单句柄泄漏 | 检查 `Display` 返回值，失败即 `delete menu` |
| 16 | 管理员一次给大量经验时，升级循环的 `guard < 200` 会静默丢弃多余经验，并刷 200 条升级提示 | 循环改为由"经验不足"自然终止（上限 10000 并记日志），连升多级只发一条汇总 |
| 17 | 力量增伤把油桶、可破坏物等世界实体也算作感染者 | 抽出 `IsInfectedClassname()`，只对 9 类感染者实体生效 |
| 18 | 数据库未就绪时 `sm_rpg_setpass` / `sm_rpg_reset` / `sm_rpg_unbind` 会触发 SQL native 报错 | 三处都补上就绪检查 |
| 19 | 玩家 Tank 被击杀的判定用了无效的 `GetEdictClassname` 写法 | 同上第 7 条 |
| 20 | `sm_login <账号> <密码>` 把密码写进控制台却没有提醒 | 补上与 `!register` 相同的风险提示 |

### 第三轮（换图后大面积失效 / 账号可被接管）

第三个审查代理专门复核了上面这些修复本身，又找出 4 个高危问题（其中第 21 条影响最大）。

| # | 问题 | 修复 |
|---|------|------|
| ★21 | 4 个全局循环定时器（HUD、自动保存、属性重算、数据库重连）都带了 `TIMER_FLAG_NO_MAPCHANGE`。该标志的含义是**换图时销毁定时器**，而插件在换图时并不重新加载 → **第一次换图之后** HUD 不再刷新、自动保存不再执行、属性不再重算、账号读取失败不再重试、数据库断线不再重连，且没有任何报错 | 四个定时器全部去掉该标志（只留 `TIMER_REPEAT`），让它们跨换图持续运行 |
| ★22 | `sm_rpg_unbind` 实际无效：它只把 `steamid` 置空，但下一次自动保存/断线保存的 `UPDATE` 里又带着 `steamid`，于是绑定被原样写回，`last_seen` 也被写回 → 免密自动登录复活 | 存档的 `UPDATE` 不再写 `steamid`（绑定只在注册与登录成功时写入） |
| ★23 | 本机取不到 SteamID 时，登录的绑定校验被整块跳过，而登录成功又会无条件写 `steamid` → 拿到密码的人可以用"无 SteamID 客户端"把别人的绑定抹成空串，等于绕过 ★3 | 开启绑定时若拿不到自己的 SteamID 直接拒绝登录；登录成功时只有 SteamID 非空才写 `steamid` |
| ★24 | 登录校验的在途标志 `g_bLoginPending` 在"已经登录了"的早退分支里没有清除。进服自动读取与手动 `!login` 撞在一起时该标志永久为真 → `!logout` 之后再也不能 `!login`，只能重连 | 早退分支与登出路径都清除该标志 |
| 25 | 登出时的异步保存失败既不重试也不清 `last_seen`（回调要求"已登录"状态，此时已经切走） | `SaveClient()` 改为返回是否成功；登出改走**同步**保存，失败则再补发一条只清 `last_seen` 的 `UPDATE` |
| 26 | 存档成功后回调里无条件清 `dirty`，把"保存飞行途中新产生的经验"一起抹掉 | `dirty` 改为在**派发**时清、同步保存失败时重新立起，成功回调不再动它 |
| 27 | 换图/换队后 `g_bStatsApplied` 还是 false，玩家在这 1.5~2 秒窗口内登出，加成不会被还原 | 还原分支的门控改为 `g_bStatsApplied || g_bBaseCaptured` |
| 28 | `!logout` 后 `!login` 可以无限免费回血（耐力提升上限时无条件补当前血量） | 只有原本满血（`hp >= 原上限`）的玩家才补差额 |
| 29 | **战役模式打死 AI 特感完全没有经验金钱**：`infected_hurt` 只覆盖普通感染者/Witch，特感走 `player_hurt`；而 `player_death` 开头又把假客户端（AI 特感）过滤掉了 → 两条路都不通 | `player_death` 先按"3 队感染者"处理（含 AI 特感），再过滤假客户端；Tank 用 `m_zombieClass == 8` **加**模型名 `hulk` 双重判定，确保不双计 |
