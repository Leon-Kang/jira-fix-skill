# jira-fix-skill

English | [中文](./README.zh-CN.md)

An AI agent skill that automates the Jira → Code → Bitbucket PR workflow.

Tell your AI agent "fix PROJ-123" and it will fetch the ticket, create a branch, implement the fix, run tests, create a draft PR on Bitbucket, and propose a Jira comment — all in one flow.

## What it does

```
Jira ticket → read details → create branch → implement fix → test → lint → commit → draft PR → Jira comment
```

- **List tickets** — show your assigned Jira tickets
- **Fix a ticket** — end-to-end: fetch → branch → code → test → lint → PR → comment
- **Apply feedback** — address review comments and push updates
- **Dry run** — plan a fix without touching code

### Safety by design

- Never changes Jira ticket status (only adds comments, and only when you confirm)
- PRs are always created as drafts
- All Jira comments are shown to you first — you decide whether to post

## Supported platforms

Works with any AI coding agent that supports agent skills:

- [Cursor](https://cursor.com) (`.cursor/skills/` or `.agents/skills/`)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`~/.claude/skills/` or `.agents/skills/`)
- Any tool that reads `SKILL.md` files

## Prerequisites

- `jq`, `curl`, `git` in PATH (pre-installed on macOS)
- A Jira Cloud + Bitbucket Cloud account
- **Atlassian MCP** (optional — preferred when available, auto-fallback to bash API)

## Installation

### Option 1: Clone into your skills directory

```bash
# For Cursor / Claude Code (global)
git clone https://github.com/Leon-Kang/jira-fix-skill.git ~/.agents/skills/jira-fix

# Or inside a project (shared with team)
git clone https://github.com/Leon-Kang/jira-fix-skill.git .agents/skills/jira-fix
```

### Option 2: Copy manually

```bash
mkdir -p ~/.agents/skills/jira-fix
cp -r SKILL.md .env.example scripts/ ~/.agents/skills/jira-fix/
```

## Setup

### 1. Create your `.env`

```bash
cd ~/.agents/skills/jira-fix   # or wherever you installed
cp .env.example .env
chmod 600 .env
```

### 2. Create API tokens

Go to https://id.atlassian.com/manage-profile/security

Click **"Create and manage API tokens"** → **"Create API token with scopes"**:

#### Jira token (`ATLASSIAN_API_TOKEN`)

| Field | Value |
|-------|-------|
| Name | `jira-fix-jira` |
| App | Jira |

#### Bitbucket token (`BB_API_TOKEN`)

| Field | Value |
|-------|-------|
| Name | `jira-fix-bitbucket` |
| App | **Bitbucket** |
| Scopes | **Repositories Read + Write**, **Pull Requests Read + Write** |

> Both tokens are created on the same Atlassian page. They look similar but have different scopes.

### 3. Fill in `.env`

```bash
ATLASSIAN_EMAIL=you@example.com
ATLASSIAN_API_TOKEN=your-jira-token      # Jira token from step 2
BB_API_TOKEN=your-bitbucket-token        # Bitbucket token from step 2
JIRA_URL=https://your-site.atlassian.net
BB_WORKSPACE=your-workspace-slug
MAIN_BRANCH=develop                     # or main
TEST_URL_PATTERN=                       # optional, e.g. https://test-{TICKET_NUMBER}.example.com
```

### 4. Verify

```bash
bash scripts/jira-api.sh list
```

If you see your tickets, you're all set.

## Usage

Just talk to your AI agent naturally:

| You say | What happens |
|---------|-------------|
| "show my tickets" | Lists your assigned Jira tickets |
| "fix PROJ-123" | Full workflow: fetch → branch → code → test → lint → PR |
| "apply feedback on PROJ-123" | Reads comments, makes targeted fixes, pushes |
| "plan for PROJ-123" | Outputs a fix plan without touching code |

## `.env` reference

| Variable | Required | Description |
|----------|----------|-------------|
| `ATLASSIAN_EMAIL` | Yes | Your Atlassian account email |
| `ATLASSIAN_API_TOKEN` | Yes | Jira API token (scoped to Jira) |
| `BB_API_TOKEN` | Yes | Bitbucket API token (scoped to Bitbucket) |
| `JIRA_URL` | Yes | Your Jira Cloud URL, e.g. `https://acme.atlassian.net` |
| `BB_WORKSPACE` | Yes | Bitbucket workspace slug |
| `MAIN_BRANCH` | No | Target branch for PRs (default: `develop`) |
| `TEST_URL_PATTERN` | No | Test URL with `{TICKET_NUMBER}` placeholder |

## How it works

### MCP-first, bash-fallback

The skill prefers the **Atlassian MCP** (Cursor's built-in integration) for Jira operations. If MCP is not available, it falls back to `scripts/jira-api.sh` which calls the Jira REST API directly.

Bitbucket PR creation always uses `scripts/bb-pr.sh` (no MCP available for this).

### File structure

```
jira-fix-skill/
├── SKILL.md          # Skill definition (the AI reads this)
├── .env.example      # Template for configuration
├── .env              # Your secrets (gitignored)
├── scripts/
│   ├── jira-api.sh   # Jira API: list, get, comment
│   └── bb-pr.sh      # Bitbucket: create draft PR
├── README.md
├── LICENSE
└── .gitignore
```

## Customization

### Custom JQL

Set `JIRA_LIST_JQL` in your `.env` to override the default ticket query:

```bash
JIRA_LIST_JQL="project = MYPROJ AND assignee = currentUser() AND sprint in openSprints() ORDER BY priority ASC"
```

### Test URL

If your CI deploys preview environments, set `TEST_URL_PATTERN`:

```bash
TEST_URL_PATTERN=https://preview-{TICKET_NUMBER}.your-app.dev/
```

The `{TICKET_NUMBER}` placeholder is replaced with the numeric part of the ticket key (e.g. `PROJ-456` → `456`).

## License

MIT
