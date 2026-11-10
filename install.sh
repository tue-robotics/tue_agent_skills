#!/usr/bin/env bash
# Symlink every skill in this repo's skills/ directory into each agent CLI's
# skills directory:
#   ~/.agents/skills/  the cross-runtime directory read by Codex, Copilot CLI and
#                      Gemini CLI
#   ~/.claude/skills/  Claude Code's personal skills directory
# Safe to re-run: skips skills already correctly linked, warns (without touching
# anything) if the target exists and is something else.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skills_src="${repo_dir}/skills"
skills_dests=(
  "${HOME}/.agents/skills"
  "${HOME}/.claude/skills"
)

for skills_dest in "${skills_dests[@]}"; do
  mkdir -p "${skills_dest}"

  for skill_path in "${skills_src}"/*/; do
    skill_name="$(basename "${skill_path}")"
    dest="${skills_dest}/${skill_name}"
    src="${skills_src}/${skill_name}"

    if [ -L "${dest}" ] && [ "$(readlink -f "${dest}")" = "$(readlink -f "${src}")" ]; then
      echo "ok:      ${skill_name} -> ${dest} (already linked)"
    elif [ -e "${dest}" ] || [ -L "${dest}" ]; then
      echo "skip:    ${skill_name} (${dest} exists and is not a link to this repo)"
    else
      ln -s "${src}" "${dest}"
      echo "linked:  ${skill_name} -> ${dest}"
    fi
  done
done
