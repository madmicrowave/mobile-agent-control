import AppKit

func generateAppIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.2237 // Apple standard squircle radius
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

    NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.09, alpha: 1.0).setFill()
    path.fill()

    // Subtle border
    NSColor(calibratedWhite: 1.0, alpha: 0.15).setStroke()
    path.lineWidth = max(1.0, size * 0.015)
    path.stroke()

    let macFont = NSFont.systemFont(ofSize: size * 0.31, weight: .black)
    let aiFont = NSFont.systemFont(ofSize: size * 0.165, weight: .black)

    let macAttrs: [NSAttributedString.Key: Any] = [
        .font: macFont,
        .foregroundColor: NSColor.white,
        .kern: size * -0.01
    ]
    let aiAttrs: [NSAttributedString.Key: Any] = [
        .font: aiFont,
        .foregroundColor: NSColor(calibratedRed: 0.38, green: 0.72, blue: 1.0, alpha: 1.0),
        .baselineOffset: size * 0.11,
        .kern: size * -0.005
    ]

    let attrStr = NSMutableAttributedString(string: "MAC", attributes: macAttrs)
    attrStr.append(NSAttributedString(string: "AI", attributes: aiAttrs))
    let textSize = attrStr.size()

    let textRect = NSRect(
        x: (size - textSize.width) / 2.0,
        y: (size - textSize.height) / 2.0 + (size * 0.01),
        width: textSize.width,
        height: textSize.height
    )

    attrStr.draw(in: textRect)

    img.unlockFocus()
    return img
}

/// Generates a 72x32 px (@2x = 36x16 pt, 144 DPI) rounded-pill menu bar template icon
/// with punched-out bold "MACᴬᴵ" big letters and superscript AI for the menu bar badge.
func saveMenuBarBadgePNG(path: String) {
    let pixelWidth = 72
    let pixelHeight = 32
    let pointWidth: CGFloat = 36
    let pointHeight: CGFloat = 16

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Failed to create NSBitmapImageRep for MenuBarIcon")
    }
    // Setting size to 36x16 points encodes 144 DPI (@2x Retina) into the PNG!
    rep.size = NSSize(width: pointWidth, height: pointHeight)

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Failed to create NSGraphicsContext")
    }
    NSGraphicsContext.current = ctx
    ctx.shouldAntialias = true
    ctx.imageInterpolation = .high

    // Clear canvas
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pointWidth, height: pointHeight).fill()

    // Draw solid black rounded pill (macOS template image turns this white in dark menu bar, black in light menu bar)
    let pillRect = NSRect(x: 0.75, y: 1.0, width: pointWidth - 1.5, height: pointHeight - 2.0)
    let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 4.2, yRadius: 4.2)
    NSColor.black.setFill()
    pillPath.fill()

    // Punch out "MACᴬᴵ" in bold black letters with superscript AI using .clear compositing
    let macFont = NSFont.systemFont(ofSize: 9.6, weight: .black)
    let aiFont = NSFont.systemFont(ofSize: 5.6, weight: .black)

    let macAttrs: [NSAttributedString.Key: Any] = [
        .font: macFont,
        .foregroundColor: NSColor.black,
        .kern: -0.3
    ]
    let aiAttrs: [NSAttributedString.Key: Any] = [
        .font: aiFont,
        .foregroundColor: NSColor.black,
        .baselineOffset: 3.2,
        .kern: -0.2
    ]

    let attrStr = NSMutableAttributedString(string: "MAC", attributes: macAttrs)
    attrStr.append(NSAttributedString(string: "AI", attributes: aiAttrs))
    let textSize = attrStr.size()

    let textRect = NSRect(
        x: (pointWidth - textSize.width) / 2.0,
        y: (pointHeight - textSize.height) / 2.0 + 0.15,
        width: textSize.width,
        height: textSize.height
    )

    ctx.compositingOperation = .clear
    attrStr.draw(in: textRect)

    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode MenuBarIcon PNG")
    }
    try! pngData.write(to: URL(fileURLWithPath: path))
}

func savePNG(image: NSImage, path: String) {
    guard let tiffData = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiffData),
          let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to convert image to PNG")
    }
    try! pngData.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resourcesDir = projectRoot.appendingPathComponent("Resources", isDirectory: true)
try? fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

let iconsetDir = fm.temporaryDirectory.appendingPathComponent("MACAppIcon.iconset", isDirectory: true)
try? fm.removeItem(at: iconsetDir)
try! fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in sizes {
    let img = generateAppIcon(size: size)
    savePNG(image: img, path: iconsetDir.appendingPathComponent(name).path)
}

let icnsProc = Process()
icnsProc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
icnsProc.arguments = ["-c", "icns", iconsetDir.path, "-o", resourcesDir.appendingPathComponent("AppIcon.icns").path]
try! icnsProc.run()
icnsProc.waitUntilExit()
try? fm.removeItem(at: iconsetDir)

saveMenuBarBadgePNG(path: resourcesDir.appendingPathComponent("MenuBarIcon.png").path)
print("Generated AppIcon.icns and MenuBarIcon.png in \(resourcesDir.path)")
