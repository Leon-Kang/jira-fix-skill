#!/usr/bin/env bash
# Offline smoke test for scripts/gh-pr.sh and scripts/jira-api.sh.
#
# `gh` and `curl` are replaced by fakes on PATH and the git remote lives in a
# throwaway repository, so nothing here touches the network or a real account.
# Runs under the macOS system bash (3.2).

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GH_PR="${ROOT}/scripts/gh-pr.sh"
JIRA_API="${ROOT}/scripts/jira-api.sh"

# Physical path: on macOS /var is a symlink, and git reports worktrees by real path.
SANDBOX="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

FAKE_BIN="${SANDBOX}/bin"
REPO="${SANDBOX}/repo"
mkdir -p "$FAKE_BIN"

# Settings from the caller's shell or a developer's .env must not leak in.
unset MAIN_BRANCH GH_HOST GIT_REMOTE JIRA_URL ATLASSIAN_EMAIL ATLASSIAN_API_TOKEN JIRA_LIST_JQL
export FAKE_LOG="${SANDBOX}/calls.log"
export PATH="${FAKE_BIN}:${PATH}"

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}

not_ok() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '        %s\n' "$2"
}

expect_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else not_ok "$1" "expected [$3], got [$2]"; fi
}

expect_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else not_ok "$1" "expected to contain [$3], got [$2]"; fi
}

expect_not_contains() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else not_ok "$1" "expected not to contain [$3]"; fi
}

# ---------------------------------------------------------------------------
# Fake gh
# ---------------------------------------------------------------------------
cat >"${FAKE_BIN}/gh" <<'FAKE_GH'
#!/usr/bin/env bash
args="$*"
printf '%s\n' "gh ${args}" >>"$FAKE_LOG"

pr_json() {
  printf '{"number":42,"url":"https://ghe.example.com/%s/pull/42","title":"fix(web): PROJ-1 nav - overlap","headRefName":"feature/PROJ-1-header-overlap","baseRefName":"develop","isDraft":true,"state":"OPEN","reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"BLOCKED"}' "$1"
}

case "$args" in
  "auth status"*)
    exit 0
    ;;
  "repo view"*)
    if [[ "${FAKE_FORK:-}" == "1" ]]; then
      printf '{"isFork":true,"parent":{"owner":{"login":"upstream-org"},"name":"web"}}'
    else
      printf '{"isFork":false,"parent":null}'
    fi
    ;;
  "pr list"*)
    if [[ "${FAKE_FORK:-}" == "1" && "$args" == *"--repo ghe.example.com/upstream-org/web"* && "$args" == *"--head acme:feature/PROJ-1-header-overlap"* ]]; then
      printf '[%s]' "$(pr_json upstream-org/web)"
    elif [[ "${FAKE_FORK:-}" != "1" && "$args" == *"--head feature/PROJ-1-header-overlap"* ]]; then
      printf '[%s]' "$(pr_json acme/web)"
    else
      printf '[]'
    fi
    ;;
  "pr view"*)
    if [[ "$args" == *"upstream-org/web"* ]]; then pr_json upstream-org/web; else pr_json acme/web; fi
    ;;
  "pr checks"*)
    case "${FAKE_CHECKS:-pending}" in
      none)
        printf 'no checks reported on the branch\n' >&2
        exit 1
        ;;
      fail)
        printf '[{"name":"build","state":"FAILURE","bucket":"fail","link":"https://ci/1"},{"name":"lint","state":"SUCCESS","bucket":"pass","link":"https://ci/2"}]'
        exit 1
        ;;
      *)
        printf '[{"name":"build","state":"IN_PROGRESS","bucket":"pending","link":"https://ci/1"},{"name":"lint","state":"SUCCESS","bucket":"pass","link":"https://ci/2"}]'
        exit 8
        ;;
    esac
    ;;
  *" user --jq"*)
    printf 'me\n'
    ;;
  *"issues/42/comments"*)
    # Two pages, as `gh api --paginate` prints them.
    printf '%s\n' '[{"user":{"login":"reviewer"},"body":"before the cutoff","html_url":"u1","created_at":"2026-09-05T09:00:00Z"},{"user":{"login":"reviewer"},"body":"after the cutoff","html_url":"u2","created_at":"2026-09-05T10:00:00Z"},{"user":{"login":"me"},"body":"my own reply","html_url":"u3","created_at":"2026-09-05T11:00:00Z"}]'
    printf '%s\n' '[{"user":{"login":"reviewer"},"body":"second page","html_url":"u4","created_at":"2026-09-05T12:00:00Z"}]'
    ;;
  *"pulls/42/reviews"*)
    printf '%s\n' '[{"user":{"login":"cursor-enterprise[bot]"},"body":"<!-- BUGBOT_REVIEW -->\nfound 2 issues","state":"COMMENTED","html_url":"r1","submitted_at":"2026-09-05T10:30:00Z"},{"user":{"login":"cursor-enterprise[bot]"},"body":"<!-- BUGBOT_REVIEW_STALE -->\nstale","state":"COMMENTED","html_url":"r2","submitted_at":"2026-09-05T10:31:00Z"},{"user":{"login":"reviewer"},"body":"","state":"COMMENTED","html_url":"r3","submitted_at":"2026-09-05T10:32:00Z"},{"user":{"login":"reviewer"},"body":"needs work","state":"CHANGES_REQUESTED","html_url":"r4","submitted_at":"2026-09-05T10:45:00Z"}]'
    ;;
  "api graphql"*)
    printf '%s' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":true,"isOutdated":false,"path":"a.ts","line":1,"comments":{"nodes":[{"author":{"login":"cursor-enterprise"},"body":"inline resolved","url":"c1","createdAt":"2026-09-05T10:15:00Z"}]}},{"isResolved":false,"isOutdated":false,"path":"b.ts","line":7,"comments":{"nodes":[{"author":{"login":"reviewer"},"body":"inline open","url":"c2","createdAt":"2026-09-05T10:20:00Z"}]}}]}}}}}'
    ;;
  *)
    printf 'fake gh: no route for: %s\n' "$args" >&2
    exit 1
    ;;
esac
FAKE_GH

# ---------------------------------------------------------------------------
# Fake curl (Jira REST)
# ---------------------------------------------------------------------------
FIXTURES="${SANDBOX}/fixtures"
mkdir -p "$FIXTURES"
export FIXTURES

cat >"${FIXTURES}/field.json" <<'JSON'
[{"id":"customfield_1","name":"Acceptance Criteria","custom":true,"schema":{"custom":"com.atlassian.jira.plugin.system.customfieldtypes:textarea"}},
 {"id":"customfield_2","name":"Rank","custom":true,"schema":{"custom":"com.pyxis.greenhopper.jira:gh-lexo-rank"}}]
JSON
cat >"${FIXTURES}/issue.json" <<'JSON'
{"key":"PROJ-7","fields":{"summary":"Signup popup","issuetype":{"name":"Story"},"priority":{"name":"High"},"status":{"name":"Open"},
 "description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Show a popup"}]},{"type":"mediaSingle","content":[{"type":"media","attrs":{"alt":"shot.png"}}]}]},
 "customfield_1":{"type":"doc","content":[{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"AC one"}]}]}]}]},
 "customfield_2":"0|abc","attachment":[{"id":9,"filename":"shot.png"}],"issuelinks":[{"inwardIssue":{"key":"PROJ-6"}}]}}
JSON
comment() {
  printf '{"id":"%s","author":{"displayName":"r"},"created":"%s","body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"c%s"}]}]}}' "$1" "$2" "$1"
}
printf '{"startAt":0,"maxResults":2,"total":3,"comments":[%s,%s]}' \
  "$(comment 1 2026-11-27T10:00:00.000+0900)" "$(comment 2 2026-11-27T12:00:00.000+0900)" >"${FIXTURES}/comments0.json"
printf '{"startAt":2,"maxResults":2,"total":3,"comments":[%s]}' \
  "$(comment 3 2026-11-27T20:00:00.000+0900)" >"${FIXTURES}/comments1.json"
printf '%s' '{"issues":[{"key":"PROJ-7","fields":{"summary":"Signup popup","issuetype":{"name":"Story"},"priority":{"name":"High"},"status":{"name":"Open"},"updated":"x"}}]}' >"${FIXTURES}/search.json"

cat >"${FAKE_BIN}/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w | -H | -X | -d | --max-time) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "curl ${url}" >>"$FAKE_LOG"
case "$url" in
  */field) fixture=field.json ;;
  *"/comment?"*"startAt=0"*) fixture=comments0.json ;;
  *"/comment?"*"startAt=2"*) fixture=comments1.json ;;
  *"/issue/PROJ-7?"*) fixture=issue.json ;;
  */search/jql) fixture=search.json ;;
  *)
    printf '%s' '{"errorMessages":["no fixture"]}' >"$out"
    printf 404
    exit 0
    ;;
esac
cat "${FIXTURES}/${fixture}" >"$out"
printf 200
FAKE_CURL
chmod +x "${FAKE_BIN}/gh" "${FAKE_BIN}/curl"

# ---------------------------------------------------------------------------
# Throwaway repository with a GitHub Enterprise remote and a worktree
# ---------------------------------------------------------------------------
git init -q "$REPO"
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$REPO" remote add origin git@ghe.example.com:acme/web.git
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
git -C "$REPO" branch feature/PROJ-1-header-overlap
git -C "$REPO" branch feature/PROJ-12-avatars
git -C "$REPO" worktree add -q "${SANDBOX}/web-PROJ-1" feature/PROJ-1-header-overlap

gh_pr() { (cd "$REPO" && bash "$GH_PR" "$@" 2>&1); }

echo "gh-pr.sh"

out="$(gh_pr repo detect --format json)"
expect_eq "repo detect reads host and repository" "$(jq -r '"\(.host) \(.repo) \(.defaultBranch)"' <<<"$out")" \
  "ghe.example.com ghe.example.com/acme/web develop"

out="$(gh_pr branches --key PROJ-1)"
expect_contains "branches --key matches the branch" "$out" "feature/PROJ-1-header-overlap"
expect_contains "branches --key reports the worktree" "$out" "worktree: ${SANDBOX}/web-PROJ-1"
expect_not_contains "branches --key PROJ-1 does not match PROJ-12" "$out" "PROJ-12"
expect_eq "branches --key=VALUE form" "$(gh_pr branches --key=PROJ-12 --format json | jq -c '.branches')" \
  '["feature/PROJ-12-avatars"]'

expect_eq "pr find --source BRANCH (space form)" \
  "$(gh_pr pr find --source feature/PROJ-1-header-overlap --format json | jq -r '.id')" "42"
expect_eq "pr find --source=BRANCH (equals form)" \
  "$(gh_pr pr find --source=feature/PROJ-1-header-overlap --format=json | jq -r '.id')" "42"
expect_eq "pr find --pr NUMBER" "$(gh_pr pr find --pr 42 --format json | jq -r '.id')" "42"
expect_eq "pr find with no open PR prints null" "$(gh_pr pr find --source feature/none --format json)" "null"

out="$(gh_pr pr feedback --pr 42 --since 2026-09-05T18:30:00+09:00 --format json)"
expect_eq "feedback: +09:00 cutoff, pagination, resolved/self/wrapper filtering, sort order" \
  "$(jq -c '[.feedback[].body]' <<<"$out")" \
  '["after the cutoff","inline open","needs work","second page"]'
expect_eq "feedback excludes the authenticated user" "$(jq -r '.excludedViewer' <<<"$out")" "me"

out="$(gh_pr pr feedback --pr=42 --include-resolved --include-self --format=json)"
expect_contains "feedback --include-resolved keeps resolved threads" "$(jq -c '[.feedback[].body]' <<<"$out")" "inline resolved"
expect_contains "feedback --include-self keeps own comments" "$(jq -c '[.feedback[].body]' <<<"$out")" "my own reply"
expect_not_contains "Bugbot review wrappers are always dropped" "$(jq -c '[.feedback[].body]' <<<"$out")" "BUGBOT"

expect_eq "pr checks: pending exit code 8 still parses" "$(gh_pr pr checks --pr 42 --format json | jq -r '.overall')" "pending"
expect_eq "pr checks: reports the review decision and merge state" \
  "$(gh_pr pr checks --pr 42 --format json | jq -r '"\(.review.decision) \(.review.mergeState)"')" "REVIEW_REQUIRED BLOCKED"
expect_eq "pr checks: failing run" "$(FAKE_CHECKS=fail gh_pr pr checks --pr 42 --format json | jq -r '.overall')" "fail"
expect_eq "pr checks: no checks reported" "$(FAKE_CHECKS=none gh_pr pr checks --pr 42 --format json | jq -r '.overall')" "none"

out="$(gh_pr pr create --title "fix(web): PROJ-1 nav - overlap" --source feature/PROJ-1-header-overlap --dry-run --format json)"
expect_eq "pr create --dry-run reads space-separated values" "$(jq -r '"\(.title)|\(.source)|\(.target)|\(.draft)"' <<<"$out")" \
  "fix(web): PROJ-1 nav - overlap|feature/PROJ-1-header-overlap|develop|true"
out="$(gh_pr pr create --title=t --source=x --target=main --no-draft --dry-run --format=json)"
expect_eq "pr create --dry-run reads equals values and --no-draft" "$(jq -r '"\(.title)|\(.source)|\(.target)|\(.draft)"' <<<"$out")" \
  "t|x|main|false"

out="$(FAKE_FORK=1 gh_pr pr find --source feature/PROJ-1-header-overlap --format json)"
expect_eq "fork: pr find looks in the upstream with an owner:branch head" "$(jq -r '"\(.repoOwner)/\(.repoName) #\(.id)"' <<<"$out")" \
  "upstream-org/web #42"
out="$(FAKE_FORK=1 gh_pr pr create --title t --source feature/PROJ-1-header-overlap --dry-run --format json)"
expect_eq "fork: pr create targets the upstream" "$(jq -r '"\(.repo) \(.source)"' <<<"$out")" \
  "ghe.example.com/upstream-org/web acme:feature/PROJ-1-header-overlap"

out="$(gh_pr pr find --source)"
expect_contains "a value option with nothing after it is an error" "$out" "INVALID_INPUT: --source requires a value"
out="$(gh_pr pr find --source --format json)"
expect_contains "a value option followed by another flag is an error" "$out" "--source requires a value"
out="$(gh_pr pr find --bogus 1)"
expect_contains "an unknown option is an error" "$out" "unknown option '--bogus'"

# .env is parsed, never executed
ENV_SKILL="${SANDBOX}/skill"
mkdir -p "${ENV_SKILL}/scripts"
cp "$GH_PR" "$JIRA_API" "${ENV_SKILL}/scripts/"
cat >"${ENV_SKILL}/.env" <<EOF
JIRA_URL=https://acme.atlassian.net
TEST_CMD=yarn run test
JIRA_LIST_JQL=project = PROJ AND sprint in openSprints() ORDER BY priority DESC
ATLASSIAN_API_TOKEN=tok\$(touch ${SANDBOX}/pwned)\`touch ${SANDBOX}/pwned2\`
MAIN_BRANCH="release/24"
EOF
out="$(cd "$REPO" && bash "${ENV_SKILL}/scripts/gh-pr.sh" repo detect --format json 2>&1)"
expect_eq "unquoted .env values do not break the script" "$(jq -r '.defaultBranch' <<<"$out")" "release/24"
if [[ ! -e "${SANDBOX}/pwned" && ! -e "${SANDBOX}/pwned2" ]]; then
  ok ".env values are never executed"
else
  not_ok ".env values are never executed" "a command substitution in .env ran"
fi
printf 'GH_HOST=github.com\n' >>"${ENV_SKILL}/.env"
out="$(cd "$REPO" && bash "${ENV_SKILL}/scripts/gh-pr.sh" repo detect 2>&1)"
expect_contains "GH_HOST guards against the wrong remote" "$out" "REMOTE_MISMATCH"

echo "jira-api.sh"

JIRA_SKILL="${SANDBOX}/jira"
mkdir -p "${JIRA_SKILL}/scripts"
cp "$JIRA_API" "${JIRA_SKILL}/scripts/"
jira() { bash "${JIRA_SKILL}/scripts/jira-api.sh" "$@" 2>&1; }

out="$(jira get PROJ-7)"
expect_contains "jira: missing .env is CONFIG_MISSING" "$out" "CONFIG_MISSING"

printf 'JIRA_URL=https://acme.atlassian.net\nATLASSIAN_EMAIL=dev@acme.test\nATLASSIAN_API_TOKEN=fake-token\n' >"${JIRA_SKILL}/.env"

out="$(jira get 'https://acme.atlassian.net/browse/proj-7?focusedCommentId=1' --format json)"
expect_eq "jira get accepts a /browse/ URL" "$(jq -r '.key' <<<"$out")" "PROJ-7"
expect_eq "jira get reads prose custom fields, not Rank" "$(jq -c '[.customFields[].name]' <<<"$out")" '["Acceptance Criteria"]'
expect_eq "jira get renders ADF and keeps images" "$(jq -r '.description' <<<"$out")" $'Show a popup\n[image: shot.png]'
expect_eq "jira get reads links and attachments" "$(jq -c '[.linkedIssues, [.attachments[].id]]' <<<"$out")" '[["PROJ-6"],["9"]]'

out="$(jira comments PROJ-7 --since 2026-11-27T11:30:00+09:00 --format json)"
expect_eq "jira comments: all pages, instant cutoff" "$(jq -c '[.comments[].body]' <<<"$out")" '["c2","c3"]'

expect_contains "jira comment --dry-run posts nothing" "$(jira comment PROJ-7 --text 'Fixed: x' --dry-run)" "[dry-run] Would comment on PROJ-7"
if grep -q '/comment"$\|/comment$' "$FAKE_LOG"; then
  not_ok "jira comment --dry-run made no POST" "a comment request was sent"
else
  ok "jira comment --dry-run made no POST"
fi
expect_contains "jira list" "$(jira list)" "PROJ-7  [Story]  High  Open"
expect_contains "jira rejects a non-key" "$(jira get not-a-key)" "INVALID_INPUT"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
