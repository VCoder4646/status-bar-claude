#!/usr/bin/env bash
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
input=$(cat)

IFS=$'\x1f' read -r cwd model ctx_pct hour_pct week_pct hour_reset week_reset <<EOF
$(echo "$input" | jq -r '[
  (.workspace.current_dir // .cwd // ""),
  (.model.display_name // ""),
  ((.context_window.used_percentage // "") | tostring),
  (((.rate_limits["5h"] // .rate_limits.five_hour // .rate_limits.hour // {}).used_percentage // "") | tostring),
  (((.rate_limits["7d"] // .rate_limits.seven_day // .rate_limits.week // {}).used_percentage // "") | tostring),
  (((.rate_limits["5h"] // .rate_limits.five_hour // .rate_limits.hour // {}).resets_at // "") | tostring),
  (((.rate_limits["7d"] // .rate_limits.seven_day // .rate_limits.week // {}).resets_at // "") | tostring)
] | join("\u001f")')
EOF

dir=$(basename "$cwd")
now=$(date +%s)
[[ "$hour_reset" =~ ^[0-9]+$ ]] || hour_reset=""
[[ "$week_reset" =~ ^[0-9]+$ ]] || week_reset=""

ESC=$'\033'
RESET="${ESC}[0m"
DIM="${ESC}[2;37m"
WHITE="${ESC}[0;37m"
BOLD_WHITE="${ESC}[1;37m"
GREEN="${ESC}[0;32m"
CYAN="${ESC}[0;36m"
YELLOW="${ESC}[0;33m"
RED="${ESC}[0;31m"
BOLD_RED="${ESC}[1;31m"
ALERT="${ESC}[1;31m"

to_pct() {
  local v
  v=$(LC_ALL=C printf '%.0f' "$1" 2>/dev/null)
  [ -z "$v" ] && v=${1%%.*}
  [[ "$v" =~ ^-?[0-9]+$ ]] || v=0
  [ "$v" -lt 0 ] && v=0
  [ "$v" -gt 100 ] && v=100
  printf '%s' "$v"
}

trunc() {
  local s=$1 m=$2
  if (( ${#s} > m )); then printf '%s…' "${s:0:m-1}"; else printf '%s' "$s"; fi
}

fmt_dur() {
  local s=$1
  if   (( s >= 86400 )); then printf '%dd%dh' $(( s / 86400 )) $(( s % 86400 / 3600 ))
  elif (( s >= 3600 ));  then printf '%dh%02dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
  elif (( s >= 60 ));    then printf '%dm' $(( s / 60 ))
  else                        printf '<1m'
  fi
}

format_reset_time() {
  local epoch=$1 hhmm
  hhmm=$(date -r "$epoch" "+%l:%M %p" 2>/dev/null || date -d "@$epoch" "+%l:%M %p" 2>/dev/null)
  [ -z "$hhmm" ] && return 1
  hhmm="${hhmm# }"
  local hour=${hhmm%%:*} rest=${hhmm#*:}
  local mins=${rest%% *} ampm=${rest##* }
  ampm=$(printf '%s' "$ampm" | tr '[:upper:]' '[:lower:]')
  if [ "$mins" = "00" ]; then printf '%s%s' "$hour" "$ampm"
  else printf '%s:%s%s' "$hour" "$mins" "$ampm"
  fi
}

pct_color() {
  if   (( $1 >= 90 )); then PC=$BOLD_RED
  elif (( $1 >= 75 )); then PC=$RED
  elif (( $1 >= 50 )); then PC=$YELLOW
  else                      PC=$CYAN
  fi
}

cd_color() {
  local p=$(( $1 * 100 / $2 ))
  if   (( p >= 50 )); then CDC=$GREEN
  elif (( p >= 25 )); then CDC=$CYAN
  elif (( p >= 10 )); then CDC=$YELLOW
  else                     CDC=$RED
  fi
}

EIGHTH=("" ▏ ▎ ▍ ▌ ▋ ▊ ▉)

build_bar() {
  local pct=$1 w=$2 e8 full rem i
  e8=$(( pct * w * 8 / 100 ))
  full=$(( e8 / 8 )); rem=$(( e8 % 8 ))
  (( pct > 0 && e8 == 0 )) && rem=1
  BAR=""
  for (( i = 0; i < w; i++ )); do
    if (( i < full )); then
      BAR+="${WHITE}█"
    elif (( i == full && rem > 0 )); then
      BAR+="${WHITE}${EIGHTH[$rem]}"
    else
      BAR+="${DIM}░${RESET}"
    fi
  done
  BAR+=$RESET
}

meter() {
  local label=$1 pct=$2 barstr=""
  pct_color "$pct"
  if (( BAR_W > 0 )); then build_bar "$pct" "$BAR_W"; barstr=" $BAR"; fi
  if (( pct >= 90 )); then
    METER="${DIM}${label}${RESET}${barstr} ${ALERT}⚠ ${pct}%${RESET}"
  else
    METER="${DIM}${label}${RESET}${barstr} ${PC}${pct}%${RESET}"
  fi
}

ctx_i="";  [ -n "$ctx_pct" ]  && ctx_i=$(to_pct "$ctx_pct")
hour_i=""; [ -n "$hour_pct" ] && hour_i=$(to_pct "$hour_pct")
week_i=""; [ -n "$week_pct" ] && week_i=$(to_pct "$week_pct")

# ── shared cache — all windows converge ──────────────────────────────
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
CACHE="$CACHE_DIR/cache"
mkdir -p "$CACHE_DIR" 2>/dev/null

if [ -f "$CACHE" ]; then
  read -r cache_ts cache_ctx cache_hour cache_week cache_hr cache_wr cache_model < "$CACHE" 2>/dev/null || cache_ts=0
else
  cache_ts=0
fi

if (( now - cache_ts > 30 )) || [ -z "${cache_ctx:-}" ]; then
  printf '%s\n' "$now $ctx_i $hour_i $week_i $hour_reset $week_reset $model" > "$CACHE.tmp"
  mv "$CACHE.tmp" "$CACHE" 2>/dev/null || true
  read -r cache_ts cache_ctx cache_hour cache_week cache_hr cache_wr cache_model < "$CACHE" 2>/dev/null || true
fi

if [ -n "${cache_ctx:-}" ]; then
  ctx_i=$cache_ctx
  hour_i=$cache_hour
  week_i=$cache_week
  [ -n "$cache_model" ] && model=$cache_model
  [[ "$cache_hr" =~ ^[0-9]+$ ]] && hour_reset=$cache_hr
  [[ "$cache_wr" =~ ^[0-9]+$ ]] && week_reset=$cache_wr
fi

# ── git ──────────────────────────────────────────────────────────────
branch="" dirty="" ab=""
[ -n "$cwd" ] && gs=$(git -C "$cwd" -c core.hooksPath=/dev/null status --porcelain=v2 --branch --untracked-files=no 2>/dev/null) && {
  branch=$(sed -n 's/^# branch\.head //p' <<<"$gs")
  [ "$branch" = "(detached)" ] && branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  abline=$(sed -n 's/^# branch\.ab //p' <<<"$gs")
  if [ -n "$abline" ]; then
    a=${abline%% *}; b=${abline##* }; a=${a#+}; b=${b#-}
    [ "$a" != 0 ] && ab+="↑$a"
    [ "$b" != 0 ] && ab+="↓$b"
  fi
  grep -q '^[^#]' <<<"$gs" && dirty=1
}

# ── terminal width ───────────────────────────────────────────────────
cols=${COLUMNS:-}
if ! [[ "$cols" =~ ^[0-9]+$ ]] || [ "$cols" -le 0 ]; then
  cols=$( (stty size < /dev/tty) 2>/dev/null | awk '{print $2}')
fi
if ! [[ "$cols" =~ ^[0-9]+$ ]] || [ "$cols" -le 0 ]; then
  pid=$PPID
  for _ in 1 2 3 4 5; do
    [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || break
    t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -n "$t" ] && [ "$t" != "?" ] && [ -r "/dev/$t" ]; then
      cols=$( (stty size < "/dev/$t") 2>/dev/null | awk '{print $2}')
      [[ "$cols" =~ ^[0-9]+$ ]] && [ "$cols" -gt 0 ] && break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
fi
! [[ "$cols" =~ ^[0-9]+$ ]] || [ "$cols" -le 0 ] && cols=80

PAD=${CLAUDE_STATUSLINE_PAD:-4}
vis_len() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g' | wc -m; }

render() {
  local lvl=$1 name_max sep
  local BAR_W=0 show_5h=1 show_7d=1 show_branch=1 show_cd=1 show_abs=1 show_wcd=1 show_model=1
  case $lvl in
    0)  BAR_W=8;  name_max=24; show_branch=1 show_5h=1 show_7d=1 show_cd=1 show_wcd=1 show_abs=1 show_model=1 ;;
    1)  BAR_W=6;  name_max=20; show_branch=1 show_5h=1 show_7d=1 show_cd=1 show_wcd=1 show_model=1 ;;
    2)  BAR_W=6;  name_max=18; show_branch=1 show_5h=1 show_7d=1 show_cd=1 show_wcd=1 ;;
    3)  BAR_W=4;  name_max=16; show_branch=1 show_5h=1 show_7d=1 show_cd=1 ;;
    4)  BAR_W=0;  name_max=14; show_branch=1 show_5h=1 show_7d=1 ;;
    5)  BAR_W=0;  name_max=12; show_branch=1 show_5h=1 show_7d=1 ;;
    6)  BAR_W=0;  name_max=12; show_branch=1 show_5h=1 ;;
    7)  BAR_W=0;  name_max=10; show_branch=1 show_5h=1 ;;
    8)  BAR_W=0;  name_max=10; show_5h=1 ;;
    9)  BAR_W=0;  name_max=10 ;;
    10) BAR_W=0;  name_max=10; show_model=0 ;;
  esac
  sep="  ${DIM}│${RESET}  "

  local d b
  d=$(trunc "$dir" "$name_max")
  b=$(trunc "$branch" "$name_max")

  OUT="${BOLD_WHITE}${d}${RESET}"
  if [ -n "$branch" ] && (( show_branch )); then
    OUT+=" ${DIM}⎇${RESET} ${GREEN}${b}${RESET}"
    [ -n "$dirty" ] && OUT+="${YELLOW}●${RESET}"
    [ -n "$ab" ] && OUT+=" ${DIM}${ab}${RESET}"
  fi
  if (( show_model )); then
    OUT+="${sep}${WHITE}${model:-claude}${RESET}"
  fi
  if [ -n "$ctx_i" ]; then
    meter ctx "$ctx_i"
    OUT+="${sep}${METER}"
  fi
  if [ -n "$hour_i" ] && (( show_5h )); then
    meter 5h "$hour_i"
    OUT+="${sep}${METER}"
    if [ -n "$hour_reset" ] && (( show_cd )) && (( hour_reset > now )); then
      cd_color $(( hour_reset - now )) 18000
      OUT+="  ${DIM}↻${RESET} ${CDC}$(fmt_dur $(( hour_reset - now )))${RESET}"
      if (( show_abs )); then
        abs=$(format_reset_time "$hour_reset") && [ -n "$abs" ] && OUT+=" ${DIM}(${abs})${RESET}"
      fi
    fi
  fi
  if [ -n "$week_i" ] && (( show_7d )); then
    meter 7d "$week_i"
    OUT+="${sep}${METER}"
    if [ -n "$week_reset" ] && (( show_wcd )) && (( week_reset > now )); then
      cd_color $(( week_reset - now )) 604800
      OUT+="  ${DIM}↻${RESET} ${CDC}$(fmt_dur $(( week_reset - now )))${RESET}"
    fi
  fi
}

for lvl in 0 1 2 3 4 5 6 7 8 9 10; do
  render "$lvl"
  (( $(vis_len "$OUT") <= cols - PAD )) && break
done

if (( $(vis_len "$OUT") > cols - PAD )); then
  max=$(( cols - PAD ))
  (( max < 1 )) && max=1
  OUT="${BOLD_WHITE}$(trunc "$dir" "$max")${RESET}"
fi

printf '%s' "$OUT"
