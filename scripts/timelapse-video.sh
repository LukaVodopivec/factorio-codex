#!/usr/bin/env bash
# Linux/macOS port of timelapse-video.ps1: joins the timelapse frames the mod
# saved (script-output/timelapse/<run>/frame_NNNNNN_t<tick>.jpg) into a video
# with ffmpeg. --every 2 keeps every second frame (twice as fast); --skip-idle
# drops frames where nothing changed. Frames the client could not render leave
# gaps in the numbering, so the frame list is read from disk.
# Each frame shows the time since the first frame (HH:MM:SS from its tick, at
# 60 ticks a second) at a fixed spot in a monospace font; --no-clock leaves it
# out. --captions names a JSON list of {"from": "H:MM:SS", "to": "H:MM:SS",
# "text": "..."} on that same clock: each frame in [from, to) gets the text,
# wrapped to two centred lines at the bottom, and the video goes to
# <run>-timelapse-captions.mp4 so the plain video is kept. The frames
# themselves are only read. Needs ffmpeg (with libx265, or libx264 for
# --x264), fc-match for the DejaVu fonts, and node for --captions.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/timelapse-video.sh [options] <frames-dir>

  <frames-dir>        a run's folder of frame_NNNNNN_t<tick>.jpg files
  --fps N             output frame rate (default 30)
  --every N           keep every Nth frame (default 1)
  --skip-idle         drop frames where nothing changed
  --no-clock          leave out the HH:MM:SS clock
  --captions FILE     burn timed captions from a JSON list into the video
  --out FILE          output path (default: next to <frames-dir>,
                      <run>-timelapse.mp4 or <run>-timelapse-captions.mp4)
  --x264              encode H.264 with libx264 instead of HEVC with libx265
EOF
}

die() { echo "timelapse-video: $*" >&2; exit 1; }

fps=30 every=1 skip_idle=0 no_clock=0 captions="" out="" x264=0 frames=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fps) [ $# -ge 2 ] || die "--fps needs a value"; fps=$2; shift 2 ;;
    --every) [ $# -ge 2 ] || die "--every needs a value"; every=$2; shift 2 ;;
    --skip-idle) skip_idle=1; shift ;;
    --no-clock) no_clock=1; shift ;;
    --captions) [ $# -ge 2 ] || die "--captions needs a file"; captions=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || die "--out needs a path"; out=$2; shift 2 ;;
    --x264) x264=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option $1" ;;
    *) [ -z "$frames" ] || die "only one frames directory may be given"; frames=$1; shift ;;
  esac
done
[ -n "$frames" ] || { usage >&2; exit 1; }
[ -d "$frames" ] || die "no timelapse frames directory: $frames"
[[ $fps =~ ^[0-9]+$ && $every =~ ^[0-9]+$ && $fps -ge 1 && $every -ge 1 ]] || die "--fps and --every must be whole numbers of at least 1"
[ -z "$captions" ] || [ -f "$captions" ] || die "no captions file: $captions"
command -v ffmpeg >/dev/null || die "ffmpeg is not installed"

frames=$(cd "$frames" && pwd -P)
run=$(basename "$frames")
if [ -z "$out" ]; then
  suffix=""; [ -z "$captions" ] || suffix="-captions"
  out="$(dirname "$frames")/$run-timelapse$suffix.mp4"
fi

# Byte order, whatever the caller's locale, like a sorted directory listing.
saved_lc_all=${LC_ALL-unset}
LC_ALL=C
shopt -s nullglob
files=("$frames"/frame_*.jpg)
shopt -u nullglob
if [ "$saved_lc_all" = unset ]; then unset LC_ALL; else LC_ALL=$saved_lc_all; fi
[ ${#files[@]} -gt 0 ] || die "no frame_*.jpg files in $frames"
kept=()
for ((i = 0; i < ${#files[@]}; i += every)); do kept+=("${files[i]}"); done

pattern='^frame_[0-9]+_t([0-9]+)\.jpg$'
timed=0
if [ "$no_clock" -eq 0 ] || [ -n "$captions" ]; then timed=1; fi
tick_of() { # sets $tick from a frame path
  local name=${1##*/}
  [[ $name =~ $pattern ]] || die "$name has no tick in its name; the clock and captions need it"
  tick=$((10#${BASH_REMATCH[1]}))
}
t0=0
if [ "$timed" -eq 1 ]; then
  for f in "${kept[@]}"; do tick_of "$f"; done
  tick_of "${kept[0]}"; t0=$tick
fi

seconds() { # sets $secs from H:MM:SS
  [[ $1 =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]] || die "caption time '$1' is not H:MM:SS"
  secs=$((10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]}))
}
# Two lines of at most 90 characters, split at spaces; sets $line1 and $line2.
wrap() {
  local text=$1 word count=1
  local -a words
  line1="" line2=""
  read -r -a words <<<"$text" || true
  for word in ${words[@]+"${words[@]}"}; do
    if [ "$count" -eq 1 ]; then
      if [ -n "$line1" ] && [ $((${#line1} + 1 + ${#word})) -gt 90 ]; then count=2; line2=$word
      else line1="${line1:+$line1 }$word"; fi
    else
      if [ -n "$line2" ] && [ $((${#line2} + 1 + ${#word})) -gt 90 ]; then die "caption longer than two 90-character lines: $text"
      else line2="${line2:+$line2 }$word"; fi
    fi
  done
}
chapter_from=() chapter_to=() chapter_top=() chapter_bottom=()
if [ -n "$captions" ]; then
  command -v node >/dev/null || die "--captions needs node to read the JSON file"
  # node prints from, to and text of each caption, each ended by a NUL byte.
  caption_fields=$(mktemp "${TMPDIR:-/tmp}/timelapse-captions.XXXXXX")
  trap 'rm -f "$caption_fields"' EXIT
  # shellcheck disable=SC2016 # the JavaScript is meant to stay unexpanded
  node -e '
    try {
      const list = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      if (!Array.isArray(list)) throw new Error("captions must be a JSON list");
      for (const c of list) for (const k of ["from", "to", "text"]) {
        if (typeof c?.[k] !== "string") throw new Error(`caption field ${k} must be a string`);
        process.stdout.write(c[k].replace(/\0/g, "") + "\0");
      }
    } catch (error) { console.error(`timelapse-video: ${error.message}`); process.exit(1); }
  ' "$captions" >"$caption_fields" || die "cannot read captions from $captions"
  while IFS= read -r -d '' from && IFS= read -r -d '' to && IFS= read -r -d '' text; do
    seconds "$from"; chapter_from+=("$secs")
    seconds "$to"; chapter_to+=("$secs")
    wrap "$text"
    # A one-line caption sits on the bottom line.
    if [ -n "$line2" ]; then chapter_top+=("$line1"); chapter_bottom+=("$line2")
    else chapter_top+=(""); chapter_bottom+=("$line1"); fi
  done <"$caption_fields"
fi

# ffconcat strings: single-quoted, a quote written as '\''.
quote() { local q="'\\''"; printf "'%s'" "${1//\'/$q}"; }
duration=$(awk -v f="$fps" 'BEGIN { printf "%.10f", 1 / f }')
entry() {
  printf 'file %s\nduration %s\n' "$(quote "$1")" "$duration"
  [ "$timed" -eq 1 ] || return 0
  tick_of "$1"
  local s=$(((tick - t0) / 60)) c
  if [ "$no_clock" -eq 0 ]; then
    printf 'file_packet_meta clock %02d:%02d:%02d\n' $((s / 3600)) $((s / 60 % 60)) $((s % 60))
  fi
  for ((c = 0; c < ${#chapter_from[@]}; c++)); do
    if [ "$s" -ge "${chapter_from[c]}" ] && [ "$s" -lt "${chapter_to[c]}" ]; then
      [ -z "${chapter_top[c]}" ] || printf 'file_packet_meta caption1 %s\n' "$(quote "${chapter_top[c]}")"
      printf 'file_packet_meta caption2 %s\n' "$(quote "${chapter_bottom[c]}")"
      break
    fi
  done
}
list=$(mktemp "${TMPDIR:-/tmp}/timelapse-frames.XXXXXX")
trap 'rm -f "$list" ${caption_fields:+"$caption_fields"}' EXIT
{
  echo "ffconcat version 1.0"
  for f in "${kept[@]}"; do entry "$f"; done
  # The concat demuxer ignores the last entry's duration unless the file repeats.
  entry "${kept[${#kept[@]} - 1]}"
} >"$list"

font() { # prints the font file fc-match finds for a pattern
  command -v fc-match >/dev/null || die "fc-match (fontconfig) is needed to find the $1 font"
  local file
  file=$(fc-match -f '%{file}' "$1")
  [ -f "$file" ] || die "no font file found for $1"
  case "$file" in *[\',:\\]*) die "font path $file needs escaping; install DejaVu fonts in a plain path" ;; esac
  case "$file" in *DejaVu*) ;; *) echo "timelapse-video: $1 not installed, using $file" >&2 ;; esac
  printf '%s' "$file"
}

# The list's durations set the pace; --skip-idle then re-times what is left.
# Text is drawn after mpdecimate, or its changing clock digits would keep
# every frame; DejaVu Sans Mono Bold is monospace, so the digits never shift.
# A frame without a caption line draws neither text nor box.
chain=()
[ "$skip_idle" -eq 0 ] || chain+=("mpdecimate,setpts=N/($fps*TB)")
if [ "$no_clock" -eq 0 ]; then
  mono=$(font "DejaVu Sans Mono:bold")
  chain+=("drawtext=fontfile='$mono':text='%{metadata\\:clock}':fontsize=120:fontcolor=white:borderw=5:bordercolor=black:box=1:boxcolor=black@0.55:boxborderw=24:x=192:y=108")
fi
if [ -n "$captions" ]; then
  sans=$(font "DejaVu Sans")
  style="fontfile='$sans':fontsize=68:fontcolor=white:box=1:boxcolor=black@0.65:boxborderw=22:x=(w-tw)/2"
  chain+=("drawtext=$style:text='%{metadata\\:caption1}':y=h-330")
  chain+=("drawtext=$style:text='%{metadata\\:caption2}':y=h-230")
fi
filter=()
if [ ${#chain[@]} -gt 0 ]; then
  joined=$(IFS=,; printf '%s' "${chain[*]}")
  filter=(-vf "$joined")
fi

if [ "$x264" -eq 1 ]; then codec=(-c:v libx264 -preset medium -crf 20)
else codec=(-c:v libx265 -preset medium -crf 20 -tag:v hvc1); fi
encoder=${codec[1]}
encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null) || die "cannot list ffmpeg encoders"
case "$encoders" in
  *" $encoder "*) ;;
  *) hint=""; [ "$x264" -eq 1 ] || hint="; try --x264"; die "this ffmpeg has no $encoder encoder$hint" ;;
esac

ffmpeg -hide_banner -loglevel warning -stats -y -f concat -safe 0 -i "$list" \
  ${filter[@]+"${filter[@]}"} -r "$fps" "${codec[@]}" -pix_fmt yuv420p "$out" ||
  die "ffmpeg failed with exit code $?"
seconds_out=$(awk -v n="${#kept[@]}" -v f="$fps" 'BEGIN { printf "%.1f", n / f }')
echo "${#kept[@]} frames of ${#files[@]} -> $out ($seconds_out s at $fps fps)"
