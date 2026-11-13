import AppKit
import WebKit

@MainActor
final class BannerRenderer: NSObject, WKNavigationDelegate {
    private var finished = false

    func renderHTML(_ html: String, width: CGFloat, height: CGFloat, cornerRadius: CGFloat = 26, outURL: URL) throws {
        finished = false
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
        webView.navigationDelegate = self

        let win = NSWindow(
            contentRect: NSRect(x: -12000, y: -12000, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.contentView = webView
        win.orderBack(nil)

        webView.loadHTMLString(html, baseURL: nil)

        let deadline = Date().addingTimeInterval(8.0)
        while !finished && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
        let settle = Date().addingTimeInterval(0.25)
        while Date() < settle {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        var snapImage: NSImage?
        var snapErr: Error?
        var snapDone = false
        let snapCfg = WKSnapshotConfiguration()
        snapCfg.rect = CGRect(x: 0, y: 0, width: width, height: height)
        snapCfg.snapshotWidth = NSNumber(value: Int(width * 2))

        webView.takeSnapshot(with: snapCfg) { img, err in
            snapImage = img
            snapErr = err
            snapDone = true
        }

        let snapDeadline = Date().addingTimeInterval(6.0)
        while !snapDone && Date() < snapDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
        win.orderOut(nil)

        if let err = snapErr { throw err }
        guard let rawImage = snapImage,
              let rawTiff = rawImage.tiffRepresentation,
              let rawRep = NSBitmapImageRep(data: rawTiff) else {
            throw NSError(domain: "BannerRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Snapshot failed"])
        }

        let pxW = rawRep.pixelsWide
        let pxH = rawRep.pixelsHigh
        let scale = CGFloat(pxW) / width
        let scaledRadius = cornerRadius * scale

        guard let alphaRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxW,
            pixelsHigh: pxH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "BannerRenderer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bitmap alloc failed"])
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: alphaRep)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: pxW, height: pxH).fill()

        let fullRect = NSRect(x: 0, y: 0, width: CGFloat(pxW), height: CGFloat(pxH))
        let clipPath = NSBezierPath(roundedRect: fullRect, xRadius: scaledRadius, yRadius: scaledRadius)
        clipPath.addClip()

        rawRep.draw(in: fullRect)

        let borderRect = fullRect.insetBy(dx: 1.0, dy: 1.0)
        let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: scaledRadius - 1.0, yRadius: scaledRadius - 1.0)
        borderPath.lineWidth = 2.0
        NSColor(calibratedRed: 0.58, green: 0.64, blue: 0.72, alpha: 0.22).setStroke()
        borderPath.stroke()

        NSGraphicsContext.restoreGraphicsState()

        guard let png = alphaRep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "BannerRenderer", code: 3, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
        }
        try png.write(to: outURL, options: .atomic)
        print("Saved \(outURL.path) (\(pxW)x\(pxH) RGBA)")
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.finished = true
        }
    }
}

let macBannerHTML = """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; -webkit-font-smoothing: antialiased; }
  html, body {
    width: 1280px;
    height: 700px;
    overflow: hidden;
    background: #070b16;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", sans-serif;
  }
  .canvas {
    width: 1280px;
    height: 700px;
    background: radial-gradient(circle at 80% 18%, rgba(56, 189, 248, 0.17) 0%, transparent 40%),
                radial-gradient(circle at 77% 84%, rgba(139, 92, 246, 0.22) 0%, transparent 44%),
                linear-gradient(135deg, #070b16 0%, #0d1529 52%, #130f29 100%);
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 32px 76px 32px 62px;
    position: relative;
  }
  .left {
    width: 720px;
    display: flex;
    flex-direction: column;
    gap: 22px;
  }
  .top-pill {
    display: inline-flex;
    align-items: center;
    gap: 9px;
    width: fit-content;
    padding: 7px 15px;
    border-radius: 999px;
    background: rgba(23, 32, 54, 0.92);
    border: 1px solid rgba(71, 85, 105, 0.65);
    color: #e2e8f0;
    font-size: 12.5px;
    font-weight: 600;
  }
  .dot-green {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #22c55e;
    box-shadow: 0 0 8px rgba(34, 197, 94, 0.85);
  }
  .brand-row {
    display: flex;
    align-items: center;
    gap: 16px;
    margin-top: 2px;
  }
  .mac-badge-lg {
    background: #ffffff;
    color: #090d1a;
    font-weight: 900;
    font-size: 28px;
    letter-spacing: -0.9px;
    padding: 8px 18px;
    border-radius: 12px;
    box-shadow: 0 8px 24px rgba(255, 255, 255, 0.14);
    display: inline-flex;
    align-items: center;
    line-height: 1;
  }
  .mac-badge-lg small {
    font-size: 0.60em;
    font-weight: 900;
    color: #0284c7;
    margin-right: 5px;
    line-height: 1;
    display: inline-flex;
    align-items: center;
    transform: translateY(-0.5px);
  }
  .mac-badge-lg .mac-text {
    line-height: 1;
    display: inline-flex;
    align-items: center;
  }
  .brand-title {
    font-size: 48px;
    font-weight: 800;
    color: #ffffff;
    letter-spacing: -1.1px;
    line-height: 1.05;
  }
  .subtitle {
    font-size: 23px;
    font-weight: 700;
    background: linear-gradient(90deg, #38bdf8 0%, #60a5fa 50%, #c084fc 100%);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    line-height: 1.25;
  }
  .desc {
    font-size: 16px;
    line-height: 1.56;
    color: #cbd5e1;
    max-width: 675px;
  }
  .macos-strip-card {
    background: rgba(15, 23, 42, 0.88);
    border: 1px solid rgba(71, 85, 105, 0.62);
    border-radius: 14px;
    padding: 13px 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
    max-width: 675px;
  }
  .macos-menubar {
    height: 30px;
    background: #090e1a;
    border: 1px solid #28354d;
    border-radius: 8px;
    padding: 0 14px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-size: 12px;
    color: #cbd5e1;
    font-weight: 600;
  }
  .menubar-left { display: flex; align-items: center; gap: 14px; color: #94a3b8; }
  .menubar-left strong { color: #f8fafc; }
  .menubar-right { display: flex; align-items: center; gap: 10px; }
  .mac-menubar-pill {
    background: #ffffff;
    color: #090d1a;
    font-weight: 900;
    font-size: 11.5px;
    padding: 2px 7px;
    border-radius: 4px;
    letter-spacing: -0.3px;
    display: inline-flex;
    align-items: center;
    line-height: 1;
  }
  .mac-menubar-pill small {
    font-size: 0.72em;
    font-weight: 800;
    color: #0284c7;
    margin-right: 2px;
    display: inline-flex;
    align-items: center;
    transform: translateY(-0.5px);
  }
  .strip-caption {
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-size: 12px;
    color: #94a3b8;
  }
  .strip-caption span.ok { color: #4ade80; font-weight: 600; }

  .steps-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 12px;
    max-width: 675px;
  }
  .step-box {
    background: rgba(19, 28, 49, 0.86);
    border: 1px solid rgba(51, 65, 85, 0.88);
    border-radius: 12px;
    padding: 13px 15px;
  }
  .step-box h4 {
    font-size: 13.5px;
    font-weight: 700;
    color: #38bdf8;
    margin-bottom: 5px;
  }
  .step-box:nth-child(2) h4 { color: #818cf8; }
  .step-box:nth-child(3) h4 { color: #34d399; }
  .step-box p {
    font-size: 12px;
    line-height: 1.4;
    color: #cbd5e1;
  }
  .footer-line {
    font-size: 12.2px;
    font-weight: 600;
    color: #94a3b8;
    margin-top: 2px;
  }

  /* ============================================================================
     EXACT IPHONE 17 HARDWARE PROPORTIONS (6.3" 19.5:9 = 402x874 pt @ 0.71x)
     ============================================================================ */
  .phone-wrap {
    width: 308px;
    height: 640px;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    position: relative;
  }
  .hw-btn {
    position: absolute;
    background: linear-gradient(180deg, #525a6b 0%, #2c313d 100%);
    border-radius: 2px;
  }
  .hw-action { left: 1px; top: 118px; width: 3px; height: 22px; }
  .hw-vol-up { left: 1px; top: 154px; width: 3px; height: 42px; }
  .hw-vol-dn { left: 1px; top: 206px; width: 3px; height: 42px; }
  .hw-power  { right: 1px; top: 172px; width: 3px; height: 64px; }

  .iphone17 {
    width: 300px;
    height: 635px;
    border-radius: 46px;
    background: linear-gradient(145deg, #434a59 0%, #181b22 46%, #2f3542 100%);
    padding: 7.3px;
    box-shadow: 0 30px 64px rgba(0, 0, 0, 0.74),
                inset 0 0 0 1.3px rgba(255, 255, 255, 0.28),
                inset 0 0 0 3px #0b0d12;
    position: relative;
  }
  .iphone17-viewport {
    width: 285.4px;
    height: 620.4px;
    border-radius: 39px;
    overflow: hidden;
    position: relative;
    background: #0e0b16;
  }
  .iphone17-screen {
    width: 402px;
    height: 874px;
    transform: scale(0.71);
    transform-origin: top left;
    background: radial-gradient(circle at 32% 18%, #231938 0%, #130e1e 56%, #0d0a15 100%);
    display: flex;
    flex-direction: column;
    position: relative;
  }

  /* Floating Top Overlay (Status bar + Liquid Glass Telegram Header) */
  .top-chrome {
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    z-index: 10;
    background: linear-gradient(180deg, rgba(16, 12, 26, 0.94) 0%, rgba(16, 12, 26, 0.72) 72%, rgba(16, 12, 26, 0) 100%);
    padding-bottom: 6px;
  }
  .ios-statusbar {
    height: 50px;
    padding: 13px 28px 0;
    display: flex;
    align-items: center;
    justify-content: space-between;
    color: #ffffff;
    font-size: 16px;
    font-weight: 700;
    letter-spacing: -0.2px;
  }
  .dynamic-island {
    width: 120px;
    height: 35px;
    background: #000000;
    border-radius: 999px;
    display: flex;
    align-items: center;
    justify-content: flex-end;
    padding-right: 11px;
  }
  .camera-lens {
    width: 11px;
    height: 11px;
    border-radius: 50%;
    background: radial-gradient(circle at 35% 35%, #1e3a8a 0%, #090d16 65%, #000 100%);
    opacity: 0.75;
  }
  .ios-status-icons {
    display: flex;
    align-items: center;
    gap: 7px;
    font-size: 13px;
  }
  .battery {
    background: #facc15;
    color: #000;
    font-weight: 800;
    font-size: 11.5px;
    padding: 2px 6.5px;
    border-radius: 6px;
    line-height: 1.1;
  }

  .tg-header {
    padding: 4px 12px 4px;
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .tg-back {
    width: 40px;
    height: 40px;
    border-radius: 50%;
    background: rgba(46, 42, 60, 0.85);
    backdrop-filter: blur(14px);
    -webkit-backdrop-filter: blur(14px);
    border: 1px solid rgba(255,255,255,0.12);
    display: flex;
    align-items: center;
    justify-content: center;
    color: #ffffff;
    font-size: 22px;
    font-weight: 500;
    padding-right: 2px;
  }
  .tg-title-pill {
    background: rgba(46, 42, 60, 0.86);
    backdrop-filter: blur(14px);
    -webkit-backdrop-filter: blur(14px);
    border: 1px solid rgba(255,255,255,0.12);
    border-radius: 22px;
    padding: 5px 24px;
    text-align: center;
  }
  .tg-title-pill .name {
    font-size: 15px;
    font-weight: 700;
    color: #ffffff;
    line-height: 1.18;
  }
  .tg-title-pill .sub {
    font-size: 11.8px;
    color: #9ca3af;
    line-height: 1.12;
  }
  .tg-avatar {
    width: 40px;
    height: 40px;
    border-radius: 50%;
    background: linear-gradient(135deg, #fb7185, #f97316);
    color: #ffffff;
    font-weight: 800;
    font-size: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  /* Authentic Tight iOS Telegram Message Stack (bottom-anchored with 7px gap!) */
  .tg-wallpaper {
    flex: 1;
    display: flex;
    flex-direction: column;
    justify-content: flex-end;
    gap: 7px;
    padding: 0 11px 8px;
    overflow: hidden;
  }
  .tg-msg-group {
    display: flex;
    flex-direction: column;
    gap: 4px;
    max-width: 93%;
  }
  .tg-bubble-bot {
    background: rgba(42, 31, 58, 0.96);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 16px 16px 16px 5px;
    padding: 8.5px 12px 7.5px;
    color: #f3f4f6;
    font-size: 13.4px;
    line-height: 1.35;
    position: relative;
  }
  .tg-bubble-bot b { color: #ffffff; font-weight: 700; }
  .tg-bubble-bot code {
    font-family: "SF Mono", ui-monospace, Menlo, monospace;
    font-size: 12.2px;
    color: #93c5fd;
  }
  .tg-spacer { height: 6px; }
  .tg-time {
    float: right;
    font-size: 10.8px;
    color: rgba(203, 213, 225, 0.52);
    margin-left: 8px;
    margin-top: 3px;
  }
  .tg-inline-kb {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .tg-kb-row {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 4px;
  }
  .tg-kb-row.single {
    grid-template-columns: 1fr;
  }
  .tg-kb-btn {
    background: rgba(55, 43, 74, 0.92);
    border-radius: 10px;
    padding: 8px 8px;
    text-align: center;
    color: #f8fafc;
    font-size: 13px;
    font-weight: 600;
  }

  .tg-bubble-user {
    align-self: flex-end;
    max-width: 85%;
    background: linear-gradient(135deg, #8b5cf6 0%, #6d28d9 100%);
    color: #ffffff;
    border-radius: 16px 16px 5px 16px;
    padding: 7.5px 13px;
    font-size: 13.4px;
    line-height: 1.33;
    box-shadow: 0 3px 10px rgba(0, 0, 0, 0.24);
  }
  .tg-bubble-user .tg-time {
    color: rgba(255, 255, 255, 0.80);
  }

  /* Native 402pt iOS Telegram Bottom Bar + Persistent Reply Keyboard */
  .tg-bottom {
    background: rgba(21, 17, 30, 0.98);
    border-top: 1px solid rgba(255, 255, 255, 0.08);
    padding: 8px 10px 10px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    flex-shrink: 0;
  }
  .tg-input-row {
    display: flex;
    align-items: center;
    gap: 7px;
  }
  .tg-menu-pill {
    background: #2581dc;
    color: #ffffff;
    font-size: 13.5px;
    font-weight: 700;
    padding: 7px 13px;
    border-radius: 18px;
    flex-shrink: 0;
  }
  .tg-icon-circle {
    width: 34px;
    height: 34px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.08);
    color: #cbd5e1;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }
  .tg-msg-field {
    flex: 1;
    height: 35px;
    border-radius: 18px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.10);
    padding: 0 13px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    color: #9ca3af;
    font-size: 14px;
  }
  .tg-reply-kb {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 6px;
  }
  .tg-reply-btn {
    background: rgba(55, 52, 68, 0.94);
    border-radius: 10px;
    padding: 10px 8px;
    text-align: center;
    color: #ffffff;
    font-size: 13.8px;
    font-weight: 600;
  }
  .ios-home-bar {
    width: 138px;
    height: 5px;
    border-radius: 99px;
    background: rgba(255, 255, 255, 0.78);
    margin: 4px auto 0;
  }
</style>
</head>
<body>
  <div class="canvas">
    <div class="left">
      <div class="top-pill">
        <span class="dot-green"></span>
        <span>Native macOS Menu Bar &amp; Dock App (mac.app) • Swift &amp; SwiftUI • MIT</span>
      </div>

      <div class="brand-row">
        <div class="mac-badge-lg"><small>AI</small><span class="mac-text">MAC</span></div>
        <div class="brand-title">Mobile Agent Control</div>
      </div>

      <div class="subtitle">Control Local AI Coding Workspaces via Telegram</div>

      <div class="desc">
        Run Google Antigravity (<b>Gemini 4 Argon</b>, <b>Gemini 3.8</b> &amp; <b>Claude</b>) across your Mac's local Workspaces, review changed files, push Git branches, and promote Staging → Production Jenkins CI/CD directly from Telegram on your iPhone.
      </div>

      <div class="macos-strip-card">
        <div class="macos-menubar">
          <div class="menubar-left">
            <strong></strong>
            <strong><small style="font-size: 0.72em; font-weight: 800; color: #38bdf8; margin-right: 2px; display: inline-flex; align-items: center; transform: translateY(-0.5px);">AI</small>MAC</strong>
            <span>File</span>
            <span>Edit</span>
          </div>
          <div class="menubar-right">
            <span class="mac-menubar-pill"><small>AI</small>MAC</span>
            <span>Tue 9:41 AM</span>
          </div>
        </div>
        <div class="strip-caption">
          <span class="ok">● Running in macOS Menu Bar · Awake &amp; Autostart Enabled</span>
          <span>Zero Open Ports / VPN</span>
        </div>
      </div>

      <div class="steps-grid">
        <div class="step-box">
          <h4>1. Open mac.app</h4>
          <p>Lives next to clock as <b><small style="font-size: 0.75em; color: #38bdf8; display: inline-flex; align-items: center; transform: translateY(-0.5px);">AI</small> MAC</b>; Open App appears in Dock.</p>
        </div>
        <div class="step-box">
          <h4>2. Add Workspaces</h4>
          <p>Configure Telegram, 5 AI Engines, Git folders &amp; CI/CD.</p>
        </div>
        <div class="step-box">
          <h4>3. Ship from iPhone</h4>
          <p>Switch Workspaces, prompt AI, push Git &amp; deploy CI/CD.</p>
        </div>
      </div>

      <div class="footer-line">Open-Source macOS Software by DOMONK Factory • https://domonk.com</div>
    </div>

    <!-- EXACT IPHONE 17 (402x874 pt, 19.5:9) WITH TIGHT REAL TELEGRAM SPACING -->
    <div class="phone-wrap">
      <div class="hw-btn hw-action"></div>
      <div class="hw-btn hw-vol-up"></div>
      <div class="hw-btn hw-vol-dn"></div>
      <div class="hw-btn hw-power"></div>

      <div class="iphone17">
        <div class="iphone17-viewport">
          <div class="iphone17-screen">
            <div class="top-chrome">
              <div class="ios-statusbar">
                <span>9:41</span>
                <div class="dynamic-island">
                  <div class="camera-lens"></div>
                </div>
                <div class="ios-status-icons">
                  <svg width="16" height="12" viewBox="0 0 16 12" fill="#fff"><rect x="0" y="7.5" width="2.7" height="4.5" rx="0.8"/><rect x="4.3" y="5.2" width="2.7" height="6.8" rx="0.8"/><rect x="8.6" y="2.6" width="2.7" height="9.4" rx="0.8"/><rect x="12.9" y="0" width="2.7" height="12" rx="0.8"/></svg>
                  <svg width="15" height="12" viewBox="0 0 24 18" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round"><path d="M2 6.5C7.5 1.5 16.5 1.5 22 6.5"/><path d="M5.8 10.5C9.4 7.2 14.6 7.2 18.2 10.5"/><circle cx="12" cy="14.8" r="1.8" fill="#fff" stroke="none"/></svg>
                  <span class="battery">98</span>
                </div>
              </div>

              <div class="tg-header">
                <div class="tg-back">‹</div>
                <div class="tg-title-pill">
                  <div class="name">Mobile Agent Control (<small style="font-size:0.75em;color:#38bdf8;display:inline-flex;align-items:center;transform:translateY(-0.5px);">AI</small> MAC)</div>
                  <div class="sub">bot</div>
                </div>
                <div class="tg-avatar"><small style="font-size:9px;font-weight:900;color:#bae6fd;margin-right:1px;display:inline-flex;align-items:center;transform:translateY(-0.5px);">AI</small>M</div>
              </div>
            </div>

            <div class="tg-wallpaper">
              <!-- Top scrolled message: Select a Workspace buttons (just like real iOS Telegram scroll!) -->
              <div class="tg-msg-group">
                <div class="tg-inline-kb">
                  <div class="tg-kb-row">
                    <div class="tg-kb-btn">🟢 PAYMENT BOOK •</div>
                    <div class="tg-kb-btn">🟢 AI Portfolio</div>
                  </div>
                  <div class="tg-kb-row">
                    <div class="tg-kb-btn">🟢 CRYPTO FUSION</div>
                    <div class="tg-kb-btn">⚙️ Settings</div>
                  </div>
                </div>
              </div>

              <!-- Message 1: Workspace Selected + 2x2 Inline Keyboard -->
              <div class="tg-msg-group">
                <div class="tg-bubble-bot">
                  <div>🗂 <b>Workspace Selected</b></div>
                  <div><b>PAYMENT BOOK</b></div>
                  <div><code>/Users/dev/code/payment-book</code></div>
                  <div class="tg-spacer"></div>
                  <div>🧠 AI Model: <code>Gemini 4 Argon (high)</code></div>
                  <div class="tg-spacer"></div>
                  <div>🚀 Staging (3): <code>BACKOFFICE, API, GATE</code></div>
                  <div>🏁 Prod (3): <code>BACKOFFICE, API, GATE</code><span class="tg-time">09:38</span></div>
                </div>
                <div class="tg-inline-kb">
                  <div class="tg-kb-row">
                    <div class="tg-kb-btn">✅ Same Chat •</div>
                    <div class="tg-kb-btn">🆕 New Chat</div>
                  </div>
                  <div class="tg-kb-row">
                    <div class="tg-kb-btn">📜 History</div>
                    <div class="tg-kb-btn">🧠 AI Model</div>
                  </div>
                </div>
              </div>

              <!-- User Prompt Bubble -->
              <div class="tg-bubble-user">
                Fix mobile sticky header redraw on modal open<span class="tg-time">09:39 ✓✓</span>
              </div>

              <!-- Message 2: Antigravity working… -->
              <div class="tg-msg-group">
                <div class="tg-bubble-bot">
                  <div>🤖 Antigravity working…</div>
                  <div><b>PAYMENT BOOK</b></div>
                  <div class="tg-spacer"></div>
                  <div>⚙️ <code>tool: edit_file (ACTIVE)</code><span class="tg-time">09:40</span></div>
                </div>
              </div>

              <!-- Message 3: Staging Deploy Succeeded -> Promote to Prod? -->
              <div class="tg-msg-group">
                <div class="tg-bubble-bot">
                  <div>🚀 <b>Staging Jenkins Deploy Succeeded!</b></div>
                  <div>• <code>BACKOFFICE #410</code> — <b>SUCCESS</b></div>
                  <div class="tg-spacer"></div>
                  <div><b>Deploy to Production?</b><span class="tg-time">09:41</span></div>
                </div>
                <div class="tg-inline-kb">
                  <div class="tg-kb-row single">
                    <div class="tg-kb-btn">🚀 Yes, deploy on prod</div>
                  </div>
                  <div class="tg-kb-row">
                    <div class="tg-kb-btn">✅ Yes (skip prod)</div>
                    <div class="tg-kb-btn">↩️ Revert</div>
                  </div>
                </div>
              </div>
            </div>

            <!-- Bottom Telegram Input + Persistent 2-Button Reply Keyboard -->
            <div class="tg-bottom">
              <div class="tg-input-row">
                <div class="tg-menu-pill">≡ Menu</div>
                <div class="tg-icon-circle">
                  <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="#cbd5e1" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"/></svg>
                </div>
                <div class="tg-msg-field">
                  <span>Message</span>
                  <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="#9ca3af" stroke-width="1.8"><rect x="2" y="5" width="20" height="14" rx="2"/><line x1="6" y1="9" x2="6.01" y2="9"/><line x1="10" y1="9" x2="10.01" y2="9"/><line x1="14" y1="9" x2="14.01" y2="9"/><line x1="18" y1="9" x2="18.01" y2="9"/><line x1="7" y1="15" x2="17" y2="15"/></svg>
                </div>
                <div class="tg-icon-circle">
                  <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="#cbd5e1" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><line x1="12" y1="19" x2="12" y2="23"/></svg>
                </div>
              </div>
              <div class="tg-reply-kb">
                <div class="tg-reply-btn">🔀 Workspace</div>
                <div class="tg-reply-btn">⚙️ Settings</div>
              </div>
              <div class="ios-home-bar"></div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</body>
</html>
"""

@MainActor
func run() throws {
    let _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.accessory)
    let renderer = BannerRenderer()
    let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let outURL = currentDir.appendingPathComponent("assets/banner.png")
    try renderer.renderHTML(
        macBannerHTML,
        width: 1280,
        height: 700,
        outURL: outURL
    )
}

try MainActor.assumeIsolated {
    try run()
}
