#!/bin/bash
# Builds build/Tanto.app from the Swift package. With --install it also copies the app to /Applications, after showing
# what it replaces and asking first. With --dmg it also makes build/Tanto-<version>.dmg for a release, with the app and
# a shortcut to Applications; that needs a tree without uncommitted changes, so that the DMG matches a commit. On a
# branch other than main it builds build/Tanto Dev.app instead, with its own app ID, so that macOS never opens it in
# place of the installed app and the two keep their own settings; it neither installs nor makes a DMG.
set -euo pipefail

cd "$(dirname "$0")/.."
install=false
dmg=false
case "${1:-}" in
    "") ;;
    --install) install=true ;;
    --dmg) dmg=true ;;
    *)
        echo "usage: scripts/build-app.sh [--install | --dmg]" >&2
        exit 2
        ;;
esac

# The version a release is tagged with, as v$version.
version=0.1.0
# The oldest macOS the app runs on, as in Package.swift.
minimum=15.0

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
    if $install || $dmg; then
        echo "Only main installs or makes a DMG; this is $branch" >&2
        exit 1
    fi
fi
if $dmg && [ -n "$(git status --porcelain)" ]; then
    echo "Commit the changes first, so that the DMG matches a commit" >&2
    exit 1
fi

# SwiftPM's link records the minimum also as the SDK version, and macOS then draws the app as one built for that older
# macOS, without the current look. The linker therefore gets the SDK's own version.
link=(-Xlinker -platform_version -Xlinker macos -Xlinker "$minimum" -Xlinker "$(xcrun --show-sdk-version)")
swift build -c release --product Tanto "${link[@]}"
bin=$(swift build -c release --product Tanto "${link[@]}" --show-bin-path)

app="build/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Tanto" "$app/Contents/MacOS/Tanto"
# The linker leaves the paths of the build folder in the binary as debugging information, and with them the user's name
# on this Mac; the app needs none of it.
strip -S -no_code_signature_warning "$app/Contents/MacOS/Tanto"
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
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSHasLocalizedDisplayName</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>$minimum</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
# Copied files keep their extended attributes, such as the download mark on the icon; the app ships without them.
xattr -cr "$app"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
echo "Built $app"

if $dmg; then
    # The disk image opens to the app and a shortcut to Applications to drag it onto.
    image="build/Tanto-$version.dmg"
    staging=build/dmg
    rm -rf "$staging" "$image"
    mkdir "$staging"
    ditto "$app" "$staging/$name.app"
    ln -s /Applications "$staging/Applications"
    diskutil image create from --format UDZO --volumeName "$shown" "$staging" "$image"
    rm -rf "$staging"
    hdiutil verify "$image"
    echo "Built $image"
fi

if $install; then
    target=/Applications/Tanto.app
    if [ -e "$target" ]; then
        installed=$(defaults read "$target/Contents/Info" CFBundleShortVersionString 2> /dev/null || echo unknown)
        echo "$target exists: version $installed, modified $(stat -f %Sm "$target")"
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
