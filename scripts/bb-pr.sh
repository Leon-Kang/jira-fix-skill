#!/usr/bin/env bash
# Create Bitbucket draft PR (the only thing Atlassian MCP can't do)
# Usage: bb-pr.sh TICKET "TITLE" SOURCE_BRANCH "DESCRIPTION"

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${SKILL_DIR}/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: Create ${ENV_FILE} (copy from .env.example) — see README"; exit 1; }
source "$ENV_FILE"

MAIN_BRANCH="${MAIN_BRANCH:-develop}"

[[ "${ATLASSIAN_EMAIL:-}" == *"@"* && "${ATLASSIAN_EMAIL:-}" != "your-"* ]] \
  || { echo "ERROR: Set ATLASSIAN_EMAIL in ${ENV_FILE}"; exit 1; }
[[ -n "${BB_API_TOKEN:-}" && "${BB_API_TOKEN:-}" != "your-"* ]] \
  || { echo "ERROR: Set BB_API_TOKEN in ${ENV_FILE} (create at id.atlassian.com -> API tokens -> Bitbucket scopes)"; exit 1; }
[[ -n "${BB_WORKSPACE:-}" && "${BB_WORKSPACE:-}" != "your-"* ]] \
  || { echo "ERROR: Set BB_WORKSPACE in ${ENV_FILE}"; exit 1; }

BB_REPO=$(git remote get-url origin 2>/dev/null \
  | sed -n 's|.*bitbucket\.org[:/]'"${BB_WORKSPACE}"'/\([^.]*\).*|\1|p')
[[ -n "$BB_REPO" ]] || { echo "ERROR: Cannot detect repo from git remote"; exit 1; }

TICKET="${1:?Usage: bb-pr.sh TICKET TITLE SOURCE_BRANCH [DESCRIPTION]}"
TITLE="${2:?title}"
SOURCE="${3:?source branch}"
DESC="${4:-}"

PAYLOAD=$(jq -n \
  --arg t "[DRAFT] ${TITLE}" --arg d "$DESC" \
  --arg s "$SOURCE" --arg dest "${MAIN_BRANCH}" \
  '{title:$t,source:{branch:{name:$s}},destination:{branch:{name:$dest}},close_source_branch:true} | if $d != "" then .description = $d else . end')

TMPBODY=$(mktemp)
trap 'rm -f "$TMPBODY"' EXIT

STATUS=$(curl -s --max-time 30 -w '%{http_code}' -o "$TMPBODY" \
  -u "${ATLASSIAN_EMAIL}:${BB_API_TOKEN}" \
  -X POST "https://api.bitbucket.org/2.0/repositories/${BB_WORKSPACE}/${BB_REPO}/pullrequests" \
  -H "Content-Type: application/json" -d "$PAYLOAD") || STATUS="000"

if [[ "$STATUS" -ge 200 && "$STATUS" -lt 300 ]] 2>/dev/null; then
  PR_URL=$(jq -r '.links.html.href // "unknown"' "$TMPBODY")
  PR_ID=$(jq -r '.id // "unknown"' "$TMPBODY")
  PR_TITLE=$(jq -r '.title // "unknown"' "$TMPBODY")
  PR_DEST=$(jq -r '.destination.branch.name // "unknown"' "$TMPBODY")
  echo "--- PR Created ---"
  echo "ID:     ${PR_ID}"
  echo "Title:  ${PR_TITLE}"
  echo "URL:    ${PR_URL}"
  echo "Source: ${SOURCE}"
  echo "Target: ${PR_DEST}"
  echo "Status: DRAFT"
  echo "---"
else
  MSG=$(jq -r '.error.message // .error // .message // empty' "$TMPBODY" 2>/dev/null)
  echo "ERROR: Bitbucket API returned HTTP ${STATUS}" >&2
  [[ -n "$MSG" ]] && echo "Detail: ${MSG}" >&2
  exit 1
fi
