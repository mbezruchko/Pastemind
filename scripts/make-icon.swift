// Flattens Resources/AppIcon.icon (Icon Composer's format: the Liquid Glass layers build.sh compiles for macOS 26)
// into Resources/AppIcon.icns, every size up to 1024, for macOS 14 and 15: the icon as macOS 26 draws it in the default
// style. Run it after changing the icon (in Icon Composer, or its SVG layers):
//   swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let work = FileManager.default.temporaryDirectory.appendingPathComponent("pastemind-icon-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: work) }

func run(_ tool: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try! process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("\(tool) failed") }
}

// The system draws an app's icon, not an .icon file: a throwaway app around the compiled icon (with something to run,
// or it gets the "can't open" badge), under a name of its own so no cached icon stands in.
let app = work.appendingPathComponent("Icon.app/Contents")
try FileManager.default.createDirectory(at: app.appendingPathComponent("Resources"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("MacOS/Icon").path)
run("/usr/bin/xcrun", ["actool", root.appendingPathComponent("Resources/AppIcon.icon").path,
                       "--compile", app.appendingPathComponent("Resources").path, "--platform", "macosx",
                       "--minimum-deployment-target", "14.0", "--app-icon", "AppIcon", "--target-device", "mac",
                       "--output-partial-info-plist", work.appendingPathComponent("partial.plist").path])
let info: NSDictionary = ["CFBundleIdentifier": "app.pastemind.icon.\(UUID().uuidString)", "CFBundleExecutable": "Icon",
                          "CFBundlePackageType": "APPL", "CFBundleIconName": "AppIcon", "CFBundleIconFile": "AppIcon"]
info.write(to: app.appendingPathComponent("Info.plist"), atomically: true)

// The default style (light, in color), whatever this Mac's icon style is.
UserDefaults.standard.setVolatileDomain(["AppleIconAppearanceTheme": "RegularLight"], forName: UserDefaults.argumentDomain)
let icon = NSWorkspace.shared.icon(forFile: app.deletingLastPathComponent().path)

/// At 2x the bitmap says so (its size in points): drawn at 1024 points, the icon has nothing that big to show.
func render(_ points: Int, scale: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: points * scale, pixelsHigh: points * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: points, height: points)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        icon.draw(in: NSRect(x: 0, y: 0, width: points, height: points))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = work.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(points, scale: 1).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(points, scale: 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path])
print("wrote Resources/AppIcon.icns")
