# ScanNPrint for Mac

Native SwiftUI/AppKit app, macOS 14 or later. It does the same as the Windows app and uses the same `.snp` project files, so a project saved on one opens on the other.

- **Scanning:** through ImageCaptureCore, so it finds the same USB and network scanners as Image Capture. It supports the flatbed, the document feeder (one or both sides), the resolution, colour mode and scan area.
- **Scans:** you can save them as PDF, PNG, JPEG or TIFF, or print them fit to page or at actual size. You can also import images or PDFs, or drop them on the scan list.
- **Compose:** pick the output paper and orientation. On each scan, select an area like cropping; Auto-detect finds the content and straightens it. Then place it on the page and move, resize or turn it there; it snaps to the margins, the centre and the other pieces. You can add several pages, undo and redo, and export or print the result.

## Build

```
xcodebuild -project ScanNPrint.xcodeproj -scheme ScanNPrint -configuration Release -derivedDataPath build/DerivedData build
```

Or open `ScanNPrint.xcodeproj` in Xcode and press Run. The app is ad-hoc signed, so no Apple Developer account is needed to use it on this Mac. Copy `ScanNPrint.app` to `/Applications`, and double-clicking `.snp` files then opens them in it.

Debug builds listen for scripted test commands (`App/DebugSnapshot.swift`); Release builds leave that file out.

## Release build

```
mac/scripts/make-dmg.sh
```

Builds one app for Apple silicon and Intel, signs it with the Developer ID certificate and writes `mac/dist/ScanNPrint-<version>.dmg`. With `NOTARY_PROFILE=<profile>` it also notarizes and staples the DMG, so other Macs open it without a warning. Save the profile once with `xcrun notarytool store-credentials`.
