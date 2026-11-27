---
name: jira-fix
description: "Use when the user pastes a Jira ticket URL or GitHub pull request URL, names a Jira ticket key (e.g. PROJ-123), or asks to list assigned Jira tickets, plan or fix a ticket, open a draft PR for a ticket, check a PR's CI or review comments, or apply reviewer feedback."
---

# Jira Fix Workflow

```
ticket → recon → intel gate → plan gate → code → verify → review → push gate → (optional) draft PR → (optional) Jira comment
```

`SKILL_DIR` is the directory holding this file.

- **Read `SKILL_DIR/LOCAL.md` first if it exists.** It holds the user's workspace rules (which repository a ticket belongs to, test policy, verification commands) and overrides this file.
- **The target repository's rules override this file's defaults too:** `AGENTS.md`, `CLAUDE.md`, `.cursor/rules/`, hooks, PR templates. A hook that blocks an edit is a repository rule: report it, and never route around it.
- If `SKILL_DIR/.env` is missing or still has placeholders, run first-time setup from `references/setup.md`.
- Never change a Jira ticket's status. Only comment, and only after the user confirms the exact text.

## Gates

On new work, never skip a gate unless the user explicitly says to for this ticket, and never fold one into the next step:

1. **Intel gate** — under-specified ticket → name each gap and why it matters, then stop.
2. **Plan gate** — six-section plan, then wait for explicit approval before any branch, file write, or formatter run.
3. **Push gate** — staged diff stat and the exact commit message, then wait for explicit approval.

Approval means the user says to proceed; a question or silence is not approval. A draft PR and a Jira comment are separate opt-ins after the push gate.

## Which workflow

Decide from the repository's state, never from the wording alone:

```bash
bash SKILL_DIR/scripts/gh-pr.sh branches --key TICKET-KEY      # branches and worktrees
bash SKILL_DIR/scripts/gh-pr.sh pr find --source <branch>      # open PR?
```

| State | Workflow |
|---|---|
| A PR URL was pasted, or the ticket's branch has an open PR | 3 — feedback, no gates |
| Pushed branch, no PR | 3 — feedback, from the Jira comments |
| Local-only branch with commits | Ask |
| No branch | 2 — new work |
| The user asked for a plan only | 4 — plan only |

If the branch is checked out in a worktree, work in that worktree.

## Tools

**Jira — Atlassian MCP first.** `cloudId` is the site hostname from `JIRA_URL`.

| Need | Call |
|---|---|
| List | `searchJiraIssuesUsingJql`, `fields:["summary","status","issuetype","priority","updated"]`, JQL `assignee = currentUser() AND statusCategory != Done ORDER BY priority DESC, updated DESC` or `JIRA_LIST_JQL` |
| Ticket | `getJiraIssue` with `view:"full"`, `responseContentFormat:"html"`, `fields:["summary","description","environment","status","issuetype","priority","labels","components","assignee","issuelinks","attachment"]` (the default view drops links and type) |
| Acceptance criteria, repro steps | a second `getJiraIssue` with `view:"evidence"` and no `fields`; read `fields.customFields` by display name |
| Comments | `listJiraIssueComments` with `responseContentFormat:"html"`, paged until `isLast` (`getJiraIssue` only counts them) |
| Images | `executeRead` → `downloadJiraIssueAttachment` with the numeric attachment `id` and `outputPath:"/tmp/jira-fix-KEY/<file>"`; run the returned `downloadCommand`, then open the file |
| Comment | `addOrEditJiraIssueComment`; for a real mention use `contentFormat:"html"` and `<span data-type="mention" data-user-id="ID">@Name</span>` |

Read bodies as `html`: markdown turns images into unreachable `blob:` links, and `adf` is rejected. Each image is a media element whose `data-alt` is its filename, which ties it to `fields.attachment`.

Without MCP, use `bash SKILL_DIR/scripts/jira-api.sh list|get|comments|comment` (see `--help`). It accepts keys or `/browse/` URLs but cannot download images, so ask the user to paste any load-bearing one.

**GitHub — `bash SKILL_DIR/scripts/gh-pr.sh`** (fork-aware, `--format json`, `--help`): `repo detect` · `branches --key` · `pr find` · `pr create` (draft, idempotent, `--dry-run`) · `pr feedback` (drops resolved threads, review summaries whose threads are all resolved, and your own replies; `--since` compares instants) · `pr checks`.

**Verification commands**, first match wins: `LOCAL.md` and the repository's `AGENTS.md` / `CLAUDE.md`; `TEST_CMD` / `LINT_CMD` / `FMT_CMD` in `.env`; `package.json` scripts with the lockfile's package manager. Nothing found → skip it; never invent a command.

## Workflow 1 — list my tickets

List with the JQL above, present the tickets plainly, and let the user pick. Never start work off the list.

## Workflow 2 — new work

`MAIN_BRANCH` comes from `.env` (default `develop`).

**Phase 0 — Recon** (read-only)

1. Confirm the ticket belongs to this repository: platform, service, the `LOCAL.md` mapping. If not, switch to the right checkout.
2. Read the ticket, its custom fields, and every comment. Follow linked tickets, Confluence pages, and Figma links for the spec; designs get revised in comments, and the latest one wins. Download each relevant image to `/tmp/jira-fix-KEY/`, never into a repository, and look at it.
3. Check prior work: `gh-pr.sh branches --key KEY` and `gh-pr.sh pr find`.
4. Read the repository's and the module's `AGENTS.md`, then the code. Locate with search first; read in full the files the change touches or directly depends on, and cite the rest by path. Naming a file is not reading it.
5. Run `git log --oneline -20 -- <paths>` and decide how the fix will be verified.

Report a **Recon Summary**: target repository and branch/worktree state · ticket type and ask · files read · verification path.

**Phase 1 — Intel gate.** Proceed only if all of these hold:

- The repository is confirmed.
- The goal is unambiguous.
- A bug has repro steps; a story has acceptance criteria (custom fields count).
- The impact is traced to files you read.
- The expected result is stated, not inferred.
- There is a way to verify it.
- Nothing load-bearing exists only in media you could not open.

Otherwise stop and ask, and offer to post the questions on Jira.

**Phase 2 — Plan gate.** Six sections:

1. Understanding / root cause
2. Files
3. Change plan
4. Verification: tests, commands, and the `TEST_URL_PATTERN` link with `{TICKET_NUMBER}` filled in, if it is set
5. Risk
6. Branch `feature/KEY-three-to-five-words` and commit `type(scope): KEY module - description` (`feat` for stories, `fix` for bugs, else `refactor` / `chore` / `docs`)

Then stop and wait for approval.

**Phase 3 — Branch.** If the ticket already has a worktree, work there. Otherwise run `git status --short`. If anything is dirty, never stash: offer a worktree (`git worktree add ../<repo>-KEY -b "$BRANCH" origin/MAIN_BRANCH`), or wait. In a clean tree:

```bash
git fetch origin
if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
  git checkout "${BRANCH}" && git merge origin/MAIN_BRANCH
else
  git checkout --no-track -b "${BRANCH}" origin/MAIN_BRANCH
fi
```

A merge conflict means stop and ask.

**Phase 4 — Implement** the approved plan and nothing else. Add or update tests for the change, unless `LOCAL.md` or the repository's rules say otherwise. If the plan turns out wrong, go back to Phase 2.

**Phase 5 — Verify** with the resolved commands. Fix what your change broke, up to 3 attempts; leave pre-existing warnings in other files alone.

**Phase 6 — Review.**

1. Run `git status --short`, then stage only the intended files: `git add -- <files>`.
2. Review the staged diff with a local-diff review skill or the repository's review rules, or yourself: `git diff --cached "$(git merge-base origin/MAIN_BRANCH HEAD)"`. Check that it fully addresses the ticket, handles the edge cases, matches the surrounding code, and carries the tests the repository expects.
3. Fix the findings, re-verify, and summarize what you found and fixed.

**Phase 7 — Push gate.** Show what changed in 2-3 lines, `git diff --cached --stat "$(git merge-base origin/MAIN_BRANCH HEAD)"`, the verification results, and the exact commit message. After approval: `git commit -m "…" && git push -u origin "${BRANCH}"`.

**Phase 8 — Optional PR and Jira comment.** `gh-pr.sh pr create --title "<commit subject>" --source "${BRANCH}" --body-file -`, then `gh-pr.sh pr checks`.

## Workflow 3 — feedback

No gates.

1. In the branch's worktree, run `git fetch origin`; if the tree is clean and behind `origin/${BRANCH}`, run `git merge --ff-only`. Then run `gh-pr.sh pr feedback --since "$(git log -1 --format=%cI)"` and `gh-pr.sh pr checks`, and read the Jira comments with the same cutoff. `pr checks` also reports the review decision and merge state; an "LGTM" comment is not an approval. If that shows nothing new, or the history was amended or rebased, run `pr feedback` without `--since`.
2. Write one line per item, `[source] ask → action`, then start working:
   - clear and in scope → fix it;
   - a question, or a claim the code contradicts → check the code and draft a reply;
   - ambiguous, reviewers disagree, outside this diff, an API or schema change, or in conflict with the acceptance criteria → ask about that item only, and ship the rest.
3. Change only what was flagged. A real problem you find outside the feedback gets reported, not fixed silently in this diff.
4. Stage only what you changed, verify (Phase 5), review (Phase 6), then `git commit -m "fix(scope): KEY module - address review feedback" && git push`. Never `--force-with-lease` without approval.
5. Report the changes and any drafted replies, and offer a Jira comment.

## Workflow 4 — plan only

Phases 0-2, then stop.

## Output formats

PR body, about 12 lines, unless the repository has its own template:

```markdown
## Ticket
PROJ-482 — one line, in your own words, of what was asked.
https://your-site.atlassian.net/browse/PROJ-482

## Scope
- packages/client/src/app/chat — message bubble layout and action menu

## Changes
- Hide the react action on outgoing voice messages
```

Nothing else: no test logs, checkboxes, checklists, restated ticket text, screenshots you did not take, or "please review".

Jira comment: at most 3 lines and 200 characters, outcome and links only, no filler. Without a PR, the second line is `Branch: <branch>`; the `TEST_URL_PATTERN` link may be the third.

```
Fixed: header overlap on mobile nav.
PR: https://your-host.ghe.com/org/repo/pull/123
```

## Red flags

| Thought | Instead |
|---|---|
| "It's a small fix, skip the plan" | Present the plan and wait. |
| "I'll stash their changes for now" | Never stash. Use a worktree, or ask. |
| "Save the screenshot to `./`" | `/tmp/jira-fix-KEY/` only, and stage explicit files. |
| "The reviewer said so, just change it" | Check the code first; reply or escalate if it conflicts. |
| "While I'm here, I'll fix this too" | Report it; feedback fixes touch only what was flagged. |
| "Read every related file to be safe" | Search first; read in full what the change touches. |
