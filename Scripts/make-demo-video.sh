#!/bin/bash
#
# Builds the demo video from rendered frames.
#
# The frames come from GPUWatchSnapshot, which renders the real popover view
# driven by the real evaluator over the demo fleet. Nothing is screen-recorded,
# so nothing else on the machine can end up in the output, and the sequence is
# reproducible.
#
# Outputs:
#   dist/demo.mp4   H.264, for the release page and for viewing
#   dist/demo.gif   for the README, where a GIF autoplays and a video does not
#
# Captions are composited as a band below the popover rather than drawn over it,
# because text burned across the header would hide the thing being shown.
#
# The caption band is built with ImageMagick and overlaid with ffmpeg's
# `overlay` filter. `drawtext` would be the obvious choice, but the ffmpeg builds
# available here omit freetype, so it is not present.
#
# Requires ffmpeg and ImageMagick (`magick`).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FRAMES="$ROOT/dist/video-frames"
OUT_MP4="$ROOT/dist/demo.mp4"
OUT_GIF="$ROOT/dist/demo.gif"
FPS=12
BAND_HEIGHT=104

for tool in ffmpeg ffprobe magick; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool is required" >&2
    exit 1
  fi
done

FONT=""
for candidate in \
  /System/Library/Fonts/Supplemental/Arial.ttf \
  /System/Library/Fonts/Supplemental/Verdana.ttf \
  /Library/Fonts/Arial.ttf
do
  if [ -f "$candidate" ]; then FONT="$candidate"; break; fi
done
if [ -z "$FONT" ]; then
  echo "error: no usable font found for captions" >&2
  exit 1
fi

echo "==> Rendering frames"
rm -rf "$FRAMES"
swift run -c release GPUWatchSnapshot --video-frames "$FRAMES" 2>&1 | sed 's/^/    /'

if [ ! -f "$FRAMES/captions.tsv" ]; then
  echo "error: the harness did not produce captions.tsv" >&2
  exit 1
fi

echo "==> Grouping frames into shots"
mkdir -p "$FRAMES/captions"
python3 - "$FRAMES/captions.tsv" "$FRAMES/captions" <<'PY'
import sys, pathlib, collections

manifest, outdir = sys.argv[1], pathlib.Path(sys.argv[2])
rows = [line.split("\t") for line in pathlib.Path(manifest).read_text().splitlines() if line.strip()]

# Frames are emitted shot by shot, so grouping by shot name gives contiguous
# ranges without having to trust index arithmetic.
shots = collections.OrderedDict()
for index, row in enumerate(rows):
    name = row[1] if len(row) > 1 else "shot"
    caption = row[2] if len(row) > 2 else ""
    entry = shots.setdefault(name, {"first": index, "last": index, "caption": caption})
    entry["last"] = index

lines = []
for name, info in shots.items():
    caption_file = f"{name}.txt"
    (outdir / caption_file).write_text((info["caption"] or " ") + "\n")
    # The caption text is carried in the manifest as well as written to a file:
    # ImageMagick's `-annotate` does not read `@file` the way `-label` does, and
    # renders the path as literal text instead.
    lines.append(f"{name}\t{info['first']}\t{info['last']}\t{caption_file}\t{info['caption']}")
    print(f"    {name}: frames {info['first']}-{info['last']}  {info['caption']}")

(outdir / "shots.tsv").write_text("\n".join(lines) + "\n")
PY

WIDTH=$(magick identify -format '%w' "$FRAMES/frame-00000.png")
echo "==> Frame size ${WIDTH}px wide; caption band ${BAND_HEIGHT}px"

echo "==> Building segments"
SEGMENTS="$FRAMES/segments"
rm -rf "$SEGMENTS"
mkdir -p "$SEGMENTS"
INDEX=0
CONCAT_LIST="$SEGMENTS/list.txt"
: > "$CONCAT_LIST"

while IFS=$'\t' read -r name first last caption_file caption; do
  [ -z "${name:-}" ] && continue
  count=$((last - first + 1))

  # The caption is passed literally. `@file` is not supported by `-annotate`,
  # which silently renders the path itself as the text.
  band="$SEGMENTS/$name-band.png"
  magick -size "${WIDTH}x${BAND_HEIGHT}" xc:'#141414' \
    -font "$FONT" -pointsize 28 -fill '#EDEDED' -gravity center \
    -annotate 0 "$caption" "$band"

  segment="$SEGMENTS/segment-$(printf '%02d' "$INDEX").mp4"
  # `-frames:v` is an output option. Placed before the second `-i` ffmpeg treats
  # it as an input option for the band image and refuses to run.
  ffmpeg -hide_banner -loglevel error -y \
    -framerate "$FPS" -start_number "$first" -i "$FRAMES/frame-%05d.png" \
    -i "$band" \
    -filter_complex "[0]pad=iw:ih+$BAND_HEIGHT:0:0:color=0x141414[padded];[padded][1]overlay=0:H-$BAND_HEIGHT:format=auto[v]" \
    -map "[v]" -frames:v "$count" -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p \
    "$segment"
  echo "    $name -> $(basename "$segment") ($count frames)"
  echo "file '$segment'" >> "$CONCAT_LIST"
  INDEX=$((INDEX + 1))
done < "$FRAMES/captions/shots.tsv"

echo "==> Concatenating"
ffmpeg -hide_banner -loglevel error -y \
  -f concat -safe 0 -i "$CONCAT_LIST" \
  -c copy -movflags +faststart "$OUT_MP4"

echo "==> Encoding gif"
# Deliberately frugal. A GIF sits inline in the README, so it has to download
# quickly: 8 fps, 380 px wide, a 64-colour palette and no dithering. The UI is
# flat dark surfaces with a few saturated dots, so a small palette costs almost
# nothing visually, while dithering noise is what makes these files large.
ffmpeg -hide_banner -loglevel error -y \
  -i "$OUT_MP4" \
  -vf "fps=8,scale=380:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=64[p];[b][p]paletteuse=dither=none" \
  -loop 0 \
  "$OUT_GIF"

echo
for file in "$OUT_MP4" "$OUT_GIF"; do
  size=$(du -h "$file" | cut -f1)
  duration=$(ffprobe -hide_banner -loglevel error -show_entries format=duration -of csv=p=0 "$file")
  dimension=$(ffprobe -hide_banner -loglevel error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$file")
  printf '  %-12s %6s  %5.1fs  %s\n' "$(basename "$file")" "$size" "$duration" "$dimension"
done
