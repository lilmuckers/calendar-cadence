#!/usr/bin/env bash
# Joins screen recordings into one captioned 1080p video for Google's OAuth verification.
#
#   scripts/verification-video/assemble.sh <clips-dir> [out.mp4]
#
# <clips-dir>/shots.txt lists the video in order, one shot per line ("#" lines and blank lines are skipped):
#   card | Cadence\nGoogle OAuth verification demo        a 4-second title card (\n = new line)
#   01-signin.mov | Sign-in: consent screen               a clip with a caption along the bottom
#   02-list.mov | calendar.readonly: meetings | 3 | 21    …trimmed to seconds 3–21
#   03-extra.mov |                                        no caption
# Clips can be any size or orientation (Mac ⌘⇧5 recordings, Simulator recordings); each is fitted
# into 1920×1080 on black (above the caption band when there is a caption). Audio is dropped.
set -euo pipefail

dir=${1:?usage: assemble.sh <clips-dir> [out.mp4]}
out=${2:-$dir/cadence-oauth-demo.mp4}
here=$(cd "$(dirname "$0")" && pwd)
manifest=$dir/shots.txt
[[ -f $manifest ]] || { echo "No $manifest" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "Needs ffmpeg (brew install ffmpeg)" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-video.XXXXXX")
trap 'rm -rf "$work"' EXIT
# Compile the caption renderer once rather than interpreting it per shot.
swiftc -O -o "$work/caption" "$here/caption.swift" 2>/dev/null

trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
fit="scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps=30"
# With a caption, the video sits in the top 920 px so the caption band below never covers the app.
fitcap="scale=1920:920:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(920-ih)/2:black,setsar=1,fps=30"
enc=(-c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -an -loglevel error -y)

n=0
: > "$work/list.txt"
while IFS='|' read -r file caption start end || [[ -n ${file:-} ]]; do
    file=$(trim "${file:-}"); caption=$(trim "${caption:-}"); start=$(trim "${start:-}"); end=$(trim "${end:-}")
    [[ -z $file || $file == \#* ]] && continue
    n=$((n + 1))
    seg=$work/$(printf '%03d' $n).mp4
    if [[ $file == card ]]; then
        "$work/caption" card "$caption" "$work/$n.png"
        ffmpeg -nostdin -loop 1 -t 4 -i "$work/$n.png" -vf "fps=30,format=yuv420p" "${enc[@]}" "$seg"
        echo "  $n. card: ${caption%%\\n*}"
    else
        [[ -f $dir/$file ]] || { echo "Missing clip: $dir/$file" >&2; exit 1; }
        range=()
        [[ -n $start ]] && range+=(-ss "$start")
        [[ -n $end ]] && range+=(-to "$end")
        if [[ -n $caption ]]; then
            "$work/caption" lower "$caption" "$work/$n.png"
            ffmpeg -nostdin ${range[@]+"${range[@]}"} -i "$dir/$file" -i "$work/$n.png" \
                -filter_complex "[0:v]$fitcap[v];[v][1:v]overlay=0:0,format=yuv420p" "${enc[@]}" "$seg"
        else
            ffmpeg -nostdin ${range[@]+"${range[@]}"} -i "$dir/$file" -vf "$fit,format=yuv420p" "${enc[@]}" "$seg"
        fi
        echo "  $n. $file${caption:+ — $caption}"
    fi
    echo "file '$seg'" >> "$work/list.txt"
done < "$manifest"

ffmpeg -nostdin -f concat -safe 0 -i "$work/list.txt" -c copy -movflags +faststart -loglevel error -y "$out"
secs=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out")
printf 'Wrote %s (%.0f s)\n' "$out" "$secs"
