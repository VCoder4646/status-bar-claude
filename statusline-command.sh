#!/usr/bin/env bash
input=$(cat)

# ── parse everything in a single jq pass ─────────────────────────────
IFS=$'\x1f' read -r cwd model ctx_pct hour_pct week_pct hour_reset week_reset sid <<EOF
$(echo "$input" | jq -r '[
  (.workspace.current_dir // .cwd // ""),
  (.model.display_name // ""),
  ((.context_window.used_percentage // "") | tostring),
  (((.rate_limits["5h"] // .rate_limits.five_hour // .rate_limits.hour // {}).used_percentage // "") | tostring),
  (((.rate_limits["7d"] // .rate_limits.seven_day // .rate_limits.week // {}).used_percentage // "") | tostring),
  (((.rate_limits["5h"] // .rate_limits.five_hour // .rate_limits.hour // {}).resets_at // "") | tostring),
  (((.rate_limits["7d"] // .rate_limits.seven_day // .rate_limits.week // {}).resets_at // "") | tostring),
  (.session_id // "")
] | join("\u001f")')
EOF

dir=$(basename "$cwd")
now=$(date +%s)
[[ "$hour_reset" =~ ^[0-9]+$ ]] || hour_reset=""
[[ "$week_reset" =~ ^[0-9]+$ ]] || week_reset=""

# ── colors ───────────────────────────────────────────────────────────
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

case "${COLORTERM:-}" in
  truecolor|24bit) TRUECOLOR=1; EMPTY_C="${ESC}[38;2;70;70;70m" ;;
  *)               TRUECOLOR=0; EMPTY_C="${ESC}[38;5;238m" ;;
esac

EIGHTH=("" ▏ ▎ ▍ ▌ ▋ ▊ ▉)
SPARKCH=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
PAL256=(46 82 118 154 190 226 220 214 208 202 196)

# ── helpers ──────────────────────────────────────────────────────────
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

pct_color() { # sets PC
  if   (( $1 >= 90 )); then PC=$BOLD_RED
  elif (( $1 >= 75 )); then PC=$RED
  elif (( $1 >= 50 )); then PC=$YELLOW
  else                      PC=$CYAN
  fi
}

cell_color() { # $1=cell index, $2=bar width → sets CC (green→yellow→red gradient)
  local i=$1 w=$2 den t u r g b
  den=$(( w > 1 ? w - 1 : 1 ))
  t=$(( i * 1000 / den ))
  if (( TRUECOLOR )); then
    if (( t <= 500 )); then
      u=$(( t * 2 ))
      r=$(( 240 * u / 1000 )); g=200; b=$(( 80 * (1000 - u) / 1000 ))
    else
      u=$(( (t - 500) * 2 ))
      r=$(( (240 * (1000 - u) + 230 * u) / 1000 ))
      g=$(( (200 * (1000 - u) + 60 * u) / 1000 ))
      b=$(( 50 * u / 1000 ))
    fi
    CC="${ESC}[38;2;${r};${g};${b}m"
  else
    CC="${ESC}[38;5;${PAL256[$(( t / 100 ))]}m"
  fi
}

build_bar() { # $1=pct, $2=width → sets BAR (sub-cell resolution via eighth blocks)
  local pct=$1 w=$2 e8 full rem i
  e8=$(( pct * w * 8 / 100 ))
  full=$(( e8 / 8 )); rem=$(( e8 % 8 ))
  (( pct > 0 && e8 == 0 )) && rem=1
  BAR=""
  for (( i = 0; i < w; i++ )); do
    if (( i < full )); then
      cell_color "$i" "$w"; BAR+="${CC}█"
    elif (( i == full && rem > 0 )); then
      cell_color "$i" "$w"; BAR+="${CC}${EIGHTH[$rem]}"
    else
      BAR+="${EMPTY_C}░"
    fi
  done
  BAR+=$RESET
}

meter() { # $1=label, $2=pct → sets METER (alert chip at ≥90%)
  local label=$1 pct=$2 barstr=""
  pct_color "$pct"
  if (( BAR_W > 0 )); then build_bar "$pct" "$BAR_W"; barstr=" $BAR"; fi
  if (( pct >= 90 )); then
    METER="${DIM}${label}${RESET}${barstr} ${ALERT}⚠ ${pct}%${RESET}"
  else
    METER="${DIM}${label}${RESET}${barstr} ${PC}${pct}%${RESET}"
  fi
}

cd_color() { # $1=remaining secs, $2=window secs → sets CDC (urgency as countdown drains)
  local p=$(( $1 * 100 / $2 ))
  if   (( p >= 50 )); then CDC=$GREEN
  elif (( p >= 25 )); then CDC=$CYAN
  elif (( p >= 10 )); then CDC=$YELLOW
  else                     CDC=$RED
  fi
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

# ── normalized percentages ───────────────────────────────────────────
ctx_i="";  [ -n "$ctx_pct" ]  && ctx_i=$(to_pct "$ctx_pct")
hour_i=""; [ -n "$hour_pct" ] && hour_i=$(to_pct "$hour_pct")
week_i=""; [ -n "$week_pct" ] && week_i=$(to_pct "$week_pct")

# ── git: branch + dirty + ahead/behind in one invocation ─────────────
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

# ── state: history for sparkline, burn rate, exhaustion projection ───
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
[ -z "$sid" ] && sid=$(printf '%s' "$cwd" | cksum | cut -d' ' -f1)
STATE="$STATE_DIR/state-$sid"
mkdir -p "$STATE_DIR" 2>/dev/null

if [ -n "$ctx_i$hour_i" ] && [ -d "$STATE_DIR" ]; then
  last_ts=$(tail -n 1 "$STATE" 2>/dev/null | cut -d' ' -f1)
  [[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0
  if (( now - last_ts >= 30 )); then
    echo "$now ${ctx_i:--} ${hour_i:--}" >> "$STATE"
    if (( $(wc -l < "$STATE") > 80 )); then
      tail -n 60 "$STATE" > "$STATE.tmp" 2>/dev/null && mv "$STATE.tmp" "$STATE"
    fi
  fi
fi

hist=() old_ts="" old_hour=""
if [ -f "$STATE" ]; then
  while read -r ts c h; do
    [[ "$ts" =~ ^[0-9]+$ ]] || continue
    [ "$c" != "-" ] && hist+=("$c")
    # burn-rate baseline: latest sample at least 5 min old (short windows
    # extrapolate noise — a 1% tick over 30s reads as 120%/hr)
    if [ "$h" != "-" ] && (( now - ts >= 300 )); then old_ts=$ts; old_hour=$h; fi
  done < "$STATE"
fi

# sparkline of recent context usage (needs ≥2 samples)
spark=""
n=${#hist[@]}
if (( n >= 2 )); then
  start=$(( n > 8 ? n - 8 : 0 ))
  for (( i = start; i < n; i++ )); do
    v=${hist[i]}
    pct_color "$v"
    spark+="${PC}${SPARKCH[$(( v * 7 / 100 ))]}"
  done
  spark+=$RESET
fi

# burn rate (pct/hour) → trend arrow + projected exhaustion before reset
trend="" will_exhaust=0
if [ -n "$old_hour" ] && [ -n "$hour_i" ] && (( now > old_ts )); then
  delta=$(( hour_i - old_hour ))
  rate=$(( delta * 3600 / (now - old_ts) ))
  if   (( rate >= 15 )); then trend="↑↑"
  elif (( rate >= 5 ));  then trend="↑"
  fi
  # warn only on a sustained, clearly-measured burn (≥2% over the baseline);
  # integer percentages make single-tick rates pure quantization noise
  if [ -n "$hour_reset" ] && (( hour_reset > now )) && (( delta >= 2 )); then
    proj=$(( hour_i + rate * (hour_reset - now) / 3600 ))
    (( proj >= 100 && hour_i < 100 )) && will_exhaust=1
  fi
fi

# ── terminal width detection ─────────────────────────────────────────
# Claude Code sets COLUMNS for the statusline process; fall back to the
# controlling tty, then walk up ancestor processes to find the real
# terminal (the statusline script itself runs without a tty).
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
if ! [[ "$cols" =~ ^[0-9]+$ ]] || [ "$cols" -le 0 ]; then
  cols=80   # conservative: better to show less than overflow into "…"
fi

# margin for Claude Code's own padding around the statusline
PAD=${CLAUDE_STATUSLINE_PAD:-4}

vis_len() { # visible length: ANSI stripped, multibyte-aware
  printf '%s' "$1" | sed "s/${ESC}\[[0-9;]*m//g" | wc -m
}

# ── render at a degradation level; auto-fit picks the first that fits ─
render() { # $1=level → sets OUT
  local lvl=$1 name_max sep
  local show_spark=0 show_cd=0 show_wcd=0 show_abs=0 show_7d=0 show_branch=0 show_5h=0 show_model=1
  case $lvl in
    0)  BAR_W=8; name_max=24; show_spark=1 show_cd=1 show_wcd=1 show_abs=1 show_7d=1 show_branch=1 show_5h=1 ;;
    1)  BAR_W=6; name_max=20; show_spark=1 show_cd=1 show_wcd=1 show_7d=1 show_branch=1 show_5h=1 ;;
    2)  BAR_W=6; name_max=18; show_cd=1 show_wcd=1 show_7d=1 show_branch=1 show_5h=1 ;;
    3)  BAR_W=4; name_max=16; show_cd=1 show_wcd=1 show_7d=1 show_branch=1 show_5h=1 ;;
    4)  BAR_W=0; name_max=14; show_cd=1 show_wcd=1 show_7d=1 show_branch=1 show_5h=1 ;;
    5)  BAR_W=0; name_max=12; show_cd=1 show_7d=1 show_branch=1 show_5h=1 ;;
    6)  BAR_W=0; name_max=12; show_7d=1 show_branch=1 show_5h=1 ;;
    7)  BAR_W=0; name_max=10; show_branch=1 show_5h=1 ;;
    8)  BAR_W=0; name_max=10; show_5h=1 ;;
    9)  BAR_W=0; name_max=10 ;;
    10) BAR_W=0; name_max=10; show_model=0 ;;
  esac
  if (( BAR_W > 0 )); then sep="  ${DIM}│${RESET}  "; else sep="  "; fi

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
    if [ -n "$model" ]; then OUT+="${sep}${WHITE}${model}${RESET}"
    else OUT+="${sep}${DIM}claude${RESET}"
    fi
  fi
  if [ -n "$ctx_i" ]; then
    meter ctx "$ctx_i"
    OUT+="${sep}${METER}"
    (( show_spark )) && [ -n "$spark" ] && OUT+=" ${spark}"
  fi
  if [ -n "$hour_i" ] && (( show_5h )); then
    meter 5h "$hour_i"
    OUT+="${sep}${METER}"
    [ -n "$trend" ] && OUT+=" ${RED}${trend}${RESET}"
    if [ -n "$hour_reset" ] && (( show_cd )) && (( hour_reset > now )); then
      local abs
      cd_color $(( hour_reset - now )) 18000
      (( will_exhaust )) && CDC=$BOLD_RED
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

# last resort for ultra-narrow terminals: bare truncated dir
if (( $(vis_len "$OUT") > cols - PAD )); then
  max=$(( cols - PAD ))
  (( max < 1 )) && max=1
  OUT="${BOLD_WHITE}$(trunc "$dir" "$max")${RESET}"
fi

printf '%s' "$OUT"
