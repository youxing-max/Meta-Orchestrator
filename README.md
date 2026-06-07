# Meta-Orchestrator

<p align="center">
  <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT">
  <img src="https://img.shields.io/badge/platform-Claude%20Code%20%7C%20Codex-orange.svg" alt="Platform: Claude Code | Codex">
  <img src="https://img.shields.io/badge/inspiration-OpenSquilla-purple.svg" alt="Inspiration: OpenSquilla">
  <img src="https://img.shields.io/badge/version-v1.0-green.svg" alt="Version: v1.0">
</p>

> DAG 工作流编排引擎，将 Claude Code / Codex 从线性 Agent 升级为有向无环图执行引擎。灵感来自 [OpenSquilla](https://github.com/opensquilla/opensquilla) 的 MetaSkill 模型。

**Meta-Orchestrator** 将复杂任务拆解为 DAG，同层独立步骤并行分发，按 T0-T3 复杂度分级路由模型，重复 3 次以上的复杂模式自动沉淀为可复用工作流，已有工作流出错时自愈修复。纯 Skill 实现，零外部依赖。

---

## 安装

### 选择平台与位置

| 平台 | 项目本地路径 | 全局路径 | 生效范围 |
|------|-------------|---------|----------|
| **Claude Code** | `your-project/.claude/` | `~/.claude/` | 仅当前项目 / 所有项目 |
| **Codex** | `your-project/.codex/` | `~/.codex/` | 仅当前项目 / 所有项目 |

### 方式一：手动复制（30 秒）

**Claude Code — 安装到项目本地：**

```bash
git clone https://github.com/youxing-max/Meta-Orchestrator.git /tmp/meta-orchestrator
cp -r /tmp/meta-orchestrator/.claude /your-project/
```

**Claude Code — 安装到全局（所有项目生效）：**

```bash
git clone https://github.com/youxing-max/Meta-Orchestrator.git /tmp/meta-orchestrator
cp -rn /tmp/meta-orchestrator/.claude/* ~/.claude/
```

**Codex — 安装到项目本地：**

```bash
git clone https://github.com/youxing-max/Meta-Orchestrator.git /tmp/meta-orchestrator
cp -r /tmp/meta-orchestrator/.codex /your-project/
```

**Codex — 安装到全局：**

```bash
git clone https://github.com/youxing-max/Meta-Orchestrator.git /tmp/meta-orchestrator
cp -rn /tmp/meta-orchestrator/.codex/* ~/.codex/
```

> `cp -rn` 不会覆盖已有文件，安全合并。如果目标目录不存在，先 `mkdir -p` 创建。

### 方式二：AI 一键安装

把下面对应的话发给 Claude Code（或 Codex），它会自动拉取并安装：

**Claude Code — 安装到当前项目：**

```
从 https://github.com/youxing-max/Meta-Orchestrator 获取项目，
把 .claude/ 目录复制到当前项目根目录。然后在当前项目的 CLAUDE.md
中写入以下内容（如果已有 CLAUDE.md 则追加到末尾）：

## Meta-Orchestrator

**ALWAYS invoke `meta-orchestrator` skill at session start.**

Before any substantial work:
1. Check `.claude/workflows/` for matching pre-defined workflows
2. Classify complexity (T0 → haiku, T2 → sonnet, T3 → opus)
3. Decompose into a DAG with `depends_on` edges
4. Dispatch independent steps in parallel
5. Track execution via TaskCreate
6. Synthesize results
7. Propose workflow crystallization for repeatable patterns
```

**Codex — 安装到当前项目：**

```
从 https://github.com/youxing-max/Meta-Orchestrator 获取项目，
把 .codex/ 目录复制到当前项目根目录。然后在当前项目的 CODEX.md
中写入以下内容（如果已有 CODEX.md 则追加到末尾）：

## Meta-Orchestrator

**ALWAYS invoke `meta-orchestrator` skill at session start.**

Before any substantial work:
1. Check `.codex/workflows/` for matching pre-defined workflows
2. Classify complexity (T0 → haiku, T2 → sonnet, T3 → opus)
3. Decompose into a DAG with `depends_on` edges
4. Dispatch independent steps in parallel
5. Synthesize results
6. Propose workflow crystallization for repeatable patterns
```

**安装到全局平台：**

```
从 https://github.com/youxing-max/Meta-Orchestrator 获取项目，
把 .claude/skills/ 和 .claude/workflows/ 合并复制到 ~/.claude/
对应目录下（Codex 用户用 .codex/），不要覆盖已有文件。
然后创建或更新 ~/.claude/CLAUDE.md（Codex 用 CODEX.md），
写入以下内容：

## Meta-Orchestrator

**ALWAYS invoke `meta-orchestrator` skill at session start.**
```

安装完成后的目录结构：

```
your-project/
├── .claude/              # Claude Code 用户
│   ├── .pattern-memory.yaml
│   ├── skills/
│   │   └── meta-orchestrator/
│   │       └── SKILL.md
│   └── workflows/
│       ├── code-review-pipeline.yaml
│       ├── deploy-checklist.yaml
│       ├── bug-fix-workflow.yaml
│       ├── api-migration.yaml
│       └── parallel-analysis.yaml
│
└── .codex/               # Codex 用户（内容相同）
    └── ...
```

下次打开 Claude Code 即自动生效。

---

## 为什么需要 Meta-Orchestrator？

Claude Code 默认按顺序执行任务，靠模型自身的"记忆"来完成多步骤工作。这在简单场景下没问题，但遇到复杂任务时会暴露问题：

| 没有 Meta-Orchestrator | 有 Meta-Orchestrator |
|---|---|
| 顺序执行，即使子任务互不依赖 | DAG 分解，独立步骤并行分发 |
| 模型凭记忆决定下一步 | 依赖图强制执行正确顺序 |
| 每次都重新规划相同模式 | 重复 3 次后自动结晶为 `.yaml` 工作流 |
| 一个模型干所有事 | T0-T3 分级路由（haiku → sonnet → opus） |
| 失败步骤静默中断进度 | `on_failure` 显式回退处理 |
| 无法感知执行进度 | 每个 DAG 步骤对应一个 Task 追踪 |
| 结晶后的工作流可能出错 | 自愈机制：检测死锁/路由缺失/fallback违规，自动修复 |

核心原则：**用结构来保障执行，而不是指望模型自己做好。**

---

## 工作原理

```
用户请求
     │
     ▼
┌─────────────────────────────────────┐
│ Step 0: 复杂度分级                  │
│ T0 (haiku) → T1 → T2 (sonnet) → T3 │
└──────────────┬──────────────────────┘
               ▼
┌─────────────────────────────────────┐
│ Step 1: 检查已有工作流              │
│ .claude/workflows/*.yaml            │
└──────┬──────────────────┬───────────┘
       │ 命中             │ 未命中
       ▼                  ▼
┌──────────────┐  ┌───────────────────┐
│ 执行已有     │  │ Step 2: DAG 分解  │
│ 工作流 YAML  │  │                   │
└──────────────┘  │ classify → agent  │
                  │ generate → skill  │
                  │ input   → tool    │
                  └────────┬──────────┘
                           ▼
┌─────────────────────────────────────┐
│ Step 3: 并行分发                   │
│ 同层独立步骤 → 一个批次             │
└──────────────┬──────────────────────┘
               ▼
┌─────────────────────────────────────┐
│ Step 4: 追踪 + 综合输出            │
│ TaskCreate 追踪每一步               │
└──────────────┬──────────────────────┘
               ▼
┌─────────────────────────────────────┐
│ Step 5: 工作流结晶 + 自愈          │
│ T2+ 且重复 3 次？→ 保存为 .yaml    │
│ 执行出错？→ 自动检测并修复          │
└─────────────────────────────────────┘
```

### 步骤类型

| 类型 | 用途 | 示例 |
|------|------|------|
| `classify` | 分类路由，输出一个选项实现 DAG 分支 | "这是 bug、功能还是重构？" |
| `agent` | 分派子 Agent 执行推理或实现 | 代码审查、安全扫描、功能实现 |
| `generate` | 纯 LLM 生成，不调用工具 | 总结、报告、文档生成 |
| `skill` | 调用命名技能 | `tdd`、`security-review` |
| `input` | 暂停收集用户结构化输入 | 审批关卡、设计评审 |
| `tool` | 确定性工具调用（Bash, Read, Write, MCP 等） | 构建、文件操作、MCP API 调用 |

### 复杂度分级

| 级别 | 场景 | 模型 | 开销 |
|------|------|------|------|
| **T0** | 查找、阅读、解释 | haiku | $ |
| **T1** | 简单编辑、单文件修复 | haiku → 按需升级 | $ |
| **T2** | 功能开发、多文件、重构 | sonnet | $$ |
| **T3** | 架构设计、深度推理 | opus | $$$ |

---

## 使用方式

### 自动激活（默认）

正常使用 Claude Code 即可。非平凡任务自动触发编排：

```
用户: 帮我把 session 认证改成 JWT
      ↓
Meta-Orchestrator:
  1. 分级: T2（多文件功能开发）
  2. 无匹配工作流 → 临时 DAG
  3. DAG: audit || research → design → implement → test || security → synthesize
  4. 并行分发: [audit, research] → [design] → [implement] → [test, security] → [synthesize]
  5. 执行完毕，记录到模式记忆
```

### 意图匹配

使用自然语言即可命中预定义工作流：

```
> 上线前检查一下
→ 命中 deploy-checklist.yaml 触发器 "上线前检查"
→ 执行: test || security → build → summary → notify
```

### 工作流结晶

T2+ 复杂任务被执行 3 次以上后，自动提议保存为可复用工作流。用户说"每次/以后/记住"则立即结晶，无需等待计数：

```
> 每次改完代码后自动跑测试和 lint 检查，记住了
→ 检测到 "每次" + "记住" → 立即结晶
→ .claude/workflows/auto-test-lint.yaml 已创建
```

---

## 内置工作流

### 1. Code Review Pipeline

触发器：`全面审查` `安全审计` `code review` `代码审查`

```
security_review || quality_review || infra_review → synthesize_report
```

### 2. Deploy Checklist

触发器：`上线前检查` `pre-deploy` `发版检查`

```
run_tests || security_scan → build → deploy_ready → notify
```

### 3. Bug Fix Workflow

触发器：`修bug` `fix bug` `debug` `修复`

```
classify_severity (P0→incident, P1-P3→diagnose)
  → diagnose → repro_steps
  → implement_fix || write_tests
  → review_fix || verify_edge_cases
  → synthesize
```

### 4. API Migration

触发器：`API 迁移` `接口迁移` `migrate API`

```
audit_endpoints || research_target || analyze_breaking
  → design_migration → user_approve
  → implement_phase1 → test_migration
  → review_migration → migration_docs → synthesize
```

---

## 编写自定义工作流

```yaml
name: my-workflow              # kebab-case 标识符
kind: meta                     # 固定值
description: 一句话描述用途
triggers:                      # 2-5 个自然语言触发短语
  - do the thing
  - 做这件事
meta_priority: 10              # 数值越大优先级越高
always: false
final_text_mode: auto          # auto | raw | step:<id>

composition:
  steps:
    - id: step_1
      kind: agent              # classify | agent | generate | skill | input | tool
      description: 这一步做什么
      depends_on: []           # 空 = 根步骤，立即并行执行
      agent_type: Explore
      model: haiku             # haiku | sonnet | opus
      prompt: "..."

    - id: step_2
      kind: generate
      depends_on: [step_1]
      prompt: "..."

    - id: step_3
      kind: tool               # Bash/Read/Write 或 MCP 工具
      tool: mcp__headroom__headroom_compress  # MCP: mcp__<server>__<tool>
      params:
        content: "{{step_2.output}}"   # 引用上游步骤产出
      depends_on: [step_2]
      on_failure: fallback_id   # 休眠 — 仅在父步骤失败时执行

    - id: router
      kind: classify
      output_choices: [A, B]
      route:
        - when: A
          to: path_a           # 仅命中分支执行
        - when: B
          to: path_b
```

### DAG 规则

1. `depends_on` 为空 → 立即并行执行
2. `depends_on` 非空 → 等待所有前置步骤完成
3. 同层独立步骤 → **必须在同一个批次中并行分发**
4. 图必须 **无环** — 不允许循环依赖
5. `depends_on` 只能引用 **保证执行** 的步骤（不可引用 route 分支目标或 fallback 步骤）
6. 条件分支后的汇合点依赖分支前的公共祖先，不依赖各分支目标
7. Route 的每个 `output_choices` 值必须有对应 `route.when`，不可遗漏
8. Fallback 步骤 **休眠** — 仅在父步骤失败时触发，不可被其他步骤的 `depends_on` 引用

> 常见死锁模式见 [SKILL.md](.claude/skills/meta-orchestrator/SKILL.md) DAG Rules 章节后的 **Common Deadlock Patterns**。

---

## 设计哲学

直接受 [OpenSquilla](https://github.com/opensquilla/opensquilla) MetaSkill 系统启发：

| OpenSquilla | Meta-Orchestrator |
|---|---|
| 外部 Python 运行时强制 DAG | Claude 按 Skill 指令执行 DAG |
| LightGBM + ONNX 路由分类 | Claude 按关键词 + 上下文启发式分类 |
| `meta_invoke()` 工具触发工作流 | 意图匹配触发器短语 |
| 人工审核关卡 | 重复 3 次后提议结晶 |
| 风险级别沙箱 | Claude Code 权限系统 |
| 20+ LLM 后端路由 | haiku/sonnet/opus 分级路由 |

---

## 要求

- [Claude Code](https://claude.ai/code)（任意较新版本）
- 零外部依赖 — 完全运行在 Claude Code Skill 系统内

## 参考

- [OpenSquilla](https://github.com/opensquilla/opensquilla) — Token 高效 AI Agent，首创 MetaSkill 系统
- [Claude Code Skills](https://docs.anthropic.com/en/docs/claude-code/skills) — Claude Code 官方技能文档

## License

MIT
