# Tanto app icon

## What's in here

| Folder | Use it for |
| --- | --- |
| `icon-composer/` | The macOS 26+ (Liquid Glass) icon. Two layers on a 1024 px canvas, numbered in stacking order: `1-background.png` and `2-tanto-mark.svg` (PNG copy included). No rounded-rectangle mask, because the system applies it. The mark is flat white; glass, shadows and highlights are added in Icon Composer. |
| `xcode/AppIcon.appiconset/` | The classic icon for an Xcode asset catalog, used on macOS 15 and earlier. All 10 sizes plus `Contents.json`. |
| `icns/AppIcon.icns` | Builds without Xcode (py2app, PyInstaller, Briefcase, Tauri, Electron). Point the bundle's `CFBundleIconFile` at it. |
| `icns/AppIcon.iconset/` | The same images in Apple's iconset layout. On a Mac, `iconutil -c icns AppIcon.iconset` rebuilds the .icns with Apple's own tool. |
| `png/` | Plain PNGs from 16 to 1024 px for the README, website or docs. |
| `source/` | Master SVGs. `tanto-icon.svg` is the classic icon. `tanto-icon-small.svg` is the simplified version used at 16 and 32 px (no wrap diamonds, grind line or background waves, which turn into noise at that size). |

## Xcode app

1. Open Icon Composer and drag in both files from `icon-composer/`. Adjust the glass to taste, then save as `AppIcon.icon`.
2. Drag `AppIcon.icon` into the Xcode project and select it as the app icon. The App Icon Set Name in the target settings must match the file name (`AppIcon`).
3. To support macOS 15 and earlier, also put `AppIcon.appiconset` in `Assets.xcassets` and turn on "Include all app icon assets" in the target settings. Developers report that older macOS then uses the classic icon and macOS 26+ uses the Icon Composer one.

## App built without Xcode

Use `icns/AppIcon.icns`. On macOS 26 and later, the system may shrink an app's classic-only icon and place it on a grey rounded square if it doesn't match Apple's template. Shipping the Icon Composer version avoids this: Xcode's `actool` can compile `AppIcon.icon` into the app's `Assets.car` as a build step.
