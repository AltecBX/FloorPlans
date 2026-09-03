#!/bin/bash
#
# Double-click this file in Finder to change the app icon.
#
# It opens a normal "choose a file" window, installs the picture you pick as
# the app icon, and — if this folder came from `git clone` — saves and
# uploads the change so it is never lost again. Nothing to type.

cd "$(dirname "$0")/.." || exit 1
repo_root=$(pwd)
icon_set="$repo_root/FieldPlan/Assets.xcassets/AppIcon.appiconset"

say() { printf '\n%s\n' "$1"; }
finish() {
    say "$1"
    say "Press return to close this window."
    read -r _
    exit "${2:-0}"
}

if [ ! -d "$icon_set" ]; then
    finish "Could not find the app's icon folder. Is this the JerryFieldPlans project folder?" 1
fi

say "Choose your app icon — a square PNG picture."
source_image=$(osascript -e 'POSIX path of (choose file with prompt "Choose your app icon (a square PNG)" of type {"public.png"})' 2>/dev/null)

if [ -z "$source_image" ] || [ ! -f "$source_image" ]; then
    finish "No picture chosen — nothing was changed."
fi

# iOS wants one opaque 1024x1024 PNG and generates every other size from it.
# sips ships with macOS, so no installation is needed.
if command -v sips >/dev/null 2>&1; then
    sips -s format png -z 1024 1024 "$source_image" --out "$icon_set/AppIcon.png" >/dev/null 2>&1 \
        || finish "That file could not be read as a picture. Try a PNG." 1
else
    cp "$source_image" "$icon_set/AppIcon.png" || finish "Could not copy the picture." 1
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

say "Icon installed. Build in Xcode to see it on the phone."

# Save it back to GitHub, so a fresh copy of the project keeps the icon.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    finish "This folder was downloaded as a ZIP, so the icon cannot be saved back to GitHub from here.
It will work in Xcode now, but a fresh download would lose it again.
To keep it forever, upload the picture on github.com — Claude has the link."
fi

git add "FieldPlan/Assets.xcassets/AppIcon.appiconset" >/dev/null 2>&1
if git diff --cached --quiet; then
    finish "That is already the current icon — nothing to save."
fi

git commit -m "Update the app icon" >/dev/null 2>&1 || finish "Could not save the change." 1
if git push >/dev/null 2>&1; then
    finish "Icon installed and uploaded to GitHub. It will survive every future update."
fi
finish "Icon installed and saved on this Mac, but the upload to GitHub failed.
Check your internet connection, or ask Claude to push it."
