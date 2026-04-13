#!/usr/bin/env bash
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_NAME="jira-fix"

echo ""
echo "  jira-fix-skill installer"
echo "  ========================"
echo ""

PATHS=()
LABELS=()

[[ -d "$HOME/.cursor" ]] && { PATHS+=("$HOME/.cursor/skills/$SKILL_NAME"); LABELS+=("Cursor (global)"); }
[[ -d "$HOME/.claude" ]] && { PATHS+=("$HOME/.claude/skills/$SKILL_NAME"); LABELS+=("Claude Code (global)"); }
[[ -d "$HOME/.codex" ]] && { PATHS+=("$HOME/.codex/skills/$SKILL_NAME"); LABELS+=("Codex CLI (global)"); }
PATHS+=(".agents/skills/$SKILL_NAME")
LABELS+=("Project (.agents/)")

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

  mkdir -p "$dest/scripts"
  cp "$PKG_DIR/SKILL.md" "$dest/"
  cp "$PKG_DIR/.env.example" "$dest/"
  cp "$PKG_DIR/scripts/jira-api.sh" "$dest/scripts/"
  cp "$PKG_DIR/scripts/bb-pr.sh" "$dest/scripts/"
  chmod +x "$dest/scripts/"*.sh

  if [[ ! -f "$dest/.env" ]]; then
    cp "$PKG_DIR/.env.example" "$dest/.env"
    chmod 600 "$dest/.env"
  fi

  echo "  ✓ Installed to $dest ($label)"
}

echo ""
for idx in "${SELECTED_IDX[@]}"; do
  install_to "${PATHS[$idx]}" "${LABELS[$idx]}"
done

echo ""
echo "  Next steps:"
echo "    1. Edit .env in the install directory (fill in your tokens)"
echo "    2. See README for token creation: https://github.com/Leon-Kang/jira-fix-skill"
echo "    3. Tell your AI agent: \"show my tickets\""
echo ""
