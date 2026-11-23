#!/usr/bin/env bash
# Blurs one rectangle of a recording between two times, e.g. a password field and keyboard.
#
#   scripts/verification-video/blur.sh <in> <out> <start-s> <end-s> <x> <y> <w> <h>
#
# x/y/w/h are in the recording's own pixels (ffprobe shows its size). Run it once per region,
# feeding the output back in, then point shots.txt at the blurred file.
set -euo pipefail
[[ $# -eq 8 ]] || { sed -n '2,7p' "$0" >&2; exit 2; }
in=$1 out=$2 start=$3 end=$4 x=$5 y=$6 w=$7 h=$8

ffmpeg -nostdin -loglevel error -y -i "$in" -filter_complex \
    "[0:v]split[base][cut];[cut]crop=$w:$h:$x:$y,boxblur=luma_radius='min(40,min(w,h)/2-1)':luma_power=3:chroma_radius='min(10,min(cw,ch)/2-1)'[blur];\
[base][blur]overlay=$x:$y:enable='between(t,$start,$end)'" \
    -an -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p "$out"
echo "Wrote $out (blurred $w×$h at $x,$y from ${start}s to ${end}s)"
