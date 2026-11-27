#!/usr/bin/env bash
# GitHub / GitHub Enterprise pull request helper for the jira-fix skill.
# Credentials come from the `gh` credential store — no GitHub token is ever
# read from or written to .env.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${SKILL_DIR}/.env"

# Parse KEY=VALUE lines without `source`, so unquoted spaces, parentheses in JQL,
# or `$` characters in tokens never execute as shell syntax.
load_env_file() {
  local file="$1" line key val
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[2]}"
      val="${BASH_REMATCH[3]}"
      # Trim leading/trailing whitespace only around unquoted values
      if [[ "$val" =~ ^\"(.*)\"[[:space:]]*$ ]]; then
        val="${BASH_REMATCH[1]}"
      elif [[ "$val" =~ ^\'(.*)\'[[:space:]]*$ ]]; then
        val="${BASH_REMATCH[1]}"
      else
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
      fi
      # Environment variables set by the caller win over .env
      if [[ -z "${!key+x}" ]]; then
        printf -v "$key" '%s' "$val"
      fi
    fi
  done <"$file"
}

load_env_file "$ENV_FILE"

FORMAT="text"
TITLE=""
SOURCE=""
TARGET=""
BODY=""
BODY_FILE=""
PR_REF=""
SINCE=""
ISSUE_KEY=""
DRAFT="true"
DRY_RUN="false"
INCLUDE_RESOLVED="false"
INCLUDE_SELF="false"
PR_NUMBER=""
RESOLVED_PR=""

HOST=""
OWNER=""
NAME=""
REPO_REF=""
PR_OWNER=""
PR_NAME=""
PR_REPO_REF=""
REMOTE_NAME=""
REMOTE_SAFE=""
DEFAULT_BRANCH=""
TMP_BODY=""

cleanup() {
  [[ -n "$TMP_BODY" && -f "$TMP_BODY" ]] && rm -f "$TMP_BODY"
  return 0
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
gh-pr.sh — GitHub / GitHub Enterprise pull request & branch helper (draft-first, idempotent)

USAGE
  gh-pr.sh repo detect             [--format text|json]
  gh-pr.sh branches --key KEY      [--format text|json]
  gh-pr.sh pr find                 [--source BRANCH | --pr NUMBER|URL] [--format text|json]
  gh-pr.sh pr create --title TITLE --source BRANCH [--target BASE]
                                   [--body TEXT | --body-file PATH|-]
                                   [--no-draft] [--dry-run] [--format text|json]
  gh-pr.sh pr feedback             [--source BRANCH | --pr NUMBER|URL] [--since ISO8601]
                                   [--include-resolved] [--include-self] [--format text|json]
  gh-pr.sh pr checks               [--source BRANCH | --pr NUMBER|URL] [--format text|json]

OPTIONS
  --key KEY            Ticket key (or URL) for token-boundary branch & worktree lookup
  --source BRANCH      Branch to look up; defaults to the current branch
  --pr NUMBER|URL      Target a pull request directly. A full URL also selects the
                       host and repository, so it works outside the checkout.
  --since ISO8601      Only return feedback created after this instant (timezone-safe)
  --include-resolved   Include resolved inline review threads (dropped by default)
  --include-self       Include your own comments (dropped by default)
  --no-draft           Open a ready-for-review pull request instead of a draft
  --dry-run            Validate and print what pr create would do without opening a PR
  --format text|json   Output format (default: text)
  -h, --help           Show this help

BEHAVIOUR
  Host, owner and repository are detected from the git remote (GIT_REMOTE, default "origin"),
  or from the URL passed to --pr. Fork repositories automatically target upstream.
  Target branch resolution order: --target > MAIN_BRANCH in .env > <remote>/HEAD > develop.
  "pr create" is idempotent: if an open pull request already exists for the same source
  branch it is returned instead of opening a second one. New pull requests default to draft.
  "pr feedback" paginates all comments/reviews/threads, compares --since as UTC instants,
  and filters out resolved threads, stale bot wrappers, and your own replies by default.

EXAMPLES
  gh-pr.sh repo detect --format json
  gh-pr.sh branches --key PROJ-123
  gh-pr.sh pr find --source feature/PROJ-123-header-overlap
  gh-pr.sh pr create --title "fix(client): PROJ-123 nav - fix header overlap" \
                     --source feature/PROJ-123-header-overlap --body-file - <<<"Fixes PROJ-123"
  gh-pr.sh pr feedback --since "$(git log -1 --format=%cI)"
  gh-pr.sh pr checks --pr 42
EOF
}

die() {
  local code="$1"
  shift
  if [[ "$FORMAT" == "json" ]] && command -v jq >/dev/null 2>&1; then
    jq -cn --arg code "$code" --arg message "$*" '{error:{code:$code,message:$message}}' >&2
  else
    printf 'ERROR: %s: %s\n' "$code" "$*" >&2
  fi
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 \
    || die MISSING_DEPENDENCY "'$1' is required but was not found in PATH."
}

brief() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-200; }

normalize_ticket_key() {
  local raw="$1"
  if [[ "$raw" =~ /browse/([A-Za-z][A-Za-z0-9_]*-[0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$raw"
  fi
}

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

parse_pr_url() {
  [[ "$1" =~ ^https?://([^/]+)/([^/]+)/([^/]+)/pull/([0-9]+) ]] || return 1
  HOST="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
  OWNER="${BASH_REMATCH[2]}"
  NAME="${BASH_REMATCH[3]}"
  PR_OWNER="$OWNER"
  PR_NAME="$NAME"
  PR_NUMBER="${BASH_REMATCH[4]}"
  REPO_REF="${HOST}/${OWNER}/${NAME}"
  PR_REPO_REF="$REPO_REF"
  if [[ -n "${GH_HOST:-}" && "$(printf '%s' "$GH_HOST" | tr '[:upper:]' '[:lower:]')" != "$HOST" ]]; then
    die REMOTE_MISMATCH "GH_HOST is '${GH_HOST}' but the PR URL points at '${HOST}'."
  fi
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

  if [[ -n "${GH_HOST:-}" && "$(printf '%s' "$GH_HOST" | tr '[:upper:]' '[:lower:]')" != "$HOST" ]]; then
    die REMOTE_MISMATCH "GH_HOST is '${GH_HOST}' but the git remote points at '${HOST}'."
  fi

  DEFAULT_BRANCH="$(resolve_default_branch)"
  REPO_REF="${HOST}/${OWNER}/${NAME}"
  PR_OWNER="$OWNER"
  PR_NAME="$NAME"
  PR_REPO_REF="$REPO_REF"
}

ensure_auth() {
  require_cmd gh
  gh auth status --hostname "$HOST" >/dev/null 2>&1 \
    || die AUTH_REQUIRED "not logged in to ${HOST}. Run: gh auth login --hostname ${HOST} --git-protocol ssh --web"
}

# Sets PR_OWNER, PR_NAME, PR_REPO_REF to upstream when the current repo is a fork.
resolve_fork_target() {
  local meta is_fork up_owner up_name
  meta="$(gh repo view "$REPO_REF" --json isFork,parent 2>/dev/null || true)"
  if [[ -n "$meta" ]] && printf '%s' "$meta" | jq -e '.isFork == true and .parent != null' >/dev/null 2>&1; then
    up_owner="$(printf '%s' "$meta" | jq -r '.parent.owner.login // .parent.owner // empty')"
    up_name="$(printf '%s' "$meta" | jq -r '.parent.name // empty')"
    if [[ -n "$up_owner" && -n "$up_name" ]]; then
      PR_OWNER="$up_owner"
      PR_NAME="$up_name"
      PR_REPO_REF="${HOST}/${up_owner}/${up_name}"
      return 0
    fi
  fi
  return 1
}

find_pr_in_repo_json() {
  local repo_ref="$1" head_ref="$2" r_owner="$3" r_name="$4" out
  if ! out="$(gh pr list --repo "$repo_ref" --head "$head_ref" --state open --limit 1 \
    --json number,url,title,headRefName,baseRefName,isDraft,state 2>&1)"; then
    die API_ERROR "gh pr list failed for ${repo_ref}: $(brief "$out")"
  fi

  printf '%s' "$out" | jq -c --arg host "$HOST" --arg ro "$r_owner" --arg rn "$r_name" '
    if length == 0 then empty
    else .[0] | {
      provider: "github",
      host: $host,
      repoOwner: $ro,
      repoName: $rn,
      id: .number,
      url: .url,
      title: .title,
      sourceBranch: .headRefName,
      targetBranch: .baseRefName,
      draft: .isDraft,
      state: ((.state // "OPEN") | ascii_upcase)
    } end'
}

find_pr_json() {
  local branch="$1" found=""
  if resolve_fork_target; then
    local head_ref="$branch"
    [[ "$head_ref" == *:* ]] || head_ref="${OWNER}:${branch}"
    found="$(find_pr_in_repo_json "$PR_REPO_REF" "$head_ref" "$PR_OWNER" "$PR_NAME")"
    if [[ -n "$found" ]]; then
      printf '%s' "$found"
      return
    fi
    PR_OWNER="$OWNER"
    PR_NAME="$NAME"
    PR_REPO_REF="$REPO_REF"
  fi
  find_pr_in_repo_json "$REPO_REF" "$branch" "$OWNER" "$NAME"
}

view_pr_json() {
  local number="$1" target_ref="${2:-$PR_REPO_REF}" r_owner="${3:-$PR_OWNER}" r_name="${4:-$PR_NAME}" out
  if ! out="$(gh pr view "$number" --repo "$target_ref" \
    --json number,url,title,headRefName,baseRefName,isDraft,state 2>&1)"; then
    die API_ERROR "gh pr view failed for ${target_ref}#${number}: $(brief "$out")"
  fi

  printf '%s' "$out" | jq -c --arg host "$HOST" --arg ro "$r_owner" --arg rn "$r_name" '{
    provider: "github",
    host: $host,
    repoOwner: $ro,
    repoName: $rn,
    id: .number,
    url: .url,
    title: .title,
    sourceBranch: .headRefName,
    targetBranch: .baseRefName,
    draft: .isDraft,
    state: ((.state // "OPEN") | ascii_upcase)
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
    "State:  \(.state // "OPEN")",
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

cmd_branches() {
  require_cmd git
  require_cmd jq
  [[ -n "$ISSUE_KEY" ]] || die INVALID_INPUT "--key TICKET-KEY is required. Usage: gh-pr.sh branches --key PROJ-123"

  local clean_key all_branches worktree_raw cur payload
  clean_key="$(normalize_ticket_key "$ISSUE_KEY")"
  cur="$(current_branch)"
  all_branches="$(git branch -a --format='%(refname:short)' 2>/dev/null || true)"
  worktree_raw="$(git worktree list --porcelain 2>/dev/null || true)"

  payload="$(jq -Rn \
    --arg key "$clean_key" \
    --arg cur "$cur" \
    --arg branches_raw "$all_branches" \
    --arg wt_raw "$worktree_raw" '
    ($key | gsub("(?<c>[.*+?^${}()|\\[\\]\\\\])"; "\\\(.c)")) as $esc
    | ("(^|[^A-Za-z0-9])" + $esc + "([^A-Za-z0-9]|$)") as $pat
    | ($branches_raw | split("\n") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0 and test($pat; "i")))) as $branches
    | (
        $wt_raw | split("\n\n") | map(select(length > 0)) | map(
          split("\n") | reduce .[] as $line ({path:null, head:null, branch:null};
            if ($line | startswith("worktree ")) then .path = ($line | sub("^worktree ";""))
            elif ($line | startswith("HEAD ")) then .head = ($line | sub("^HEAD ";""))
            elif ($line | startswith("branch ")) then .branch = ($line | sub("^branch refs/heads/";"") | sub("^branch ";""))
            else . end
          )
        )
        | map(select((.branch != null and (.branch | test($pat; "i"))) or (.path != null and (.path | test($pat; "i")))))
      ) as $worktrees
    | { key: $key, current: (if $cur == "" or $cur == "HEAD" then null else $cur end), branches: $branches, worktrees: $worktrees }
  ')"

  if [[ "$FORMAT" == "json" ]]; then
    printf '%s\n' "$payload"
    return
  fi

  printf '%s' "$payload" | jq -r '
    if ((.branches | length) == 0 and (.worktrees | length) == 0) then
      "No branch or worktree mentions \(.key)."
    else
      (.branches[]),
      (.worktrees[] | "worktree: \(.path)\(if .branch then " [\(.branch)]" else "" end)")
    end'
}

resolve_pr() {
  if [[ -n "$PR_REF" ]]; then
    if parse_pr_url "$PR_REF"; then
      require_cmd jq
      ensure_auth
      RESOLVED_PR="$(view_pr_json "$PR_NUMBER" "$PR_REPO_REF" "$PR_OWNER" "$PR_NAME")"
      return
    elif [[ "$PR_REF" =~ ^[0-9]+$ ]]; then
      detect_repo
      ensure_auth
      PR_NUMBER="$PR_REF"
      if resolve_fork_target && gh pr view "$PR_NUMBER" --repo "$PR_REPO_REF" --json number >/dev/null 2>&1; then
        RESOLVED_PR="$(view_pr_json "$PR_NUMBER" "$PR_REPO_REF" "$PR_OWNER" "$PR_NAME")"
      else
        PR_OWNER="$OWNER"
        PR_NAME="$NAME"
        PR_REPO_REF="$REPO_REF"
        RESOLVED_PR="$(view_pr_json "$PR_NUMBER" "$REPO_REF" "$OWNER" "$NAME")"
      fi
      return
    else
      die INVALID_INPUT "--pr must be a pull request number or a .../pull/N URL (got '${PR_REF}')."
    fi
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
  local head_arg="$SOURCE"
  if resolve_fork_target; then
    [[ "$head_arg" == *:* ]] || head_arg="${OWNER}:${SOURCE}"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    local dry_payload
    dry_payload="$(jq -n --arg title "$TITLE" --arg source "$head_arg" --arg target "$target" --arg repo "$PR_REPO_REF" --argjson draft "$DRAFT" \
      '{dryRun:true, repo:$repo, title:$title, source:$source, target:$target, draft:$draft}')"
    if [[ "$FORMAT" == "json" ]]; then
      printf '%s\n' "$dry_payload"
    else
      printf '[dry-run] Would create PR in %s: "%s" (%s -> %s, draft=%s)\n' "$PR_REPO_REF" "$TITLE" "$head_arg" "$target" "$DRAFT"
    fi
    return
  fi

  if ! git ls-remote --exit-code --heads "$REMOTE_NAME" "$SOURCE" >/dev/null 2>&1; then
    die BRANCH_NOT_PUSHED "branch '${SOURCE}' does not exist on ${REMOTE_NAME}. Push it first: git push -u ${REMOTE_NAME} ${SOURCE}"
  fi

  local existing
  existing="$(find_pr_in_repo_json "$PR_REPO_REF" "$head_arg" "$PR_OWNER" "$PR_NAME")"
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

  local create_args=(pr create --repo "$PR_REPO_REF" --head "$head_arg" --base "$target" --title "$TITLE" --body-file "$TMP_BODY")
  [[ "$DRAFT" == "true" ]] && create_args+=(--draft)

  local out
  if ! out="$(gh "${create_args[@]}" 2>&1)"; then
    die API_ERROR "gh pr create failed for ${PR_REPO_REF}: $(brief "$out")"
  fi

  local number
  number="$(printf '%s\n' "$out" | grep -Eo '/pull/[0-9]+' | tail -n 1)"
  number="${number##*/}"
  [[ -n "$number" ]] || die API_ERROR "gh pr create returned no pull request URL."

  local created
  created="$(view_pr_json "$number" "$PR_REPO_REF" "$PR_OWNER" "$PR_NAME")"
  emit_pr "$created"
}

JQ_TIME_HELPERS='
def to_epoch_ms:
  if type != "string" or length == 0 then null
  else
    (try capture("^(?<y>[0-9]{4})-(?<m>[0-9]{2})-(?<d>[0-9]{2})(?:[T ](?<H>[0-9]{2}):(?<M>[0-9]{2})(?::(?<S>[0-9]{2}))?(?:\\.(?<ms>[0-9]{1,9}))?(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})?)?$") catch null) as $p
    | if $p == null then null
      else
        ([$p.y,$p.m,$p.d,($p.H // "0"),($p.M // "0"),($p.S // "0")] | map(tonumber)) as $t
        | ([$t[0], $t[1]-1, $t[2], $t[3], $t[4], $t[5], 0, 0] | mktime) as $utc
        | ((($p.ms // "") + "000")[0:3] | tonumber) as $milli
        | (if ($p.tz == null or $p.tz == "" or $p.tz == "Z" or $p.tz == "z") then 0
           else
             (($p.tz | sub(":";"")) as $z
              | (if ($z[0:1] == "-") then -1 else 1 end)
                * (((($z[1:3] | tonumber) * 60) + ($z[3:5] | tonumber)) * 60))
           end) as $off
        | (($utc - $off) * 1000 + $milli)
      end
  end;
def is_after($cutoff):
  ($cutoff | to_epoch_ms) as $c
  | if $c == null then true
    else
      to_epoch_ms as $v
      | if $v == null then true else ($v > $c) end
    end;
def norm_login: sub("\\[bot\\]$"; "") | ascii_downcase;
'

cmd_pr_feedback() {
  resolve_pr
  local pr="$RESOLVED_PR"
  [[ -n "$pr" ]] \
    || die PR_NOT_FOUND "no open pull request for ${SOURCE:-the current branch}."

  local number r_owner r_name
  number="$(printf '%s' "$pr" | jq -r '.id')"
  r_owner="$(printf '%s' "$pr" | jq -r '.repoOwner // empty')"
  r_name="$(printf '%s' "$pr" | jq -r '.repoName // empty')"
  [[ -n "$r_owner" ]] || r_owner="$OWNER"
  [[ -n "$r_name" ]] || r_name="$NAME"

  local viewer=""
  if [[ "$INCLUDE_SELF" != "true" ]]; then
    viewer="$(gh api --hostname "$HOST" user --jq '.login // empty' 2>/dev/null || true)"
  fi

  local conv_raw reviews_raw
  if ! conv_raw="$(gh api --hostname "$HOST" --paginate "repos/${r_owner}/${r_name}/issues/${number}/comments?per_page=100" 2>&1 | jq -s 'add // []' 2>/dev/null)"; then
    die API_ERROR "failed to read conversation comments for ${r_owner}/${r_name}#${number}"
  fi
  if ! reviews_raw="$(gh api --hostname "$HOST" --paginate "repos/${r_owner}/${r_name}/pulls/${number}/reviews?per_page=100" 2>&1 | jq -s 'add // []' 2>/dev/null)"; then
    die API_ERROR "failed to read reviews for ${r_owner}/${r_name}#${number}"
  fi

  # Prefer GraphQL reviewThreads so resolved threads are filtered accurately.
  local gql_query inline_items="[]" cursor="" has_next="true" gql_ok="true"
  gql_query='query($owner:String!,$name:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$cursor){pageInfo{hasNextPage endCursor} nodes{isResolved isOutdated path line comments(first:100){nodes{author{login} body url createdAt}}}}}}}'

  while [[ "$has_next" == "true" ]]; do
    local gql_args=(api graphql --hostname "$HOST" -f "query=${gql_query}" -F "owner=${r_owner}" -F "name=${r_name}" -F "number=${number}")
    [[ -n "$cursor" ]] && gql_args+=(-F "cursor=${cursor}")
    local gql_out
    if ! gql_out="$(gh "${gql_args[@]}" 2>&1)" \
      || ! printf '%s' "$gql_out" | jq -e '.data.repository.pullRequest.reviewThreads.nodes | type == "array"' >/dev/null 2>&1; then
      gql_ok="false"
      printf 'WARNING: could not read GraphQL reviewThreads (%s); falling back to REST with resolved=unknown.\n' "$(brief "$gql_out")" >&2
      break
    fi

    inline_items="$(jq -n --argjson acc "$inline_items" --argjson page "$gql_out" '
      $acc + [
        $page.data.repository.pullRequest.reviewThreads.nodes[] as $t
        | ($t.comments.nodes // [])[]
        | {
            kind: "review_comment",
            author: (.author.login // "unknown"),
            body: (.body // ""),
            url: (.url // ""),
            createdAt: (.createdAt // ""),
            state: "",
            path: (($t.path // "") + (if $t.line then ":\($t.line)" else "" end)),
            resolved: ($t.isResolved == true)
          }
      ]')"
    has_next="$(printf '%s' "$gql_out" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false')"
    cursor="$(printf '%s' "$gql_out" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty')"
  done

  if [[ "$gql_ok" != "true" ]]; then
    local rest_inline
    if rest_inline="$(gh api --hostname "$HOST" --paginate "repos/${r_owner}/${r_name}/pulls/${number}/comments?per_page=100" 2>&1 | jq -s 'add // []' 2>/dev/null)"; then
      inline_items="$(printf '%s' "$rest_inline" | jq '[.[] | {
        kind: "review_comment",
        author: (.user.login // "unknown"),
        body: (.body // ""),
        url: (.html_url // ""),
        createdAt: (.created_at // ""),
        state: "",
        path: ((.path // "") + (if .line then ":\(.line)" elif .original_line then ":\(.original_line)" else "" end)),
        resolved: null
      }]')"
    else
      printf 'WARNING: could not read inline review comments via REST either.\n' >&2
      inline_items="[]"
    fi
  fi

  local payload
  payload="$(jq -n "$JQ_TIME_HELPERS"'
    (
      (($conv // []) | map({
        kind: "comment",
        author: (.user.login // "unknown"),
        body: (.body // ""),
        url: (.html_url // ""),
        createdAt: (.created_at // ""),
        state: "",
        path: "",
        resolved: false
      }))
      + (($reviews // [])
        | map(select(
            ((.body // "") | contains("<!-- BUGBOT_REVIEW_STALE -->") | not)
            and (((.state // "") == "COMMENTED" and ((.body // "") | contains("<!-- BUGBOT_REVIEW -->"))) | not)
            and (((.body // "") | gsub("^\\s+|\\s+$";"")) != "" or (.state // "") != "COMMENTED")
          ))
        | map({
            kind: "review",
            author: (.user.login // "unknown"),
            body: (.body // ""),
            url: (.html_url // ""),
            createdAt: (.submitted_at // ""),
            state: (.state // ""),
            path: "",
            resolved: false
          }))
      + ($inline // [])
    )
    | map(select($inc_res == "true" or .resolved != true))
    | map(select($viewer == "" or ((.author | norm_login) != ($viewer | norm_login))))
    | map(select($since == "" or (.createdAt | is_after($since))))
    | sort_by(.createdAt | to_epoch_ms // 0)
    | { pullRequest: $pr, excludedViewer: (if $viewer == "" then null else $viewer end), feedback: . }
  ' \
    --argjson pr "$pr" \
    --argjson conv "$conv_raw" \
    --argjson reviews "$reviews_raw" \
    --argjson inline "$inline_items" \
    --arg since "$SINCE" \
    --arg viewer "$viewer" \
    --arg inc_res "$INCLUDE_RESOLVED")"

  if [[ "$FORMAT" == "json" ]]; then
    printf '%s\n' "$payload"
    return
  fi

  printf '%s' "$payload" | jq -r '
    "PR #\(.pullRequest.id)  \(.pullRequest.url)",
    "Feedback items: \(.feedback | length)",
    "---",
    (.feedback[] |
      "[\(.kind)\(if .state != "" then " \(.state)" else "" end)\(if .path != "" then " \(.path)" else "" end)\(if .resolved == null then " resolved=unknown" else "" end)] \(.author)  \(.createdAt)",
      (.body | split("\n")[] | "  " + .),
      "")'
}

cmd_pr_checks() {
  resolve_pr
  local pr="$RESOLVED_PR"
  [[ -n "$pr" ]] \
    || die PR_NOT_FOUND "no open pull request for ${SOURCE:-the current branch}."

  local number r_owner r_name target_ref out err rc=0
  number="$(printf '%s' "$pr" | jq -r '.id')"
  r_owner="$(printf '%s' "$pr" | jq -r '.repoOwner // empty')"
  r_name="$(printf '%s' "$pr" | jq -r '.repoName // empty')"
  target_ref="${HOST}/${r_owner:-$OWNER}/${r_name:-$NAME}"

  TMP_BODY="$(mktemp)"
  out="$(gh pr checks "$number" --repo "$target_ref" --json name,state,bucket,link 2>"$TMP_BODY")" || rc=$?
  err="$(cat "$TMP_BODY")"

  if [[ -z "${out//[[:space:]]/}" ]] && [[ "$err" == *"no checks reported"* ]]; then
    out="[]"
  elif ! printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    die API_ERROR "gh pr checks failed for ${target_ref}#${number} (exit ${rc}): $(brief "${err:-$out}")"
  fi

  # Green checks plus an "LGTM" comment can still be unmergeable: a comment is
  # not an approval, and a required review keeps the PR blocked.
  local review
  review="$(gh pr view "$number" --repo "$target_ref" --json reviewDecision,mergeStateStatus 2>/dev/null \
    | jq -c '{decision: (.reviewDecision // null | if . == "" then null else . end), mergeState: (.mergeStateStatus // null)}' 2>/dev/null)" \
    || review=""
  [[ -n "$review" ]] || review='{"decision":null,"mergeState":null}'

  local payload
  payload="$(jq -n --argjson pr "$pr" --argjson raw "$out" --argjson review "$review" '
    ($raw | map({
      name: (.name // "unnamed"),
      state: ((.state // "") | ascii_upcase),
      bucket: ((.bucket // "") | ascii_downcase),
      url: (.link // null)
    })) as $checks
    | (
        if ($checks | length) == 0 then "none"
        elif ($checks | any(.bucket == "fail" or .bucket == "cancel" or (.state | IN("FAILURE","ERROR","CANCELLED","TIMED_OUT","ACTION_REQUIRED")))) then "fail"
        elif ($checks | any(.bucket == "pending" or (.state | IN("PENDING","IN_PROGRESS","QUEUED","EXPECTED")))) then "pending"
        else "pass" end
      ) as $overall
    | { pullRequest: $pr, overall: $overall, review: $review, checks: $checks }
  ')"

  if [[ "$FORMAT" == "json" ]]; then
    printf '%s\n' "$payload"
    return
  fi

  printf '%s' "$payload" | jq -r '
    "PR #\(.pullRequest.id)  overall=\(.overall)  (\(.checks | length) checks)  review=\(.review.decision // "unknown")  merge=\(.review.mergeState // "unknown")",
    (.checks[] | "  [\(.bucket // .state)] \(.name)\(if .url then " — \(.url)" else "" end)")'
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
ACTION=""
if [[ "$GROUP" != "branches" && -n "${1:-}" && "${1:-}" != -* ]]; then
  ACTION="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then
    name="${1%%=*}"
    value="${1#*=}"
    step=1
  else
    name="$1"
    value="${2-}"
    step=2
  fi

  case "$name" in
    --format | --key | --title | --source | --target | --body | --body-file | --pr | --since)
      if [[ "$step" == 2 && ( $# -lt 2 || "$value" == --* ) ]]; then
        die INVALID_INPUT "${name} requires a value. Run 'gh-pr.sh --help' for usage."
      fi
      case "$name" in
        --format) FORMAT="$value" ;;
        --key) ISSUE_KEY="$value" ;;
        --title) TITLE="$value" ;;
        --source) SOURCE="$value" ;;
        --target) TARGET="$value" ;;
        --body) BODY="$value" ;;
        --body-file) BODY_FILE="$value" ;;
        --pr) PR_REF="$value" ;;
        --since) SINCE="$value" ;;
      esac
      shift "$step"
      ;;
    --include-resolved)
      INCLUDE_RESOLVED="true"
      shift
      ;;
    --include-self)
      INCLUDE_SELF="true"
      shift
      ;;
    --no-draft)
      DRAFT="false"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
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
  branches:) cmd_branches ;;
  pr:find) cmd_pr_find ;;
  pr:create) cmd_pr_create ;;
  pr:feedback) cmd_pr_feedback ;;
  pr:checks) cmd_pr_checks ;;
  *)
    printf 'ERROR: INVALID_INPUT: unknown command "%s%s".\n\n' "$GROUP" "${ACTION:+ $ACTION}" >&2
    usage >&2
    exit 1
    ;;
esac
