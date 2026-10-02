# Tantō app icon

| File or folder | Use |
| --- | --- |
| `AppIcon.icns` | The icon that `scripts/build-app.sh` puts into the app. |
| `icon-composer/` | The two layers of a macOS 26+ (Liquid Glass) icon for Apple's Icon Composer, on a 1024 px canvas and numbered in stacking order: `1-background.png` and `2-tanto-mark.svg`. The mark is flat white; Icon Composer adds glass, shadows and highlights, and the system applies the rounded mask. |
| `source/` | Master SVGs: `tanto-icon.svg` is the classic icon, `tanto-icon-small.svg` the simplified version for 16 and 32 px (no wrap diamonds, grind line or background waves, which turn into noise at that size), and `icon-composer-background.svg` the background layer. |

The app ships only the classic icon. On macOS 26 and later the system may shrink a classic-only icon onto a grey rounded
square if it does not match Apple's template. An Icon Composer icon avoids this: Xcode's `actool` can compile
`AppIcon.icon` into the app's `Assets.car`.
