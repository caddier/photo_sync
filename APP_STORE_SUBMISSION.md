# App Store Submission Guide for Photo Sync

## Prerequisites

Before submitting to the App Store, ensure you have:

1. ✅ **Apple Developer Account** ($99/year)
   - Enrolled at: https://developer.apple.com/programs/

2. ✅ **App Store Connect Setup**
   - Create app listing at: https://appstoreconnect.apple.com
   - App Name: "Photo Sync" (or your preferred name)
   - Bundle ID: `com.appdevpub.photoSync` (must match Xcode project)
   - SKU: Any unique identifier
   - Primary Language: English (or your preference)

3. ✅ **Certificates & Provisioning Profiles**
   - iOS Distribution Certificate
   - App Store Provisioning Profile
   - Managed through Xcode > Preferences > Accounts

## Step-by-Step Build Process

### Option 1: Using Xcode (Recommended for App Store)

1. **Open project in Xcode:**
   ```bash
   open ios/Runner.xcworkspace
   ```

2. **Configure signing:**
   - Select "Runner" project in left sidebar
   - Select "Runner" target
   - Go to "Signing & Capabilities" tab
   - Check "Automatically manage signing"
   - Select your Apple Developer Team
   - Ensure Bundle Identifier matches: `com.appdevpub.photoSync`

3. **Set build configuration:**
   - Product > Scheme > Edit Scheme
   - Set "Build Configuration" to "Release"

4. **Update version and build number:**
   - In Runner target settings, update:
     - Version: `1.0.0` (or your desired version)
     - Build: `1` (increment for each upload)
   - Or update in `pubspec.yaml`: `version: 1.0.0+1`

5. **Archive the app:**
   - Select "Any iOS Device" as destination (NOT a simulator)
   - Product > Archive
   - Wait for archive to complete (5-10 minutes)

6. **Upload to App Store Connect:**
   - When archive completes, Organizer window opens
   - Select your archive
   - Click "Distribute App"
   - Choose "App Store Connect"
   - Click "Upload"
   - Select "Automatically manage signing"
   - Click "Upload"
   - Wait for upload to complete

### Option 2: Using Command Line + Xcode

1. **Build using Flutter:**
   ```bash
   flutter build ios --release
   ```

2. **Open in Xcode and follow steps 2-6 from Option 1**

## App Store Connect Setup

### Required Information:

1. **App Information:**
   - Name: Photo Sync
   - Subtitle: Sync photos across devices
   - Category: Photo & Video / Utilities
   - Content Rights: Your info

2. **Privacy Policy:**
   - Required for photo access
   - Host on GitHub Pages, website, or use a privacy policy generator

3. **App Description:**
   ```
   Photo Sync allows you to seamlessly synchronize photos and videos between your iOS device and your personal server.

   Features:
   • Easy local network device discovery
   • Batch photo and video synchronization
   • Sync history tracking
   • Support for all photo formats (JPEG, PNG, HEIC, etc.)
   • Support for video formats (MP4, MOV, etc.)
   • Secure local network communication

   Perfect for backing up your photos to your own server without cloud storage!
   ```

4. **Keywords:**
   ```
   photo, sync, backup, transfer, local, server, network, media
   ```

5. **Screenshots Required:**
   - 6.5" iPhone (1290 x 2796 pixels) - 3-5 screenshots
   - 5.5" iPhone (1242 x 2208 pixels) - 3-5 screenshots
   - 12.9" iPad Pro (2048 x 2732 pixels) - 3-5 screenshots

6. **App Icon:**
   - Already generated at: `ios/Runner/Assets.xcassets/AppIcon.appiconset/`
   - 1024x1024 PNG required in App Store Connect

## Common Issues & Solutions

### Issue: "No accounts with App Store Connect access"
**Solution:** Add your Apple ID in Xcode > Preferences > Accounts

### Issue: "Failed to verify code signature"
**Solution:** 
- Ensure you selected a physical device (not simulator) when archiving
- Check that provisioning profile is valid

### Issue: "Missing compliance"
**Solution:** 
- When uploading, you'll be asked about encryption
- For this app: Answer "NO" (no proprietary encryption, only standard HTTPS/TLS)

### Issue: "Invalid Bundle ID"
**Solution:**
- Ensure Bundle ID in Xcode matches App Store Connect
- Current: `com.appdevpub.photoSync`

## Testing Before Submission

1. **TestFlight (Recommended):**
   - After upload, app appears in TestFlight
   - Add internal testers (free, up to 100 users)
   - Test on real devices before public release

2. **Internal Testing:**
   - Install on your device via Xcode
   - Test all features thoroughly

## Submission Checklist

- [ ] App built and archived successfully
- [ ] Screenshots captured and uploaded
- [ ] App description written
- [ ] Privacy policy URL added
- [ ] Support URL added
- [ ] Age rating completed
- [ ] Pricing set (Free/Paid)
- [ ] TestFlight testing completed
- [ ] Submit for Review clicked

## Post-Submission

- Review typically takes 1-3 days
- You'll receive email notifications about status changes
- If rejected, check Resolution Center for feedback
- Make required changes and resubmit

## Version Updates

For future updates:
1. Update `version` in `pubspec.yaml` (e.g., `1.0.1+2`)
2. Run `flutter clean && flutter pub get`
3. Follow archiving steps again
4. In App Store Connect, create new version
5. Upload new build
6. Submit for review

---

## Quick Commands Reference

```bash
# Clean and rebuild
flutter clean
flutter pub get

# Build iOS release
flutter build ios --release

# Open in Xcode
open ios/Runner.xcworkspace

# Check build settings
flutter doctor -v
```

## Support Resources

- [Apple Developer Documentation](https://developer.apple.com/documentation/)
- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Flutter iOS Deployment](https://docs.flutter.dev/deployment/ios)
- [App Store Connect Help](https://help.apple.com/app-store-connect/)
