---
name: jira-fix
description: "Automate the full Jira ticket fix workflow: list your assigned tickets, pick one, auto-fix code, create Bitbucket draft PR, and comment on Jira. Also handles reviewer feedback loops. Use this skill whenever the user mentions Jira tickets, fixing a ticket, listing their tasks, creating a PR from a ticket, responding to Jira feedback, or anything involving the Jira-to-code-to-PR pipeline. Trigger phrases include: 'fix PROJ-123', 'show my tickets', 'my Jira tasks', 'what should I work on', 'continue fixing', 'apply feedback', 'create PR for ticket', 'list my bugs'. Even casual phrases like 'what tickets do I have' or 'work on the next bug' should trigger this skill."
---

# Jira Fix Workflow

Automates: Jira ticket → code fix → Bitbucket draft PR → Jira comment → feedback loop.

**Scope**: Only comments on Jira. Never changes ticket status. PO manages lifecycle. PRs are always draft — human reviews before merge.

## Prerequisites

- `jq`, `curl`, `git` available in PATH (pre-installed on macOS)
- **Atlassian MCP** (optional — preferred when available, auto-fallback to bash API otherwise)

### First-time setup

Before first use, check if `SKILL_DIR/.env` exists and contains valid (non-placeholder) values. If not, run the interactive setup below.

**Step 1 — Ask for a Jira ticket URL:**

Ask the user: "Paste a link to any Jira ticket (e.g. from your browser address bar)."

The user will provide something like:
`https://acme.atlassian.net/browse/PROJ-123` or `https://acme.atlassian.net/jira/software/c/projects/PROJ/boards/1?assignee=...`

Extract from the URL:
- **JIRA_URL**: the origin part → `https://acme.atlassian.net`
- **Project prefix**: the ticket key prefix → `PROJ` (store this for later use in branch naming and JQL)

**Step 2 — Auto-detect Bitbucket workspace:**

```bash
git remote get-url origin
```

If the remote contains `bitbucket.org`, extract the workspace:
- `git@bitbucket.org:myworkspace/myrepo.git` → `BB_WORKSPACE=myworkspace`
- `https://bitbucket.org/myworkspace/myrepo.git` → `BB_WORKSPACE=myworkspace`

If not a Bitbucket remote, ask the user for `BB_WORKSPACE`.

**Step 3 — Detect default branch:**

```bash
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||'
```

Use the result as `MAIN_BRANCH`. Fall back to `develop` if detection fails.

**Step 4 — Check for Atlassian MCP:**

Check if `plugin-atlassian-atlassian` MCP server is available by attempting a lightweight call:

```
CallMcpTool(server:"plugin-atlassian-atlassian", toolName:"getAccessibleAtlassianResources", arguments:{})
```

- **If MCP responds**: Tell the user "Atlassian MCP is connected. Jira operations will use MCP (faster, no extra token needed for read)."
- **If MCP is not available**: Tell the user:
  > Atlassian MCP is not installed. The skill will use direct API calls instead (works fine, just needs an API token).
  >
  > To install the MCP for a better experience:
  > 1. Open Cursor Settings → MCP
  > 2. Search for "Atlassian" and enable it
  > 3. Follow the OAuth login prompt
  >
  > Would you like to continue without MCP, or set it up first?

  Proceed with setup regardless of the answer — the skill works with or without MCP.

**Step 5 — Create .env:**

```bash
cp SKILL_DIR/.env.example SKILL_DIR/.env
chmod 600 SKILL_DIR/.env
```

Then write the auto-detected values into `SKILL_DIR/.env`:

```bash
ATLASSIAN_EMAIL=        # ask the user
ATLASSIAN_API_TOKEN=    # ask the user (see token creation below)
BB_API_TOKEN=           # ask the user (see token creation below)
JIRA_URL=               # auto-detected from step 1
BB_WORKSPACE=           # auto-detected from step 2
MAIN_BRANCH=            # auto-detected from step 3
TEST_URL_PATTERN=       # ask the user (optional)
```

**Step 6 — Guide token creation:**

Ask the user for their Atlassian email, then guide them to create tokens:

> Go to https://id.atlassian.com/manage-profile/security
>
> Click **"Create and manage API tokens"** → **"Create API token with scopes"**:
>
> **Token 1 — Jira** (`ATLASSIAN_API_TOKEN`):
> - Name: `jira-fix-jira`
> - App: Jira
>
> **Token 2 — Bitbucket** (`BB_API_TOKEN`):
> - Name: `jira-fix-bitbucket`
> - App: **Bitbucket**
> - Scopes: **Repositories Read + Write**, **Pull Requests Read + Write**
>
> Both tokens are created on the same page. They look similar but have different scopes.

Collect the email and both tokens from the user, then write them into `SKILL_DIR/.env`.

**Step 7 — Verify:**

```bash
bash SKILL_DIR/scripts/jira-api.sh list
```

If it returns tickets, tell the user setup is complete. If it fails, read the error and help troubleshoot (common issues: wrong email, expired token, incorrect JIRA_URL).

### .env variables

All environment-specific values are read from `SKILL_DIR/.env`:

- **JIRA_URL**: Your Atlassian site (e.g. `https://your-site.atlassian.net`)
- **BB_WORKSPACE**: Your Bitbucket workspace slug
- **MAIN_BRANCH**: Target branch for PRs (default: `develop`)
- **TEST_URL_PATTERN**: Optional test URL pattern with `{TICKET_NUMBER}` placeholder
- **Bitbucket repo**: auto-detected from `git remote`

## Jira access: MCP-first, bash-fallback

For every Jira operation, prefer MCP if available; fall back to bash script if not.

### MCP (preferred)

Use when `plugin-atlassian-atlassian` MCP server is connected:

Read `JIRA_URL` from `SKILL_DIR/.env` to get the cloudId (the hostname part, e.g. `your-site.atlassian.net`):

- **List tickets**: `CallMcpTool(server:"plugin-atlassian-atlassian", toolName:"searchJiraIssuesUsingJql", arguments:{cloudId:"<JIRA_HOST>", jql:"...", maxResults:20, fields:["summary","status","issuetype","priority","updated"], responseContentFormat:"markdown"})`
- **Get ticket**: `CallMcpTool(server:"plugin-atlassian-atlassian", toolName:"getJiraIssue", arguments:{cloudId:"<JIRA_HOST>", issueIdOrKey:"TICKET-KEY", responseContentFormat:"markdown"})`
- **Add comment**: `CallMcpTool(server:"plugin-atlassian-atlassian", toolName:"addCommentToJiraIssue", arguments:{cloudId:"<JIRA_HOST>", issueIdOrKey:"TICKET-KEY", commentBody:"TEXT", contentFormat:"markdown"})`

### Bash fallback

Use when MCP is not available:

- **List tickets**: `bash SKILL_DIR/scripts/jira-api.sh list`
- **Get ticket**: `bash SKILL_DIR/scripts/jira-api.sh get TICKET-KEY`
- **Add comment**: `bash SKILL_DIR/scripts/jira-api.sh comment TICKET-KEY "TEXT"`

### Bitbucket (bash only — no MCP available)

- **Create draft PR**: `bash SKILL_DIR/scripts/bb-pr.sh TICKET-KEY "TITLE" BRANCH "DESCRIPTION"`

## Workflows

### 1. List my tickets

When user says things like "show my tickets", "what should I work on", "my Jira tasks":

**Jira: list tickets** (MCP or bash — see above)

Default JQL: `assignee = currentUser() AND status not in (Done, Cancelled) ORDER BY priority ASC, updated DESC`

Present the tickets clearly. Let the user pick one, or suggest the highest-priority actionable ticket.

### 2. Fix a ticket

When user says "fix PROJ-123" or picks a ticket from the list:

**Step 1 — Fetch ticket details:**

**Jira: get ticket** (MCP or bash)

Read the output — it contains summary, type, priority, and description. Share this with the user for confirmation before proceeding.

**Step 2 — Pull latest & create branch (BEFORE any code work):**

This step MUST complete before reading, exploring, or modifying any code:
```bash
# Save any uncommitted work (remember to restore later if needed)
STASHED=false
if ! git diff --quiet HEAD 2>/dev/null || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  git stash --include-untracked && STASHED=true
fi

git checkout develop
git pull origin develop

# Check if branch already exists
BRANCH="fix/TICKET-KEY-short-description"
if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
  git checkout "${BRANCH}"
  git merge develop  # bring branch up to date
else
  git checkout -b "${BRANCH}"
fi

# Restore stashed work if it was on develop (skip if switching context)
$STASHED && echo "NOTE: You have stashed changes. Run 'git stash pop' if you need them."
```
Use `feature/` prefix for Story/Feature types. Generate a short kebab-case suffix from the ticket summary.

**Step 3 — Implement the fix:**

Only start after the feature branch is checked out:
- Read the codebase to understand relevant code
- Plan the fix based on ticket description
- Implement with clean, tested code
- Run existing tests
- Add or update tests for changes
- Keep changes minimal and focused on the ticket

**Step 4 — Test (auto-retry up to 3 times):**
Run `yarn run test` (or `yarn run jest --no-cache --runInBand path/to/test.spec.ts` for specific test files). If tests fail, read the output and fix. Retry up to 3 times. If still failing after 3 attempts, tell the user and ask whether to comment on Jira.

**Step 5 — Format & Lint (must pass before commit):**

Run dprint on all changed files (excluding deleted), then run the CI lint script:
```bash
# Format changed files (--diff-filter=d excludes deleted files)
yarn run dprint fmt --allow-no-files $(git diff --diff-filter=d --name-only develop -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.json')

# Ensure origin/develop is fresh before lint comparison
git fetch origin develop

# Full lint check (TS types + Biome lint + format verification)
scripts/changes-lint.sh --merge-base origin/develop
```

If lint errors are found, fix them and re-run until clean. Do NOT skip this step — PRs that fail CI lint will be rejected.

**Step 6 — Commit and push:**
Use the project commit convention: `type(package): TICKET-KEY module - description`

- **type**: `feat` for Story/Feature, `fix` for Bug, `refactor`/`chore`/`docs` as appropriate
- **package**: `client` or `server`
- **module**: the feature/module within the package — e.g. `nav`, `chat`, `profile`, `payment`, `component`

Examples:
- `fix(client): PROJ-123 nav - layout style issue`
- `feat(server): PROJ-456 ssr - conditional SSR by route config`

```bash
git add -A
git commit -m "MESSAGE"
git push -u origin BRANCH
```

**Step 7 — Create Bitbucket draft PR:**

PR title MUST follow the project convention: `type(package): TICKET-KEY module - description`

Examples:
- `fix(client): PROJ-123 nav - layout style issue`
- `feat(client): PROJ-456 component - add brand-primary type`
- `feat(server): PROJ-789 ssr - conditional SSR by route config`

```bash
bash SKILL_DIR/scripts/bb-pr.sh TICKET-KEY "type(package): TICKET-KEY module - description" BRANCH "DESCRIPTION"
```

The script will prefix `[DRAFT]` to the title. Share the PR URL with the user.

**Step 8 — Propose Jira comment (DO NOT post automatically):**

Print the following message in the chat and ask the user whether to post it on Jira:

```
Draft PR created
PR: PR_URL
Branch: BRANCH
Please review and mark ready when satisfied
```

If `TEST_URL_PATTERN` is set in `.env`, include a test link by replacing `{TICKET_NUMBER}` with the numeric part of the ticket key.

Only call **Jira: add comment** (MCP or bash) if the user explicitly confirms.

### 3. Apply feedback (continue fixing)

When user says "continue fixing PROJ-123", "apply feedback", "address the review comments":

**Step 1 — Get latest feedback:**

**Jira: get ticket** (MCP or bash)

**Step 2 — Checkout existing branch:**
Find and checkout the branch matching the ticket key.

**Step 3 — Make targeted fixes:**
Read the feedback, check current changes with `git diff develop`, make only the fixes that were requested. Do NOT rewrite from scratch.

**Step 4 — Format & Lint:**
```bash
yarn run dprint fmt --allow-no-files $(git diff --diff-filter=d --name-only develop -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.json')
git fetch origin develop
scripts/changes-lint.sh --merge-base origin/develop
```

**Step 5 — Push and reply:**
```bash
git add -A
git commit -m "fix(package): TICKET-KEY module - address review feedback"
git push --force-with-lease origin BRANCH
```

Print the following message in the chat and ask the user whether to post it on Jira:

```
Feedback addressed and pushed.
Changes: SUMMARY
```

If `TEST_URL_PATTERN` is set in `.env`, include a test link.

Only call **Jira: add comment** (MCP or bash) if the user explicitly confirms.

### 4. Dry run (plan only)

When user says "plan for PROJ-123" or "what would you change for this ticket":

Fetch the ticket (MCP or bash), read the codebase, output a detailed fix plan in markdown. Do NOT create a branch, modify code, or create a PR. This is just planning.

## Important rules

1. **Never change Jira ticket status** — only add comments
2. **PRs are always draft** — user decides when to publish
3. **Commit messages reference the ticket** — always include `refs TICKET-KEY`
4. **Ask before acting on ambiguous tickets** — if the description is vague, ask the user for clarification before coding
5. **Feedback fixes are surgical** — don't rewrite the whole thing, only address what was flagged
