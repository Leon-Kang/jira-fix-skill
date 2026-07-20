# Multi-Git Provider Design

## Purpose

Keep `jira-fix` useful as a workflow and safety policy layer while supporting:

- Bitbucket Cloud
- GitHub.com
- GitHub Enterprise Server, including custom SSH usernames and hosts

The skill should not replace Jira, GitHub, or Bitbucket clients. Its value is coordinating a consistent Jira-to-code workflow with verification, review, explicit mutation gates, and optional external publication.

## Goals

- Detect the Git hosting provider and repository from the current Git remote.
- Create draft pull requests through a common provider contract.
- Read pull-request reviews and comments during feedback handling.
- Preserve existing Bitbucket installations and `.env` values.
- Use GitHub CLI credential storage instead of adding GitHub tokens to `.env`.
- Require confirmation before commit and push.
- Provide non-interactive, agent-friendly CLIs with text and JSON output.

## Non-goals

- Changing Jira ticket status.
- Replacing Atlassian MCP.
- Managing GitHub or Bitbucket organization settings.
- Supporting GitLab in this version.
- Hiding or automatically stashing an existing dirty worktree.

## Architecture

### Workflow layer

`SKILL.md` remains the policy and orchestration layer. It defines:

- Jira ticket selection and requirement confirmation.
- Safe branch preparation.
- Implementation, testing, formatting, linting, and review.
- Confirmation before commit and push.
- Optional draft PR creation and Jira comments.
- Feedback collection from both Jira and the active pull request.

Platform-specific API details must not be embedded in the workflow instructions.

### Reusable Git-host library

Add a standalone CommonJS library under `lib/git-host/`:

- `index.js` — public API and provider dispatch.
- `detect.js` — remote parsing and repository detection.
- `github.js` — GitHub.com and GHES provider.
- `bitbucket.js` — Bitbucket Cloud provider.
- `errors.js` — stable error types and safe messages.

Public operations:

```text
detectRepository(options) -> Repository
createDraftPullRequest(repository, input) -> PullRequest
findPullRequest(repository, input) -> PullRequest | null
getPullRequestFeedback(repository, input) -> Feedback[]
```

Shared models:

```text
Repository:
  provider, host, owner, name, remoteName, defaultBranch

PullRequest:
  provider, id, url, title, sourceBranch, targetBranch, draft

Feedback:
  provider, kind, author, body, url, createdAt, state
```

### Providers

GitHub:

- Supports `github.com` and arbitrary GHES hosts.
- Uses `gh` with an explicit `[HOST/]OWNER/REPO` repository argument.
- Verifies authentication for the detected host.
- Uses native draft PR state.
- Reads reviews and conversation comments with `gh pr view` or `gh api`.

Bitbucket:

- Supports Bitbucket Cloud.
- Uses the existing REST API token and workspace configuration.
- Preserves the existing `[DRAFT]` title convention because Bitbucket Cloud has no equivalent native draft state in the current implementation.
- Reads pull-request activity/comments through Bitbucket REST APIs.

### Unified CLI

Add a non-interactive CLI as a second package binary named `jira-fix-host`; keep the existing
`jira-fix-skill` installer binary unchanged. `SKILL.md` calls the installed script by its
`SKILL_DIR` path so the workflow does not depend on global PATH configuration.

Commands:

```text
jira-fix-host repo detect
jira-fix-host pr create
jira-fix-host pr find
jira-fix-host pr feedback
```

Requirements:

- Accept input through flags, stdin, or files where body content is involved.
- Support `--format text|json`.
- Include copy-pasteable examples in each `--help`.
- Emit stable JSON objects for structured exchange.
- Exit quickly with actionable errors.
- Avoid interactive prompts.
- Treat repeated PR creation as idempotent by returning the existing PR.

`scripts/bb-pr.sh` remains as a compatibility shim. It translates the old positional interface to the unified CLI and emits a deprecation warning without breaking existing automation.

## Repository detection

Detection reads the configured push URL first and falls back to the fetch URL.

Supported forms:

```text
https://host/owner/repo.git
ssh://user@host/owner/repo.git
user@host:owner/repo.git
```

Rules:

- `bitbucket.org` selects the Bitbucket provider.
- `github.com` selects the GitHub provider.
- A non-Bitbucket host uses the GitHub provider only after a successful `gh auth status --hostname HOST` check.
- `MAIN_BRANCH` overrides default-branch discovery; otherwise use `origin/HEAD`, then the provider API, then `develop`.
- Credentials embedded in HTTPS URLs are redacted from all output.
- Unknown or unsupported remotes fail with an explicit remediation message.

No business repository or enterprise hostname is hardcoded in `.env`.

## Configuration and authentication

Backward-compatible `.env` values:

- `ATLASSIAN_EMAIL`
- `ATLASSIAN_API_TOKEN`
- `BB_API_TOKEN`
- `BB_WORKSPACE`
- `JIRA_URL`
- `MAIN_BRANCH`
- `TEST_URL_PATTERN`
- command overrides and custom JQL

Optional additions:

- `GIT_REMOTE`, defaulting to `origin`
- provider override only for diagnostics and tests

GitHub authentication:

- Use the `gh` credential store.
- Guide users to `gh auth login --hostname HOST --git-protocol ssh --web`.
- Never request, print, or persist a GitHub token in the skill `.env`.

Bitbucket authentication remains unchanged for compatibility.

## Workflow

### Fix ticket

1. Fetch the Jira ticket through Atlassian MCP or the REST fallback.
2. Present the requirements and receive confirmation.
3. Inspect the worktree.
4. If dirty, stop and ask the user how to proceed; do not stash automatically.
5. Detect the provider, repository, and default branch.
6. Update the base branch with `git pull --ff-only`.
7. Create or update the ticket branch.
8. Implement the focused change.
9. Run tests, formatting, and linting.
10. Review the local diff against the base branch.
11. Present the change summary, validation evidence, and proposed commit.
12. After explicit confirmation, commit and push.
13. Separately ask whether to create a draft PR and whether to comment on Jira.

### Apply feedback

1. Locate the existing ticket branch and pull request.
2. Read Jira comments and PR reviews/conversation comments.
3. Present the actionable feedback sources.
4. Make only the requested changes.
5. Re-run verification and local review.
6. Receive confirmation before commit and push.
7. Use a normal push for additive commits; use force-with-lease only when the user explicitly approved history rewriting.

The Jira REST fallback must add a feedback/comments operation; the current issue-fields request
does not return comments and cannot satisfy this workflow by itself.

## Error handling

Use distinct, actionable errors for:

- Missing command dependency.
- Unsupported remote.
- Authentication missing for the detected provider.
- Configured repository and remote mismatch.
- Dirty worktree.
- Missing remote branch.
- Source branch not pushed.
- Conflicting pull-request state, such as a closed PR for the same source branch.
- API permission or SSO denial.
- Rate limit, timeout, or malformed API response.

Errors must not expose tokens, credential-bearing URLs, or full API response bodies that may contain secrets.

## Backward compatibility

- Preserve existing Bitbucket `.env` values.
- Keep `scripts/bb-pr.sh` as a shim for at least one major release.
- Installer upgrades preserve `.env`.
- Installer adds new files and reports deprecated files without deleting user-modified content.
- Existing Jira MCP and REST behavior remains available.
- Branch naming and commit-message conventions remain unchanged.

## Testing

### Library and CLI tests

Use Node's built-in test runner and fixtures:

- Parse HTTPS, SSH URL, SCP-like SSH, custom usernames, and credential-bearing remotes.
- Detect Bitbucket, github.com, and arbitrary GHES.
- Verify provider contract parity.
- Mock `gh` execution and Bitbucket HTTP responses.
- Verify native GitHub draft state and Bitbucket draft-title compatibility.
- Verify existing-PR idempotency.
- Verify text and JSON output.
- Verify safe error redaction.
- Verify feedback normalization.

### Skill behavior tests

Before editing `SKILL.md`, run baseline pressure scenarios without the new instructions and record failures. Re-run the same scenarios after the edit:

- GitHub Enterprise repository with an authenticated SSH remote but missing `gh` API authentication.
- Bitbucket repository using an existing `.env`.
- Dirty worktree under pressure to start immediately.
- Existing PR when asked to create another.
- Feedback split between Jira and PR reviews.
- User declines commit/push after implementation.

Success means the agent selects the correct provider, stops at mutation gates, avoids duplicate PRs, and reads feedback from both systems.

## Documentation and packaging

Update:

- `SKILL.md`
- `README.md`
- `README.zh-CN.md`
- `.env.example`
- `bin/install.sh`
- `package.json`

The package metadata should describe multi-provider Git hosting rather than Bitbucket-only behavior. The reusable library and unified CLI must be included in the published package.

## Success criteria

- One installed skill works unchanged in Bitbucket Cloud, github.com, and GHES repositories.
- Existing Bitbucket configuration continues to work.
- GitHub users authenticate with `gh`, not a token stored by the skill.
- The CLI accepts text input, emits text, and supports JSON.
- Commit/push never occur without explicit confirmation.
- PR creation is optional and idempotent.
- Feedback handling includes Jira and pull-request feedback.
