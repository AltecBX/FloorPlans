#!/bin/bash
#
# Installs an app icon into the asset catalog and commits it, so it survives
# a fresh clone instead of having to be dragged into Xcode again.
#
#   Scripts/set-app-icon.sh ~/Downloads/jerry-icon.png
#
# iOS wants one 1024x1024 PNG; Xcode generates every other size from it. A
# source image of another size is resized here rather than rejected.

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 <path-to-icon.png>" >&2
    exit 64
fi

source_image=$1
repo_root=$(cd "$(dirname "$0")/.." && pwd)
icon_set="$repo_root/FieldPlan/Assets.xcassets/AppIcon.appiconset"
destination="$icon_set/AppIcon.png"

if [ ! -f "$source_image" ]; then
    echo "No such file: $source_image" >&2
    exit 66
fi
if [ ! -d "$icon_set" ]; then
    echo "Asset catalog missing: $icon_set" >&2
    exit 66
fi

# sips ships with macOS; on any other system the image is copied as-is.
if command -v sips >/dev/null 2>&1; then
    width=$(sips -g pixelWidth "$source_image" | awk '/pixelWidth/ {print $2}')
    height=$(sips -g pixelHeight "$source_image" | awk '/pixelHeight/ {print $2}')
    if [ "$width" = "1024" ] && [ "$height" = "1024" ]; then
        cp "$source_image" "$destination"
    else
        echo "Resizing ${width}x${height} to 1024x1024."
        sips -s format png -z 1024 1024 "$source_image" --out "$destination" >/dev/null
    fi
else
    cp "$source_image" "$destination"
fi

cat > "$icon_set/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

echo "Installed $(basename "$destination") into the asset catalog."
echo
echo "Commit it so it is never lost again:"
echo "  git add FieldPlan/Assets.xcassets/AppIcon.appiconset"
echo "  git commit -m 'Add the app icon'"
echo "  git push"
