#!/bin/bash
# Builds build/Tanto.app from the Swift package. With --install it also copies the app to /Applications, after showing
# what it replaces and asking first. On a branch other than main it builds build/Tanto Dev.app instead, with its own app
# ID, so that macOS never opens it in place of the installed app and the two keep their own settings; it does not
# install.
set -euo pipefail

cd "$(dirname "$0")/.."
case "${1:-}" in
    "") install=false ;;
    --install) install=true ;;
    *)
        echo "usage: scripts/build-app.sh [--install]" >&2
        exit 2
        ;;
esac

branch=$(git rev-parse --abbrev-ref HEAD)
# The app shows its name as Tantō, after the katana's companion blade, also in Finder, the Dock and Spotlight through a
# localized display name; its file stays Tanto, which is easier to type. Finder shows the localized name only while
# Info.plist's own name matches the file's, so Info.plist says Tanto and the localization Tantō.
if [ "$branch" = main ]; then
    name=Tanto
    shown=Tantō
    identifier=io.github.pwhofman.tanto
else
    name="Tanto Dev"
    shown="Tantō Dev"
    identifier=io.github.pwhofman.tanto.dev
    if $install; then
        echo "Only main installs; this is $branch" >&2
        exit 1
    fi
fi

swift build -c release --product Tanto
bin=$(swift build -c release --product Tanto --show-bin-path)

app="build/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Tanto" "$app/Contents/MacOS/Tanto"
# SwiftPM's resource bundle is not found inside a hand-made app, so the app loads its own copy of the table.
cp Sources/KatanaKit/Resources/parameters.json "$app/Contents/Resources/"
cp Icon/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
mkdir -p "$app/Contents/Resources/en.lproj"
printf 'CFBundleDisplayName = "%s";\nCFBundleName = "%s";\n' "$shown" "$shown" \
    > "$app/Contents/Resources/en.lproj/InfoPlist.strings"
plutil -lint "$app/Contents/Resources/en.lproj/InfoPlist.strings"
cat > "$app/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$name</string>
    <key>CFBundleExecutable</key>
    <string>Tanto</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$identifier</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSHasLocalizedDisplayName</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>27.0</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
echo "Built $app"

if $install; then
    target=/Applications/Tanto.app
    if [ -e "$target" ]; then
        version=$(defaults read "$target/Contents/Info" CFBundleShortVersionString 2> /dev/null || echo unknown)
        echo "$target exists: version $version, modified $(stat -f %Sm "$target")"
        read -r -p "Replace it? [y/N] " answer
        if [ "$answer" != y ]; then
            echo "Not installed"
            exit 1
        fi
        rm -rf "$target"
    fi
    ditto "$app" "$target"
    # So that Finder and the Dock show the new display name rather than a remembered one.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target"
    echo "Installed $target"
fi
