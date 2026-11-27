#!/usr/bin/env bash
# Jira REST fallback for the jira-fix skill, used when the Atlassian MCP is not available.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${SKILL_DIR}/.env"

FORMAT="text"
TEXT=""
TEXT_FILE=""

usage() {
  cat <<'EOF'
jira-api.sh — Jira Cloud REST access for the jira-fix skill

USAGE
  jira-api.sh list                     [--format text|json]
  jira-api.sh get      TICKET-KEY      [--format text|json]
  jira-api.sh comments TICKET-KEY      [--format text|json]
  jira-api.sh comment  TICKET-KEY TEXT [--format text|json]
  jira-api.sh comment  TICKET-KEY --text-file PATH|-

OPTIONS
  --format text|json   Output format (default: text)
  --text TEXT          Comment body
  --text-file PATH|-   Read the comment body from a file, or from stdin with "-"
  -h, --help           Show this help

NOTES
  Credentials and JIRA_URL are read from the skill .env file.
  "list" uses JIRA_LIST_JQL when set, otherwise your open assigned issues.
  "comments" is what the fix workflow uses to gather prior discussion on a ticket.

EXAMPLES
  jira-api.sh list --format json
  jira-api.sh get PROJ-123
  jira-api.sh comments PROJ-123 --format json
  jira-api.sh comment PROJ-123 "Fixed: header overlap on mobile nav."
  printf 'Fixed: ...\nPR: https://...\n' | jira-api.sh comment PROJ-123 --text-file -
EOF
}

die() {
  local code="$1"
  shift
  printf 'ERROR: %s: %s\n' "$code" "$*" >&2
  exit 1
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

CMD="$1"
shift

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)
      FORMAT="${2:?--format needs text or json}"
      shift 2
      ;;
    --text)
      TEXT="${2:?--text needs a value}"
      shift 2
      ;;
    --text-file)
      TEXT_FILE="${2:?--text-file needs a path or -}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      die INVALID_INPUT "unknown option '$1'. Run 'jira-api.sh --help' for usage."
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

[[ "$FORMAT" == "text" || "$FORMAT" == "json" ]] \
  || die INVALID_INPUT "--format must be 'text' or 'json' (got '${FORMAT}')."

command -v jq >/dev/null 2>&1 || die MISSING_DEPENDENCY "'jq' is required but was not found in PATH."
command -v curl >/dev/null 2>&1 || die MISSING_DEPENDENCY "'curl' is required but was not found in PATH."

[[ -f "$ENV_FILE" ]] || die CONFIG_MISSING "create ${ENV_FILE} (copy from .env.example) — see README."
# shellcheck disable=SC1090
source "$ENV_FILE"

[[ "${ATLASSIAN_EMAIL:-}" == *"@"* && "${ATLASSIAN_EMAIL:-}" != "your-"* ]] \
  || die CONFIG_MISSING "set ATLASSIAN_EMAIL in ${ENV_FILE}."
[[ -n "${ATLASSIAN_API_TOKEN:-}" && "${ATLASSIAN_API_TOKEN:-}" != "your-"* ]] \
  || die CONFIG_MISSING "set ATLASSIAN_API_TOKEN in ${ENV_FILE}."
[[ -n "${JIRA_URL:-}" && "${JIRA_URL:-}" != "your-"* ]] \
  || die CONFIG_MISSING "set JIRA_URL in ${ENV_FILE}."

# GNU base64 wraps at 76 columns, which would corrupt the header for longer credentials.
AUTH=$(printf '%s' "${ATLASSIAN_EMAIL}:${ATLASSIAN_API_TOKEN}" | base64 | tr -d '\n')
API="${JIRA_URL%/}/rest/api/3"

# Performs a request and fails with the Jira error message rather than a raw dump.
_curl() {
  local body status
  body="$(mktemp)"
  status="$(curl -s --max-time 30 -w '%{http_code}' -o "$body" \
    -H "Authorization: Basic ${AUTH}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "$@")" || status="000"

  if [[ "$status" -lt 200 || "$status" -ge 300 ]] 2>/dev/null; then
    local msg
    msg="$(jq -r '[.errorMessages[]?, (.errors // {} | to_entries[]? | "\(.key): \(.value)")] | join("; ")' "$body" 2>/dev/null || true)"
    rm -f "$body"
    die API_ERROR "Jira returned HTTP ${status}${msg:+ — ${msg}}"
  fi

  cat "$body"
  rm -f "$body"
}

# Renders an Atlassian Document Format node as plain text, one line per top-level block.
# Media nodes become "[image: filename]" so a screenshot is never silently dropped —
# the filename is what ties it back to the attachment list.
ADF_TO_TEXT='
def inline_text: [ .. | .text? // empty ] | join("");
def adf_text:
  if . == null then "" else
    [ .. | select(type == "object") |
        if .type? == "media"
        then "[image: " + (.attrs.alt // .attrs.id // "unnamed") + "]"
        elif (.type? == "paragraph" or .type? == "heading" or .type? == "codeBlock")
        then inline_text
        else empty end ]
    | map(select(. != "")) | join("\n")
  end;
'

emit() {
  local payload="$1" text_filter="$2"
  if [[ "$FORMAT" == "json" ]]; then
    printf '%s\n' "$payload" | jq '.'
  else
    printf '%s\n' "$payload" | jq -r "$text_filter"
  fi
}

case "$CMD" in
  list)
    JQL="${JIRA_LIST_JQL:-assignee = currentUser() AND status not in (Done, Cancelled) ORDER BY priority DESC, updated DESC}"
    REQ=$(jq -n --arg jql "$JQL" \
      '{jql:$jql,fields:["summary","status","issuetype","priority","updated"],maxResults:20}')
    RESP=$(_curl -X POST "${API}/search/jql" -d "$REQ")

    PAYLOAD=$(printf '%s' "$RESP" | jq --arg base "${JIRA_URL%/}" '{
      issues: [.issues[]? | {
        key: .key,
        summary: (.fields.summary // ""),
        type: (.fields.issuetype.name // "Task"),
        priority: (.fields.priority.name // "None"),
        status: (.fields.status.name // "Unknown"),
        updated: (.fields.updated // ""),
        url: "\($base)/browse/\(.key)"
      }]
    }')

    emit "$PAYLOAD" '
      (.issues[] | "  \(.key)  [\(.type)]  \(.priority)  \(.status)\n    \(.summary)\n"),
      "Total: \(.issues | length) tickets"'
    ;;

  get)
    KEY="${POSITIONAL[0]:-}"
    [[ -n "$KEY" ]] || die INVALID_INPUT "usage: jira-api.sh get TICKET-KEY"
    RESP=$(_curl "${API}/issue/${KEY}?fields=summary,description,issuetype,priority,status,labels,components,assignee,issuelinks,attachment")

    PAYLOAD=$(printf '%s' "$RESP" | jq --arg base "${JIRA_URL%/}" "$ADF_TO_TEXT"' {
      key: .key,
      summary: (.fields.summary // ""),
      type: (.fields.issuetype.name // "Task"),
      priority: (.fields.priority.name // "None"),
      status: (.fields.status.name // "Unknown"),
      assignee: (.fields.assignee.displayName // "Unassigned"),
      labels: [.fields.labels[]?],
      components: [.fields.components[]?.name],
      linkedIssues: [.fields.issuelinks[]? | (.outwardIssue // .inwardIssue) | select(. != null) | .key],
      attachments: [.fields.attachment[]?.filename],
      description: (.fields.description | adf_text),
      url: "\($base)/browse/\(.key)"
    }')

    emit "$PAYLOAD" '
      "Key: \(.key)",
      "Summary: \(.summary)",
      "Type: \(.type)",
      "Priority: \(.priority)",
      "Status: \(.status)",
      "Assignee: \(.assignee)",
      (select((.labels | length) > 0) | "Labels: \(.labels | join(", "))"),
      (select((.components | length) > 0) | "Components: \(.components | join(", "))"),
      (select((.linkedIssues | length) > 0) | "Linked: \(.linkedIssues | join(", "))"),
      (select((.attachments | length) > 0) | "Attachments: \(.attachments | join(", "))"),
      "---",
      "Description:",
      (if .description == "" then "(no description)" else .description end),
      "---",
      "Link: \(.url)"'
    ;;

  comments)
    KEY="${POSITIONAL[0]:-}"
    [[ -n "$KEY" ]] || die INVALID_INPUT "usage: jira-api.sh comments TICKET-KEY"
    RESP=$(_curl "${API}/issue/${KEY}/comment?orderBy=created&maxResults=50")

    PAYLOAD=$(printf '%s' "$RESP" | jq --arg key "$KEY" "$ADF_TO_TEXT"' {
      key: $key,
      comments: [.comments[]? | {
        id: .id,
        author: (.author.displayName // "unknown"),
        createdAt: (.created // ""),
        updatedAt: (.updated // ""),
        body: (.body | adf_text)
      }]
    }')

    emit "$PAYLOAD" '
      "--- \(.key): \(.comments | length) comment(s) ---",
      (.comments[] |
        "[\(.createdAt)] \(.author)",
        (.body | split("\n")[] | "  " + .),
        "")'
    ;;

  comment)
    KEY="${POSITIONAL[0]:-}"
    [[ -n "$KEY" ]] || die INVALID_INPUT "usage: jira-api.sh comment TICKET-KEY TEXT"

    if [[ "$TEXT_FILE" == "-" ]]; then
      TEXT="$(cat)"
    elif [[ -n "$TEXT_FILE" ]]; then
      [[ -f "$TEXT_FILE" ]] || die INVALID_INPUT "text file '${TEXT_FILE}' does not exist."
      TEXT="$(cat "$TEXT_FILE")"
    elif [[ -z "$TEXT" ]]; then
      TEXT="${POSITIONAL[1]:-}"
    fi
    [[ -n "${TEXT//[[:space:]]/}" ]] || die INVALID_INPUT "comment text is empty. Pass it positionally, with --text, or with --text-file -"

    REQ=$(jq -n --arg t "$TEXT" '
      ($t | rtrimstr("\n") | split("\n")) as $lines |
      {body: {type: "doc", version: 1, content: [{type: "paragraph", content: (
        reduce range(0; ($lines | length)) as $i ([];
          . + (if $i > 0 then [{type: "hardBreak"}] else [] end)
            + (if ($lines[$i] | length) > 0 then [{type: "text", text: $lines[$i]}] else [] end))
      )}]}}')

    RESP=$(_curl -X POST "${API}/issue/${KEY}/comment" -d "$REQ")

    PAYLOAD=$(printf '%s' "$RESP" | jq --arg key "$KEY" --arg base "${JIRA_URL%/}" '{
      key: $key,
      posted: true,
      id: (.id // ""),
      url: "\($base)/browse/\($key)?focusedCommentId=\(.id // "")"
    }')

    emit "$PAYLOAD" '"Commented on \(.key) — \(.url)"'
    ;;

  *)
    printf 'ERROR: INVALID_INPUT: unknown command "%s".\n\n' "$CMD" >&2
    usage >&2
    exit 1
    ;;
esac
