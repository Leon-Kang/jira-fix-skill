---
name: jira-fix
description: "Use when the user pastes a Jira ticket URL or GitHub pull request URL, names a Jira ticket key (e.g. PROJ-123), or asks to list assigned Jira tickets/bugs, plan or fix a ticket, create a draft PR for a ticket, check PR CI or review comments, or apply reviewer feedback."
---

# Jira Fix Workflow

```
Jira ticket → recon → intel gate → plan gate → code → verify → review → push gate → (optional) draft PR → (optional) Jira comment
```

**Scope**: Only comments on Jira. Never changes ticket status; the PO manages lifecycle. Git hosting is GitHub / GitHub Enterprise via `gh`.

**Repository rules take precedence.** Always read the target repository's `AGENTS.md`, `CLAUDE.md`, `.cursor/rules/`, `docs/git.md`, `docs/pull-request.md`, and local hooks during recon. Whenever a repository rule restricts testing (for example, forbidding new test files or cases), package manager usage (for example, requiring `yarn` v1 `yarn run <script>`), or formatting (`dprint`), follow the repository rule strictly.

**The three gates** apply when starting new work on a ticket. Never work around them, never merge an unanswered gate with the next phase:

1. **Intel gate** — if the ticket is under-specified, ask the user and stop. Do not guess.
2. **Plan gate** — present a six-section plan and wait for explicit approval before touching any repo file, creating a branch, or running a formatter.
3. **Push gate** — present the staged diff stat and exact commit message, and wait for explicit approval before committing and pushing.

Opening a draft PR and commenting on Jira are separate opt-ins after the push gate.

## Which workflow am I in

Feedback rounds skip all three gates, so never decide from the user's phrasing alone ("continue fixing PROJ-123" or pasting a bare URL fits both new work and feedback). Check repository state first:

```bash
bash SKILL_DIR/scripts/gh-pr.sh branches --key TICKET-KEY --format json
bash SKILL_DIR/scripts/gh-pr.sh pr find --source <branch>
```

| State found | Workflow |
|---|---|
| A PR URL was pasted | **3 — apply feedback** |
| An open PR exists for the ticket's branch | **3 — apply feedback** (gates skipped) |
| Branch is pushed to remote, no open PR | **3 — apply feedback** (read Jira comments) |
| Local-only branch with commits | **Ask** whether to resume or start fresh |
| No branch exists | **2 — fix a ticket** (all three gates) |
| User asked for "plan only" | **4 — plan only** (dry run) |

If `gh-pr.sh branches` reports an active `worktree` for the ticket, switch into that worktree directory rather than checking the branch out a second time.

## SKILL_DIR resolution

`SKILL_DIR` is the directory containing this `SKILL.md`. Resolve it from this file's path; all relative paths below (`scripts/`, `.env`) are relative to `SKILL_DIR`.

## Prerequisites & first-time setup

Requires `jq`, `curl`, `git`, and `gh` authenticated against your GitHub / GHES host, plus the **Atlassian MCP** (preferred; no Jira token needed) or a fallback Jira API token.

Before first use, check if `SKILL_DIR/.env` exists with valid values. If not:

1. **Ask for any Jira ticket URL** → extract `JIRA_URL` (`https://your-site.atlassian.net`).
2. **Detect Git host & repo**: `bash SKILL_DIR/scripts/gh-pr.sh repo detect`. Stop if `UNSUPPORTED_REMOTE`.
3. **Verify `gh` auth**: `gh auth status --hostname <HOST>`. If unauthenticated, ask the user to run `gh auth login --hostname <HOST> --git-protocol ssh --web`. Never ask for or store a GitHub token.
4. **Confirm `MAIN_BRANCH`** from `DefaultBranch` (for example `develop` vs `main`).
5. **Check Atlassian MCP**: call `getAccessibleAtlassianResources` on `plugin-atlassian-atlassian`. If connected, skip Jira token setup.
6. **Create `.env`**: `cp SKILL_DIR/.env.example SKILL_DIR/.env && chmod 600 SKILL_DIR/.env`. Write `JIRA_URL` and `MAIN_BRANCH`. If installed inside a git repo (`.agents/skills/`), ensure `.env` is ignored:
   ```bash
   if git -C SKILL_DIR rev-parse --is-inside-work-tree >/dev/null 2>&1 && ! git -C SKILL_DIR check-ignore -q .env; then
     printf '.env\n' >> SKILL_DIR/.gitignore
   fi
   ```
7. **Fallback Jira token (only when MCP is unavailable)**: ask for `ATLASSIAN_EMAIL` and a Jira-scoped API token, write them to `SKILL_DIR/.env`, and verify with `bash SKILL_DIR/scripts/jira-api.sh list`.

## Jira access: MCP-first, bash-fallback

**Use MCP whenever connected.** `cloudId` accepts the site hostname from `JIRA_URL` (e.g. `your-site.atlassian.net`), any Jira URL, or the site UUID.

### MCP (preferred)

- **List tickets**: `searchJiraIssuesUsingJql` with `{cloudId, jql, maxResults:20, fields:["summary","status","issuetype","priority","updated"], responseContentFormat:"markdown"}`
- **Get ticket (standard fields, links, type, attachments)** — pass `view:"full"` with `fields` (compact view drops `issuelinks` and `issuetype`):
  ```json
  {
    "cloudId": "<site>",
    "issueIdOrKey": "TICKET-KEY",
    "view": "full",
    "fields": ["summary","description","environment","status","issuetype","priority","labels","components","assignee","issuelinks","attachment"],
    "responseContentFormat": "html"
  }
  ```
- **Get custom fields (Acceptance Criteria, Steps to Reproduce, Expected Result)**: a second `getJiraIssue` call with `{cloudId, issueIdOrKey, view:"evidence"}` and **no `fields`**. Values appear under `fields.customFields` keyed by display name.
- **Get comments**: `listJiraIssueComments` with `{cloudId, issueIdOrKey, responseContentFormat:"html", view:"evidence"}`, paged until `isLast`. (`getJiraIssue` only reports comment count, never the thread.)
- **Download attachments**: `executeRead` with `{name:"downloadJiraIssueAttachment", cloudId, inputs:{attachmentId, outputPath:"/tmp/jira-fix-TICKET-KEY/<filename>"}}` using the numeric `id` from `fields.attachment`. **Always save under `/tmp/jira-fix-TICKET-KEY/` — never inside the repository working tree**, even though the tool's own hint suggests `./`. Run the returned `downloadCommand`, then read the image file.
- **Add comment**: `addOrEditJiraIssueComment` with `{cloudId, issueIdOrKey, commentBody, contentFormat:"markdown"}` (or `contentFormat:"html"` with `<span data-type="mention" data-user-id="ACCOUNT_ID">@Name</span>` for real @mentions).

**Why `html` for bodies with media:** markdown turns embedded images into unreachable `![](blob:...)` links (`adf` is rejected). In `html`, each image is a `media` element whose `data-alt` carries the filename, tying it to `fields.attachment` and the surrounding requirement.

### Bash fallback (only when MCP is not connected)

Accepts either `PROJ-123` or a full `https://.../browse/PROJ-123` URL:

- `bash SKILL_DIR/scripts/jira-api.sh list [--format json]`
- `bash SKILL_DIR/scripts/jira-api.sh get KEY|URL [--format json]` (includes prose custom fields)
- `bash SKILL_DIR/scripts/jira-api.sh comments KEY|URL [--since ISO8601] [--format json]` (paginated, timezone-safe)
- `bash SKILL_DIR/scripts/jira-api.sh comment KEY|URL --text-file - [--dry-run]`

Without MCP, attachments cannot be downloaded automatically; ask the user to paste load-bearing screenshots.

## GitHub / GHES CLI helper

All GitHub operations go through `gh-pr.sh` (fork-aware, idempotent, `--format json` everywhere):

- **Detect repo**: `bash SKILL_DIR/scripts/gh-pr.sh repo detect`
- **Find branches & worktrees**: `bash SKILL_DIR/scripts/gh-pr.sh branches --key TICKET-KEY`
- **Find open PR**: `bash SKILL_DIR/scripts/gh-pr.sh pr find [--source BRANCH | --pr NUMBER|URL]`
- **Create draft PR**: `bash SKILL_DIR/scripts/gh-pr.sh pr create --title "TITLE" --source BRANCH --body-file -`
- **Read PR feedback**: `bash SKILL_DIR/scripts/gh-pr.sh pr feedback [--source BRANCH | --pr NUMBER|URL] [--since ISO8601]` (paginated, drops resolved threads, stale Bugbot wrappers, and your own replies; compares `--since` as UTC instants)
- **Check PR CI**: `bash SKILL_DIR/scripts/gh-pr.sh pr checks [--source BRANCH | --pr NUMBER|URL]`

## Resolving verification commands

Check in order:
1. Repository `AGENTS.md` / `CLAUDE.md` (for example diff-scoped `scripts/changes-lint.sh --merge-base origin/develop`, `yarn run lint:tsc`, `yarn run lint:src`, `yarn run dprint fmt --allow-no-files <files>`, targeted `yarn run jest --no-cache --runInBand <spec>`).
2. `SKILL_DIR/.env` overrides (`TEST_CMD`, `LINT_CMD`, `FMT_CMD`).
3. `package.json` scripts (matching the repo's lockfile package manager). Skip lint/format if none exists; do not invent commands.

## Workflows

### 1. List my tickets

Default JQL: `assignee = currentUser() AND statusCategory != Done ORDER BY priority DESC, updated DESC` (or `JIRA_LIST_JQL` from `.env`). Present tickets clearly and let the user pick; never start fixing off a list.

### 2. Fix a ticket

Read `MAIN_BRANCH` from `SKILL_DIR/.env` (default: `develop`).

#### Phase 0 — Recon (read-only: no branch, no repo edits)

Work every step before forming an opinion:

1. **Repository & platform match** — confirm the ticket's target platform/service (e.g. Web vs Mobile App vs Backend) matches the current workspace repository. If it belongs to a sibling checkout in the parent workspace directory, switch to that repository first; if it spans multiple repositories, state both.
2. **Ticket, custom fields, and comments** — run both `getJiraIssue` calls (`view:"full"` + `view:"evidence"`) and `listJiraIssueComments`. Requirements, scope changes, and branches already started often live in comments.
3. **Linked specs, Confluence, Figma, and screenshots** — follow linked blocking/related Jira issues (designs are often revised in the spec ticket's comments — latest wins), linked Confluence pages (`getConfluenceContent`), and Figma URLs (load the Figma design skill first when connected). Download every relevant screenshot to `/tmp/jira-fix-TICKET-KEY/` and inspect it. If media/recordings cannot be fetched and are load-bearing, record an intel gap; never guess what they show.
4. **Prior work & worktrees** — run `gh-pr.sh branches --key TICKET-KEY` and `gh-pr.sh pr find`.
5. **Code & repo rules** — read `AGENTS.md` / `.cursor/rules/` in the target repo, and *read* the actual files the change will touch.
6. **History & verification** — run `git log --oneline -20 -- <paths>` and identify exact verification commands/steps.

Output a concise **Recon Summary** (target repo & branch/worktree state, ticket type & ask, files read, verification path) before Gate 1.

#### Phase 1 — Intel gate

Ready to plan only if **all** hold:
- Target repository is confirmed.
- Problem or goal is unambiguous.
- Bugs have repro steps or trigger; stories/tasks have acceptance criteria (checked in custom fields and description).
- Impact is traceable to specific files you have read.
- Expected result is stated, not inferred.
- Concrete verification path exists.
- Nothing load-bearing lives only in media/specs you could not read.

If **any** fails, **stop**. Ask structured questions naming what is missing and why. Offer to post open questions as a Jira comment (post only if confirmed).

#### Phase 2 — Plan gate

Present **all six sections**:
1. **Understanding / root cause** (2-3 lines)
2. **Files involved** (concrete paths)
3. **Change plan** (actual edits, as bullets)
4. **Verification** (exact commands, manual steps, preview URL if `TEST_URL_PATTERN` is set)
5. **Risk and blast radius**
6. **Branch and commit** (proposed `feature/TICKET-KEY-...` branch and commit message)

**Stop and wait for explicit approval.** Skip only if the user explicitly waived this gate for this ticket.

#### Phase 3 — Branch (only after approval)

1. If `gh-pr.sh branches --key TICKET-KEY` showed an existing worktree for this ticket, `cd` into that worktree and `git fetch origin`.
2. Otherwise run `git status --short` in the target repo. **Never stash automatically.** If uncommitted/untracked changes exist (or another branch is actively in progress), stop and ask whether to create an isolated git worktree (`git fetch origin && git worktree add ../<repo>-TICKET-KEY -b "feature/TICKET-KEY-short-desc" "origin/MAIN_BRANCH"`) or wait for cleanup.
3. In a clean tree:
   ```bash
   git fetch origin
   BRANCH="feature/TICKET-KEY-short-description"
   if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
     git checkout "${BRANCH}"
     git merge "origin/MAIN_BRANCH"
   else
     git checkout --no-track -b "${BRANCH}" "origin/MAIN_BRANCH"
   fi
   ```
   Branch prefix is always `feature/` (`3-5` kebab-case words). If `git merge` conflicts, **stop and ask** — never resolve conflicts silently.

#### Phase 4 — Implement

Implement the approved plan minimally. **Follow the repository's test policy strictly**:
- If the repository's rules or hooks forbid adding new tests, do **not** create test files or add test cases — only update existing test expectations broken by your intentional change so CI stays green.
- Otherwise, add or update unit tests for non-UI logic (UI components/screens get no Jest tests unless explicitly requested).

If implementation shows the plan was wrong, return to Phase 2 with a corrected plan rather than widening scope silently.

#### Phase 5 — Verify (test, typecheck, format, lint)

Run the resolved verification commands (preferring targeted existing specs + diff-scoped lint/typecheck scripts like `scripts/changes-lint.sh --merge-base origin/MAIN_BRANCH` and `dprint` when configured). Fix issues caused by your change (up to 3 attempts); do not touch unrelated files for pre-existing warnings.

#### Phase 6 — Code review (mandatory, before the push gate)

1. Run `git status --short` first. Ensure no downloaded screenshots, `.env`, or scratch files sit in the repo. Stage **only** the intended files (`git add -- <intended-files>`).
2. Check for a local-diff review skill or repo review rules (`.cursor/BUGBOT.md`, `.cursor/rules/code-review.mdc`) and run/apply them against `git diff --cached "$(git merge-base origin/MAIN_BRANCH HEAD)"`.
3. Fix every valid issue, re-stage intended files, re-run Phase 5, and summarize findings and fixes.

#### Phase 7 — Push gate

Present:
- 2-3 line summary of what changed
- `git diff --cached --stat "$(git merge-base origin/MAIN_BRANCH HEAD)"`
- verification evidence (typecheck/lint/test results)
- exact commit message: `type(scope): TICKET-KEY module - description` (`feat` for Story/Feature, `fix` for Bug, `refactor`/`chore`/`docs` as appropriate)

Ask for explicit approval, then:
```bash
git commit -m "type(scope): TICKET-KEY module - description"
git push -u origin "${BRANCH}"
```

#### Phase 8 — Optional draft PR, CI check, and Jira comment

Ask whether the user wants a draft PR, a Jira comment, both, or neither:

```bash
bash SKILL_DIR/scripts/gh-pr.sh pr create \
  --title "type(scope): TICKET-KEY module - description" \
  --source "${BRANCH}" --body-file -
bash SKILL_DIR/scripts/gh-pr.sh pr checks --source "${BRANCH}"
```

Post a Jira comment only after the user confirms the exact text.

### 3. Apply feedback (continue fixing)

**Skips intel, plan, and push gates** — the branch is already published.

1. **Sync and locate feedback & CI status**: switch into the ticket's worktree if one exists, run `git fetch origin`, and if the worktree is clean and behind `origin/${BRANCH}`, fast-forward (`git merge --ff-only "origin/${BRANCH}"`) before reading `--since`:
   ```bash
   bash SKILL_DIR/scripts/gh-pr.sh pr feedback --since "$(git log -1 --format=%cI)"
   bash SKILL_DIR/scripts/gh-pr.sh pr checks
   ```
   Also read `listJiraIssueComments` with the same cutoff. If `--since` returns 0 items (e.g. after `amend`/`rebase`, or resuming an unfinished batch) or the user asked for all open comments, run `gh-pr.sh pr feedback` **without `--since`** to see all remaining unresolved review threads, cross-checking `git log origin/MAIN_BRANCH..HEAD` so committed fixes are not redone.
2. **Verify before editing**: post one triage line per item (`[source] ask → action`).
   - Clear code fix in scope → implement directly.
   - Question or factually questionable claim → **verify against the codebase/AC first** and draft a concise reply for the user instead of blindly breaking working code.
   - Ambiguous, conflicting reviewers, out-of-scope files, schema/API changes, or AC conflicts → **escalate that single item** while shipping the rest.
3. **Make surgical fixes**: stage intended files and verify `git diff --cached "$(git merge-base origin/MAIN_BRANCH HEAD)"`.
4. **Verify & review** (Phases 5 & 6), then **commit and push directly** (`git commit -m "fix(scope): TICKET-KEY module - address review feedback" && git push origin "${BRANCH}"`; `--force-with-lease` still requires explicit approval).
5. Report changes, diff stat, and any drafted replies; offer an optional Jira comment.

### 4. Plan only (dry run)

Run Phase 0 and Phase 1, output the Phase 2 plan, and stop.

## PR body template (~12 lines, nothing else)

Unless the repository defines its own PR conventions (`docs/pull-request.md` / `.github/pull_request_template.md`), use:

```markdown
## Ticket
PROJ-482 — message actions are unreachable on sent voice recordings and invite chats.
https://your-site.atlassian.net/browse/PROJ-482

## Scope
- packages/client/src/app/chat — message bubble layout and action menu

## Changes
- Hide the react action on outgoing voice messages
- Drop avatars from invite chats so the action row fits
- Cap bubble max-width so actions stay visible on narrow screens
```

No test logs, no checkboxes, no restated ticket description, no "Please review".

## Jira comment style (hard limit: 3 lines, 200 chars)

Outcome + links only, no filler, posted only after user confirmation:

```
Fixed: header overlap on mobile nav.
PR: https://your-host.ghe.com/org/repo/pull/123
```

```
Addressed review feedback: null check on empty state.
PR: https://your-host.ghe.com/org/repo/pull/123
```

## Red flags — stop immediately if you catch yourself thinking:

| Rationalization | Reality |
|---|---|
| "It's a tiny fix, skip the 6-section plan" | Wrong-place tiny fixes waste full review rounds. Present the plan and wait. |
| "I'll `git stash` their dirty worktree and pop later" | Never stash automatically. Reuse an existing worktree or offer a new one. |
| "Save the Jira attachment to `./` and `git add -A`" | Save attachments to `/tmp/jira-fix-KEY/` only, and stage explicit files. |
| "I'll add a helpful unit test even though repo rules say no new tests" | Repo rules & hooks win. In no-new-test repos, only update broken existing assertions. |
| "Reviewer asked for X, I'll change it without checking" | Verify against code and AC first; draft a reply or escalate if it conflicts. |
