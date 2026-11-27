---
name: jira-fix
description: "Automate the full Jira ticket fix workflow: list your assigned tickets, pick one, gather intel, get a plan approved, fix the code, create a GitHub Enterprise draft PR, and comment on Jira. Also handles reviewer feedback loops. Use this skill whenever the user mentions Jira tickets, fixing a ticket, listing their tasks, creating a PR from a ticket, responding to Jira feedback, or anything involving the Jira-to-code-to-PR pipeline. Trigger phrases include: 'fix PROJ-123', 'show my tickets', 'my Jira tasks', 'what should I work on', 'continue fixing', 'apply feedback', 'create PR for ticket', 'list my bugs'. Even casual phrases like 'what tickets do I have' or 'work on the next bug' should trigger this skill."
---

# Jira Fix Workflow

Automates: Jira ticket → intel gathering → approved plan → code fix → code review → (optional) GitHub draft PR → (optional) Jira comment → feedback loop.

**Scope**: Only comments on Jira. Never changes ticket status; the PO manages lifecycle. Git hosting is GitHub / GitHub Enterprise via the `gh` CLI.

**The three gates** apply when starting new work on a ticket. Never work around them, never batch them together:

1. **Intel gate** — if the ticket is under-specified, ask the user and stop. Do not guess.
2. **Plan gate** — present a plan and wait for explicit approval before touching any file.
3. **Push gate** — present the diff summary and wait for explicit approval before commit and push.

Creating a PR and commenting on Jira are separate opt-ins after the push gate.

**Feedback rounds skip all three** — see workflow 3. The ticket was already investigated, the plan was already approved and the branch is already published, so reviewer feedback goes straight to work with per-item escalation instead.

## SKILL_DIR resolution

`SKILL_DIR` refers to the directory where this `SKILL.md` file lives. Determine it by resolving the path of this file's parent directory. All relative paths in this document (`.env`, `scripts/`) are relative to `SKILL_DIR`.

## Prerequisites

- `jq`, `curl`, `git` available in PATH (pre-installed on macOS)
- **`gh`** (GitHub CLI) authenticated against your GitHub Enterprise host — this is how the skill creates PRs and reads PR feedback
- **Atlassian MCP** — the preferred path for every Jira operation, including comments. When it is connected, no Jira token is needed anywhere.
- **A Jira API token** — only needed as a fallback when the Atlassian MCP is not available

### First-time setup

Before first use, check if `SKILL_DIR/.env` exists and contains valid (non-placeholder) values. If not, run the interactive setup below.

**Step 1 — Ask for a Jira ticket URL:**

Ask the user: "Paste a link to any Jira ticket (e.g. from your browser address bar)."

The user will provide something like:
`https://acme.atlassian.net/browse/PROJ-123` or `https://acme.atlassian.net/jira/software/c/projects/PROJ/boards/1?assignee=...`

Extract from the URL:
- **JIRA_URL**: the origin part → `https://acme.atlassian.net`
- **Project prefix**: the ticket key prefix → `PROJ` (store this for later use in branch naming and JQL)

**Step 2 — Detect the Git host and repository:**

```bash
bash SKILL_DIR/scripts/gh-pr.sh repo detect
```

This prints the provider, host, `owner/name`, and default branch, all derived from the git remote. Nothing needs to be written to `.env` for this — detection runs fresh in whatever repo the user is working in.

If it fails with `UNSUPPORTED_REMOTE`, the current directory is not a GitHub/GHES repository. Tell the user; do not continue.

**Step 3 — Verify GitHub authentication:**

```bash
gh auth status --hostname <HOST-from-step-2>
```

If not authenticated, tell the user to run:

```bash
gh auth login --hostname <HOST> --git-protocol ssh --web
```

Never ask for or store a GitHub token — `gh` owns those credentials.

**Step 4 — Confirm the default branch:**

Use the `DefaultBranch` from Step 2 as `MAIN_BRANCH`. Confirm it with the user, since some teams merge into `develop` while `origin/HEAD` points at `main`.

**Step 5 — Check for Atlassian MCP:**

Call `getAccessibleAtlassianResources` on the `plugin-atlassian-atlassian` MCP server. The response also gives you the `cloudId` for the site — record it.

- **If MCP responds**: tell the user Jira will go through MCP, and **skip token creation entirely**. Go to Step 6.
- **If MCP is not available**: tell the user it can be enabled in Cursor Settings → MCP, and that without it the skill needs a Jira API token. Do Step 6 and Step 7.

**Step 6 — Create .env:**

```bash
cp SKILL_DIR/.env.example SKILL_DIR/.env
chmod 600 SKILL_DIR/.env
```

Write `JIRA_URL` (step 1) and `MAIN_BRANCH` (step 4). With MCP connected, that is all `.env` needs — leave `ATLASSIAN_EMAIL` and `ATLASSIAN_API_TOKEN` empty.

**Step 7 — Jira token (only when MCP is unavailable):**

Ask the user for their Atlassian email, then:

> Go to https://id.atlassian.com/manage-profile/security → **"Create and manage API tokens"** → **"Create API token with scopes"**
> - Name: `jira-fix-jira`
> - App: **Jira**

Write `ATLASSIAN_EMAIL` and `ATLASSIAN_API_TOKEN` into `SKILL_DIR/.env`, then verify:

```bash
bash SKILL_DIR/scripts/jira-api.sh list
```

If it fails, read the error and help troubleshoot (common issues: wrong email, expired token, incorrect JIRA_URL).

### .env variables

- **ATLASSIAN_EMAIL**, **ATLASSIAN_API_TOKEN**: only needed when the Atlassian MCP is unavailable; leave empty otherwise
- **JIRA_URL**: Your Atlassian site (e.g. `https://your-site.atlassian.net`)
- **MAIN_BRANCH**: Target branch for PRs (default: `develop`)
- **GIT_REMOTE**: Optional, defaults to `origin`
- **GH_HOST**: Optional guard — if set, the scripts refuse to act on a repo whose remote points elsewhere
- **TEST_URL_PATTERN**: Optional test URL pattern with `{TICKET_NUMBER}` placeholder
- **TEST_CMD**, **LINT_CMD**, **FMT_CMD**: Optional command overrides
- **JIRA_LIST_JQL**: Custom JQL for ticket listing (optional)

GitHub credentials are **not** stored here — they live in the `gh` credential store. With the Atlassian MCP connected, this file holds no secrets at all.

## Jira access: MCP-first, bash-fallback

**Use MCP whenever it is available.** It covers every Jira operation this skill needs, including comments and attachment downloads, and requires no token. Only drop to the bash scripts when the MCP server is not connected.

### MCP (preferred)

Get the `cloudId` from `getAccessibleAtlassianResources` — it is the site UUID, not the hostname.

- **List tickets**: `searchJiraIssuesUsingJql` with `{cloudId, jql, maxResults:20, fields:["summary","status","issuetype","priority","updated"], responseContentFormat:"markdown"}`
- **Get ticket** — `fields` must be passed explicitly, because the default field set silently omits `attachment` and `issuelinks`:

  ```
  getJiraIssue {
    cloudId,
    issueIdOrKey: "TICKET-KEY",
    fields: ["summary","description","status","issuetype","priority","labels",
             "components","assignee","issuelinks","attachment"],
    responseContentFormat: "markdown"
  }
  ```

- **Get the comment thread**: `listJiraIssueComments` with `{cloudId, issueIdOrKey, responseContentFormat:"html", view:"evidence"}`. Each comment has `author.displayName`, `author.accountId`, `created`, `body`, and `parentId` when it is a reply. Do not read comments from `getJiraIssue`: it can leave `comment` out even when `fields` lists it, so an empty result there does not mean the thread is empty.
- **Download an attachment**: `executeRead` with `{name:"downloadJiraIssueAttachment", cloudId, inputs:{attachmentId, outputPath}}`. `attachmentId` is the numeric `id` from `fields.attachment`, not the media UUID in the body. The call returns a `downloadCommand` (`curl` with a short-lived URL). Run it right away, then open the saved file with the image reader.
- **Add comment**: `addOrEditJiraIssueComment` with `{cloudId, issueIdOrKey, commentBody, contentFormat:"markdown"}`. To notify someone, use `contentFormat:"html"` with `<span data-type="mention" data-user-id="ACCOUNT_ID">@Name</span>`; the account ID is `author.accountId` on any of their comments.

**Choosing the response format.** Use `markdown` normally. As soon as the issue or a comment has attachments, read it as `html`: markdown renders every embedded image as `![](blob:...)`, and a `blob:` URL is unreachable — the screenshot silently disappears. (`adf` is rejected as a response format.) In HTML each image is a media `<div>` whose `data-alt` is the attachment filename:

```html
<figure data-type="media-single"><div data-type="media" data-media-type="file" data-id="0d29..." data-alt="Screenshot 2026-07-17 at 12.36.17.png"></div></figure>
```

That filename is what ties the image to its entry, and its numeric `id`, in `fields.attachment`. Its position in the document tells you which requirement or comment the screenshot belongs to.

### Bash fallback (only when MCP is not connected)

- **List tickets**: `bash SKILL_DIR/scripts/jira-api.sh list`
- **Get ticket**: `bash SKILL_DIR/scripts/jira-api.sh get TICKET-KEY`
- **Get comments**: `bash SKILL_DIR/scripts/jira-api.sh comments TICKET-KEY`
- **Add comment**: `bash SKILL_DIR/scripts/jira-api.sh comment TICKET-KEY "TEXT"`

All four accept `--format json` for structured output. They read `ATLASSIAN_EMAIL` / `ATLASSIAN_API_TOKEN` from `.env` and fail with `CONFIG_MISSING` when those are empty — which is expected and harmless on an MCP-only setup.

The scripts do not download attachments. Without MCP, ask the user to paste any load-bearing screenshot.

## GitHub Enterprise access

All PR operations go through one script, which detects host/owner/repo from the git remote and authenticates via `gh`:

- **Detect repo**: `bash SKILL_DIR/scripts/gh-pr.sh repo detect`
- **Find existing PR**: `bash SKILL_DIR/scripts/gh-pr.sh pr find [--source BRANCH | --pr NUMBER|URL]`
- **Create draft PR**: `bash SKILL_DIR/scripts/gh-pr.sh pr create --title "TITLE" --source BRANCH --body-file -`
- **Read PR feedback**: `bash SKILL_DIR/scripts/gh-pr.sh pr feedback [--source BRANCH | --pr NUMBER|URL] [--since ISO8601]`

`--source` defaults to the current branch. `--pr` accepts a number, or a full pull request URL — and a URL also selects the host and repository, so a link the user pasted works even from a different checkout. `--since` filters to feedback created after a timestamp.

`pr create` is idempotent — it returns the existing open PR instead of opening a duplicate. PRs are created with GitHub's native draft state. Run `bash SKILL_DIR/scripts/gh-pr.sh --help` for full usage.

## Resolving commands for test, lint, format

Before running test/lint/format, check `SKILL_DIR/.env` for custom overrides:

- **TEST_CMD**: if set, use it. Otherwise auto-detect: look for `package.json` scripts — prefer `yarn run test` if a `test` script exists, else `npm test`.
- **LINT_CMD**: if set, use it. Otherwise skip lint (not all projects have one).
- **FMT_CMD**: if set, use it. Otherwise skip format (not all projects have one).

## Workflows

### 1. List my tickets

When user says things like "show my tickets", "what should I work on", "my Jira tasks":

**Jira: list tickets** (MCP or bash — see above)

Default JQL: `assignee = currentUser() AND status not in (Done, Cancelled) ORDER BY priority ASC, updated DESC`

Present the tickets clearly. Let the user pick one, or suggest the highest-priority actionable ticket.

### 2. Fix a ticket

When user says "fix PROJ-123" or picks a ticket from the list.

Read `MAIN_BRANCH` from `SKILL_DIR/.env` (default: `develop`). Use this value wherever `MAIN_BRANCH` appears below.

---

#### Phase 0 — Recon (read-only, no branch, no edits)

Work through the whole checklist before forming any opinion. This phase is read-only: no `git checkout`, no file writes.

1. **Ticket body and comment thread** — `getJiraIssue` with the explicit `fields` list above, plus `listJiraIssueComments` for the thread (or `jira-api.sh get` + `comments` without MCP). Read the comments properly: requirements, repro details, the branch someone already started, and prior decisions are very often there rather than in the description. If `fields.attachment` is non-empty, read the description as `html` so the images stay tied to the text.

2. **Linked issues and screenshots** — note linked issue keys. When the ticket points at another ticket for its spec, as an issue link or a link in the description, read that ticket's comments and screenshots too; designs are often revised there, and the latest one wins.

   Download every screenshot that sits next to a requirement, a repro step, or a design comment, and look at it before forming an opinion: match its `data-alt` filename to `fields.attachment`, then use `downloadJiraIssueAttachment`. Describe only what you actually saw. If a download fails, never write "as shown in the screenshot", and:

   - If an image is load-bearing (it *is* the bug report, or the only spec for a layout), ask the user to paste it into the chat. Say which filename you need and what you are trying to learn from it. A missing load-bearing screenshot is an intel gap — treat it as one.
   - If the surrounding text already states the requirement, note the image as supporting evidence you could not read, and continue.
3. **Prior work on this ticket** — check for an existing branch and PR so you do not redo finished work:
   ```bash
   git branch -a --list "*TICKET-KEY*"
   bash SKILL_DIR/scripts/gh-pr.sh pr find --source feature/TICKET-KEY-...
   ```
4. **Code** — locate the modules and files the ticket actually touches, and read them. Naming the files is not enough; you must have read them before planning.
5. **History** — `git log --oneline -20 -- <relevant paths>` to see what changed here recently and whether this area has regressed before.
6. **Verification path** — determine how the fix will be proven: which test, which command, which URL or manual step.

Report a short recon summary to the user before moving on.

#### Phase 1 — Intel gate

The ticket is ready to plan only if **all** of these hold:

- The problem or goal is unambiguous.
- Bugs have repro steps or a trigger condition; stories have acceptance criteria.
- The impact is traceable to specific code (you know which app/module/files change).
- The expected result is stated, not inferred.
- There is a concrete way to verify the fix.
- Nothing essential lives only inside a screenshot you could not download and read.

If **any** of them fails, **stop**. Ask the user with a structured question that states, for each gap, **what is missing and why you need it**. Do not create a branch, do not edit code, do not guess a "reasonable" interpretation.

Offer to post the open questions as a Jira comment, but only post if the user confirms.

#### Phase 2 — Plan gate

When intel is sufficient, present a plan with exactly these six sections:

1. **Understanding / root cause** — 2-3 lines.
2. **Files involved** — concrete paths.
3. **Change plan** — the actual edits, as bullets.
4. **Verification** — test command, manual steps, test URL if `TEST_URL_PATTERN` is set.
5. **Risk and blast radius** — what else could break.
6. **Branch and commit** — proposed branch name and commit message.

Then **stop and wait for explicit approval**. Do not checkout, do not write files, do not run formatters. Approval means the user actually says to proceed; silence, a question, or a related comment is not approval.

Skip this gate only if the user has explicitly said to skip it for this ticket.

#### Phase 3 — Branch (only after approval)

Check the worktree first. **Never stash automatically.**

```bash
git status --short
```

If anything is uncommitted or untracked, stop and ask the user how to handle it (commit, stash themselves, or discard). Continue only once the worktree is clean or the user explicitly tells you to proceed.

```bash
git checkout MAIN_BRANCH
git pull --ff-only

BRANCH="feature/TICKET-KEY-short-description"
if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
  git checkout "${BRANCH}"
  git merge MAIN_BRANCH
else
  git checkout -b "${BRANCH}"
fi
```

Branch prefix is always `feature/`, regardless of ticket type (Bug, Story, Task, Chore). Never use a `fix/` prefix for branch names. Generate a short kebab-case suffix from the ticket summary (3-5 words max).

Examples: `feature/PROJ-123-header-overlap`, `feature/PROJ-456-user-avatar`

#### Phase 4 — Implement

Implement the approved plan. Keep changes minimal and focused on the ticket. Add or update tests for the change. If implementation reveals the plan was wrong, stop and re-run Phase 2 with the corrected plan rather than silently expanding scope.

#### Phase 5 — Test, format, lint

Run the test command (see "Resolving commands"). If tests fail, read the output and fix. Retry up to 3 times; if still failing, stop and report to the user.

Then run format and lint, if configured. Fix lint errors and re-run until clean. Do not skip this when the commands are available — PRs failing CI lint get rejected.

#### Phase 6 — Code review (mandatory, before the push gate)

1. **Look for a review skill in the current project.** Search `.cursor/skills/`, `.agents/skills/`, `.claude/skills/`, `.codex/skills/` and the skills available in the session for one whose name or description mentions "review".
2. **If a review skill exists**: invoke it on the feature branch diff against `MAIN_BRANCH` and follow its workflow. Do not pick a skill that reviews a *published PR URL* — at this point nothing is pushed.
3. **If no review skill exists**: review it yourself. Run `git diff MAIN_BRANCH` and check: does the change fully address the ticket, are there bugs or unhandled edge cases, is the code consistent with the surrounding codebase, is test coverage adequate.
4. **Fix every valid issue**, then re-run Phase 5 until clean.
5. Summarize the findings and the fixes for the user.

#### Phase 7 — Push gate

Present, in the chat:

- what changed, in 2-3 lines
- `git diff MAIN_BRANCH --stat`
- verification evidence (test/lint results)
- the exact commit message

Then **ask for approval to commit and push**. Only after the user approves:

```bash
git add -A
git commit -m "MESSAGE"
git push -u origin BRANCH
```

Commit message format: `type(scope): TICKET-KEY module - description`

- **type**: `feat` for Story/Feature, `fix` for Bug, `refactor`/`chore`/`docs` as appropriate
- **scope**: the top-level package or area (e.g. `client`, `server`, `api`, `web`)
- **module**: the feature/module within the scope (e.g. `nav`, `chat`, `profile`, `payment`)

Examples:
- `fix(client): PROJ-123 nav - fix header overlap on mobile`
- `feat(server): PROJ-456 auth - add OAuth2 support`

#### Phase 8 — Optional PR and Jira comment

Both are opt-in and independent. Ask which the user wants; they may choose one, both, or neither.

**If the user wants a PR** — the PR title uses the same convention as the commit message:

```bash
bash SKILL_DIR/scripts/gh-pr.sh pr create \
  --title "type(scope): TICKET-KEY module - description" \
  --source BRANCH --body-file -
```

Pass the PR body on stdin, built from the "PR body template" below. Share the returned PR URL with the user.

**If the user wants a Jira comment** — build it per "Jira comment style" below and post only after the user confirms the exact text.

### 3. Apply feedback (continue fixing)

Triggered by a PR link on its own, "check the latest comments", "continue fixing PROJ-123", "apply feedback", "address the review comments".

**This workflow does not re-run the intel gate or the plan gate.** The ticket was already investigated and the plan already approved; a reviewer asking for a null check does not need a fresh six-section plan. Read the feedback, then start working. Escalate per-item, only when Step 3 says to.

**Step 1 — Locate the feedback.** Pick whichever applies:

```bash
# A PR link was pasted — works from any directory
bash SKILL_DIR/scripts/gh-pr.sh pr feedback --pr <PR-URL>

# A ticket key was named — find its branch, then read both sources
bash SKILL_DIR/scripts/gh-pr.sh pr feedback --source feature/TICKET-KEY-...

# "check the latest comments" with no target — use the current branch
bash SKILL_DIR/scripts/gh-pr.sh pr feedback
```

"Latest" means anything newer than the last commit on the branch, so you do not re-address what you already fixed:

```bash
bash SKILL_DIR/scripts/gh-pr.sh pr feedback --since "$(git log -1 --format=%cI)"
```

Also read the Jira comment thread (MCP `listJiraIssueComments`) and apply the same cutoff — reviewers use whichever channel is convenient. If the user only asked you to *check*, report what you found and stop there.

**Step 2 — Triage, then start immediately.** Post one line per item, `[source] what was asked → what you will do`, and begin working in the same turn. Do not wait for approval on this list; it exists so the user can interrupt if you misread something, not to block you.

**Step 3 — Escalate individual items, not the batch.** Do the clear items right away. Stop and ask about an item only when it:

- is ambiguous, self-contradictory, or two reviewers disagree
- needs a design or architecture change beyond the current diff
- requires touching files outside the scope of this change
- conflicts with the ticket's acceptance criteria
- changes a public API, a data schema, or needs a migration
- describes something you cannot reproduce or verify

Everything else is just work — naming, null checks, extracted helpers, missing tests, copy fixes. Never hold the whole batch hostage to one unclear comment: ship the rest and ask about that one.

**Step 4 — Make targeted fixes.** Check the current state with `git diff MAIN_BRANCH` and change only what was flagged. Do not rewrite from scratch and do not slip in unrelated improvements. If the code review in Step 6 finds a real problem outside the feedback, report it rather than silently expanding the diff.

**Step 5 — Test, format, lint** (same as Phase 5).

**Step 6 — Code review** (same as Phase 6).

**Step 7 — Commit and push directly.** No push gate here: the branch is already published and under review, so an extra round-trip buys nothing.

```bash
git add -A
git commit -m "fix(scope): TICKET-KEY module - address review feedback"
git push origin BRANCH
```

Normal push only. `--force-with-lease` still requires explicit approval, because rewriting history can drop a reviewer's context.

Then report what you changed and the resulting diff stat.

**Step 8 — Optional Jira comment**, per the style rules below, only if the user confirms.

### 4. Plan only (dry run)

When user says "plan for PROJ-123" or "what would you change for this ticket":

Run Phase 0 and Phase 1, then output the Phase 2 plan. Stop there. Do not create a branch, modify code, or create a PR.

## PR body template

A reviewer opens a PR wanting three answers: what was asked for, where do I look, and what did you actually do. Give exactly those, in this order, and nothing else.

```markdown
## Ticket
TICKET-KEY — one line stating what the ticket asks for.
https://your-site.atlassian.net/browse/TICKET-KEY

## Scope
- path/to/module — what part of it this touches

## Changes
- what you actually changed
```

Rules for each section:

- **Ticket** — the key, one line of your own words describing the ask, and the link. Not a copy-paste of the description.
- **Scope** — the directories or modules the diff touches, one line each, so the reviewer knows where to look. Usually 1-3 lines. Skip individual filenames; the diff already lists them.
- **Changes** — one bullet per real change, phrased as what it does, matching what is actually in the diff. Usually 2-5 bullets.

The whole body should fit in roughly 12 lines. Do not add: test logs, "Type of change" checkboxes, a checklist, a restatement of the ticket description, screenshots you did not actually take, or "Please review / Let me know if you have questions". If verification is non-obvious, it gets one bullet in Changes — not its own section.

Worked example:

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

## Jira comment style

Jira comments are status pings for humans who already have the ticket open, not reports. Hard limits:

- **Maximum 3 lines and 200 characters.**
- Only the outcome plus links.
- No diffs, no file lists, no test output, no restating the ticket.
- No filler such as "Please review and mark ready when satisfied" or "Let me know if you have any questions".

After a fix:

```
Fixed: header overlap on mobile nav.
PR: https://your-host.ghe.com/org/repo/pull/123
```

After applying feedback:

```
Addressed review feedback: null check + regression test.
PR: https://your-host.ghe.com/org/repo/pull/123
```

If no PR was created, replace the PR line with `Branch: BRANCH`. If `TEST_URL_PATTERN` is set in `.env`, a test link may be the third line — replace `{TICKET_NUMBER}` with the numeric part of the ticket key.

Always show the exact comment text in chat and post it only after the user confirms.

## Important rules

1. **Never change Jira ticket status** — only add comments.
2. **Use MCP for Jira whenever it is connected** — never ask the user for a Jira token that MCP makes unnecessary.
3. **Recon before opinion** — read the ticket, its comments, and the actual code before saying anything about how to fix it.
4. **Under-specified means stop** — ask what is missing and why; never guess your way past the intel gate.
5. **Look at screenshots before describing them** — download them with `downloadJiraIssueAttachment`. Never describe one you could not download; ask the user to paste it.
6. **No edits before plan approval** — on new ticket work, the plan gate covers file writes, branch creation and formatters.
7. **No commit or push before approval** — on new ticket work, show the diff stat and commit message first.
8. **Never stash automatically** — a dirty worktree stops the workflow and gets escalated to the user.
9. **Always code-review before the push gate** — use the project's review skill if one exists, otherwise review the diff yourself, and fix what it finds.
10. **PRs are optional and always drafts** — ask first; `pr create` never opens a duplicate.
11. **Commit messages always include the ticket key** — format: `type(scope): TICKET-KEY module - description`.
12. **Jira comments stay under 3 lines** — outcome and links only.
13. **PR bodies are Ticket / Scope / Changes** — nothing else, roughly 12 lines.
14. **Feedback fixes are surgical and ungated** — go straight to work; only address what was flagged; escalate single unclear items without blocking the rest.
