# jira-fix-skill

[English](./README.md) | 中文

一个 AI Agent Skill，自动化 Jira → 写代码 → GitHub Enterprise PR 的完整工作流，并在关键位置设置人工确认门禁。

对你的 AI 说一句 "fix PROJ-123"，它会先做情报收集——ticket 正文、评论历史、已有分支和 PR、相关代码、git 历史——然后要么告诉你缺什么信息并停下，要么给出一份计划请你确认。只有你批准之后它才会动代码。提交、推送、开 PR、在 Jira 留言，每一步都要经过你同意。

## 功能

```
Jira ticket → 情报调查 → 情报门禁 → 计划门禁 → 写代码 → 测试 → lint → review → 推送门禁 → （可选）Draft PR → （可选）Jira 留言
```

- **查看 tickets** — 列出分配给你的 Jira tickets
- **修复 ticket** — 端到端，带三道确认门禁
- **处理反馈** — 粘一个 PR 链接或说一句"检查最新评论"即可；同时读取 Jira 评论**和** PR 的 review、行内评论，然后直接施工
- **只出计划** — 只做调查和计划，不动代码

### 三道门禁

1. **情报门禁** — ticket 信息不足时，明确告诉你缺什么、为什么需要，然后停下。不猜。
2. **计划门禁** — 给出六段式计划（理解、涉及文件、改动方案、验证方式、风险、分支与提交信息），你批准前不会写任何文件。
3. **推送门禁** — 提交和推送之前，先给你看 diff 统计、验证结果和确切的 commit message。

反馈轮次刻意跳过这三道门禁：ticket 早已调查过、计划早已批准、分支也已经推上去了，所以 review 意见直接进入施工——只有确实存在歧义、超出改动范围、或与 ticket 验收标准冲突的条目才逐条问询。

### 其他安全设计

- 从不修改 Jira ticket 状态——只留言，且需你确认后才发送
- 从不自动 stash 你的改动；工作区不干净会停下来问你
- 推送门禁之前必定跑一次 code review，项目里有 review skill 就调用它
- PR 始终是 Draft，且 `pr create` 幂等，不会重复开 PR
- Jira 留言硬性限制 3 行——只有结论和链接

## 支持的平台

兼容所有支持 Agent Skill 的 AI 编程工具：

- [Cursor](https://cursor.com) — `.cursor/skills/` 或 `.agents/skills/`
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — `~/.claude/skills/` 或 `.agents/skills/`
- [Codex CLI](https://github.com/openai/codex) — `~/.codex/skills/` 或 `.agents/skills/`
- 任何读取 `SKILL.md` 的工具

> **注意**：仅支持 macOS 和 Linux，不支持 Windows（依赖 bash 脚本）。

## 前置要求

- `jq`、`curl`、`git` 在 PATH 中（macOS 自带）
- [`gh`](https://cli.github.com) 已登录你的 GitHub / GitHub Enterprise 主机
- Jira Cloud 账号
- **Atlassian MCP** — Jira 访问的首选方式。装了它就完全不需要 Jira token；没装才用 API token 兜底。

## 安装

### 方式一：npx（推荐）

```bash
npx jira-fix-skill
```

自动检测已安装的 AI 工具（Cursor / Claude Code / Codex CLI），让你选择安装位置。无需全局安装。如果已有旧版本，会原地升级并保留 `.env` 配置。

### 方式二：克隆到 skills 目录

```bash
# Cursor（全局）
git clone https://github.com/Leon-Kang/jira-fix-skill.git ~/.cursor/skills/jira-fix

# Claude Code（全局）
git clone https://github.com/Leon-Kang/jira-fix-skill.git ~/.claude/skills/jira-fix

# Codex CLI（全局）
git clone https://github.com/Leon-Kang/jira-fix-skill.git ~/.codex/skills/jira-fix

# 或安装到项目中（团队共享，所有平台通用）
git clone https://github.com/Leon-Kang/jira-fix-skill.git .agents/skills/jira-fix
```

### 方式三：手动复制

```bash
# 选一个平台路径，或用 .agents/skills/ 跨平台通用
TARGET=~/.cursor/skills/jira-fix   # 或 ~/.claude/skills/ 或 ~/.codex/skills/
mkdir -p "$TARGET/scripts"
cp SKILL.md .env.example "$TARGET/"
cp scripts/*.sh "$TARGET/scripts/"
chmod +x "$TARGET/scripts/"*.sh
```

## 配置

AI agent 会在首次使用时自动引导你完成配置。只需说 "show my tickets"。

### GitHub 认证

GitHub 凭据存放在 `gh` 的凭据库里——skill 不会索要、打印或保存任何 GitHub token。

```bash
gh auth login --hostname your-host.ghe.com --git-protocol ssh --web
gh auth status --hostname your-host.ghe.com
```

主机、组织和仓库都从当前仓库的 git remote 自动识别，所以 `.env` 里不需要写任何跟具体仓库相关的配置。

### Jira 访问

如果已连接 Atlassian MCP，就不需要配置任何认证——包括评论在内的所有 Jira 读写都走 MCP。

```bash
cd <安装目录>    # 例如 ~/.cursor/skills/jira-fix
cp .env.example .env
chmod 600 .env
```

```bash
JIRA_URL=https://your-site.atlassian.net
MAIN_BRANCH=develop
```

**只有在没有 MCP 时**，才需要在 https://id.atlassian.com/manage-profile/security → **"Create API token with scopes"** → App 选 **Jira** 创建一个兜底 token：

```bash
ATLASSIAN_EMAIL=you@example.com
ATLASSIAN_API_TOKEN=your-jira-token
```

用 `bash scripts/jira-api.sh list` 验证兜底路径。

## 使用方法

用自然语言对 AI 说：

| 你说 | 效果 |
|------|------|
| "show my tickets" | 列出你的 Jira tickets |
| "fix PROJ-123" | 调查 → 情报门禁 → 出计划 → 你批准 → 写代码 → 测试 → review → 推送门禁 |
| "检查最新评论" | 读取当前分支 PR 上的新反馈并直接修复 |
| *（粘一个 PR 链接）* | 同上，针对该 PR——在任意目录都能用 |
| "plan for PROJ-123" | 只调查和出计划，绝不动代码 |

## `.env` 变量说明

| 变量 | 必填 | 说明 |
|------|------|------|
| `JIRA_URL` | 是 | Jira Cloud 地址，如 `https://acme.atlassian.net` |
| `ATLASSIAN_EMAIL` | 否 | 仅用于无 MCP 时的兜底 |
| `ATLASSIAN_API_TOKEN` | 否 | 仅用于无 MCP 时的兜底（Jira 权限） |
| `MAIN_BRANCH` | 否 | PR 目标分支（默认 `develop`） |
| `GIT_REMOTE` | 否 | 读取仓库信息的 git remote（默认 `origin`） |
| `GH_HOST` | 否 | 期望的 GitHub 主机，用于防止误操作到别的仓库 |
| `TEST_URL_PATTERN` | 否 | 测试环境 URL，支持 `{TICKET_NUMBER}` 占位符 |
| `TEST_CMD` | 否 | 自定义测试命令（默认自动检测） |
| `LINT_CMD` | 否 | 自定义 lint 命令（未设置则跳过） |
| `FMT_CMD` | 否 | 自定义格式化命令（未设置则跳过） |
| `JIRA_LIST_JQL` | 否 | 自定义 JQL 覆盖默认的 ticket 查询 |

GitHub token 不属于这个文件；连接了 MCP 时，Jira token 也不需要。

## 工作原理

### Jira：MCP 优先

只要 Atlassian MCP 可用，所有 Jira 操作都走 MCP——列表、读 ticket、读评论线程、下载截图、发评论。`scripts/jira-api.sh` 只服务于没有装 MCP 的环境，直接调用 Jira REST API。

有两个坑值得知道：

`getJiraIssue` 的默认字段集不含 `attachment` 和 `issuelinks`，所以 skill 总是显式传 `fields`。评论用 `listJiraIssueComments` 读，因为 `getJiraIssue` 即使指定了也可能不返回评论。`getJiraIssue` 没返回评论，不代表这个 ticket 没有评论。

截图会下载下来看。markdown 格式会把内嵌图片渲染成无法访问的 `![](blob:...)`，所以带附件的 ticket 改用 HTML 读——那里每张图是一个 media 节点，带着附件文件名，能对上它属于哪条需求。然后 skill 通过 MCP 的 `downloadJiraIssueAttachment` 把图片下载下来看。只有下载失败时，才会请你把关键截图贴进对话，而不是猜图里是什么。

### GitHub：通过 `gh`

`scripts/gh-pr.sh` 封装 GitHub CLI。它解析 git remote（支持 `me@your-host.ghe.com:org/repo.git` 这类自定义 SSH 用户名的地址，并对 HTTPS 地址里内嵌的凭据做脱敏），校验该主机的 `gh` 登录状态，然后分发 PR 操作。

两个脚本都是非交互式的，接受文本输入、输出文本，并支持 `--format json`：

```bash
bash scripts/gh-pr.sh repo detect --format json
bash scripts/gh-pr.sh pr find                     # 当前分支
bash scripts/gh-pr.sh pr create --title "fix(web): PROJ-123 nav - fix overlap" \
                                --source feature/PROJ-123-header-overlap --body-file -
bash scripts/gh-pr.sh pr feedback --pr https://HOST/org/repo/pull/42
bash scripts/gh-pr.sh pr feedback --since "$(git log -1 --format=%cI)" --format json

bash scripts/jira-api.sh list --format json
bash scripts/jira-api.sh get PROJ-123
bash scripts/jira-api.sh comments PROJ-123 --format json
printf 'Fixed: ...\nPR: https://...\n' | bash scripts/jira-api.sh comment PROJ-123 --text-file -
```

两个脚本都支持 `--help` 查看完整用法。

### 文件结构

```
jira-fix-skill/
├── SKILL.md          # Skill 定义文件（AI 读取）
├── .env.example      # 配置模板
├── .env              # 你的本地配置（已 gitignore）
├── package.json      # npm 包（支持 npx 安装）
├── bin/
│   └── install.sh    # 交互式安装脚本
├── scripts/
│   ├── jira-api.sh   # Jira：list、get、comments、comment
│   └── gh-pr.sh      # GitHub / GHES：repo detect、pr find/create/feedback
├── README.md         # English
├── README.zh-CN.md   # 中文
├── LICENSE
└── .gitignore
```

## 自定义

### 自定义 JQL

```bash
JIRA_LIST_JQL="project = MYPROJ AND assignee = currentUser() AND sprint in openSprints() ORDER BY priority ASC"
```

### 自定义测试 / lint / 格式化命令

```bash
TEST_CMD=yarn run test
FMT_CMD=yarn run prettier --write .
LINT_CMD=scripts/lint-changed.sh --merge-base origin/main
```

未设置时，skill 会从 `package.json` 自动检测测试命令，lint / 格式化若未配置则跳过。

### 测试环境 URL

如果你的 CI 会部署预览环境：

```bash
TEST_URL_PATTERN=https://preview-{TICKET_NUMBER}.your-app.dev/
```

`{TICKET_NUMBER}` 会被替换为 ticket key 的数字部分（如 `PROJ-456` → `456`）。

## 升级

再次运行 `npx jira-fix-skill` 即可——会检测已有安装并原地升级，保留 `.env` 配置。

### 从 1.x（Bitbucket）升级

2.0 版本用 GitHub / GitHub Enterprise 替换了 Bitbucket Cloud：

- `scripts/bb-pr.sh` 已删除，改用 `scripts/gh-pr.sh`
- `BB_API_TOKEN` 和 `BB_WORKSPACE` 不再使用，可以从 `.env` 中删掉
- 改用 `gh auth login --hostname HOST --git-protocol ssh --web` 认证

升级时安装脚本会提示这两处残留。

## License

MIT
