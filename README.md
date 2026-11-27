# jira-fix-skill

English | [中文](./README.zh-CN.md)

An AI agent skill that automates the Jira → Code → GitHub Enterprise PR workflow, with human approval gates in the right places.

Tell your AI agent "fix PROJ-123" and it gathers the intel first — ticket, comment thread, existing branches and PRs, the actual code, the git history — then either asks you what is missing or hands you a plan to approve. Only after you approve does it touch code. Nothing gets committed, pushed, opened as a PR, or posted to Jira without your say-so.

## What it does

```
Jira ticket → recon → intel gate → plan gate → code → test → lint → review → push gate → (optional) draft PR → (optional) Jira comment
```

- **List tickets** — show your assigned Jira tickets
- **Fix a ticket** — end-to-end, with three approval gates
- **Apply feedback** — paste a PR link or just say "check the latest comments"; reads Jira comments *and* PR reviews/inline comments, then goes straight to fixing
- **Plan only** — recon and plan without touching code

### The three gates

1. **Intel gate** — if the ticket is under-specified, the agent tells you exactly what is missing and why, then stops. It does not guess.
2. **Plan gate** — you get a six-section plan (understanding, files, changes, verification, risk, branch/commit) and nothing is written until you approve it.
3. **Push gate** — you see the diff stat, verification evidence and the exact commit message before anything is committed or pushed.

Feedback rounds deliberately skip all three. The ticket was already investigated, the plan already approved and the branch already published, so reviewer comments go straight to work — with per-item escalation when something is genuinely ambiguous, out of scope, or conflicts with the ticket.

### Other safety properties

- Never changes Jira ticket status — comments only, and only when you confirm
- Never stashes your work automatically; a dirty worktree stops the workflow
- Always runs a code review before the push gate, using the project's review skill when one exists
- PRs are always drafts, and `pr create` is idempotent so it never opens a duplicate
- Jira comments are capped at 3 lines — outcome and links, nothing else

## Supported platforms

Works with any AI coding agent that supports agent skills:

- [Cursor](https://cursor.com) — `.cursor/skills/` or `.agents/skills/`
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — `~/.claude/skills/` or `.agents/skills/`
- [Codex CLI](https://github.com/openai/codex) — `~/.codex/skills/` or `.agents/skills/`
- Any tool that reads `SKILL.md` files

> **Note**: Requires macOS or Linux. Windows is not supported (bash scripts).

## Prerequisites

- `jq`, `curl`, `git` in PATH (pre-installed on macOS)
- [`gh`](https://cli.github.com) authenticated against your GitHub / GitHub Enterprise host
- A Jira Cloud account
- **Atlassian MCP** — the preferred path for all Jira access. With it connected, the skill needs no Jira token at all; without it, a Jira API token is used as a fallback.

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
cp SKILL.md .env.example "$TARGET/"
cp scripts/*.sh "$TARGET/scripts/"
chmod +x "$TARGET/scripts/"*.sh
```

## Setup

The AI agent handles setup interactively on first use. Just say "show my tickets" and it walks you through it.

### GitHub authentication

GitHub credentials live in the `gh` credential store — the skill never asks for, prints, or stores a GitHub token.

```bash
gh auth login --hostname your-host.ghe.com --git-protocol ssh --web
gh auth status --hostname your-host.ghe.com
```

The host, owner and repository are detected from the git remote of whatever repo you are working in, so nothing repo-specific goes into `.env`.

### Jira access

If the Atlassian MCP is connected, there is nothing to authenticate — all Jira reads and writes, comments included, go through MCP.

```bash
cd <your-install-directory>    # e.g. ~/.cursor/skills/jira-fix
cp .env.example .env
chmod 600 .env
```

```bash
JIRA_URL=https://your-site.atlassian.net
MAIN_BRANCH=develop
```

**Only if you do not have the MCP**, add a fallback token created at https://id.atlassian.com/manage-profile/security → **"Create API token with scopes"** → App: **Jira**:

```bash
ATLASSIAN_EMAIL=you@example.com
ATLASSIAN_API_TOKEN=your-jira-token
```

Verify the fallback with `bash scripts/jira-api.sh list`.

## Usage

Just talk to your AI agent naturally:

| You say | What happens |
|---------|-------------|
| "show my tickets" | Lists your assigned Jira tickets |
| "fix PROJ-123" | Recon → intel gate → plan → your approval → code → test → review → push gate |
| "check the latest comments" | Reads new feedback on the current branch's PR and fixes it |
| *(paste a PR link)* | Same, for that PR — works from any directory |
| "plan for PROJ-123" | Recon and plan only, never touches code |

## `.env` reference

| Variable | Required | Description |
|----------|----------|-------------|
| `JIRA_URL` | Yes | Your Jira Cloud URL, e.g. `https://acme.atlassian.net` |
| `ATLASSIAN_EMAIL` | No | Only for the no-MCP fallback |
| `ATLASSIAN_API_TOKEN` | No | Only for the no-MCP fallback (scoped to Jira) |
| `MAIN_BRANCH` | No | Target branch for PRs (default: `develop`) |
| `GIT_REMOTE` | No | Git remote to read the repository from (default: `origin`) |
| `GH_HOST` | No | Expected GitHub host; guards against acting on the wrong repo |
| `TEST_URL_PATTERN` | No | Test URL with `{TICKET_NUMBER}` placeholder |
| `TEST_CMD` | No | Custom test command (default: auto-detect) |
| `LINT_CMD` | No | Custom lint command (default: skip if not set) |
| `FMT_CMD` | No | Custom format command (default: skip if not set) |
| `JIRA_LIST_JQL` | No | Custom JQL to override default ticket query |

No GitHub token belongs in this file, and no Jira token either when the MCP is connected.

## How it works

### MCP-first for Jira

Jira operations go through the **Atlassian MCP** whenever it is available — listing, reading tickets, reading the comment thread, downloading screenshots, and posting comments. `scripts/jira-api.sh` exists for setups without the MCP and talks to the Jira REST API directly.

Two details worth knowing:

`getJiraIssue` omits `attachment` and `issuelinks` from its default field set, so the skill always passes `fields` explicitly. Comments come from `listJiraIssueComments`, because `getJiraIssue` can leave them out even when asked. A ticket is not commentless just because `getJiraIssue` came back without comments.

Screenshots are downloaded and read. In markdown responses every embedded image becomes an unreachable `![](blob:...)`, so tickets with attachments are read as HTML, where each image is a media node carrying the attachment filename — that ties a screenshot to the requirement it sits under. The skill then downloads the image through the MCP `downloadJiraIssueAttachment` operation and looks at it. Only when a download fails does it ask you to paste a load-bearing screenshot, rather than guessing what it shows.

### GitHub through `gh`

`scripts/gh-pr.sh` wraps the GitHub CLI. It parses the git remote (including SSH remotes with custom usernames like `me@your-host.ghe.com:org/repo.git`, redacting any credentials embedded in HTTPS URLs), verifies `gh` auth for that host, and dispatches PR operations.

Both scripts are non-interactive, take text input, print text, and support `--format json`:

```bash
bash scripts/gh-pr.sh repo detect --format json
bash scripts/gh-pr.sh pr find                     # current branch
bash scripts/gh-pr.sh pr create --title "fix(web): PROJ-123 nav - fix overlap" \
                                --source feature/PROJ-123-header-overlap --body-file -
bash scripts/gh-pr.sh pr feedback --pr https://HOST/org/repo/pull/42
bash scripts/gh-pr.sh pr feedback --since "$(git log -1 --format=%cI)" --format json

bash scripts/jira-api.sh list --format json
bash scripts/jira-api.sh get PROJ-123
bash scripts/jira-api.sh comments PROJ-123 --format json
printf 'Fixed: ...\nPR: https://...\n' | bash scripts/jira-api.sh comment PROJ-123 --text-file -
```

Run either script with `--help` for full usage.

### File structure

```
jira-fix-skill/
├── SKILL.md          # Skill definition (the AI reads this)
├── .env.example      # Template for configuration
├── .env              # Your local config (gitignored)
├── package.json      # npm package (enables npx install)
├── bin/
│   └── install.sh    # Interactive installer
├── scripts/
│   ├── jira-api.sh   # Jira: list, get, comments, comment
│   └── gh-pr.sh      # GitHub / GHES: repo detect, pr find/create/feedback
├── README.md
├── LICENSE
└── .gitignore
```

## Customization

### Custom JQL

```bash
JIRA_LIST_JQL="project = MYPROJ AND assignee = currentUser() AND sprint in openSprints() ORDER BY priority ASC"
```

### Custom test / lint / format commands

```bash
TEST_CMD=yarn run test
FMT_CMD=yarn run prettier --write .
LINT_CMD=scripts/lint-changed.sh --merge-base origin/main
```

If not set, the skill auto-detects test commands from `package.json` and skips lint/format if no command is configured.

### Test URL

If your CI deploys preview environments:

```bash
TEST_URL_PATTERN=https://preview-{TICKET_NUMBER}.your-app.dev/
```

The `{TICKET_NUMBER}` placeholder is replaced with the numeric part of the ticket key (e.g. `PROJ-456` → `456`).

## Upgrading

Run `npx jira-fix-skill` again — it detects existing installs and upgrades while preserving your `.env`.

### Upgrading from 1.x (Bitbucket)

Version 2.0 replaces Bitbucket Cloud with GitHub / GitHub Enterprise:

- `scripts/bb-pr.sh` is gone; use `scripts/gh-pr.sh`
- `BB_API_TOKEN` and `BB_WORKSPACE` are no longer used — delete them from `.env`
- Authenticate with `gh auth login --hostname HOST --git-protocol ssh --web` instead

The installer flags both leftovers during an upgrade.

## License

MIT
