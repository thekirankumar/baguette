#!/bin/sh
# Rebuild chrome-lab and regenerate the comparison images in ../assets from
# the committed Device Hub capture. Needs Xcode's DeviceKit chrome bundles.
#   docs/features/chrome-bezel/scripts/make-assets.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
assets="$here/../assets"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
lab="$work/chrome-lab"
capture="$assets/device-hub-watch4-1x.png"

swiftc -O "$here/chrome-lab.swift" -o "$lab"

# Whole watch: Device Hub, baguette today (1×, buttons under the whole case,
# no ridges), and the Device Hub model at 3×.
"$lab" render --out "$work/today.png" --scale 1 --baguette-today
"$lab" render --out "$work/hub-3x.png" --scale 3 --device-hub-rest
sips -c 216 200 --cropOffset 26 12 "$capture" --out "$work/hub-watch.png" >/dev/null
"$lab" compare --out "$assets/watch-device-hub-vs-baguette.png" --height 520 \
  "$work/hub-watch.png" "Device Hub (1× display)" \
  "$work/today.png" "baguette today (1×)" \
  "$work/hub-3x.png" "Device Hub model (3×)"

# Crown close-up on Device Hub's own pixel grid, nearest-neighbour so each
# capture pixel stays visible: the fit's model, crisp and with the blur
# Device Hub's 1× upscale adds.
"$lab" fit --capture "$capture" --device-hub-rest --write "$work"
for f in hub:"$capture" soft:"$work/model-soft.png" crisp:"$work/model-crisp.png"; do
  sips -c 123 28 --cropOffset 78 182 "${f#*:}" --out "$work/close-${f%%:*}.png" >/dev/null
done
"$lab" compare --out "$assets/crown-device-hub-vs-model.png" --nearest --height 740 \
  "$work/close-hub.png" "Device Hub" \
  "$work/close-soft.png" "model, blurred" \
  "$work/close-crisp.png" "model, crisp"
