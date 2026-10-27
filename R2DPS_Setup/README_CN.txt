R2DPS 1.0.0 一键安装包 —— 遗迹2（Remnant II）伤害统计 mod
只需要房主装，队友不用装。
项目主页 / 反馈问题：https://github.com/OzakiJUN/Remnant2-DPS-Meter

==== 安装 ====
1. 先退出游戏。
2. 双击 Install.bat。
   - 自动找到遗迹2（Steam 版，多个库文件夹也能找）。找不到会让你把游戏文件夹拖进窗口。
   - 安装包自带 UE4SS（setup\ue4ss_bundle 里），不用联网。
   - 已经装了 UE4SS 的话会检查版本：太旧（没有 R2DPS 需要的游戏线程定时器）会提示升级，
     旧的 UE4SS 先整个备份成 ue4ss_backup_日期 文件夹，Mods 里的其他 mod 保留。
   - 游戏装在 C:\Program Files (x86) 之类的地方时会弹管理员权限确认，点"是"。
   - 再次运行就是更新：你改过的 config.txt / names.txt 会保留，只补新增的条目。
   - 会问要不要关掉 UE4SS 自带、用不到的 mod（推荐关；装了别的 BP mod 的话默认不关）。
3. 启动游戏。

==== 卸载 ====
双击 Uninstall.bat：删除 R2DPS。如果 UE4SS 是这个安装包装的，会再问你要不要一起删（默认不删）。

==== 用法 ====
- 小 HUD：右上角小地图下面（名字 / 实时DPS / 总伤害 / 占比）。
- 战斗中点一下 H：详细面板一直开着，再按一下关掉；按住 H：松开就收起。
- Tab 菜单 -> 碎片页：右上角"伤害统计"卡片，点开可以翻历史、切换看每个人的伤害构成。
- 设置都在 ue4ss\Mods\R2DPS\config.txt，中文名在 names.txt。
- 详细说明见 setup\R2DPS\README_CN.txt。

==== 文件说明 ====
Install.bat / Uninstall.bat   启动器（只是调用 setup 里的 PowerShell 脚本）
setup\*.ps1                   安装逻辑，可以用记事本打开看
setup\R2DPS\                  mod 本体
setup\ue4ss_bundle\           自带的 UE4SS（MIT 许可证，https://github.com/UE4SS-RE/RE-UE4SS）
