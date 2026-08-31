#!/usr/bin/env bash
# GitHub / GitHub Enterprise pull request helper for the jira-fix skill.
# Credentials come from the `gh` credential store — no GitHub token is ever
# read from or written to .env.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${SKILL_DIR}/.env"

# .env is optional here — only GIT_REMOTE, GH_HOST and MAIN_BRANCH are consulted.
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

FORMAT="text"
TITLE=""
SOURCE=""
TARGET=""
BODY=""
BODY_FILE=""
PR_REF=""
SINCE=""
PR_NUMBER=""
RESOLVED_PR=""

HOST=""
OWNER=""
NAME=""
REPO_REF=""
REMOTE_NAME=""
REMOTE_SAFE=""
DEFAULT_BRANCH=""
TMP_BODY=""

cleanup() {
  [[ -n "$TMP_BODY" ]] && rm -f "$TMP_BODY"
  return 0
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
gh-pr.sh — GitHub / GitHub Enterprise pull request helper (draft-first, idempotent)

USAGE
  gh-pr.sh repo detect [--format text|json]
  gh-pr.sh pr find     [--source BRANCH | --pr NUMBER|URL] [--format text|json]
  gh-pr.sh pr create   --title TITLE --source BRANCH [--target BASE]
                       [--body TEXT | --body-file PATH | --body-file -]
                       [--format text|json]
  gh-pr.sh pr feedback [--source BRANCH | --pr NUMBER|URL] [--since ISO8601]
                       [--format text|json]

OPTIONS
  --source BRANCH      Branch to look up; defaults to the current branch
  --pr NUMBER|URL      Target a pull request directly. A full URL also selects the
                       host and repository, so it works outside the checkout.
  --since ISO8601      Only return feedback created after this timestamp
  --format text|json   Output format (default: text)
  -h, --help           Show this help

BEHAVIOUR
  Host, owner and repository are detected from the git remote (GIT_REMOTE, default "origin"),
  or from the URL passed to --pr.
  Target branch resolution order: --target > MAIN_BRANCH in .env > <remote>/HEAD > develop.
  "pr create" is idempotent: if an open pull request already exists for the same source
  branch it is returned instead of opening a second one. New pull requests are drafts.
  "pr feedback" returns review verdicts, conversation comments and inline code comments.

AUTHENTICATION
  gh auth login --hostname HOST --git-protocol ssh --web

EXAMPLES
  gh-pr.sh repo detect --format json
  gh-pr.sh pr find --source feature/PROJ-123-header-overlap
  gh-pr.sh pr create --title "fix(web): PROJ-123 nav - fix header overlap" \
                     --source feature/PROJ-123-header-overlap --body-file - <<<"Fixes PROJ-123"
  gh-pr.sh pr feedback                                    # current branch
  gh-pr.sh pr feedback --pr https://HOST/org/repo/pull/42
  gh-pr.sh pr feedback --since "$(git log -1 --format=%cI)" --format json
EOF
}

die() {
  local code="$1"
  shift
  printf 'ERROR: %s: %s\n' "$code" "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 \
    || die MISSING_DEPENDENCY "'$1' is required but was not found in PATH."
}

# Trim a captured error stream so tokens or long API payloads never reach stdout.
brief() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-200; }

parse_remote_url() {
  local url="$1" hostpart path scheme rest

  case "$url" in
    ssh://* | http://* | https://*)
      scheme="${url%%://*}"
      rest="${url#*://}"
      hostpart="${rest%%/*}"
      path="${rest#*/}"
      hostpart="${hostpart##*@}"
      hostpart="${hostpart%%:*}"
      REMOTE_SAFE="${scheme}://${hostpart}/${path}"
      ;;
    *:*)
      hostpart="${url%%:*}"
      hostpart="${hostpart##*@}"
      path="${url#*:}"
      REMOTE_SAFE="$url"
      ;;
    *)
      die UNSUPPORTED_REMOTE "cannot parse the git remote URL."
      ;;
  esac

  path="${path#/}"
  path="${path%/}"
  path="${path%.git}"

  local slashes="${path//[^\/]/}"
  [[ ${#slashes} -eq 1 ]] \
    || die UNSUPPORTED_REMOTE "the git remote must point at OWNER/REPO (parsed '${path}')."

  HOST="$(printf '%s' "$hostpart" | tr '[:upper:]' '[:lower:]')"
  OWNER="${path%%/*}"
  NAME="${path##*/}"
  REMOTE_SAFE="${REMOTE_SAFE%.git}"

  [[ -n "$HOST" && -n "$OWNER" && -n "$NAME" ]] \
    || die UNSUPPORTED_REMOTE "could not extract host, owner and repository from the remote."

  if [[ "$HOST" == "bitbucket.org" ]]; then
    die UNSUPPORTED_REMOTE "this skill targets GitHub and GitHub Enterprise; Bitbucket is no longer supported."
  fi
}

# Accepts a pull request URL and sets host/owner/repo/number from it, so a pasted
# link works even when the current directory is a different repository.
parse_pr_url() {
  [[ "$1" =~ ^https?://([^/]+)/([^/]+)/([^/]+)/pull/([0-9]+) ]] || return 1
  HOST="${BASH_REMATCH[1]}"
  OWNER="${BASH_REMATCH[2]}"
  NAME="${BASH_REMATCH[3]}"
  PR_NUMBER="${BASH_REMATCH[4]}"
  REPO_REF="${HOST}/${OWNER}/${NAME}"
  return 0
}

current_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || true
}

resolve_default_branch() {
  if [[ -n "${MAIN_BRANCH:-}" ]]; then
    printf '%s' "$MAIN_BRANCH"
    return
  fi
  local head
  head="$(git symbolic-ref "refs/remotes/${REMOTE_NAME}/HEAD" 2>/dev/null || true)"
  if [[ -n "$head" ]]; then
    printf '%s' "${head##*/}"
    return
  fi
  printf 'develop'
}

detect_repo() {
  require_cmd git
  require_cmd jq

  REMOTE_NAME="${GIT_REMOTE:-origin}"

  local url
  url="$(git remote get-url --push "$REMOTE_NAME" 2>/dev/null || true)"
  [[ -n "$url" ]] || url="$(git remote get-url "$REMOTE_NAME" 2>/dev/null || true)"
  [[ -n "$url" ]] \
    || die UNSUPPORTED_REMOTE "no git remote named '${REMOTE_NAME}' in $(pwd)."

  parse_remote_url "$url"

  if [[ -n "${GH_HOST:-}" && "${GH_HOST}" != "${HOST}" ]]; then
    die REMOTE_MISMATCH "GH_HOST is '${GH_HOST}' but the git remote points at '${HOST}'."
  fi

  DEFAULT_BRANCH="$(resolve_default_branch)"
  REPO_REF="${HOST}/${OWNER}/${NAME}"
}

ensure_auth() {
  require_cmd gh
  gh auth status --hostname "$HOST" >/dev/null 2>&1 \
    || die AUTH_REQUIRED "not logged in to ${HOST}. Run: gh auth login --hostname ${HOST} --git-protocol ssh --web"
}

# Prints one normalized PR object, or nothing when no open PR exists.
find_pr_json() {
  local branch="$1" out
  if ! out="$(gh pr list --repo "$REPO_REF" --head "$branch" --state open --limit 1 \
    --json number,url,title,headRefName,baseRefName,isDraft 2>&1)"; then
    die API_ERROR "gh pr list failed for ${REPO_REF}: $(brief "$out")"
  fi

  printf '%s' "$out" | jq -c --arg host "$HOST" '
    if length == 0 then empty
    else .[0] | {
      provider: "github",
      host: $host,
      id: .number,
      url: .url,
      title: .title,
      sourceBranch: .headRefName,
      targetBranch: .baseRefName,
      draft: .isDraft
    } end'
}

view_pr_json() {
  local number="$1" out
  if ! out="$(gh pr view "$number" --repo "$REPO_REF" \
    --json number,url,title,headRefName,baseRefName,isDraft 2>&1)"; then
    die API_ERROR "gh pr view failed for ${REPO_REF}#${number}: $(brief "$out")"
  fi

  printf '%s' "$out" | jq -c --arg host "$HOST" '{
    provider: "github",
    host: $host,
    id: .number,
    url: .url,
    title: .title,
    sourceBranch: .headRefName,
    targetBranch: .baseRefName,
    draft: .isDraft
  }'
}

emit_pr() {
  local pr="$1"
  if [[ "$FORMAT" == "json" ]]; then
    printf '%s\n' "$pr"
    return
  fi
  printf '%s' "$pr" | jq -r '
    "--- Pull Request ---",
    "ID:     \(.id)",
    "Title:  \(.title)",
    "URL:    \(.url)",
    "Source: \(.sourceBranch)",
    "Target: \(.targetBranch)",
    "Draft:  \(.draft)",
    "---"'
}

cmd_repo_detect() {
  detect_repo

  local payload
  payload="$(jq -n \
    --arg host "$HOST" --arg owner "$OWNER" --arg name "$NAME" \
    --arg remoteName "$REMOTE_NAME" --arg remoteUrl "$REMOTE_SAFE" \
    --arg defaultBranch "$DEFAULT_BRANCH" --arg repo "$REPO_REF" \
    '{provider:"github", host:$host, owner:$owner, name:$name, repo:$repo,
      remoteName:$remoteName, remoteUrl:$remoteUrl, defaultBranch:$defaultBranch}')"

  if [[ "$FORMAT" == "json" ]]; then
    printf '%s\n' "$payload"
    return
  fi
  printf '%s' "$payload" | jq -r '
    "Provider:      \(.provider)",
    "Host:          \(.host)",
    "Repository:    \(.owner)/\(.name)",
    "Remote:        \(.remoteName) → \(.remoteUrl)",
    "DefaultBranch: \(.defaultBranch)"'
}

# Resolves the target pull request from --pr, --source, or the current branch, and
# leaves the result in RESOLVED_PR. Must not run in a subshell: it also sets the
# host/owner/repo globals that the feedback API calls depend on.
resolve_pr() {
  if [[ -n "$PR_REF" ]]; then
    if parse_pr_url "$PR_REF"; then
      require_cmd jq
    elif [[ "$PR_REF" =~ ^[0-9]+$ ]]; then
      detect_repo
      PR_NUMBER="$PR_REF"
    else
      die INVALID_INPUT "--pr must be a pull request number or a .../pull/N URL (got '${PR_REF}')."
    fi
    ensure_auth
    RESOLVED_PR="$(view_pr_json "$PR_NUMBER")"
    return
  fi

  detect_repo
  ensure_auth
  local branch="${SOURCE:-$(current_branch)}"
  [[ -n "$branch" && "$branch" != "HEAD" ]] \
    || die INVALID_INPUT "cannot determine a branch. Pass --source BRANCH or --pr NUMBER|URL."
  RESOLVED_PR="$(find_pr_json "$branch")"
}

cmd_pr_find() {
  resolve_pr
  local pr="$RESOLVED_PR"
  if [[ -z "$pr" ]]; then
    if [[ "$FORMAT" == "json" ]]; then
      printf 'null\n'
    else
      printf 'No open pull request for %s.\n' "${SOURCE:-the current branch}"
    fi
    return
  fi
  emit_pr "$pr"
}

cmd_pr_create() {
  detect_repo
  ensure_auth
  [[ -n "$TITLE" ]] || die INVALID_INPUT "--title TITLE is required."
  [[ -n "$SOURCE" ]] || die INVALID_INPUT "--source BRANCH is required."

  local target="${TARGET:-$DEFAULT_BRANCH}"

  if ! git ls-remote --exit-code --heads "$REMOTE_NAME" "$SOURCE" >/dev/null 2>&1; then
    die BRANCH_NOT_PUSHED "branch '${SOURCE}' does not exist on ${REMOTE_NAME}. Push it first: git push -u ${REMOTE_NAME} ${SOURCE}"
  fi

  local existing
  existing="$(find_pr_json "$SOURCE")"
  if [[ -n "$existing" ]]; then
    printf 'NOTE: an open pull request already exists for %s; returning it.\n' "$SOURCE" >&2
    emit_pr "$existing"
    return
  fi

  TMP_BODY="$(mktemp)"
  if [[ "$BODY_FILE" == "-" ]]; then
    cat >"$TMP_BODY"
  elif [[ -n "$BODY_FILE" ]]; then
    [[ -f "$BODY_FILE" ]] || die INVALID_INPUT "body file '${BODY_FILE}' does not exist."
    cat "$BODY_FILE" >"$TMP_BODY"
  else
    printf '%s' "$BODY" >"$TMP_BODY"
  fi

  local out
  if ! out="$(gh pr create --repo "$REPO_REF" --head "$SOURCE" --base "$target" \
    --draft --title "$TITLE" --body-file "$TMP_BODY" 2>&1)"; then
    die API_ERROR "gh pr create failed for ${REPO_REF}: $(brief "$out")"
  fi

  local number
  number="$(printf '%s\n' "$out" | grep -Eo '/pull/[0-9]+' | tail -n 1)"
  number="${number##*/}"
  [[ -n "$number" ]] || die API_ERROR "gh pr create returned no pull request URL."

  local created
  created="$(view_pr_json "$number")"
  emit_pr "$created"
}

cmd_pr_feedback() {
  resolve_pr
  local pr="$RESOLVED_PR"
  [[ -n "$pr" ]] \
    || die PR_NOT_FOUND "no open pull request for ${SOURCE:-the current branch}."

  local number
  number="$(printf '%s' "$pr" | jq -r '.id')"

  local view inline
  if ! view="$(gh pr view "$number" --repo "$REPO_REF" --json comments,reviews 2>&1)" \
    || ! printf '%s' "$view" | jq -e 'type == "object"' >/dev/null 2>&1; then
    die API_ERROR "gh pr view failed for ${REPO_REF}#${number}: $(brief "$view")"
  fi

  # Inline code comments are not exposed by `gh pr view`; they need the REST API.
  # A failure here must be loud — silently returning fewer items would look like
  # the reviewer said nothing.
  if ! inline="$(gh api --hostname "$HOST" \
    "repos/${OWNER}/${NAME}/pulls/${number}/comments?per_page=100" 2>&1)" \
    || ! printf '%s' "$inline" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf 'WARNING: could not read inline review comments (%s). Showing review verdicts and conversation comments only.\n' \
      "$(brief "$inline")" >&2
    inline='[]'
  fi

  local payload
  payload="$(jq -n \
    --argjson pr "$pr" \
    --argjson view "$view" \
    --argjson inline "$inline" \
    --arg since "$SINCE" \
    '{
      pullRequest: $pr,
      feedback: (
        (($view.comments // []) | map({
          kind: "comment",
          author: (.author.login // "unknown"),
          body: (.body // ""),
          url: (.url // ""),
          createdAt: (.createdAt // ""),
          state: "",
          path: ""
        }))
        + (($view.reviews // []) | map(select((.body // "") != "" or (.state // "") != "COMMENTED")) | map({
          kind: "review",
          author: (.author.login // "unknown"),
          body: (.body // ""),
          url: (.url // ""),
          createdAt: (.submittedAt // ""),
          state: (.state // ""),
          path: ""
        }))
        + (($inline // []) | map({
          kind: "review_comment",
          author: (.user.login // "unknown"),
          body: (.body // ""),
          url: (.html_url // ""),
          createdAt: (.created_at // ""),
          state: "",
          path: ((.path // "") + (if .line then ":\(.line)" else "" end))
        }))
      )
      | map(select($since == "" or .createdAt > $since))
      | sort_by(.createdAt)
    }')"

  if [[ "$FORMAT" == "json" ]]; then
    printf '%s\n' "$payload"
    return
  fi

  printf '%s' "$payload" | jq -r '
    "PR #\(.pullRequest.id)  \(.pullRequest.url)",
    "Feedback items: \(.feedback | length)",
    "---",
    (.feedback[] |
      "[\(.kind)\(if .state != "" then " \(.state)" else "" end)\(if .path != "" then " \(.path)" else "" end)] \(.author)  \(.createdAt)",
      (.body | split("\n")[] | "  " + .),
      "")'
}

[[ $# -gt 0 ]] || {
  usage
  exit 1
}

case "${1:-}" in
  -h | --help | help)
    usage
    exit 0
    ;;
esac

GROUP="$1"
shift
ACTION="${1:-}"
[[ -n "$ACTION" && "$ACTION" != -* ]] && shift || ACTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)
      FORMAT="${2:?--format needs text or json}"
      shift 2
      ;;
    --title)
      TITLE="${2:?--title needs a value}"
      shift 2
      ;;
    --source)
      SOURCE="${2:?--source needs a branch name}"
      shift 2
      ;;
    --target)
      TARGET="${2:?--target needs a branch name}"
      shift 2
      ;;
    --body)
      BODY="${2:?--body needs a value}"
      shift 2
      ;;
    --body-file)
      BODY_FILE="${2:?--body-file needs a path or -}"
      shift 2
      ;;
    --pr)
      PR_REF="${2:?--pr needs a pull request number or URL}"
      shift 2
      ;;
    --since)
      SINCE="${2:?--since needs an ISO8601 timestamp}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die INVALID_INPUT "unknown option '$1'. Run 'gh-pr.sh --help' for usage."
      ;;
  esac
done

[[ "$FORMAT" == "text" || "$FORMAT" == "json" ]] \
  || die INVALID_INPUT "--format must be 'text' or 'json' (got '${FORMAT}')."

case "${GROUP}:${ACTION}" in
  repo:detect) cmd_repo_detect ;;
  pr:find) cmd_pr_find ;;
  pr:create) cmd_pr_create ;;
  pr:feedback) cmd_pr_feedback ;;
  *)
    printf 'ERROR: INVALID_INPUT: unknown command "%s %s".\n\n' "$GROUP" "$ACTION" >&2
    usage >&2
    exit 1
    ;;
esac
