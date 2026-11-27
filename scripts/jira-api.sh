#!/usr/bin/env bash
# Jira REST fallback for the jira-fix skill, used when the Atlassian MCP is not available.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${SKILL_DIR}/.env"

load_env_file() {
  local file="$1" line key val
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[2]}"
      val="${BASH_REMATCH[3]}"
      if [[ "$val" =~ ^\"(.*)\"[[:space:]]*$ ]]; then
        val="${BASH_REMATCH[1]}"
      elif [[ "$val" =~ ^\'(.*)\'[[:space:]]*$ ]]; then
        val="${BASH_REMATCH[1]}"
      else
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
      fi
      if [[ -z "${!key+x}" ]]; then
        printf -v "$key" '%s' "$val"
      fi
    fi
  done <"$file"
}

FORMAT="text"
TEXT=""
TEXT_FILE=""
SINCE=""
DRY_RUN="false"

usage() {
  cat <<'EOF'
jira-api.sh — Jira Cloud REST access for the jira-fix skill

USAGE
  jira-api.sh list                     [--format text|json]
  jira-api.sh get      KEY|URL         [--format text|json]
  jira-api.sh comments KEY|URL         [--since ISO8601] [--format text|json]
  jira-api.sh comment  KEY|URL TEXT    [--dry-run] [--format text|json]
  jira-api.sh comment  KEY|URL --text-file PATH|- [--dry-run]

OPTIONS
  --format text|json   Output format (default: text)
  --since ISO8601      Only return comments created after this instant (timezone-safe)
  --text TEXT          Comment body
  --text-file PATH|-   Read the comment body from a file, or from stdin with "-"
  --dry-run            Validate and preview comment without posting to Jira
  -h, --help           Show this help

NOTES
  Credentials and JIRA_URL are read safely from the skill .env file.
  KEY|URL accepts either "PROJ-123" or a full "https://.../browse/PROJ-123" URL.
  "get" also fetches prose custom fields (e.g. Acceptance Criteria, Steps to Reproduce).
  "comments" paginates the entire thread rather than stopping at the first page.

EXAMPLES
  jira-api.sh list --format json
  jira-api.sh get PROJ-123
  jira-api.sh get https://acme.atlassian.net/browse/PROJ-123
  jira-api.sh comments PROJ-123 --since "$(git log -1 --format=%cI)"
  printf 'Fixed: ...\nPR: https://...\n' | jira-api.sh comment PROJ-123 --text-file -
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

normalize_key() {
  local raw="$1"
  if [[ "$raw" =~ /browse/([A-Za-z][A-Za-z0-9_]*-[0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]'
  elif [[ "$raw" =~ ^[A-Za-z][A-Za-z0-9_]*-[0-9]+$ ]]; then
    printf '%s' "$raw" | tr '[:lower:]' '[:upper:]'
  else
    die INVALID_INPUT "'${raw}' is not a Jira issue key or /browse/KEY URL."
  fi
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
  arg="$1"
  val=""
  has_eq="false"
  if [[ "$arg" == --*=* ]]; then
    has_eq="true"
    val="${arg#*=}"
    arg="${arg%%=*}"
  fi

  case "$arg" in
    --format)
      if [[ "$has_eq" == "true" ]]; then FORMAT="$val"; shift; else FORMAT="${2:?--format needs text or json}"; shift 2; fi
      ;;
    --text)
      if [[ "$has_eq" == "true" ]]; then TEXT="$val"; shift; else TEXT="${2:?--text needs a value}"; shift 2; fi
      ;;
    --text-file)
      if [[ "$has_eq" == "true" ]]; then TEXT_FILE="$val"; shift; else TEXT_FILE="${2:?--text-file needs a path or -}"; shift 2; fi
      ;;
    --since)
      if [[ "$has_eq" == "true" ]]; then SINCE="$val"; shift; else SINCE="${2:?--since needs an ISO8601 timestamp}"; shift 2; fi
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
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
load_env_file "$ENV_FILE"

[[ "${ATLASSIAN_EMAIL:-}" == *"@"* && "${ATLASSIAN_EMAIL:-}" != "your-"* ]] \
  || die CONFIG_MISSING "set ATLASSIAN_EMAIL in ${ENV_FILE}."
[[ -n "${ATLASSIAN_API_TOKEN:-}" && "${ATLASSIAN_API_TOKEN:-}" != "your-"* ]] \
  || die CONFIG_MISSING "set ATLASSIAN_API_TOKEN in ${ENV_FILE}."
[[ -n "${JIRA_URL:-}" && "${JIRA_URL:-}" != "your-"* ]] \
  || die CONFIG_MISSING "set JIRA_URL in ${ENV_FILE}."

AUTH=$(printf '%s' "${ATLASSIAN_EMAIL}:${ATLASSIAN_API_TOKEN}" | base64 | tr -d '\n')
API="${JIRA_URL%/}/rest/api/3"

_curl() {
  local body status
  body="$(mktemp)"
  status="$(curl -s --max-time 30 -w '%{http_code}' -o "$body" \
    -H "Authorization: Basic ${AUTH}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "$@")" || status="000"

  if [[ "$status" == "401" ]]; then
    rm -f "$body"
    die AUTH_REQUIRED "Jira rejected ATLASSIAN_EMAIL / ATLASSIAN_API_TOKEN for ${JIRA_URL}."
  fi
  if [[ "$status" == "404" ]]; then
    rm -f "$body"
    die ISSUE_NOT_FOUND "Jira returned 404 (not found or no permission)."
  fi
  if [[ "$status" -lt 200 || "$status" -ge 300 ]] 2>/dev/null; then
    local msg
    msg="$(jq -r '[.errorMessages[]?, (.errors // {} | to_entries[]? | "\(.key): \(.value)")] | join("; ")' "$body" 2>/dev/null || true)"
    rm -f "$body"
    die API_ERROR "Jira returned HTTP ${status}${msg:+ — ${msg}}"
  fi

  cat "$body"
  rm -f "$body"
}

ADF_TO_TEXT='
def inline_text:
  if type == "array" then map(inline_text) | join("")
  elif type != "object" then ""
  elif .type == "text" then (.text // "")
  elif .type == "hardBreak" then "\n"
  elif .type == "mention" then ("@" + ((.attrs.text // .attrs.id // "user") | sub("^@";"")))
  elif (.type == "inlineCard" or .type == "blockCard") then (.attrs.url // "")
  elif (.type == "media" or .type == "inlineMedia") then ("[image: " + (.attrs.alt // .attrs.id // "unnamed") + "]")
  else ((.content // []) | inline_text) end;

def adf_text:
  if . == null then ""
  elif type == "string" then .
  else
    [ .. | select(type == "object") |
        if .type? == "media"
        then "[image: " + (.attrs.alt // .attrs.id // "unnamed") + "]"
        elif (.type? == "paragraph" or .type? == "heading" or .type? == "codeBlock")
        then (.content // [] | inline_text)
        else empty end ]
    | map(select(. != "")) | join("\n")
  end;

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
    JQL="${JIRA_LIST_JQL:-assignee = currentUser() AND statusCategory != Done ORDER BY priority DESC, updated DESC}"
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
    RAW_KEY="${POSITIONAL[0]:-}"
    [[ -n "$RAW_KEY" ]] || die INVALID_INPUT "usage: jira-api.sh get KEY|URL"
    KEY="$(normalize_key "$RAW_KEY")"

    FIELDS_META="$(_curl "${API}/field" 2>/dev/null || printf '[]')"
    CUSTOM_MAP="$(printf '%s' "$FIELDS_META" | jq -c '
      [ .[]? | select(.custom == true and (.schema.custom == "com.atlassian.jira.plugin.system.customfieldtypes:textarea" or .schema.custom == "com.atlassian.jira.plugin.system.customfieldtypes:textfield"))
        | { id: .id, name: .name } ]')"
    EXTRA_IDS="$(printf '%s' "$CUSTOM_MAP" | jq -r 'map(.id) | join(",")')"
    FIELD_QUERY="summary,description,environment,issuetype,priority,status,labels,components,assignee,issuelinks,attachment${EXTRA_IDS:+,${EXTRA_IDS}}"

    RESP=$(_curl "${API}/issue/${KEY}?fields=${FIELD_QUERY}")

    PAYLOAD=$(printf '%s' "$RESP" | jq --arg base "${JIRA_URL%/}" --argjson cmap "$CUSTOM_MAP" "$ADF_TO_TEXT"'
      . as $root | {
        key: .key,
        summary: (.fields.summary // ""),
        type: (.fields.issuetype.name // "Task"),
        priority: (.fields.priority.name // "None"),
        status: (.fields.status.name // "Unknown"),
        assignee: (.fields.assignee.displayName // "Unassigned"),
        labels: [.fields.labels[]?],
        components: [.fields.components[]?.name],
        linkedIssues: [.fields.issuelinks[]? | (.outwardIssue // .inwardIssue) | select(. != null) | .key],
        attachments: [.fields.attachment[]? | { id: (.id | tostring), filename: .filename }],
        description: (.fields.description | adf_text),
        environment: (.fields.environment | adf_text),
        customFields: [
          $cmap[] as $cf
          | ($root.fields[$cf.id] | adf_text) as $txt
          | select(($txt | gsub("^\\s+|\\s+$";"")) != "")
          | { id: $cf.id, name: $cf.name, text: $txt }
        ],
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
      (select((.attachments | length) > 0) | "Attachments: \([.attachments[].filename] | join(", "))"),
      "---",
      "Description:",
      (if .description == "" then "(no description)" else .description end),
      (select(.environment != "") | "\nEnvironment:\n\(.environment)"),
      (.customFields[] | "\n\(.name):\n\(.text)"),
      "---",
      "Link: \(.url)"'
    ;;

  comments)
    RAW_KEY="${POSITIONAL[0]:-}"
    [[ -n "$RAW_KEY" ]] || die INVALID_INPUT "usage: jira-api.sh comments KEY|URL [--since ISO8601]"
    KEY="$(normalize_key "$RAW_KEY")"

    ALL_COMMENTS="[]"
    START_AT=0
    while true; do
      PAGE=$(_curl "${API}/issue/${KEY}/comment?orderBy=created&startAt=${START_AT}&maxResults=100")
      ALL_COMMENTS=$(jq -n --argjson acc "$ALL_COMMENTS" --argjson p "$PAGE" '$acc + ($p.comments // [])')
      PAGE_COUNT=$(printf '%s' "$PAGE" | jq '(.comments // []) | length')
      TOTAL=$(printf '%s' "$PAGE" | jq '.total // 0')
      START_AT=$((START_AT + PAGE_COUNT))
      if (( PAGE_COUNT == 0 || START_AT >= TOTAL )); then
        break
      fi
    done

    PAYLOAD=$(jq -n --arg key "$KEY" --arg since "$SINCE" --argjson raw "$ALL_COMMENTS" "$ADF_TO_TEXT"' {
      key: $key,
      comments: [
        $raw[]
        | select($since == "" or ((.created // "") | is_after($since)))
        | {
            id: (.id | tostring),
            author: (.author.displayName // "unknown"),
            createdAt: (.created // ""),
            updatedAt: (.updated // ""),
            body: (.body | adf_text)
          }
      ]
    }')

    emit "$PAYLOAD" '
      "--- \(.key): \(.comments | length) comment(s) ---",
      (.comments[] |
        "[\(.createdAt)] \(.author)",
        (.body | split("\n")[] | "  " + .),
        "")'
    ;;

  comment)
    RAW_KEY="${POSITIONAL[0]:-}"
    [[ -n "$RAW_KEY" ]] || die INVALID_INPUT "usage: jira-api.sh comment KEY|URL TEXT"
    KEY="$(normalize_key "$RAW_KEY")"

    if [[ "$TEXT_FILE" == "-" ]]; then
      TEXT="$(cat)"
    elif [[ -n "$TEXT_FILE" ]]; then
      [[ -f "$TEXT_FILE" ]] || die INVALID_INPUT "text file '${TEXT_FILE}' does not exist."
      TEXT="$(cat "$TEXT_FILE")"
    elif [[ -z "$TEXT" ]]; then
      TEXT="${POSITIONAL[1]:-}"
    fi
    [[ -n "${TEXT//[[:space:]]/}" ]] || die INVALID_INPUT "comment text is empty. Pass it positionally, with --text, or with --text-file -"

    if [[ "$DRY_RUN" == "true" ]]; then
      PAYLOAD=$(jq -n --arg key "$KEY" --arg body "$TEXT" '{dryRun:true, key:$key, body:$body}')
      emit "$PAYLOAD" '"[dry-run] Would comment on \(.key)"'
      exit 0
    fi

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
