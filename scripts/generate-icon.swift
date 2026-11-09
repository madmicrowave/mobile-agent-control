import AppKit

func generateAppIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    let inset = size * 0.04
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let cornerRadius = rect.width * 0.2237
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.16, alpha: 1.0),
        NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.09, alpha: 1.0)
    ])
    gradient?.draw(in: path, angle: -90)

    NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.97, alpha: 0.35).setStroke()
    path.lineWidth = max(1.0, size * 0.018)
    path.stroke()

    // Subtle accent dot in top-right corner
    let dotRadius = size * 0.055
    let dotRect = NSRect(
        x: rect.maxX - size * 0.19,
        y: rect.maxY - size * 0.19,
        width: dotRadius * 2,
        height: dotRadius * 2
    )
    NSColor(calibratedRed: 0.20, green: 0.83, blue: 0.60, alpha: 1.0).setFill()
    NSBezierPath(ovalIn: dotRect).fill()

    // Draw "MAC"
    let text = "MAC"
    let fontSize = size * 0.31
    let font = NSFont.systemFont(ofSize: fontSize, weight: .black)

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center

    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraphStyle,
        .kern: size * -0.012
    ]

    let attrStr = NSAttributedString(string: text, attributes: attrs)
    let textSize = attrStr.size()
    let textRect = NSRect(
        x: (size - textSize.width) / 2.0,
        y: (size - textSize.height) / 2.0 - (size * 0.01),
        width: textSize.width,
        height: textSize.height
    )
    attrStr.draw(in: textRect)

    img.unlockFocus()
    return img
}

func generateMenuBarIcon(scale: CGFloat) -> NSBitmapImageRep {
    let ptWidth: CGFloat = 28
    let ptHeight: CGFloat = 18
    let pxW = Int(ptWidth * scale)
    let pxH = Int(ptHeight * scale)

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pxW,
        pixelsHigh: pxH,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: ptWidth, height: ptHeight)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let boxRect = NSRect(x: 1.0, y: 1.5, width: ptWidth - 2.0, height: ptHeight - 3.0)
    let border = NSBezierPath(roundedRect: boxRect, xRadius: 4.0, yRadius: 4.0)
    NSColor.black.setStroke()
    border.lineWidth = 1.35
    border.stroke()

    let font = NSFont.systemFont(ofSize: 8.6, weight: .heavy)
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.black,
        .paragraphStyle: style,
        .kern: -0.25
    ]
    let str = NSAttributedString(string: "MAC", attributes: attrs)
    let sz = str.size()
    str.draw(
        in: NSRect(
            x: (ptWidth - sz.width) / 2.0,
            y: (ptHeight - sz.height) / 2.0,
            width: sz.width,
            height: sz.height
        )
    )

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func savePNG(image: NSImage, path: String) {
    guard let tiffData = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiffData),
          let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to convert image to PNG")
    }
    try! pngData.write(to: URL(fileURLWithPath: path))
}

let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let resourcesDir = projectRoot.appendingPathComponent("Resources", isDirectory: true)
let fm = FileManager.default
try! fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

let iconsetDir = fm.temporaryDirectory.appendingPathComponent("MACAppIcon-\(UUID().uuidString).iconset")
try? fm.removeItem(at: iconsetDir)
try! fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconsetDir) }

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
    savePNG(image: generateAppIcon(size: size), path: iconsetDir.appendingPathComponent(name).path)
}

let icnsPath = resourcesDir.appendingPathComponent("AppIcon.icns").path
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsPath]
try! iconutil.run()
iconutil.waitUntilExit()

let menuRep = generateMenuBarIcon(scale: 2.0)
let menuPng = menuRep.representation(using: .png, properties: [:])!
try! menuPng.write(to: resourcesDir.appendingPathComponent("MenuBarIcon.png"))

print("Generated AppIcon.icns and MenuBarIcon.png in \(resourcesDir.path)")
