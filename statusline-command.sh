#!/usr/bin/env bash
input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')
model=$(echo "$input" | jq -r '.model.display_name')
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
hour_pct=$(echo "$input" | jq -r '(.rate_limits["5h"] // .rate_limits.five_hour // .rate_limits.hour).used_percentage // empty')
week_pct=$(echo "$input" | jq -r '(.rate_limits["7d"] // .rate_limits.seven_day // .rate_limits.week).used_percentage // empty')

dir=$(basename "$cwd")

RESET=$'\033[0m'
DIM=$'\033[2;37m'
WHITE=$'\033[0;37m'
BOLD_WHITE=$'\033[1;37m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
YELLOW=$'\033[0;33m'
RED=$'\033[0;31m'
BOLD_RED=$'\033[1;31m'

branch=""
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -C "$cwd" -c core.hooksPath=/dev/null symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
fi

build_bar() {
  local pct=$1
  local filled=$(( pct * 8 / 100 ))
  local color
  if   [ "$pct" -ge 90 ]; then color="$BOLD_RED"
  elif [ "$pct" -ge 75 ]; then color="$RED"
  elif [ "$pct" -ge 50 ]; then color="$YELLOW"
  else                          color="$CYAN"
  fi
  local i=1 result=""
  while [ $i -le 8 ]; do
    if [ $i -le $filled ]; then result="${result}${color}▊${RESET}"
    else                        result="${result}${DIM}▊${RESET}"
    fi
    i=$(( i + 1 ))
  done
  printf '%s' "$result"
}

out="${BOLD_WHITE}${dir}${RESET}"
[ -n "$branch" ] && out="${out}  ${GREEN}${branch}${RESET}"
if [ -n "$model" ]; then
  out="${out}  ${WHITE}${model}${RESET}"
else
  out="${out}  ${DIM}claude${RESET}"
fi

if [ -n "$ctx_pct" ]; then
  pct=$(printf "%.0f" "$ctx_pct")
  out="${out}  ${DIM}ctx${RESET} $(build_bar "$pct") ${WHITE}${pct}%${RESET}"
fi

if [ -n "$hour_pct" ]; then
  pct=$(printf "%.0f" "$hour_pct")
  out="${out}  ${DIM}5h${RESET} $(build_bar "$pct") ${WHITE}${pct}%${RESET}"
fi

if [ -n "$week_pct" ]; then
  pct=$(printf "%.0f" "$week_pct")
  out="${out}  ${DIM}7d${RESET} $(build_bar "$pct") ${WHITE}${pct}%${RESET}"
fi

printf '%s' "$out"
