# kr6-trainer

Kingdom Rush Genesis 的游戏内修改器。

## 下载

**[→ 点这里下载最新版本](https://github.com/LOVEIII486/kr6-genesis-trainer/releases/latest)**

Windows 下载 `kr6-trainer-*-release.zip`、macOS 下载 `kr6-trainer-*-mac.zip`
（推荐，不需要额外装 Python）。装法见下面「安装」。

> **完全免费。** 作者：B站 **LOVEIII486**。只在 B站和 GitHub 发布，从未授权任何人售卖 ——
> **如果你花钱买到了它，说明你被骗了。**

## 环境需求

- Windows **或** macOS（游戏在两个平台上都有 Steam 版）
- **可选**：Python 3（用命令行安装脚本时需要；纯标准库，无第三方依赖）

## 能改什么

全部在游戏内菜单里（按 **`Home`**）：关卡内数值：金币、生命、无限金钱、**击杀金币倍率**、下一波；**游戏速度（x0.5 慢放 – x4 加速，整局一起快）**；**敌人血量 / 移速倍率**；**防御塔四项倍率（伤害 / 攻速 / 射程 / 技能CD）**；**英雄四项倍率（血量 / 伤害 / 攻速 / 技能CD）+ 当场升级 + 解锁满级成就**；**技能无CD（法术 / 英雄 / 塔）**；**存档：星星拉满 / 升级树补全 / 法术补满**。

## 安装

### 方式一：双击安装（推荐，不需要 Python）

下载 **`kr6-trainer-*-release.zip`**，解压到**游戏安装目录**
（和 `Kingdom Rush Genesis.exe` 同一层），然后**双击 `install.bat`**。
卸载是双击 `uninstall.bat`。

> 解压时**整个 `kr6-trainer` 文件夹扔进游戏目录**、或者**只把里面的文件倒进去**都行 ——

```
kr6-trainer\
├─ 使用说明.txt            ← 玩家看的（安装位置 / 操作 / 备份提醒）
├─ install.bat            ← 双击这个
├─ uninstall.bat
├─ install.ps1
├─ uninstall.ps1
└─ mod\                   ← 要装进存档目录的两个文件
```

> **关于 `install.bat` 里的 `-ExecutionPolicy Bypass`**：默认 Windows 禁止运行
> PowerShell 脚本，不加这个标志双击会报"禁止运行脚本"。它**只对这一次调用生效**，
> 不改系统设置。`install.ps1` 是纯文本，可以直接读。

### macOS

下载 **`kr6-trainer-*-mac.zip`**，解压到**游戏安装目录**
（`Steam → 库 → 右键 Kingdom Rush 6: Genesis → 管理 → 浏览本地文件`，
macOS 上打开的是 `Kingdom Rush Genesis.app` 所在的目录）。然后：

- **双击 `Install.command`**（如果第一次双击提示"无法打开"，在终端里跑一次
  `python3 install.py` 即可，同样是全自动找游戏），或者
- 在终端里 `cd` 到解压目录跑 `python3 install.py`

卸载：双击 `Uninstall.command`，或 `python3 uninstall.py`。

macOS 的模组文件装在存档目录（**不会改游戏本身**）：
`~/Library/Application Support/kingdom_rush_genesis/`（Steam 云同步的也是这里）。

### 方式二：装了 Python 的话

clone 本仓库，在仓库目录里跑：

```bash
python install.py        # 自动找游戏（从脚本位置逐级向上找）
```

找不到就指定，或先看会做什么：

```bash
python install.py --game-dir "D:\Game\Steam\steamapps\common\Kingdom Rush Genesis"
python install.py --dry-run
```

### ⚠️ 游戏更新之后要重装一次

**游戏一更新，请重新跑一次安装**，别的什么都不用做：

- Windows：双击 `install.bat`（或 `python install.py`）
- macOS：双击 `Install.command`（或 `python3 install.py`）

安装时要从游戏里取一份它的原始代码配合加载，那份代码**跟游戏版本绑死**：
游戏更新后就配不上了，启动时会直接报错（蓝色报错页 / 游戏打不开）。
重装一次即可，**存档和设置都不受影响**。

如果重装后仍然起不来：先卸载（Windows `uninstall.bat` / macOS `Uninstall.command`），
游戏即可正常启动，再到 Issues 里反馈。

## 游戏内操作

`Home` 开关菜单。菜单里：`↑↓` 选择　`←→` 调整　`Enter` 执行　`Esc` 关闭　（鼠标点击也行）

菜单按功能分了组（资源 / 波次 / 速度 / 敌人属性 / 防御塔 / 英雄 / 技能无CD / 存档），
每组上面有一行分组标题。

**倍率行**用 `←→` 调，范围 `x0.1`–`x10`，按回 `x1` 就是还原。行右边还有一条**滑条**，
点或拖动可以直接跳到想要的档位；点左边的文字区仍然是「执行」，不会误改数值。
档位是固定的：1 以下按 0.1 细分，1–2 只有 1.5 一个中点，2 以上整档 —— 所以怎么调都不会
落到怪数值上（老版本从 x1 往下再往上会回不到 1）。

两个字面上看不出来的地方：**「技能CD」只改冷却时长，不等于无限放**（技能本身还有目标、
前摇这些条件），而且它的范围是 `x0.1`–`x1` —— **越小技能放得越快**；
**「英雄伤害」也会把英雄技能的伤害一起放大**。攻速调到很高时动画会跳帧，`x2` 上下最自然。

**倍率类只在本关生效**，退出关卡即恢复；把倍率按回 `x1` 游戏就会自己算回去。
**「存档」那一组**按完要退回主菜单重新加载存档，再重启游戏才生效。

## 卸载

- Windows：双击 `uninstall.bat`（装了 Python 也可以 `python uninstall.py`）
- macOS：双击 `Uninstall.command`（或 `python3 uninstall.py`）

游戏自己的存档不会被碰；改存档时自动留下的备份（`_kr6_slot_backup_*.lua`）也会**保留**
——想还原就把对应的那个文件复制成 `slot_1.lua`。

## 声明

作者：B站 **LOVEIII486**。本修改器完全免费，只在 B站和 GitHub 发布，从未授权任何人售卖；
如果你花钱购买说明你被骗了 —— 请申请退款并向你购买的平台举报。

非官方作品，与 Ironhide Game Studio 无关。本项目**不包含任何游戏代码或资源**；
安装所需的少量游戏侧文件由安装器在本地从玩家自己的游戏副本中读取，运行时不修改游戏文件。
游戏与 LÖVE 引擎（MIT 许可）的版权归各自所有者。

本项目自身（安装器、修改器、工具）采用 [MIT 协议](LICENSE) —— 它只授权本项目自己的代码，
不涉及游戏本身的任何权利。

改存档前请自行留意备份 —— 工具已内置备份与回滚，但不对数据损失负责。
