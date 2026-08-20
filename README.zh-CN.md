# windows-app-relocation-diagnosis

一个 [Agent Skill](https://code.claude.com/docs/en/skills)：诊断并修复 **Windows 应用移盘后损坏**，
或**用目录联接（junction）迁移数据后损坏**的问题。

[English](README.md) · MIT 许可

---

## 它解决什么问题

用户为了给 C 盘腾空间，把应用移到别的盘。应用坏了。再移回来，还是坏的。

原因几乎从来不是盘符，而是**几个月前迁移脚本留下的目录联接**。很多应用会校验关键工作目录必须是
**真实目录**，直接拒绝 reparse point。于是缺陷长期潜伏，直到一次移动操作改变了应用解析路径的形式，
核心功能突然失败，报出类似这样的错：

```
error [electron-message-handler] [Composer] submit failed
  cwd=D:\AppData\DocumentsApp\2026-08-20\some-thread
  errorMessage="Projectless thread directory must be a real directory"
```

**把应用移回原盘无法修复它，消除那个联接才行。**

## 技能提供什么

- **7 步只读诊断流程**：确认包状态 → 从 Windows 部署事件日志还原移动历史 → 排除僵尸进程 →
  枚举所有相关 reparse point → 在应用自己的日志里挖出精确报错。
- **噪音排除法**：绝大多数应用日志里，长期存在的报错占了压倒性比例。用「故障前同族日志做基线对照」
  可靠地分离信号与噪音。
- **两个加固脚本**：只读诊断收集器；幂等的「联接→真实目录」修复器（四项前置条件在代码里断言）。
- **11 条已归档的坑**，其中 3 条弄错会造成**二次数据损失**。

## 安装

### Claude Code / 读取技能目录的 agent

```bash
git clone https://github.com/B-TQ/windows-app-relocation-diagnosis.git \
  ~/.claude/skills/windows-app-relocation-diagnosis
```

常见技能根目录：

| Harness | 路径 |
|---|---|
| Claude Code（个人） | `~/.claude/skills/<skill-name>/` |
| Claude Code（项目） | `<repo>/.claude/skills/<skill-name>/` |
| 使用开放格式的 agent 框架 | `~/.agents/skills/<skill-name>/` |

格式的唯一硬要求：目录里有一个 `SKILL.md`，其 YAML frontmatter 含 `name` 和**单行** `description`。
其余（`scripts/`、`references/`）都是渐进式披露，agent 按需加载。

### 手动安装

把目录拷进你的技能根目录即可。无需构建，无依赖。

## 直接使用脚本

不需要 agent 也能用。

### 诊断（只读，任何时候都能安全执行）

```powershell
# 匹配包名、进程名、日志里所有含 "codex" 的内容
.\scripts\Diagnose-AppRelocation.ps1 -AppNamePattern 'codex'

# 追加自己怀疑的路径，并把报告写成文件便于分享
.\scripts\Diagnose-AppRelocation.ps1 -AppNamePattern 'myapp' `
    -ExtraPaths "$env:USERPROFILE\Documents\MyApp", "$env:USERPROFILE\.myapp" `
    -OutFile .\diagnosis.txt
```

除可选的报告文件外不做任何写入；某个 cmdlet 被策略拦截时会如实标注该节不可用，而不是整体失败。

### 修复（把联接变回真实目录）

```powershell
# 一定先预演
.\scripts\Repair-JunctionToRealDirectory.ps1 `
    -LinkPath "$env:USERPROFILE\Documents\MyApp" `
    -ProcessPattern '^(myapp|MyApp)$' -DryRun

# 确认无误再执行
.\scripts\Repair-JunctionToRealDirectory.ps1 `
    -LinkPath "$env:USERPROFILE\Documents\MyApp" `
    -ProcessPattern '^(myapp|MyApp)$'
```

行为约定：

- 只要有匹配 `-ProcessPattern` 的进程存活就拒绝执行。
- 路径本来就不是 reparse point 时拒绝执行并**退出码 0** —— 那正是期望的终态（脚本幂等，可重复跑）。
- 待搬目录内有嵌套 reparse point 时拒绝执行，因为 `robocopy` 会顺着它递归。
- 剩余空间不足「数据量 + 余量」时拒绝执行。
- 删除联接使用**非递归**方式，真实数据全程零风险。
- 完成后独立复核，再删除已空的源目录。

## 设计取舍

**脚本刻意全部使用 ASCII。** 在 Windows PowerShell 5.1 下，含非 ASCII 字符且无 BOM 的 `.ps1`
会按 ANSI 代码页解码，产生**行号与真实文件不符**的解析错误。保持纯 ASCII 意味着无论使用者的
PowerShell 版本、代码页、Git 检出设置如何，脚本都能正确运行。详见
[`references/powershell-pitfalls.md`](references/powershell-pitfalls.md)。

**前置条件是断言，不是文档。** 每一个破坏性步骤都在代码里设了闸。`robocopy` 退出码判断写错、
或递归删除联接，都是数据丢失事件 —— 脚本不依赖操作者记得住。

## 仓库结构

```
.
├── SKILL.md                                     # agent 加载的技能本体
├── README.md / README.zh-CN.md
├── LICENSE
├── CHANGELOG.md
├── scripts/
│   ├── Diagnose-AppRelocation.ps1               # 只读收集器
│   └── Repair-JunctionToRealDirectory.ps1       # 幂等修复器
└── references/
    ├── case-study-msix-junction-conflict.md     # 完整实战案例
    └── powershell-pitfalls.md                   # 环境坑
```

## 适用范围

**适用**：Windows 10/11；通过 设置 → 应用 → 高级选项 → 移动 迁移的 MSIX/Store 应用；任何用
`mklink /J`、`New-Item -ItemType Junction`、`robocopy /MOVE` 加联接等方式迁移过数据的应用；
已知文件夹重定向相关问题。

**不适用**：Linux/macOS 符号链接问题、容器卷挂载、通过改注册表路径迁移的 MSI/EXE 安装
（那是另一类故障，证据链不同）。

## 贡献

最有价值的贡献是**新的真实案例**，特别是路径校验报错文本不同的应用。请附上精确报错原文、
reparse point 布局、以及发现该报错的日志路径，并去除个人标识信息。

## 许可

MIT，见 [LICENSE](LICENSE)。
