# jira-fix-skill

[English](./README.md) | 中文

一个 AI Agent Skill，自动化 Jira → 写代码 → Bitbucket PR 的完整工作流。

对你的 AI 说一句 "fix PROJ-123"，它会自动拉取 ticket 详情、创建分支、实现修复、跑测试、创建 Bitbucket Draft PR，并提议在 Jira 上留言——全程自动。

## 功能

```
Jira ticket → 读取详情 → 创建分支 → 实现修复 → 测试 → lint → 提交 → Draft PR → Jira 留言
```

- **查看 tickets** — 列出分配给你的 Jira tickets
- **修复 ticket** — 端到端：拉取 → 建分支 → 写代码 → 测试 → lint → PR
- **处理反馈** — 读取 review 评论，针对性修改并推送
- **Dry run** — 只输出修复计划，不动代码

### 安全设计

- 从不修改 Jira ticket 状态（只添加评论，且需要你确认后才发送）
- PR 始终以 Draft 形式创建
- 所有 Jira 评论先展示给你看，由你决定是否发布

## 支持的平台

兼容所有支持 Agent Skill 的 AI 编程工具：

- [Cursor](https://cursor.com)（`.cursor/skills/` 或 `.agents/skills/`）
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)（`~/.claude/skills/` 或 `.agents/skills/`）
- 任何读取 `SKILL.md` 的工具

## 前置要求

- `jq`、`curl`、`git` 在 PATH 中（macOS 自带）
- Jira Cloud + Bitbucket Cloud 账号
- **Atlassian MCP**（可选——有则优先使用，无则自动降级为 bash API 调用）

## 安装

### 方式一：克隆到 skills 目录

```bash
# 全局安装（Cursor / Claude Code）
git clone https://github.com/Leon-Kang/jira-fix-skill.git ~/.agents/skills/jira-fix

# 或安装到项目中（团队共享）
git clone https://github.com/Leon-Kang/jira-fix-skill.git .agents/skills/jira-fix
```

### 方式二：手动复制

```bash
mkdir -p ~/.agents/skills/jira-fix
cp -r SKILL.md .env.example scripts/ ~/.agents/skills/jira-fix/
```

## 配置

### 1. 创建 `.env`

```bash
cd ~/.agents/skills/jira-fix   # 或你安装的位置
cp .env.example .env
chmod 600 .env
```

### 2. 创建 API Token

打开 https://id.atlassian.com/manage-profile/security

点击 **"Create and manage API tokens"** → **"Create API token with scopes"**：

#### Jira Token（`ATLASSIAN_API_TOKEN`）

| 字段 | 值 |
|------|-----|
| Name | `jira-fix-jira` |
| App | Jira |

#### Bitbucket Token（`BB_API_TOKEN`）

| 字段 | 值 |
|------|-----|
| Name | `jira-fix-bitbucket` |
| App | **Bitbucket** |
| Scopes | **Repositories Read + Write**、**Pull Requests Read + Write** |

> 两个 Token 在同一个 Atlassian 页面创建，格式相似但权限范围不同。

### 3. 填写 `.env`

```bash
ATLASSIAN_EMAIL=you@example.com
ATLASSIAN_API_TOKEN=your-jira-token      # 第 2 步创建的 Jira token
BB_API_TOKEN=your-bitbucket-token        # 第 2 步创建的 Bitbucket token
JIRA_URL=https://your-site.atlassian.net
BB_WORKSPACE=your-workspace-slug
MAIN_BRANCH=develop                     # 或 main
TEST_URL_PATTERN=                       # 可选，例如 https://test-{TICKET_NUMBER}.example.com
```

### 4. 验证

```bash
bash scripts/jira-api.sh list
```

能看到你的 tickets 就说明配置成功。

## 使用方法

用自然语言对 AI 说：

| 你说 | 效果 |
|------|------|
| "show my tickets" | 列出你的 Jira tickets |
| "fix PROJ-123" | 完整流程：拉取 → 建分支 → 写代码 → 测试 → lint → PR |
| "apply feedback on PROJ-123" | 读取评论，针对性修复，推送 |
| "plan for PROJ-123" | 只输出修复计划，不动代码 |

## `.env` 变量说明

| 变量 | 必填 | 说明 |
|------|------|------|
| `ATLASSIAN_EMAIL` | 是 | Atlassian 账号邮箱 |
| `ATLASSIAN_API_TOKEN` | 是 | Jira API Token（Jira 权限） |
| `BB_API_TOKEN` | 是 | Bitbucket API Token（Bitbucket 权限） |
| `JIRA_URL` | 是 | Jira Cloud 地址，如 `https://acme.atlassian.net` |
| `BB_WORKSPACE` | 是 | Bitbucket workspace slug |
| `MAIN_BRANCH` | 否 | PR 目标分支（默认 `develop`） |
| `TEST_URL_PATTERN` | 否 | 测试环境 URL，支持 `{TICKET_NUMBER}` 占位符 |

## 工作原理

### MCP 优先，bash 兜底

Jira 操作优先使用 **Atlassian MCP**（Cursor 内置集成）。如果 MCP 不可用，自动降级到 `scripts/jira-api.sh` 直接调用 Jira REST API。

Bitbucket PR 创建始终使用 `scripts/bb-pr.sh`（没有对应的 MCP）。

### 文件结构

```
jira-fix-skill/
├── SKILL.md          # Skill 定义文件（AI 读取）
├── .env.example      # 配置模板
├── .env              # 你的密钥（已 gitignore）
├── scripts/
│   ├── jira-api.sh   # Jira API：list、get、comment
│   └── bb-pr.sh      # Bitbucket：创建 Draft PR
├── README.md         # English
├── README.zh-CN.md   # 中文
├── LICENSE
└── .gitignore
```

## 自定义

### 自定义 JQL

在 `.env` 中设置 `JIRA_LIST_JQL` 覆盖默认的 ticket 查询：

```bash
JIRA_LIST_JQL="project = MYPROJ AND assignee = currentUser() AND sprint in openSprints() ORDER BY priority ASC"
```

### 测试环境 URL

如果你的 CI 会部署预览环境，设置 `TEST_URL_PATTERN`：

```bash
TEST_URL_PATTERN=https://preview-{TICKET_NUMBER}.your-app.dev/
```

`{TICKET_NUMBER}` 会被替换为 ticket key 的数字部分（如 `PROJ-456` → `456`）。

## License

MIT
