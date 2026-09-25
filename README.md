# kr6-trainer

Kingdom Rush Genesis 的游戏内修改器 + 离线存档编辑器。

## 下载

**[→ 点这里下载最新版本](https://github.com/LOVEIII486/kr6-genesis-trainer/releases/latest)**

下载 `kr6-trainer-*-release.zip` 那个（推荐，不需要 Python）。装法见下面「安装」。

## 环境需求

- Windows
- **可选**：Python 3（用安装脚本时需要；纯标准库，无第三方依赖）

## 两个部分

| | 改什么 | 怎么用 |
|---|---|---|
| **游戏内菜单** | 关卡内数值：金币、生命、无限金钱、下一波；**敌人血量 / 移速倍率**；**英雄当场升级**；**存档：星星拉满 / 升级树补全 / 英雄升级** | 游戏里按 **`Home`** |
| **离线存档编辑器** | 存档进度：宝石、星星、解锁英雄/防御塔/升级树、英雄经验（**带 `restore` 回滚**） | **关掉游戏**，命令行 |

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

## 游戏内操作

`Home` 开关菜单。菜单里：`↑↓` 选择　`←→` 调整　`Enter` 执行　`Esc` 关闭　（鼠标点击也行）

菜单按功能分了组（资源 / 波次 / 敌人属性 / 英雄 / 存档），每组上面有一行分组标题。

**倍率类只在本关生效**，退出关卡即恢复；把倍率按回 `x1` 游戏就会自己算回去。
**「存档」那一组**按完要退回主菜单重新加载存档，再重启游戏才生效。

## 改存档进度

**先关掉游戏。**

```bash
python tools/kr6_slot_edit.py show          # 看当前存档
python tools/kr6_slot_edit.py gems 99999    # 宝石
python tools/kr6_slot_edit.py stars-unlock  # 星星顶到奖励阈值，解锁英雄/防御塔/法术
python tools/kr6_slot_edit.py unlock-tree   # 免费补全升级树
python tools/kr6_slot_edit.py hero-max hero_gerald
python tools/kr6_slot_edit.py backups       # 备份列表
python tools/kr6_slot_edit.py restore       # 回滚
```

每次写入前自动备份成 `_kr6_slot_backup_<时间戳>.lua`，`restore` 可回滚。
游戏在运行时拒绝写入（`--force` 可强写）。

## 卸载

- 便携版：双击 `uninstall.bat`
- 装了 Python：`python uninstall.py`

游戏自己的存档不会被碰；编辑器留下的存档备份（`_kr6_slot_backup_*.lua`）也会**保留**。

## 声明

非官方作品，与 Ironhide Game Studio 无关。本项目**不包含任何游戏代码或资源**；
安装所需的少量游戏侧文件由安装器在本地从玩家自己的游戏副本中读取，运行时不修改游戏文件。
游戏与 LÖVE 引擎（MIT 许可）的版权归各自所有者。

本项目自身（安装器、修改器、工具）采用 [MIT 协议](LICENSE) —— 它只授权本项目自己的代码，
不涉及游戏本身的任何权利。

改存档前请自行留意备份 —— 工具已内置备份与回滚，但不对数据损失负责。
