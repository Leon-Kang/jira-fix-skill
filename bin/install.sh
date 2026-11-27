#!/usr/bin/env bash
set -euo pipefail

# npx exposes this script as node_modules/.bin/jira-fix-skill, a symlink into the
# package. Follow the link first, or PKG_DIR lands in node_modules/ and every
# copy below fails.
SELF="${BASH_SOURCE[0]}"
while [[ -L "$SELF" ]]; do
  LINK_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
  SELF="$(readlink "$SELF")"
  [[ "$SELF" != /* ]] && SELF="${LINK_DIR}/${SELF}"
done
PKG_DIR="$(cd -P "$(dirname "$SELF")/.." && pwd)"
SKILL_NAME="jira-fix"

echo ""
echo "  jira-fix-skill installer"
echo "  ========================"
echo ""

PATHS=()
LABELS=()

[[ -d "$HOME/.cursor" ]] && { PATHS+=("$HOME/.cursor/skills/$SKILL_NAME"); LABELS+=("Cursor (global)"); }
[[ -d "$HOME/.claude" ]] && { PATHS+=("$HOME/.claude/skills/$SKILL_NAME"); LABELS+=("Claude Code (global)"); }
[[ -d "$HOME/.codex" ]]  && { PATHS+=("$HOME/.codex/skills/$SKILL_NAME"); LABELS+=("Codex CLI (global)"); }

GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -n "$GIT_ROOT" ]]; then
  PATHS+=("$GIT_ROOT/.agents/skills/$SKILL_NAME")
  LABELS+=("Project ($GIT_ROOT/.agents/)")
fi

if [[ ${#PATHS[@]} -eq 0 ]]; then
  echo "  No supported AI tool detected and not inside a git repo."
  echo "  Install manually: copy SKILL.md, .env.example, scripts/ to your skills directory."
  exit 1
fi

echo "  Install targets:"
echo ""
for i in "${!PATHS[@]}"; do
  echo "    $((i+1))) ${LABELS[$i]} → ${PATHS[$i]}"
done
echo "    a) All"
echo "    q) Quit"
echo ""

read -rp "  Choose [1-${#PATHS[@]}/a/q]: " choice

case "$choice" in
  q|Q) echo "  Cancelled."; exit 0 ;;
  a|A)
    SELECTED_IDX=($(seq 0 $((${#PATHS[@]}-1))))
    ;;
  *)
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#PATHS[@]} )); then
      SELECTED_IDX=($((choice-1)))
    else
      echo "  Invalid choice."; exit 1
    fi
    ;;
esac

install_to() {
  local dest="$1"
  local label="$2"
  local is_upgrade=false

  [[ -f "$dest/SKILL.md" ]] && is_upgrade=true

  mkdir -p "$dest/scripts"
  cp "$PKG_DIR/SKILL.md" "$dest/"
  cp "$PKG_DIR/.env.example" "$dest/"
  cp "$PKG_DIR/scripts/jira-api.sh" "$dest/scripts/"
  cp "$PKG_DIR/scripts/gh-pr.sh" "$dest/scripts/"
  chmod +x "$dest/scripts/"*.sh

  if [[ ! -f "$dest/.env" ]]; then
    cp "$PKG_DIR/.env.example" "$dest/.env"
    chmod 600 "$dest/.env"
  fi

  if $is_upgrade; then
    echo "  ↑ Upgraded $dest ($label) — .env preserved"
    if [[ -f "$dest/scripts/bb-pr.sh" ]]; then
      echo "    ! scripts/bb-pr.sh is obsolete (Bitbucket support was removed). Delete it when convenient."
    fi
    if grep -q '^BB_' "$dest/.env" 2>/dev/null; then
      echo "    ! .env still has BB_* entries. They are unused now and can be removed."
    fi
  else
    echo "  ✓ Installed to $dest ($label)"
  fi

  # A project install lands inside the user's repository, where .env is not ignored by default.
  if git -C "$dest" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && ! git -C "$dest" check-ignore -q .env; then
    printf '.env\n' >> "$dest/.gitignore"
    echo "    + Added .env to $dest/.gitignore so it is never committed"
  fi
}

echo ""
for idx in "${SELECTED_IDX[@]}"; do
  install_to "${PATHS[$idx]}" "${LABELS[$idx]}"
done

echo ""
echo "  Next steps:"
echo "    1. Set JIRA_URL in .env (and MAIN_BRANCH if you merge into something else)"
echo "    2. Authenticate GitHub: gh auth login --hostname YOUR_HOST --git-protocol ssh --web"
echo "    3. Jira goes through the Atlassian MCP — only fill in ATLASSIAN_EMAIL and"
echo "       ATLASSIAN_API_TOKEN if you do not have that MCP installed"
echo "    4. See README: https://github.com/Leon-Kang/jira-fix-skill"
echo "    5. Tell your AI agent: \"show my tickets\""
echo ""
