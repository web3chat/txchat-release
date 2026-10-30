#!/bin/bash
# 可靠进度输出：每个模块单独占一行，绝不与 docker/go 日志混在同一行。
#
#   source progress.sh
#   init_sticky_progress
#   draw_progress <cur> <total> <phase> <module>
#   run_with_progress <cur> <total> <phase> <module> -- <cmd> [args...]
#   finish_sticky_progress

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
fi

_progress_colors() {
  if [[ -t 1 ]]; then
    C_CYAN=$'\033[38;5;51m'
    C_GREEN=$'\033[38;5;46m'
    C_YELLOW=$'\033[38;5;226m'
    C_RED=$'\033[31m'
    C_DIM=$'\033[2m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
  else
    C_CYAN="" C_GREEN="" C_YELLOW="" C_RED="" C_DIM="" C_BOLD="" C_RESET=""
  fi
}

init_sticky_progress() {
  _progress_colors
  printf '\n%s━━━━━━━━━━━━━━━━ progress ━━━━━━━━━━━━━━━━%s\n' "${C_DIM}" "${C_RESET}"
}

finish_sticky_progress() {
  _progress_colors
  printf '%s━━━━━━━━━━━━━━━━ complete ━━━━━━━━━━━━━━━━%s\n\n' "${C_DIM}" "${C_RESET}"
}

draw_progress() {
  local cur="${1:-0}"
  local total="${2:-1}"
  local phase="${3:-work}"
  local module="${4:-...}"
  local width=28
  local percent filled empty bar i

  if [[ "${total}" -le 0 ]]; then total=1; fi
  if [[ "${cur}" -lt 0 ]]; then cur=0; fi
  if [[ "${cur}" -gt "${total}" ]]; then cur="${total}"; fi

  percent=$((cur * 100 / total))
  filled=$((cur * width / total))
  empty=$((width - filled))
  bar=""
  for ((i = 0; i < filled; i++)); do bar+="█"; done
  for ((i = 0; i < empty; i++)); do bar+="░"; done

  _progress_colors
  printf '\r\033[2K%s[%s%s%s] %s%3d%%%s  %s[%d/%d]%s  %s%s%s → %s%s%s\n' \
    "${C_DIM}" "${C_CYAN}" "${bar}" "${C_DIM}" \
    "${C_YELLOW}${C_BOLD}" "${percent}" "${C_RESET}" \
    "${C_GREEN}" "${cur}" "${total}" "${C_RESET}" \
    "${C_BOLD}" "${phase}" "${C_RESET}" \
    "${C_CYAN}" "${module}" "${C_RESET}"
}

run_with_progress() {
  local cur="$1"
  local total="$2"
  local phase="$3"
  local module="$4"
  local st
  shift 4
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi

  draw_progress "${cur}" "${total}" "${phase}" "${module}"
  set +e
  "$@"
  st=$?
  set -e

  _progress_colors
  if [[ "${st}" -eq 0 ]]; then
    printf '%s✔%s %s → %s 完成 (%d/%d)\n' \
      "${C_GREEN}" "${C_RESET}" "${phase}" "${module}" "${cur}" "${total}"
  else
    printf '%s✘%s %s → %s 失败 exit=%d (%d/%d)\n' \
      "${C_RED}" "${C_RESET}" "${phase}" "${module}" "${st}" "${cur}" "${total}"
  fi
  return "${st}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  draw_progress "${1:-0}" "${2:-1}" "${3:-work}" "${4:-...}"
fi
