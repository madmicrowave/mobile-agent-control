import AppKit

func condensedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    if #available(macOS 13.0, *) {
        return NSFont.systemFont(ofSize: size, weight: weight, width: .condensed)
    } else {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let desc = base.fontDescriptor.withSymbolicTraits(.condensed)
        return NSFont(descriptor: desc, size: size) ?? base
    }
}

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

    // Centered stacked layout (2 lines with space between rows):
    // Same system font as in open app:
    // Text("AI").font(.system(size: 12.5, weight: .black))
    // Text("MAC").font(.system(size: 15.5, weight: .black))
    let macFont = NSFont.systemFont(ofSize: size * 0.31, weight: .black)
    let aiFont = NSFont.systemFont(ofSize: size * 0.266, weight: .black)

    let aiAttrs: [NSAttributedString.Key: Any] = [
        .font: aiFont,
        .foregroundColor: NSColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 1.0),
        .kern: size * 0.005
    ]
    let macAttrs: [NSAttributedString.Key: Any] = [
        .font: macFont,
        .foregroundColor: NSColor.white,
        .kern: size * -0.008
    ]

    let aiStr = NSAttributedString(string: "AI", attributes: aiAttrs)
    let macStr = NSAttributedString(string: "MAC", attributes: macAttrs)

    let aiSize = aiStr.size()
    let macSize = macStr.size()

    let macCap = macFont.capHeight
    let aiCap = aiFont.capHeight
    let visualGap = size * 0.092
    let totalCapH = macCap + visualGap + aiCap
    let bottomOfMacY = (size - totalCapH) / 2.0

    let macRect = NSRect(
        x: (size - macSize.width) / 2.0,
        y: bottomOfMacY + macFont.descender,
        width: macSize.width,
        height: macSize.height
    )
    let aiRect = NSRect(
        x: (size - aiSize.width) / 2.0,
        y: bottomOfMacY + macCap + visualGap + aiFont.descender,
        width: aiSize.width,
        height: aiSize.height
    )

    macStr.draw(in: macRect)
    aiStr.draw(in: aiRect)

    img.unlockFocus()
    return img
}

/// Generates an 80x32 px (@2x = 40x16 pt, 144 DPI) rounded-pill menu bar template icon
/// with punched-out inline "AI  MAC" in condensed font with bigger AI and clear spacing.
func saveMenuBarBadgePNG(path: String) {
    let pixelWidth = 80
    let pixelHeight = 32
    let pointWidth: CGFloat = 40
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
    // Setting size to 40x16 points encodes 144 DPI (@2x Retina) into the PNG!
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

    // Punch out inline "AI   MAC" with condensed bold font, bigger AI and clean spacing
    let aiFont = condensedFont(size: 8.2, weight: .black)
    let macFont = condensedFont(size: 9.6, weight: .black)
    let aiVerticalOffset = (macFont.capHeight - aiFont.capHeight) / 2.0

    let aiAttrs: [NSAttributedString.Key: Any] = [
        .font: aiFont,
        .foregroundColor: NSColor.black,
        .baselineOffset: aiVerticalOffset,
        .kern: 0.1
    ]
    let spaceAttrs: [NSAttributedString.Key: Any] = [
        .font: macFont,
        .foregroundColor: NSColor.black,
        .kern: 0.8
    ]
    let macAttrs: [NSAttributedString.Key: Any] = [
        .font: macFont,
        .foregroundColor: NSColor.black,
        .kern: -0.15
    ]

    let attrStr = NSMutableAttributedString(string: "AI", attributes: aiAttrs)
    attrStr.append(NSAttributedString(string: " ", attributes: spaceAttrs))
    attrStr.append(NSAttributedString(string: "MAC", attributes: macAttrs))
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
