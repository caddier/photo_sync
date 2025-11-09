# Photo Sync App Icon

## Design Description

The app icon features a modern, professional design that represents photo synchronization:

### Visual Elements:
- **Blue Gradient Background**: Represents cloud/digital storage with a tech-forward feel
- **Photo Frame**: White/light blue photo frame with a landscape scene (mountains and sun)
- **Sync Arrows**: Circular sync arrows at the bottom showing bidirectional synchronization
- **Accent Dots**: Connection dots suggesting data transfer between devices

### Color Scheme:
- Primary: `#4A90E2` to `#357ABD` (Blue gradient)
- Secondary: White (`#FFFFFF`) for photo frame and sync arrows
- Accent: `#FFD700` (Gold) for the sun element

### Files Generated:

#### iOS Icons:
- Located in: `ios/Runner/Assets.xcassets/AppIcon.appiconset/`
- Sizes: 20x20 to 1024x1024 (@1x, @2x, @3x scales)
- Includes iPhone, iPad, and App Store icons

#### Android Icons:
- Located in: `android/app/src/main/res/mipmap-*/`
- Densities: mdpi (48x48) to xxxhdpi (192x192)
- Standard launcher icon format

#### Source File:
- `assets/app_icon.svg` - Scalable vector source for future modifications

## Customization

To modify the icon design:
1. Edit `assets/app_icon.svg` with any SVG editor
2. Re-run the icon generation commands (or use flutter_launcher_icons package)

## Alternative: Using flutter_launcher_icons Package

You can also use the `flutter_launcher_icons` package for easier icon management:

```yaml
# Add to pubspec.yaml
dev_dependencies:
  flutter_launcher_icons: ^0.13.1

flutter_launcher_icons:
  android: true
  ios: true
  image_path: "assets/app_icon.png"
```

Then run: `flutter pub run flutter_launcher_icons`
