# First-time setup

Run this when `SKILL_DIR/.env` is missing or still holds placeholder values.

1. **Jira site.** Ask the user to paste any Jira ticket URL and take `JIRA_URL` from it, e.g. `https://your-site.atlassian.net`.
2. **Repository.** Run `bash SKILL_DIR/scripts/gh-pr.sh repo detect`. `UNSUPPORTED_REMOTE` means this is not a GitHub / GitHub Enterprise checkout; tell the user and stop.
3. **GitHub auth.** Run `gh auth status --hostname <HOST>`. If it fails, ask the user to run `gh auth login --hostname <HOST> --git-protocol ssh --web`. Never ask for, print, or store a GitHub token.
4. **Target branch.** Confirm `MAIN_BRANCH` with the user, starting from `DefaultBranch` in step 2. Some teams merge into `develop` while `origin/HEAD` points at `main`.
5. **Atlassian MCP.** Call `getAccessibleAtlassianResources` on the Atlassian MCP server. If it answers, Jira needs no token; skip step 7.
6. **Create `.env`:**
   ```bash
   cp SKILL_DIR/.env.example SKILL_DIR/.env && chmod 600 SKILL_DIR/.env
   ```
   Write `JIRA_URL` and `MAIN_BRANCH` into it. When the skill sits inside a git repository (a project install under `.agents/skills/`), make sure `.env` can never be committed:
   ```bash
   if git -C SKILL_DIR rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      && ! git -C SKILL_DIR check-ignore -q .env; then
     printf '.env\n' >> SKILL_DIR/.gitignore
   fi
   ```
7. **Jira token, only without MCP.** Ask for the user's Atlassian email and an API token from https://id.atlassian.com/manage-profile/security → "Create API token with scopes" → App: Jira. Write `ATLASSIAN_EMAIL` and `ATLASSIAN_API_TOKEN` into `.env` and check with `bash SKILL_DIR/scripts/jira-api.sh list`.

## Workspace rules

Rules that belong to one user's or team's workspace — which repository a ticket belongs to, whether new tests are allowed, which lint and format commands to run, internal hostnames — go in `SKILL_DIR/LOCAL.md`, not in `SKILL.md`. The skill reads `LOCAL.md` first, and installs and upgrades never overwrite it.
