# Multi-Git Provider Implementation Plan

> **SUPERSEDED (v2.0.0) — do not execute.** Bitbucket support was removed instead of being
> preserved, and the GitHub provider ships as `scripts/gh-pr.sh` rather than the `lib/` +
> `jira-fix-host` CLI described below.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `jira-fix` into a safe Jira-to-code workflow that supports Bitbucket Cloud, GitHub.com, and arbitrary GitHub Enterprise Server hosts without breaking existing Bitbucket installations.

**Architecture:** Build provider behavior first as dependency-injected CommonJS libraries under `lib/`, then expose it through non-interactive text/JSON CLIs. Keep `SKILL.md` focused on workflow policy and safety gates; preserve old shell commands as compatibility shims.

**Tech Stack:** Node.js CommonJS, built-in `node:test`, built-in `fetch`, `git`, GitHub CLI `gh`, Bash compatibility shims, Jira REST API, Bitbucket Cloud REST API.

## Global Constraints

- Support Bitbucket Cloud, github.com, and arbitrary GitHub Enterprise Server hosts.
- Do not hardcode `ideawise.ghe.com` or a business repository.
- GitHub authentication uses the `gh` credential store; do not persist GitHub tokens in `.env`.
- Existing Bitbucket `.env` values and `scripts/bb-pr.sh` continue to work.
- Every CLI accepts non-interactive text input, emits text, and supports `--format json`.
- New behavior starts as a standalone reusable library.
- A dirty worktree is never stashed automatically.
- Commit and push require explicit user confirmation.
- Pull-request creation is optional and idempotent.
- Jira comments and ticket status remain user-controlled; the skill never changes ticket status.

---

### Task 1: Repository Detection Library

**Files:**
- Create: `lib/git-host/detect.js`
- Create: `lib/git-host/errors.js`
- Create: `test/git-host/detect.test.js`

**Interfaces:**
- Produces: `parseRemoteUrl(remoteUrl) -> { provider, host, owner, name, remoteUrl }`
- Produces: `detectRepository({ cwd, remoteName, runGit, mainBranch }) -> Repository`
- Produces: `GitHostError` with stable `code`, `message`, and optional `details`

- [ ] **Step 1: Write failing remote-parser tests**

```js
const test = require('node:test');
const assert = require('node:assert/strict');
const { parseRemoteUrl } = require('../../lib/git-host/detect');

test('detects Bitbucket Cloud from SCP-style SSH', () => {
    assert.deepEqual(parseRemoteUrl('git@bitbucket.org:team/repo.git'), {
        provider: 'bitbucket',
        host: 'bitbucket.org',
        owner: 'team',
        name: 'repo',
        remoteUrl: 'git@bitbucket.org:team/repo.git',
    });
});

test('detects GHES with a custom SSH username', () => {
    assert.deepEqual(parseRemoteUrl('ideawise@ideawise.ghe.com:dating-framework/df-web.git'), {
        provider: 'github',
        host: 'ideawise.ghe.com',
        owner: 'dating-framework',
        name: 'df-web',
        remoteUrl: 'ideawise@ideawise.ghe.com:dating-framework/df-web.git',
    });
});

test('redacts credentials from HTTPS remotes', () => {
    const result = parseRemoteUrl('https://secret@example.com/acme/repo.git');
    assert.equal(result.remoteUrl, 'https://example.com/acme/repo.git');
});
```

- [ ] **Step 2: Run tests and verify RED**

Run: `node --test test/git-host/detect.test.js`

Expected: FAIL with `MODULE_NOT_FOUND` for `lib/git-host/detect`.

- [ ] **Step 3: Implement URL parsing and safe errors**

```js
class GitHostError extends Error {
    constructor(code, message, details) {
        super(message);
        this.name = 'GitHostError';
        this.code = code;
        this.details = details;
    }
}

function parseRemoteUrl(remoteUrl) {
    const value = String(remoteUrl || '').trim();
    let host;
    let path;
    let safeUrl = value;

    if (/^https?:\/\//i.test(value) || /^ssh:\/\//i.test(value)) {
        const url = new URL(value);
        host = url.hostname;
        path = url.pathname;
        url.username = '';
        url.password = '';
        safeUrl = url.toString().replace(/\/$/, '');
    } else {
        const match = value.match(/^[^@/\s]+@([^:\s]+):(.+)$/);
        if (!match) {
            throw new GitHostError('UNSUPPORTED_REMOTE', 'Unsupported Git remote URL.');
        }
        [, host, path] = match;
    }

    const parts = path.replace(/^\/+|\.git$/g, '').split('/');
    if (parts.length !== 2 || parts.some((part) => !part)) {
        throw new GitHostError('UNSUPPORTED_REMOTE', 'Git remote must contain owner/repository.');
    }

    return {
        provider: host.toLowerCase() === 'bitbucket.org' ? 'bitbucket' : 'github',
        host: host.toLowerCase(),
        owner: parts[0],
        name: parts[1],
        remoteUrl: safeUrl,
    };
}
```

- [ ] **Step 4: Add failing repository-detection tests**

Test push-URL preference, fetch-URL fallback, `MAIN_BRANCH` override, `origin/HEAD`, and `develop` fallback by injecting:

```js
const runGit = (args) => {
    const key = args.join(' ');
    return {
        'remote get-url --push origin': 'git@github.com:acme/repo.git',
        'symbolic-ref refs/remotes/origin/HEAD': 'refs/remotes/origin/main',
    }[key] ?? '';
};
```

- [ ] **Step 5: Implement `detectRepository` minimally**

Use injected `runGit(args, options)` for tests and `execFileSync('git', args)` by default. Return:

```js
{
    provider: 'github',
    host: 'github.com',
    owner: 'acme',
    name: 'repo',
    remoteName: 'origin',
    defaultBranch: 'main',
    remoteUrl: 'git@github.com:acme/repo.git',
}
```

- [ ] **Step 6: Run tests and commit**

Run: `node --test test/git-host/detect.test.js`

Expected: all tests PASS.

```bash
git add lib/git-host/detect.js lib/git-host/errors.js test/git-host/detect.test.js
git commit -m "feat: add Git host repository detection"
```

---

### Task 2: GitHub Provider

**Files:**
- Create: `lib/git-host/github.js`
- Create: `test/git-host/github.test.js`

**Interfaces:**
- Consumes: `Repository` from Task 1
- Produces: `createGitHubProvider({ runGh })`
- Provider methods: `verifyAuth(repository)`, `findPullRequest(repository, input)`, `createDraftPullRequest(repository, input)`, `getPullRequestFeedback(repository, input)`

- [ ] **Step 1: Write failing provider tests**

```js
const test = require('node:test');
const assert = require('node:assert/strict');
const { createGitHubProvider } = require('../../lib/git-host/github');

const repository = {
    provider: 'github',
    host: 'ghe.example.com',
    owner: 'acme',
    name: 'web',
};

test('uses an explicit GHES repository and native draft PR', async () => {
    const calls = [];
    const runGh = async (args) => {
        calls.push(args);
        if (args[0] === 'auth') return '';
        if (args[0] === 'pr' && args[1] === 'list') return '[]';
        if (args[0] === 'pr' && args[1] === 'create') return 'https://ghe.example.com/acme/web/pull/7\n';
        return JSON.stringify({
            number: 7,
            url: 'https://ghe.example.com/acme/web/pull/7',
            title: 'fix: PROJ-7 issue',
            headRefName: 'fix/PROJ-7-issue',
            baseRefName: 'main',
            isDraft: true,
        });
    };

    const provider = createGitHubProvider({ runGh });
    const result = await provider.createDraftPullRequest(repository, {
        title: 'fix: PROJ-7 issue',
        sourceBranch: 'fix/PROJ-7-issue',
        targetBranch: 'main',
        body: 'Description',
    });

    assert.equal(result.draft, true);
    assert.ok(calls.some((args) => args.includes('ghe.example.com/acme/web')));
    assert.ok(calls.some((args) => args.includes('--draft')));
});
```

- [ ] **Step 2: Run test and verify RED**

Run: `node --test test/git-host/github.test.js`

Expected: FAIL because `lib/git-host/github.js` does not exist.

- [ ] **Step 3: Implement the GitHub provider**

Use these command contracts:

```text
gh auth status --hostname HOST
gh pr list --repo HOST/OWNER/REPO --state open --head SOURCE --base TARGET --json number,url,title,headRefName,baseRefName,isDraft
gh pr create --repo HOST/OWNER/REPO --head SOURCE --base TARGET --draft --title TITLE --body-file -
gh pr view URL --repo HOST/OWNER/REPO --json number,url,title,headRefName,baseRefName,isDraft,comments,reviews
```

`findPullRequest` returns the first normalized open PR. `createDraftPullRequest` calls `findPullRequest` first and returns it when present. Pass PR body to the injected runner as stdin.

- [ ] **Step 4: Add feedback and failure tests**

Cover:

- Missing `gh`.
- Host authentication failure.
- Existing PR idempotency.
- Normalization of `comments` and `reviews`.
- SSO/permission errors mapped to `GitHostError('AUTH_REQUIRED', ...)` without raw command output.

- [ ] **Step 5: Run tests and commit**

Run: `node --test test/git-host/github.test.js`

Expected: all tests PASS.

```bash
git add lib/git-host/github.js test/git-host/github.test.js
git commit -m "feat: add GitHub pull request provider"
```

---

### Task 3: Bitbucket Provider

**Files:**
- Create: `lib/git-host/bitbucket.js`
- Create: `test/git-host/bitbucket.test.js`

**Interfaces:**
- Consumes: `Repository` from Task 1
- Produces: `createBitbucketProvider({ fetchImpl, email, token, workspace })`
- Implements the same four provider methods as Task 2

- [ ] **Step 1: Write failing Bitbucket tests**

Use a fixture `fetchImpl` that records URL/options and returns:

```js
{
    ok: true,
    json: async () => ({
        id: 12,
        title: '[DRAFT] fix: PROJ-12 issue',
        links: { html: { href: 'https://bitbucket.org/acme/web/pull-requests/12' } },
        source: { branch: { name: 'fix/PROJ-12-issue' } },
        destination: { branch: { name: 'develop' } },
    }),
}
```

Assert Basic auth, workspace/repository URL, `[DRAFT]` compatibility, normalized output, and no duplicate create call when an open PR exists.

- [ ] **Step 2: Run test and verify RED**

Run: `node --test test/git-host/bitbucket.test.js`

Expected: FAIL because `lib/git-host/bitbucket.js` does not exist.

- [ ] **Step 3: Implement the Bitbucket provider**

Use:

```text
GET  https://api.bitbucket.org/2.0/repositories/{workspace}/{repo}/pullrequests?q=state="OPEN" AND source.branch.name="..."
POST https://api.bitbucket.org/2.0/repositories/{workspace}/{repo}/pullrequests
GET  https://api.bitbucket.org/2.0/repositories/{workspace}/{repo}/pullrequests/{id}/activity?pagelen=100
```

Construct Basic auth with `Buffer.from(email + ':' + token).toString('base64')`. Validate that the detected owner matches `BB_WORKSPACE` when the variable is set.

- [ ] **Step 4: Add API error and feedback tests**

Cover missing token, workspace mismatch, HTTP timeout/error, comment/update normalization, and redaction of response details.

- [ ] **Step 5: Run tests and commit**

Run: `node --test test/git-host/bitbucket.test.js`

Expected: all tests PASS.

```bash
git add lib/git-host/bitbucket.js test/git-host/bitbucket.test.js
git commit -m "feat: add Bitbucket pull request provider"
```

---

### Task 4: Unified Git-Host Library and CLI

**Files:**
- Create: `lib/config.js`
- Create: `lib/git-host/index.js`
- Create: `bin/jira-fix-host.js`
- Create: `test/config.test.js`
- Create: `test/git-host/index.test.js`
- Create: `test/cli/git-host.test.js`
- Modify: `package.json`

**Interfaces:**
- Consumes: detection and providers from Tasks 1–3
- Produces: `createGitHostClient(options)`
- Produces CLI commands: `repo detect`, `pr find`, `pr create`, `pr feedback`

- [ ] **Step 1: Write failing config and dispatch tests**

Test `.env` parsing for unquoted values, quoted values, comments, and preservation of existing process environment. Test provider dispatch for GitHub and Bitbucket repositories.

- [ ] **Step 2: Run tests and verify RED**

Run: `node --test test/config.test.js test/git-host/index.test.js`

Expected: FAIL because the modules do not exist.

- [ ] **Step 3: Implement config loading and provider dispatch**

`loadEnvFile(path, target = process.env)` parses only `KEY=value` lines, strips matching single/double quotes, ignores blank/comment lines, and never overwrites an existing target key.

`createGitHostClient` exposes:

```js
{
    detectRepository,
    findPullRequest,
    createDraftPullRequest,
    getPullRequestFeedback,
}
```

It detects the repository once per operation and dispatches to the matching provider factory.

- [ ] **Step 4: Write failing CLI tests**

Spawn the CLI with fixture dependency hooks through an environment-selected fixture module. Verify:

```text
jira-fix-host repo detect --cwd PATH --format json
jira-fix-host pr create --title TITLE --source BRANCH --target BASE --body-file - --format json
jira-fix-host pr feedback --source BRANCH --format text
```

Assert stdout is valid JSON in JSON mode, human-readable text in text mode, stdin body is preserved, `--help` includes examples, and missing flags exit non-zero with a valid example.

- [ ] **Step 5: Implement the CLI**

Use a small local argument parser; do not add a dependency. Required JSON shapes:

```js
// repo detect
{ provider, host, owner, name, remoteName, defaultBranch }

// pr create/find
{ provider, id, url, title, sourceBranch, targetBranch, draft }

// pr feedback
{ pullRequest, feedback: [{ kind, author, body, url, createdAt, state }] }
```

- [ ] **Step 6: Add the package binary and test script**

Update `package.json`:

```json
{
  "version": "1.1.0",
  "bin": {
    "jira-fix-skill": "./bin/install.sh",
    "jira-fix-host": "./bin/jira-fix-host.js"
  },
  "scripts": {
    "test": "node --test"
  }
}
```

Include `lib/` and `test/` appropriately; published files need `lib/`, `bin/`, `scripts/`, `SKILL.md`, and `.env.example`, but tests need not be published.

- [ ] **Step 7: Run tests and commit**

Run: `node --test test/config.test.js test/git-host/index.test.js test/cli/git-host.test.js`

Expected: all tests PASS.

```bash
git add lib bin/jira-fix-host.js test package.json
git commit -m "feat: add unified Git host CLI"
```

---

### Task 5: Jira REST Library, Feedback, and JSON CLI

**Files:**
- Create: `lib/jira/index.js`
- Create: `bin/jira-fix-jira.js`
- Create: `test/jira/client.test.js`
- Create: `test/cli/jira.test.js`
- Modify: `scripts/jira-api.sh`
- Modify: `package.json`

**Interfaces:**
- Produces: `createJiraClient({ baseUrl, email, token, fetchImpl })`
- Methods: `listIssues(jql)`, `getIssue(key)`, `getFeedback(key)`, `addComment(key, text)`
- Produces CLI commands: `list`, `get`, `feedback`, `comment`

- [ ] **Step 1: Write failing Jira client tests**

Use injected fetch fixtures to verify:

- Issue list normalization.
- ADF description text extraction.
- Comment pagination and feedback normalization.
- Multiline comment conversion to ADF paragraphs and `hardBreak` nodes.
- Safe authentication errors.

- [ ] **Step 2: Run tests and verify RED**

Run: `node --test test/jira/client.test.js`

Expected: FAIL because `lib/jira/index.js` does not exist.

- [ ] **Step 3: Implement the Jira library**

Use Jira REST v3:

```text
POST /rest/api/3/search/jql
GET  /rest/api/3/issue/{key}?fields=summary,description,issuetype,priority,status,labels,components,assignee
GET  /rest/api/3/issue/{key}/comment?orderBy=-created&maxResults=100
POST /rest/api/3/issue/{key}/comment
```

Return normalized plain objects and keep ADF conversion inside the library.

- [ ] **Step 4: Write failing Jira CLI and shim tests**

Verify text and JSON output for every command, comment text from `--text`, `--text-file`, or stdin, and old positional forms:

```text
scripts/jira-api.sh list
scripts/jira-api.sh get PROJ-1
scripts/jira-api.sh comment PROJ-1 "message"
```

- [ ] **Step 5: Implement CLI and compatibility shim**

`bin/jira-fix-jira.js` loads `.env`, validates Jira credentials, and calls the library. `scripts/jira-api.sh` resolves `SKILL_DIR` and executes the Node CLI while preserving old positional arguments.

Add:

```json
"jira-fix-jira": "./bin/jira-fix-jira.js"
```

to `package.json#bin`.

- [ ] **Step 6: Run tests and commit**

Run: `node --test test/jira/client.test.js test/cli/jira.test.js`

Expected: all tests PASS.

```bash
git add lib/jira bin/jira-fix-jira.js scripts/jira-api.sh test/jira test/cli/jira.test.js package.json
git commit -m "feat: add Jira feedback and JSON CLI"
```

---

### Task 6: Compatibility Shim and Installer

**Files:**
- Modify: `scripts/bb-pr.sh`
- Modify: `bin/install.sh`
- Modify: `.env.example`
- Create: `test/cli/install.test.js`
- Create: `test/cli/bb-shim.test.js`

**Interfaces:**
- Consumes: unified CLIs from Tasks 4–5
- Preserves: old `bb-pr.sh TICKET TITLE SOURCE_BRANCH [DESCRIPTION]`
- Adds installer flags: `--target cursor|claude|codex|project|PATH`, `--all`, `--yes`, `--format text|json`

- [ ] **Step 1: Write failing shim tests**

Run `bb-pr.sh` with a fixture `jira-fix-host` executable and assert it forwards title/source/target/body, preserves exit code, emits a deprecation warning on stderr, and supports `--format json`.

- [ ] **Step 2: Write failing installer tests**

Use a temporary `HOME` and target directory. Verify:

- Non-interactive `--target PATH --yes --format json`.
- `SKILL.md`, `.env.example`, `lib/`, `bin/`, and `scripts/` are copied.
- Existing `.env` content and mode are preserved.
- Removed files are reported but not deleted.
- Interactive mode still works when no target flags are given.

- [ ] **Step 3: Run tests and verify RED**

Run: `node --test test/cli/install.test.js test/cli/bb-shim.test.js`

Expected: FAIL against the current installer and shim.

- [ ] **Step 4: Implement the shim and installer**

The installer copies the package tree needed at runtime and emits:

```js
{
    target: '/path/to/skill',
    upgraded: true,
    envPreserved: true,
    deprecatedFiles: ['scripts/bb-pr.sh'],
}
```

in JSON mode. It must never print token values.

- [ ] **Step 5: Update `.env.example`**

Keep Bitbucket variables as optional provider-specific values and add:

```text
GIT_REMOTE=origin
```

Document that GitHub credentials live in `gh`, not this file.

- [ ] **Step 6: Run tests and commit**

Run: `node --test test/cli/install.test.js test/cli/bb-shim.test.js`

Expected: all tests PASS.

```bash
git add scripts/bb-pr.sh bin/install.sh .env.example test/cli
git commit -m "feat: preserve Bitbucket installs with unified installer"
```

---

### Task 7: Skill RED-GREEN-REFACTOR

**Files:**
- Create: `test/skill/scenarios.md`
- Create: `test/skill/baseline-results.md`
- Create: `test/skill/verification-results.md`
- Modify: `SKILL.md`

**Interfaces:**
- Consumes: `SKILL_DIR/bin/jira-fix-host.js` and `SKILL_DIR/bin/jira-fix-jira.js`
- Produces: concise workflow policy for list, plan, fix, feedback, PR, and Jira-comment requests

- [ ] **Step 1: Record baseline scenarios before editing the skill**

Run fresh-context subagents without the proposed `SKILL.md` changes for:

1. GHES SSH works but `gh` is not authenticated.
2. Bitbucket `.env` is already configured.
3. Worktree is dirty and user says to start immediately.
4. A PR already exists for the branch.
5. Feedback is split between Jira and PR reviews.
6. User declines commit/push.

Save prompts, observed behavior, and exact failures in `test/skill/baseline-results.md`.

- [ ] **Step 2: Verify RED**

At least one scenario must demonstrate each targeted current failure:

- Bitbucket-only platform assumption.
- Automatic stash.
- Commit/push without an explicit gate.
- Feedback read only from Jira.
- Duplicate PR risk.

If a targeted failure does not reproduce, remove that claim from the skill rather than writing unnecessary guidance.

- [ ] **Step 3: Rewrite `SKILL.md` minimally**

Required frontmatter shape:

```yaml
---
name: jira-fix
description: Use when listing Jira work, planning or fixing a Jira ticket, creating a pull request from ticket work, or applying Jira or pull-request feedback.
---
```

Required workflow rules:

- Resolve `SKILL_DIR`.
- Prefer Atlassian MCP; use Jira CLI fallback.
- Detect provider through the Git-host CLI.
- Stop on a dirty worktree and ask.
- Use `git pull --ff-only`.
- Verify, review, then ask before commit/push.
- Ask separately before draft PR and Jira comment.
- Read Jira and PR feedback.
- Never change Jira ticket status.
- Never select a PR-URL review skill for a pre-commit local diff merely because its name contains `review`.

- [ ] **Step 4: Run the same scenarios with the new skill**

Record results in `test/skill/verification-results.md`. Every scenario must choose the right provider, stop at mutation gates, avoid duplicate PRs, and collect both feedback sources.

- [ ] **Step 5: Refactor wording and re-test**

Close only loopholes observed in Step 4. Keep the skill concise and move CLI details to `--help`.

- [ ] **Step 6: Commit**

```bash
git add SKILL.md test/skill
git commit -m "feat: make Jira fix workflow provider-aware"
```

---

### Task 8: Documentation, Full Verification, Push, and Local Update

**Files:**
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `package.json`
- Verify only: all source, test, and installer files
- Update outside repository after verification: `/Users/leon/.cursor/skills/jira-fix-skill`

**Interfaces:**
- Documents all public CLIs, configuration, providers, compatibility, and safety gates
- Produces a verified local Cursor skill installation

- [ ] **Step 1: Update English and Chinese documentation**

Document:

- Supported Git providers.
- `gh auth login --hostname HOST --git-protocol ssh --web`.
- Bitbucket token compatibility.
- Text/JSON CLI examples.
- Confirmation before commit/push.
- Jira plus PR feedback.
- Non-interactive installer.
- Updated file tree.

- [ ] **Step 2: Verify package metadata**

Set version `1.1.0`, update description and keywords to include GitHub, GitHub Enterprise, Bitbucket, and Jira, and ensure all binaries and runtime files are published.

- [ ] **Step 3: Run complete automated verification**

Run:

```bash
node --test
bash -n bin/install.sh scripts/bb-pr.sh scripts/jira-api.sh
node bin/jira-fix-host.js --help
node bin/jira-fix-jira.js --help
pack_file="$(mktemp /tmp/jira-fix-skill.XXXXXX.tgz)"
yarn pack --filename "$pack_file"
tar -tzf "$pack_file"
rm -f "$pack_file"
git diff --check
```

Expected: all tests pass, shell syntax succeeds, both help commands exit 0 with examples, the package archive includes required runtime files, and diff check is clean.

- [ ] **Step 4: Run provider smoke tests without external writes**

In a GitHub/GHES repository:

```bash
node bin/jira-fix-host.js repo detect --format json
```

In a Bitbucket fixture repository, run the same command. Do not create a real PR during smoke testing.

- [ ] **Step 5: Commit documentation**

```bash
git add README.md README.zh-CN.md package.json
git commit -m "docs: document multi-provider Jira workflow"
```

- [ ] **Step 6: Review the branch diff**

Review `git diff main...HEAD` for correctness, secret leakage, accidental token output, compatibility, and test completeness. Fix valid issues and rerun Step 3.

- [ ] **Step 7: Push the implementation branch**

```bash
git push origin feature/multi-git-provider
```

- [ ] **Step 8: Update the local Cursor installation**

Use the verified non-interactive installer:

```bash
bin/install.sh --target /Users/leon/.cursor/skills/jira-fix-skill --yes --format json
```

Confirm `.env` is unchanged, then run:

```bash
node /Users/leon/.cursor/skills/jira-fix-skill/bin/jira-fix-host.js --help
node /Users/leon/.cursor/skills/jira-fix-skill/bin/jira-fix-jira.js --help
```

Expected: both commands exit 0 and show the same version/help as the source branch.
