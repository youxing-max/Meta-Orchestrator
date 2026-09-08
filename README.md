# Meta-Orchestrator

> 把"重复做的事"沉淀成"可复用的工作流"——一个让 Claude Code / Codex 自己积累 workflow 库的小引擎。

[![Tier](https://img.shields.io/badge/scope-T0%20%7C%20T1%20%7C%20T2%20%7C%20T3-blue)](#tier-分类) [![Engine](https://img.shields.io/badge/runtime-Python%203-green)](#环境要求) [![Hooks](https://img.shields.io/badge/hooks-Claude%20Code%20%7C%20Codex-orange)](#安装) [![License](https://img.shields.io/badge/license-MIT-lightgrey)](#license)

---

## 目录

- [它是什么？为什么我要关心？](#它是什么为什么我要关心)
- [从零开始：5 分钟跑起来](#从零开始5-分钟跑起来)
- [一个完整的示例](#一个完整的示例)
- [核心概念速览](#核心概念速览)
- [架构设计](#架构设计)
- [安装详解](#安装详解)
- [使用手册](#使用手册)
- [工作流 YAML 全字段参考](#工作流-yaml-全字段参考)
- [脚本子命令手册](#脚本子命令手册)
- [签名 / DAG 形状 / Tier 分类](#签名--dag-形状--tier-分类)
- [Pattern Memory 数据结构](#pattern-memory-数据结构)
- [进阶：结晶 (Crystallization) 流水线](#进阶结晶-crystallization-流水线)
- [故障排查 / FAQ](#故障排查--faq)
- [开发与扩展](#开发与扩展)
- [License](#license)

---

## 它是什么？为什么我要关心？

### 先讲个故事

假设你每天都要用 Claude Code 修 bug、跑 review、写测试。第一周，你发现修一个 P1 bug 总是这几步：

1. 先用 `Explore` 子 agent 读代码定位
2. 再写最小修复
3. 让 `tdd-guide` 加回归测试
4. 让 `code-reviewer` 审一遍
5. 最后自己总结一下

第二周你又修了一个 P1，几乎同样的套路。第三周又来一个……

你会不会觉得——**这事儿能不能让 Claude "自己记住"，下次再来一句"修个 bug"就直接照这个流程跑？**

`meta-orchestrator` 就是干这个的。它做两件事：

1. **默默记下你每次做了什么**（用了什么工具、跑了哪些子 agent、是不是照着某个 workflow 跑的）
2. **当同一个套路出现 3 次以上**，主动问你："要不要把这套动作固化成 `workflows/bug-fix.yaml`？以后你再说'修个 bug'，我就直接按这个 DAG 跑。"

**一句话总结**：它是 Claude 的"肌肉记忆系统"——把临时的、一次性的操作，沉淀成持久的、可复用的工作流。

### 它解决什么问题？

| 没装之前的痛 | 装了之后 |
|--------------|----------|
| 每次都要手写"先 Explore 再 Edit 再让 reviewer 审……" | `workflows/bug-fix.yaml` 一键调用 |
| 重复劳动浪费 token | 匹配到 workflow 直接走预设 DAG |
| 不同对话间没有积累 | Pattern memory 跨会话持久化 |
| 临时凑出的流程容易漏步骤 | 结晶前给你完整方案预览 |

### 它**不**做什么？

- 不是 RAG、不是知识库——它只记**工具调用序列 + 任务类别**
- 不是 prompt 模板——它编排的是**子 agent 调度图 (DAG)**，不是 prompt 文本
- 不是自动决策——是否"结晶"成 workflow **永远需要你点一下头**

---

## 从零开始：5 分钟跑起来

> 假设你从来没碰过 Claude Code / Codex skill，从这里开始。

### Demo：仓库里有个真实的结晶产物

为了让你看清整个流水线到底写出什么东西，仓库里**故意**留了一个
`workflows/config-update.yaml`——这是用 `orchestrator.py propose --yes`
跑过一次后写出的 stub。同样的 invocation 痕迹在 `scripts/pattern-memory.yaml`
的 `archived_patterns[]` 里能看到（id=2, outcome=crystallized）。

你可以：

- `cat workflows/config-update.yaml` —— 看 stub 长什么样
- `python3 scripts/_matcher.py --text "config update"` —— 看它被 Step 0 命中
- 不喜欢就删：`rm workflows/config-update.yaml && git checkout scripts/pattern-memory.yaml`

### 0. 前置条件

- **Python 3.8+**
  - macOS / Linux：系统自带或 `brew install python3` / `apt install python3`
  - Windows：`winget install Python.Python.3.12` 或 `choco install python3`
  - 验证：`python3 --version`
- **PyYAML**：`pip install pyyaml`
- **jq**（Claude Code Stop hook 用来读 JSON）
  - macOS / Linux：`brew install jq` / `apt install jq`
  - Windows：`winget install jqlang.jq` / `choco install jq`
- **Claude Code** 或 **Codex** 任一已安装
- Windows 用户额外需要 **PowerShell 5.1+**（Win10/11 自带）或 PowerShell 7+

### 方式 A：一键安装（推荐）

#### macOS / Linux / WSL

```bash
git clone https://github.com/yourname/Meta-Orchestrator.git
cd Meta-Orchestrator
./install.sh                       # 给 Claude Code 装
./install.sh --target=both         # 同时给 Claude Code + Codex 装
./install.sh --dry-run             # 看会做什么但不真写
./install.sh --uninstall           # 卸载
```

#### Windows（PowerShell）

```powershell
git clone https://github.com/yourname/Meta-Orchestrator.git
cd Meta-Orchestrator

# 如果系统禁止运行脚本，先放宽一次执行策略（仅当前用户）：
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

.\install.ps1                       # 给 Claude Code 装
.\install.ps1 -Target both          # 同时给 Claude Code + Codex 装
.\install.ps1 -DryRun               # 看会做什么但不真写
.\install.ps1 -Uninstall            # 卸载
```

`install.sh` / `install.ps1` 自动完成：

1. 同步 skill 文件到 `~/.claude/skills/meta-orchestrator/`（Windows 下是 `%USERPROFILE%\.claude\skills\meta-orchestrator\`）
2. 写 `~/.claude/settings.json` 的 Stop hook
3. **写 `~/.claude/CLAUDE.md`**——这是关键，强制 Claude Code 每轮都加载 SKILL.md，**不依赖** description 字段的模糊匹配
4. 跑自检（`validate_dag.py` + `_matcher.py`）

> Windows 端的 Stop hook 仍然是一行 `bash` 命令调用 `claude-code-stop-reminder.sh`。Windows 10+ 自带 WSL / Git Bash，二选一装好就行（推荐 Git for Windows 的 Bash）。

### 方式 B：AI 对话式安装

直接跟 Claude Code 说：

```
帮我装一下 meta-orchestrator skill，
从 https://github.com/yourname/Meta-Orchestrator.git 克隆，
按 README 的 install.sh / install.ps1 步骤走，装好告诉我怎么验证。
```

Claude 会自己跑 `git clone` + `bash install.sh`（或 `pwsh install.ps1`）+ 自检 + 给你验证命令。

### 方式 C：手动三步（小白的进阶）

```bash
# 1. 克隆

```bash
cd /path/to/your-project
python3 <<'PYEOF'
import json, os
p = os.path.expanduser('~/.claude/settings.json')
os.makedirs(os.path.dirname(p), exist_ok=True)
data = {}
if os.path.exists(p):
    try: data = json.load(open(p))
    except: data = {}
hooks_root = data.setdefault('hooks', {})
st = hooks_root.setdefault('Stop', [])
SKILL_DIR = os.path.expanduser('~/.claude/skills/meta-orchestrator')
cmd = f'bash {SKILL_DIR}/hooks/claude-code-stop-reminder.sh'
if not any('stop-reminder' in str(h) for hs in st for h in hs.get('hooks', [])):
    st.append({'hooks': [{'type': 'command', 'command': cmd}]})
with open(p, 'w') as f: json.dump(data, f, indent=2)
print('✓ Stop hook configured at', p)
PYEOF
```

### 2.5 强制加载 SKILL.md（关键！）

光装好 skill 不够——Claude Code 默认按 description 软匹配加载，**不是**每次都进上下文。手动写 `~/.claude/CLAUDE.md` 强制加载：

```bash
cat > ~/.claude/CLAUDE.md <<'MDEOF'
# Auto-installed by meta-orchestrator

## Always-loaded skills

@~/.claude/skills/meta-orchestrator/SKILL.md

## Behavior

- Treat `meta-orchestrator` as default-on. Always loaded.
- Honor opt-out keywords: `skip`, `--no`, `don't run orchestrator`.
- After every response, emit the
  `<!-- meta-orchestrator: sig=... family=... matched=... -->`
  marker (or call `orchestrator.py record` directly).
MDEOF
```

**`install.sh` 已经自动帮你写这一步。**

### 3. 验证安装

```bash
python3 ~/.claude/skills/meta-orchestrator/scripts/validate_dag.py
# → 应该输出 "1/1 workflows valid" 之类的

python3 ~/.claude/skills/meta-orchestrator/scripts/_matcher.py --text "fix bug"
# → 应该返回 JSON，含 "matched": "bug-fix-workflow"
```

**额外验证 force-load 生效**：

```bash
# 1. 看 CLAUDE.md 有没有写好
cat ~/.claude/CLAUDE.md
# 应该看到 @~/.claude/skills/meta-orchestrator/SKILL.md

# 2. 看 settings.json 有没有 hook
cat ~/.claude/settings.json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('hooks', {}).get('Stop', []))"
# 应该看到包含 stop-reminder 的 hook

# 3. 开新 Claude Code session，随便问句"修个 bug"
# → 模型应该直接按 workflows/bug-fix-workflow.yaml 的 DAG 跑
```

### 4. 用起来

现在跟 Claude Code 正常对话就行。每轮结束后 hook 会**自动**：

1. 提取这一轮的工具序列、任务类型
2. 写入 `scripts/pattern-memory.yaml`
3. 如果某个 pattern 累计 ≥3 次，会在下一轮开头提示你"是否要结晶"

**你什么都不用多做。** 唯一会问你的：结晶时按 `y`（固化）或 `n`（丢弃）。

---

## 一个完整的示例

下面演示从零开始，到拥有一个专属 workflow 的全过程。

### 场景

你做 React 项目，发现最近三周每次修 UI bug 都做同样的事：

1. 读组件文件
2. 用 Explore 子 agent 找相关代码
3. Edit 修复
4. 跑 code-reviewer 看 diff
5. 总结

### 第 1 周：第一次修 UI bug

```
你: "按钮点击没反应，帮我修"
Claude: [读 Button.tsx → 用 Explore 找 handlers → Edit onClick → 跑 reviewer → 总结]
Hook 自动记录: signature="Read → Explore → Edit → Agent", family="ui-bug-fix"
```

### 第 2 周：第二次

```
你: "下拉框选不中，修一下"
Claude: [几乎一模一样的流程]
Hook: count=2（还差 1 次）
```

### 第 3 周：第三次

```
你: "弹窗关不掉"
Claude: [又是同一套]
Hook: count=3 🎉 —— 触发结晶提示！
```

### 下一轮开头，hook 会提醒你：

```
⚠ Crystallization threshold met — these patterns are ready to review:
  · id=1  count=3  range=2026-08-15..2026-08-29
      signature: Read → Explore → Edit → Agent
      family:    ui-bug-fix
      example:   last invocation family = 'ui-bug-fix'

For each, run: scripts/orchestrator.py propose --pattern-id 1
  (y → write workflow file   n → archive as declined)
```

### 你点头同意：

```bash
python3 scripts/orchestrator.py propose --pattern-id 1 --yes
# → 自动在 workflows/ui-bug-fix.yaml 写一个 stub
# → 你打开编辑一下 prompt 就行
```

### 第 4 周起：

```
你: "按钮点击没反应"   → Step 0 自动匹配到 workflows/ui-bug-fix.yaml
Claude: [直接按预设 DAG 跑，不再临时凑步骤]
```

---

## 核心概念速览

| 术语 | 一句话解释 | 存哪 |
|------|-----------|------|
| **Workflow** | 一个 DAG（有向无环图），定义"做某类任务的步骤序列" | `workflows/*.yaml` |
| **Step** | DAG 的节点：`agent` / `generate` / `classify` / `input` / `tool` | workflow YAML 的 `composition.steps[]` |
| **Pattern** | 一行计数记录：signature（工具序列） + family（任务名） + count（出现几次） | `scripts/pattern-memory.yaml → patterns[]` |
| **Invocation** | 一次响应的原始日志：时间戳、signature、family、是否 trivial | `scripts/pattern-memory.yaml → invocations[]` |
| **Signature** | 工具调用的"形状字符串"，如 `Read → Explore → Edit → Agent` | 计算得出 |
| **Family** | 任务的简短分类名，前 4 词小写连字符 | 计算或 marker 给定 |
| **Tier (T0–T3)** | 任务复杂度分级，决定要不要拆 DAG | 见下文 |
| **Crystallization** | "次数够了 → 提议生成 workflow 文件"这一整条流水线 | GATE 2/3/4 |
| **Step 0** | 每次响应前查"有没有现成 workflow 能复用" | hook 自动调 |
| **Step 0.5** | 任务分 Tier 的子算法 | hook 自动调 |
| **Marker** | 你或模型主动写的 `<!-- meta-orchestrator: ... -->` 注释 | 写在响应末尾 |

---

## 架构设计

### 总体流程图

```
┌─────────────────────────────────────────────────────────────────────┐
│                         用户输入一句话                                │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Step 0: 查 workflows/*.yaml                                        │
│    · 按 triggers / description 关键词打分                              │
│    · 命中阈值 (≥5) → 走预设 DAG                                       │
│    · 命中 loose (≥1) → 可选复用                                       │
│    · 没命中 → 进入 Step 0.5 决定 tier                                  │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Step 0.5: 分 Tier (T0–T3)                                          │
│    · T0 (查/找) → 直接执行                                            │
│    · T1 (改/修) → 直接执行                                            │
│    · T2 (重构/迁移) → 拆 DAG                                          │
│    · T3 (架构/设计) → 拆 DAG                                          │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  LLM 主循环: Plan → Execute (子 agent dispatch / 直接生成 / tool)      │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  响应结束 → Stop hook 触发                                            │
│    1. classifier (TRIVIAL / ACK / SIMPLE / META / COMPLEX)            │
│    2. 提取 marker 或 derive (signature / family / matched)             │
│    3. 调 orchestrator.py record                                       │
│       ├─ → 写 invocations[]                                          │
│       └─ → 若 ad-hoc 且非 trivial → patterns[].count++                │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  GATE 3: orchestrator.py check                                       │
│    · 重新计算每个 pattern 的非 trivial 次数                             │
│    · 任意一个 ≥3 → exit 0 → 触发 GATE 4                                │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  GATE 4: orchestrator.py propose                                     │
│    · 默认只打印方案                                                    │
│    · --yes → 写 workflows/<name>.yaml + 归档                          │
│    · --no  → 归档为 declined                                           │
└─────────────────────────────────────────────────────────────────────┘
```

### 各模块职责

| 模块 | 职责 | 何时调 |
|------|------|--------|
| `hooks/claude-code-stop-reminder.sh` | 响应结束后做分类 + 调 record + 检查阈值 + 提示用户 | 每轮 Stop 事件 |
| `scripts/orchestrator.py` | 提供 `record` / `check` / `propose` 三个子命令 | 手动 + hook |
| `scripts/_matcher.py` | Step 0 加权匹配 + Step 0.5 tier 分类 | hook 内 + 手动 `--text` |
| `scripts/_judge.py` | 调一次 LLM，语义判定"这条 invocation 该归到哪个已有 pattern" | hook 内 (COMPLEX_TASK 且无 marker 时) |
| `scripts/_memory.py` | atomic YAML 读写 + `.bak` 自愈 | 任何脚本要动 `pattern-memory.yaml` 时 |
| `scripts/_file_lock.py` | `fcntl.flock` 并发写保护 (POSIX only) | `_memory.py` 内部 |
| `scripts/validate_dag.py` | 校验 `workflows/*.yaml` 是否符合 schema | 手动 + 装完跑一次 |

### 数据流

```
        用户 prompt
            │
            ▼
   ┌─────────────────┐         ┌────────────────────┐
   │ _matcher.py     │ ←────── │  workflows/*.yaml  │
   │  (Step 0)       │         └────────────────────┘
   └────────┬────────┘
            │ matched=null → ad-hoc
            ▼
   ┌─────────────────┐         ┌────────────────────┐
   │ LLM 主循环      │ ───────▶│  临时工具序列        │
   └────────┬────────┘         │  (Read/Edit/...)   │
            │                  └────────────────────┘
            ▼
   ┌─────────────────┐         ┌────────────────────┐
   │ Stop hook       │ ───────▶│ pattern-memory.yaml│
   │ orchestrator.py │         │  invocations[]     │
   │  record         │         │  patterns[]        │
   └────────┬────────┘         │  archived_patterns[]│
            │                  └────────────────────┘
            ▼
   ┌─────────────────┐
   │ orchestrator.py │
   │  check          │ ─── exit 0 if any count ≥ 3
   └────────┬────────┘
            ▼
   ┌─────────────────┐
   │ orchestrator.py │ ─── --yes → 写 workflow YAML
   │  propose        │ ─── --no  → 归档 declined
   └─────────────────┘
```

### 设计哲学

1. **永远不自动改 workflow 文件**——`--yes` 才会写，且只写 stub（TODO 提示让你后续编辑）
2. **写操作最小化**——classifier 跳过 80% 的 trivial 轮次，`pattern-memory.yaml` 不会被噪音淹没
3. **签名归一化**——`agent` 和 `generate` 视作等价，方便 pattern 聚合
4. **跨会话持久化**——`pattern-memory.yaml` 是纯文本 YAML，git 友好
5. **POSIX 优先**——`fcntl.flock` 保证多 hook 并发安全；Windows 退化为 `.bak` 自愈

---

## 安装详解

### macOS / Linux（bash）

```bash
# 1. 克隆
git clone https://github.com/yourname/Meta-Orchestrator.git \
  ~/.claude/skills/meta-orchestrator

# 2. 跑 install.sh（自动配 hook + 写 CLAUDE.md + 自检）
cd ~/.claude/skills/meta-orchestrator
./install.sh

# 3. 验证
python3 ~/.claude/skills/meta-orchestrator/scripts/validate_dag.py
```

### Windows（PowerShell）

```powershell
# 1. 克隆到 skill 目录
git clone https://github.com/yourname/Meta-Orchestrator.git `
  $env:USERPROFILE\.claude\skills\meta-orchestrator

# 2. 跑 install.ps1
cd $env:USERPROFILE\.claude\skills\meta-orchestrator
.\install.ps1

# 3. 验证
python $env:USERPROFILE\.claude\skills\meta-orchestrator\scripts\validate_dag.py
```

**先决条件（Windows）**：

| 组件 | 推荐安装方式 |
|------|--------------|
| Python 3.8+ | `winget install Python.Python.3.12` 或 `choco install python3` |
| PyYAML | `pip install pyyaml` |
| jq | `winget install jqlang.jq` 或 `choco install jq` |
| bash（跑 hook 用） | Git for Windows 自带，或 WSL |
| PowerShell 5.1+ | Win10/11 自带；想用新版可 `winget install Microsoft.PowerShell` |

> Stop hook 在 Windows 上仍是一行 `bash <skill>/hooks/claude-code-stop-reminder.sh`。
> Claude Code 在 `%USERPROFILE%\.claude\settings.json` 里执行这个命令，所以 `bash` 必须在 PATH 上（Git Bash 默认安装即满足）。

### Codex（完整版）

Codex 自动发现 `~/.codex/skills/<name>/`。直接同步：

```bash
CODEX_SKILLS="$HOME/.codex/skills"
mkdir -p "$CODEX_SKILLS/meta-orchestrator"
rsync -a --exclude='.git' --exclude='__pycache__' \
          --exclude='*.pyc' --exclude='pattern-memory.yaml*' \
          ~/.claude/skills/meta-orchestrator/ \
          "$CODEX_SKILLS/meta-orchestrator/"
```

**注意**：Codex 0.144.x 没有 `turn_end` hook，hook 配置是 forward-compat 占位。Codex 端**靠模型自己**读 SKILL.md 后在响应末尾写 marker 或主动调 `orchestrator.py record`。

### 双端同步策略

Claude Code 和 Codex 各自独立技能目录。任何修改主仓库后：

```bash
rsync -a --exclude='.git' --exclude='__pycache__' \
          --exclude='*.pyc' --exclude='pattern-memory.yaml*' \
          ~/.claude/skills/meta-orchestrator/ \
          ~/.codex/skills/meta-orchestrator/
```

### 卸载

```bash
# 删目录
rm -rf ~/.claude/skills/meta-orchestrator

# 删 hook 配置（可选）
python3 -c "
import json
p = '~/.claude/settings.json'
data = json.load(open(p))
data.get('hooks', {}).pop('Stop', None)
json.dump(data, open(p, 'w'), indent=2)
"
```

---

## 使用手册

### 日常：什么都不用做

装好后跟 Claude 正常对话。每轮响应结束，hook 自动：

- 分类（trivial/ack/simple/meta/complex）
- 跳过 trivial
- 提取或 derive signature/family/matched
- 写 `pattern-memory.yaml`
- 检查阈值，必要时弹"结晶提示"

### 主动写 marker 提升精度

如果你**明确知道**这次响应属于哪个已有 pattern，直接在末尾加 marker：

```html
<!-- meta-orchestrator: sig=Read → Explore → Edit → Agent family=ui-bug-fix matched=null pattern=1 -->
```

字段说明：

| 字段 | 必需 | 说明 |
|------|------|------|
| `sig=<dag-shape>` | 是 | DAG 形状字符串 |
| `family=<slug>` | 是 | 任务分类名 |
| `matched=<workflow-or-null>` | 是 | 是否匹配到现有 workflow，`null` 表示 ad-hoc |
| `pattern=<id>` | 否 | 强制归属到某个已有 pattern，跳过 LLM judge |
| `intent="..."` | 否 | 人类可读的描述，存到新 pattern 上 |
| `--trivial` | 否 | 记账但不计入 count |

**`pattern=<id>` 优先级最高**——一旦写了这个，hook 不会再调 LLM judge（省 ~3s）。

### 手动跑 record（hook 没配时）

```bash
python3 ~/.claude/skills/meta-orchestrator/scripts/orchestrator.py record \
  --signature "Read → Explore → Edit" \
  --family "ui-bug-fix" \
  --matched null \
  --intent "React component click handler bug"
```

### 手动查阈值

```bash
python3 ~/.claude/skills/meta-orchestrator/scripts/orchestrator.py check
# → JSON list，exit 0 表示有可结晶 pattern
```

### 手动提议结晶

```bash
# 先看（只读）
python3 ~/.claude/skills/meta-orchestrator/scripts/orchestrator.py propose \
  --pattern-id 1

# 确认固化
python3 ~/.claude/skills/meta-orchestrator/scripts/orchestrator.py propose \
  --pattern-id 1 --yes

# 确认丢弃
python3 ~/.claude/skills/meta-orchestrator/scripts/orchestrator.py propose \
  --pattern-id 1 --no
```

### 强制立即结晶

如果用户在 prompt 里写了"记住"、"每次"、"from now on"、"always"、"每次"等关键词：

```bash
python3 ~/.claude/skills/meta-orchestrator/scripts/orchestrator.py propose \
  --pattern-id 1
# 仍然先跑 propose 看方案，再 --yes 确认
```

### 跳过本轮

如果你这次不想被记录：

```
你: "skip"  或  "--no"  或  "don't run orchestrator"
```

模型就会在响应末尾写 `--trivial` marker，hook 走 META_RECORD 路径但 `count` 不增。

---

## 工作流 YAML 全字段参考

最小可工作模板（`workflows/_TEMPLATE.yaml`）：

```yaml
name: my-workflow                # required, kebab-case
description: "短描述"              # required, 用于 Step 0 关键词打分
triggers:                         # required, 用户会说的短语
  - fix bug
  - 修 bug
meta_priority: 10                 # optional, 默认 0, tiebreaker
loose: true                       # optional, 阈值降到 ≥1
neg-keywords:                     # optional, 命中则排除
  - production
composition:
  steps:
    - id: step1
      kind: agent                 # agent | generate | classify | input | tool
      description: "做这事"
      prompt: "..."
      agent_type: Explore         # required if kind=agent
      model: sonnet               # optional, 默认 sonnet
      depends_on: []
      on_failure: fallback_step

    - id: classify1
      kind: classify
      description: "分类"
      prompt: "根据 X 分类"
      output_choices: [A, B, C]
      route:
        - when: A
          to: step_a
        - when: B
          to: step_b

    - id: input1
      kind: input
      description: "问用户"
      schema:
        decision: {type: enum, choices: [yes, no]}
        feedback: {type: string}
      route:
        - when: yes
          to: step_yes
        - when: no
          to: step_no
```

### 字段详解

#### 顶层

| 字段 | 必需 | 类型 | 说明 |
|------|------|------|------|
| `name` | ✅ | string | kebab-case，唯一 |
| `kind` | ❌ | string | 默认 `meta` |
| `description` | ✅ | string | 一句话，用于 Step 0 关键词打分 |
| `triggers` | ✅ | list[string] | 用户可能说的短语 |
| `meta_priority` | ❌ | int | tiebreaker，高的优先 |
| `loose` | ❌ | bool | 允许 score ≥1 命中 |
| `neg-keywords` | ❌ | list[string] | 命中即排除 |
| `always` | ❌ | bool | 默认 false |
| `final_text_mode` | ❌ | string | `auto` / `raw` / `synthesize` |
| `composition` | ✅ | object | 包含 `steps` |

#### Step 公共字段

| 字段 | 必需 | 类型 | 说明 |
|------|------|------|------|
| `id` | ✅ | string | snake_case，唯一 |
| `kind` | ✅ | enum | `agent` / `generate` / `classify` / `input` / `tool` |
| `description` | ❌ | string | 给人看的注释 |
| `prompt` | ✅ | string | 给 LLM 的指令 |
| `depends_on` | ❌ | list[string] | 前置 step id |
| `on_failure` | ❌ | string | 失败时跳到的 step id |

#### kind=agent 专属

| 字段 | 必需 | 说明 |
|------|------|------|
| `agent_type` | ✅ | `Explore` / `general-purpose` / `code-reviewer` / `security-reviewer` / `tdd-guide` |
| `model` | ❌ | `haiku` / `sonnet` / `opus`，默认 `sonnet` |

#### kind=classify 专属

| 字段 | 必需 | 说明 |
|------|------|------|
| `output_choices` | ✅ | 枚举值 |
| `route` | ✅ | 每个 choice 必须有匹配 `when` |

#### kind=input 专属

| 字段 | 必需 | 说明 |
|------|------|------|
| `schema` | ✅ | 字段定义（type: enum/string/int） |
| `route` | ✅ | 同 classify |

#### kind=tool 专属

| 字段 | 必需 | 说明 |
|------|------|------|
| `tool` | ✅ | `bash` / `python` |
| `params` | ✅ | 传给 tool 的参数 |

### DAG 硬性规则（违反则 validate_dag.py 报错）

1. **No deadlock**——每个 `depends_on` 目标必须存在
2. **Route completeness**——每个 `output_choices` / schema 枚举值都有 `route.when`
3. **Fallback isolation**——`on_failure` 目标不能再被别的 step `depends_on`
4. **Acyclicity**——不能有环
5. **One-level references**——不要 SKILL.md → a.md → b.md 嵌套

---

## 脚本子命令手册

### `orchestrator.py record`

记一条 invocation。

```bash
python3 scripts/orchestrator.py record \
  --signature "Read → Explore → Edit" \
  --family "ui-bug-fix" \
  --matched null \
  [--pattern-id <id>] \
  [--judge] \
  [--intent "..."] \
  [--trivial]
```

参数：

| 参数 | 说明 |
|------|------|
| `--signature` | DAG 形状，必填 |
| `--family` | 任务短名，必填 |
| `--matched` | 匹配的 workflow 名或 `null`（ad-hoc），必填 |
| `--pattern-id` | 强制归属已有 pattern |
| `--judge` | 调一次 LLM 判定归属（~3s） |
| `--intent` | 新 pattern 的人类描述 |
| `--trivial` | 记账但不计数 |

返回 JSON：`{"pattern_id": N, "recorded_at": "..."}`。

### `orchestrator.py check`

重算所有 pattern 的非 trivial 次数，≥3 的列为待结晶。

```bash
python3 scripts/orchestrator.py check
# → exit 0 if any pending
# → JSON list: [{"pattern_id": 1, "count": 3, "signature": "...", "task_family": "..."}]
```

### `orchestrator.py propose`

提议结晶（生成 workflow 文件或归档）。

```bash
python3 scripts/orchestrator.py propose --pattern-id 1          # 只读
python3 scripts/orchestrator.py propose --pattern-id 1 --yes    # 写 stub + 归档 crystallized
python3 scripts/orchestrator.py propose --pattern-id 1 --no     # 归档 declined
```

**--yes 行为**：

1. 把所有匹配 signature 的 `invocations[]` 行移到 `archived_patterns[]`
2. 把该 pattern 也移到 `archived_patterns[]` 标 `crystallized`
3. 写 `workflows/<family>.yaml`（TODO stub，不会覆盖已有文件）
4. 同 signature 重新触发需重新累计 3 次

### `_matcher.py`（辅助）

手动跑 Step 0：

```bash
python3 scripts/_matcher.py --text "fix bug"
# → {"matched": "bug-fix-workflow", "score": 10, "tier": "T1", "candidates": [...]}
```

参数：

| 参数 | 说明 |
|------|------|
| `--text` | 用户 prompt |
| `--workflows-dir` | 自定义 workflow 目录（默认 `<SKILL_DIR>/workflows`） |

### `validate_dag.py`（辅助）

校验所有 workflow YAML：

```bash
python3 scripts/validate_dag.py
# → "3/3 workflows valid" 或具体错误
```

---

## 签名 / DAG 形状 / Tier 分类

### 签名格式

```
<kind>|<kind> → <kind> → <kind>
```

- `|` —— parallel siblings（并行分支）
- `→` —— sequential phases（顺序阶段）
- `agent` 和 `generate` 归一化为同一种

例：

```
Read → Explore → Edit → Agent           # 顺序
classify → agent|generate → tool         # 分类 → 并行(子 agent + 生成) → 跑脚本
Read → Read → Edit                       # 连续读两次也算两个 Read
agent                                    # 占位符（没识别到工具时）
```

### Tier 分类

| Tier | 范围 | 触发词 | 动作 |
|------|------|--------|------|
| **T0** | 只读 / 查找 | `lookup`, `find`, `where`, `查`, `找` | 直接执行 |
| **T1** | 单文件编辑 | `edit`, `fix`, `change`, `update`, `修改`, `修复` | 直接执行 |
| **T2** | 多文件 / 重构 | `refactor`, `migrate`, `multi-file`, `重构`, `迁移` | 拆 DAG |
| **T3** | 架构 / 设计 | `architecture`, `design`, `redesign`, `架构`, `设计` | 拆 DAG |

**Fallback**：prompt > 200 字符 → 默认 T2，否则 T1。

### Classifier（hook 用）

| Tier | 规则 | 动作 |
|------|------|------|
| `TRIVIAL_SKIP` | < 50 字符 + 无工具 + 无 markdown | 完全跳过 |
| `ACK_SKIP` | 纯 ack（"ok" / "yes" / "好的"） | 完全跳过 |
| `SIMPLE_TASK` | 1 个工具 + 短响应 | 跳过（太薄，不值结晶） |
| `META_RECORD` | 含 meta-orchestrator / crystalliz / workflow 关键词 | 写 `--trivial` |
| `COMPLEX_TASK` | ≥3 个不同工具 / ≥500 字符 / 有 markdown / 有 marker | 写非 trivial + `--judge` |

---

## Pattern Memory 数据结构

`scripts/pattern-memory.yaml`（**脚本自动维护，别手改**）：

```yaml
next_id: 42                          # 单调递增 ID 池
patterns:                            # 当前活跃的 pattern（未结晶/未归档）
  - id: 1
    signature: "Read → Explore → Edit → Agent"
    task_family: "ui-bug-fix"
    count: 3                         # 冗余字段，check 时重算
    first_seen: 2026-08-15
    last_seen: 2026-08-29
    intent: "React component click handler bug"
archived_patterns:                   # 已处理（结晶 / 拒绝）
  - id: 2
    signature: "..."
    task_family: "..."
    outcome: crystallized            # or declined
    decided_at: 2026-09-01
    workflow_file: workflows/foo.yaml
invocations:                         # append-only 日志
  - id: 5
    timestamp: 2026-08-29T10:23:00
    signature: "Read → Explore → Edit → Agent"
    task_family: "ui-bug-fix"
    matched_workflow: null
    trivial: false
    intent: "..."
```

**注意**：

- `invocations[].id` 会有**间隙**——间隙是 `patterns[].id`
- `count` 是冗余字段，权威值由 check 重算
- `.bak` 是每次写前的快照，崩溃可恢复

---

## 进阶：结晶 (Crystallization) 流水线

整个流程分四道闸门：

### GATE 2：Record（每轮都过）

响应结束 → hook 自动跑 `orchestrator.py record`。

逻辑：

1. 优先级 1：marker 显式声明 `pattern=<id>` → 强制归属
2. 优先级 2：`--judge` 调一次 LLM 判定（~3s）→ 语义归类
3. 优先级 3：signature 字符串精确匹配
4. 兜底：新建 pattern（若非 trivial）

### GATE 3：Check（每轮都过）

`orchestrator.py check` 重算非 trivial count：

- exit 0 → 有 pattern 待结晶
- exit 1 → 都还不够

### GATE 4：Propose（仅 exit 0 时触发）

```
patterns[].count ≥ 3
   ↓
orchestrator.py propose --pattern-id N
   ↓
打印方案预览（signature + family + count + intent + 最后几次 invocation 摘要）
   ↓
用户决定:
   --yes → 写 workflows/<name>.yaml stub + 归档 crystallized
   --no  → 归档 declined
   ↓
drain：把所有匹配 signature 的 invocations 移到 archived_patterns
```

### Drain 语义

`--yes` / `--no` 会**清空**该 signature 的所有 `invocations[]` 行。**同 signature 必须重新累计 3 次**才会再触发。

这避免了"你拒绝一次后，下次稍微跑就又来烦你"。

---

## 故障排查 / FAQ

### Q：装完 hook 不生效？

**检查**：

```bash
# 1. settings.json 有没有写进去
cat ~/.claude/settings.json | jq '.hooks.Stop'

# 2. jq 装没装
which jq

# 3. 手动跑一次 hook 看输出
echo '{"stop_hook_active": false, "transcript_path": "/dev/null"}' | \
  bash ~/.claude/skills/meta-orchestrator/hooks/claude-code-stop-reminder.sh
```

### Q：`pattern-memory.yaml` 越来越胖？

**正常**：每次复杂轮次都写一行。但 classifier 已经把 trivial 都过滤了。如果还嫌大：

- 定期手归档：`mv pattern-memory.yaml.bak pattern-memory.yaml`
- 或者编辑脚本调高 COMPLEX_TASK 阈值（≥500 字符 → ≥800）

### Q：为什么 hook 跳过了我的轮次？

可能是 classifier 判了 SIMPLE_TASK（太薄）或 TRIVIAL_SKIP（太短）。手动 marker 强制覆盖：

```html
<!-- meta-orchestrator: sig=... family=... matched=null -->
```

### Q：Windows 下并发写会不会出问题？

`_file_lock.py` 在 Windows 上是 no-op，**只支持 POSIX**。Windows 用户：

- 只在单进程跑脚本
- 依赖 `.bak` 自动恢复（每次写前备份，损坏时回退）

### Q：Windows 下如何安装 / 卸载？

跑 `install.ps1`，参数和 bash 版一一对应：

| bash | PowerShell |
|------|------------|
| `./install.sh` | `.\install.ps1` |
| `./install.sh --target=both` | `.\install.ps1 -Target both` |
| `./install.sh --dry-run` | `.\install.ps1 -DryRun` |
| `./install.sh --uninstall` | `.\install.ps1 -Uninstall` |

依赖安装走 `winget` / `choco`：

- `winget install Python.Python.3.12 jqlang.jq Git.Git`
- 或者 `choco install python3 jq git`

如果 PowerShell 报 "running scripts is disabled on this system"，先放宽当前用户的执行策略：

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

卸载：

```powershell
.\install.ps1 -Uninstall
```

### Q：installer 会覆盖我自己的 `~/.claude/CLAUDE.md` 吗？

不会。两个 installer 都用**带 sentinel 的追加**策略：

- 在 `~/.claude/CLAUDE.md` 末尾追加一段被
  `<!-- >>> meta-orchestrator (managed block, do not edit) >>>` 和
  `<!-- <<< meta-orchestrator <<<` 包住的 block
- 再装一次会先剥离旧 block、再追加新版（幂等）
- `--uninstall` / `-Uninstall` 只剥离这个 block，**保留用户原来写的任何内容**

如果你自己也在 `CLAUDE.md` 里写项目说明 / 其他 skill 引用，安装是安全的。

### Q：怎么导出 / 备份我的 workflow 库？

```bash
# workflow 文件
tar czf workflows-backup.tar.gz workflows/

# pattern memory
cp scripts/pattern-memory.yaml ~/safe-place/
```

### Q：怎么让所有 hook 跳过当前 session？

在你的 prompt 里说：

```
don't run orchestrator
```

或开头加 `--no`，或直接说 `skip`。

### Q：结晶的 stub workflow 怎么改？

`--yes` 写的是 stub（prompt 全是 TODO）。打开编辑：

```bash
$EDITOR workflows/ui-bug-fix.yaml
```

填 `description`、`triggers`、`composition.steps` 即可。

### Q：能跨机器同步吗？

`pattern-memory.yaml` 是纯文本，直接 git 就行。冲突时 `_memory.py` 用 `.bak` 自动恢复 + 重试。

---

## 开发与扩展

### 加自定义 step kind

1. 编辑 `scripts/validate_dag.py` 加新 kind 的字段校验
2. 在 hook 或脚本里实现对应 executor
3. 更新 SKILL.md 文档

### 加自定义 agent_type

`kind=agent` 的 `agent_type` 字段是自由 string，没硬约束。但要确保下游真的能 dispatch——否则会失败并跳 `on_failure`。

### 加自定义 classifier 规则

改 `hooks/claude-code-stop-reminder.sh` 里 `classifier=` 那段 Python。常见扩展点：

- 加更多 trivial 关键词
- 加项目特定黑名单
- 调整 COMPLEX_TASK 阈值

### 调试 hook

```bash
# 看 hook 实际跑了什么
TAIL_LOG=/tmp/hook.log
echo '{"stop_hook_active": false, "transcript_path": "/dev/null"}' | \
  bash -x ~/.claude/skills/meta-orchestrator/hooks/claude-code-stop-reminder.sh 2>&1 | tee "$TAIL_LOG"
```

### 跑测试

仓库暂无正式 test suite。建议最小自检：

```bash
python3 scripts/validate_dag.py                # 所有 workflow 合法
python3 scripts/_matcher.py --text "fix bug"   # Step 0 正常
python3 scripts/orchestrator.py check          # check 正常
```

---

## 路线图

- [x] Windows `install.ps1`（与 bash 版参数对齐）
- [ ] Windows `msvcrt` 文件锁（当前用 `.bak` 自愈代替）
- [ ] 正式 pytest 套件
- [ ] Codex `turn_end` 真支持（等 Codex 升级 hook surface）
- [ ] Web UI 看 pattern memory
- [ ] workflow 之间的 DAG 组合（一个 workflow 引用另一个）

---

## 致谢

本项目结构受 [Claude Code Skills](https://docs.claude.com/claude-code) 的 stop hook 机制启发。

---

## License

MIT — 随意用、随意改、随意分发。提 issue / PR 更好。
