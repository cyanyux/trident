#!/usr/bin/env bash
#
# Regenerate assets/dmg-background.tiff — the Retina (1x+2x) background Finder
# shows inside the installer DMG. Run after editing render-dmg-background.swift;
# the TIFF is committed so releases don't depend on rendering at release time.

set -euo pipefail
cd "$(dirname "$0")/.."

swift scripts/render-dmg-background.swift assets
tiffutil -cathidpicheck assets/dmg-background.png assets/dmg-background@2x.png \
  -out assets/dmg-background.tiff
rm assets/dmg-background.png assets/dmg-background@2x.png
echo "wrote assets/dmg-background.tiff (1x + 2x)"
