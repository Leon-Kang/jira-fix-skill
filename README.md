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

- [Cursor](https://cursor.com) — `.cursor/skills/` or `.agents/skills/`
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — `~/.claude/skills/` or `.agents/skills/`
- [Codex CLI](https://github.com/openai/codex) — `~/.codex/skills/` or `.agents/skills/`
- Any tool that reads `SKILL.md` files

> **Note**: Requires macOS or Linux. Windows is not supported (bash scripts).

## Prerequisites

- `jq`, `curl`, `git` in PATH (pre-installed on macOS)
- A Jira Cloud + Bitbucket Cloud account
- **Atlassian MCP** (optional — preferred when available, auto-fallback to bash API)

## Installation

### Option 1: npx (recommended)

```bash
npx jira-fix-skill
```

Auto-detects your installed AI tools (Cursor / Claude Code / Codex CLI) and lets you pick where to install. No global install needed. If you already have a previous version, it upgrades in-place while preserving your `.env`.

### Option 2: Clone into your skills directory

```bash
# Cursor (global)
git clone https://github.com/Leon-Kang/jira-fix-skill.git ~/.cursor/skills/jira-fix

# Claude Code (global)
git clone https://github.com/Leon-Kang/jira-fix-skill.git ~/.claude/skills/jira-fix

# Codex CLI (global)
git clone https://github.com/Leon-Kang/jira-fix-skill.git ~/.codex/skills/jira-fix

# Or inside a project (shared with team, works with all platforms)
git clone https://github.com/Leon-Kang/jira-fix-skill.git .agents/skills/jira-fix
```

### Option 3: Copy manually

```bash
# Pick your platform — or use .agents/skills/ for cross-platform
TARGET=~/.cursor/skills/jira-fix   # or ~/.claude/skills/ or ~/.codex/skills/
mkdir -p "$TARGET/scripts"
cp SKILL.md .env.example scripts/*.sh "$TARGET/"
cp scripts/*.sh "$TARGET/scripts/"
chmod +x "$TARGET/scripts/"*.sh
```

## Setup

The AI agent handles most of the setup interactively on first use. Just say "show my tickets" and it will walk you through the process.

Here's what happens behind the scenes:

### Interactive setup (handled by the AI)

1. **Asks for a Jira ticket URL** — paste any ticket link from your browser. The agent auto-extracts your Jira domain and project prefix.
2. **Auto-detects Bitbucket workspace** — reads `git remote` to find your workspace slug.
3. **Auto-detects default branch** — checks `origin/HEAD` for `main` or `develop`.
4. **Checks for Atlassian MCP** — if installed, uses it for faster Jira access. If not, offers guidance to install it (optional).
5. **Guides token creation** — walks you through creating two API tokens at https://id.atlassian.com/manage-profile/security
6. **Writes `.env`** — saves everything to a gitignored `.env` file.
7. **Verifies** — runs a test query to confirm everything works.

### Manual setup (if you prefer)

```bash
cd <your-install-directory>    # e.g. ~/.cursor/skills/jira-fix
cp .env.example .env
chmod 600 .env
```

Create two API tokens at https://id.atlassian.com/manage-profile/security → **"Create API token with scopes"**:

| Token | App | Scopes |
|-------|-----|--------|
| `ATLASSIAN_API_TOKEN` | Jira | (default) |
| `BB_API_TOKEN` | Bitbucket | Repositories R/W, Pull Requests R/W |

Fill in `.env`:

```bash
ATLASSIAN_EMAIL=you@example.com
ATLASSIAN_API_TOKEN=your-jira-token
BB_API_TOKEN=your-bitbucket-token
JIRA_URL=https://your-site.atlassian.net
BB_WORKSPACE=your-workspace-slug
MAIN_BRANCH=develop
TEST_URL_PATTERN=
```

Verify: `bash scripts/jira-api.sh list`

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
| `TEST_CMD` | No | Custom test command (default: auto-detect) |
| `LINT_CMD` | No | Custom lint command (default: skip if not set) |
| `FMT_CMD` | No | Custom format command (default: skip if not set) |
| `JIRA_LIST_JQL` | No | Custom JQL to override default ticket query |

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
├── package.json      # npm package (enables npx install)
├── bin/
│   └── install.sh    # Interactive installer
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

### Custom test / lint / format commands

Set these in `.env` to match your project's tooling:

```bash
TEST_CMD=yarn run test
FMT_CMD=yarn run dprint fmt --allow-no-files
LINT_CMD=scripts/changes-lint.sh --merge-base origin/develop
```

If not set, the skill auto-detects test commands from `package.json` and skips lint/format if no command is configured.

### Test URL

If your CI deploys preview environments, set `TEST_URL_PATTERN`:

```bash
TEST_URL_PATTERN=https://preview-{TICKET_NUMBER}.your-app.dev/
```

The `{TICKET_NUMBER}` placeholder is replaced with the numeric part of the ticket key (e.g. `PROJ-456` → `456`).

## Upgrading

Run `npx jira-fix-skill` again — it detects existing installs and upgrades while preserving your `.env`.

Or with git:

```bash
cd <your-install-directory>
git pull
```

## License

MIT
