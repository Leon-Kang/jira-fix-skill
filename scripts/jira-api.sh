#!/usr/bin/env bash
# Jira API fallback when Atlassian MCP is not available
# Usage:
#   jira-api.sh list                    — list my assigned tickets
#   jira-api.sh get TICKET-KEY          — get ticket details
#   jira-api.sh comment TICKET-KEY TEXT — add a comment

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${SKILL_DIR}/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: Create ${ENV_FILE} (copy from .env.example) — see README"; exit 1; }
source "$ENV_FILE"

[[ "${ATLASSIAN_EMAIL:-}" == *"@"* && "${ATLASSIAN_EMAIL:-}" != "your-"* ]] \
  || { echo "ERROR: Set ATLASSIAN_EMAIL in ${ENV_FILE}"; exit 1; }
[[ "${ATLASSIAN_API_TOKEN:-}" != "your-"* && -n "${ATLASSIAN_API_TOKEN:-}" ]] \
  || { echo "ERROR: Set ATLASSIAN_API_TOKEN in ${ENV_FILE}"; exit 1; }
[[ -n "${JIRA_URL:-}" && "${JIRA_URL:-}" != "your-"* ]] \
  || { echo "ERROR: Set JIRA_URL in ${ENV_FILE}"; exit 1; }

AUTH=$(echo -n "${ATLASSIAN_EMAIL}:${ATLASSIAN_API_TOKEN}" | base64)
API="${JIRA_URL}/rest/api/3"

_curl() {
  curl -sf --max-time 30 -H "Authorization: Basic ${AUTH}" -H "Content-Type: application/json" "$@"
}

CMD="${1:?Usage: jira-api.sh list|get|comment}"
shift

case "$CMD" in
  list)
    JQL="${JIRA_LIST_JQL:-assignee = currentUser() AND status not in (Done, Cancelled) ORDER BY priority ASC, updated DESC}"
    PAYLOAD=$(jq -n --arg jql "$JQL" \
      '{jql:$jql,fields:["summary","status","issuetype","priority","updated"],maxResults:20}')
    RESP=$(_curl -X POST "${API}/search/jql" -d "$PAYLOAD")

    echo "$RESP" | jq -r '
      .issues[] |
      "  \(.key)  [\(.fields.issuetype.name)]  \(.fields.priority.name)  \(.fields.status.name)\n    \(.fields.summary)\n"'
    echo "Total: $(echo "$RESP" | jq '.issues | length') tickets"
    ;;

  get)
    KEY="${1:?Usage: jira-api.sh get TICKET-KEY}"
    RESP=$(_curl "${API}/issue/${KEY}?fields=summary,description,issuetype,priority,status,labels,components,assignee")

    echo "Key: ${KEY}"
    echo "Summary: $(echo "$RESP" | jq -r '.fields.summary // "no summary"')"
    echo "Type: $(echo "$RESP" | jq -r '.fields.issuetype.name // "Task"')"
    echo "Priority: $(echo "$RESP" | jq -r '.fields.priority.name // "Medium"')"
    echo "Status: $(echo "$RESP" | jq -r '.fields.status.name // "Unknown"')"
    LABELS=$(echo "$RESP" | jq -r '[.fields.labels[]?] | join(", ")')
    [[ -n "$LABELS" ]] && echo "Labels: ${LABELS}"
    echo "---"
    echo "Description:"
    echo "$RESP" | jq -r '
      if .fields.description then
        [.fields.description.content[]? | .. | .text? // empty] | join("\n")
      else "(no description)" end'
    echo "---"
    echo "Link: ${JIRA_URL}/browse/${KEY}"
    ;;

  comment)
    KEY="${1:?Usage: jira-api.sh comment TICKET-KEY TEXT}"
    TEXT="${2:?Provide comment text}"
    PAYLOAD=$(jq -n --arg t "$TEXT" \
      '{body:{type:"doc",version:1,content:[{type:"paragraph",content:[{type:"text",text:$t}]}]}}')
    _curl -X POST "${API}/issue/${KEY}/comment" -d "$PAYLOAD" >/dev/null
    echo "Commented on ${KEY}"
    ;;

  *)
    echo "Unknown command: ${CMD}"
    echo "Usage: jira-api.sh list|get|comment"
    exit 1
    ;;
esac
