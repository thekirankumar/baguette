// chrome-lab — research tool behind docs/features/chrome-bezel/device-hub-look.md.
//
// Renders a DeviceKit chrome the way Xcode 27's Device Hub does (crown ridges,
// behind-the-case buttons held back from the case's semi-transparent edge, any
// scale), fits that model against a Device Hub capture, captures Device Hub,
// and lays images side by side.
//
//   swiftc -O docs/features/chrome-bezel/scripts/chrome-lab.swift -o /tmp/chrome-lab
//
//   /tmp/chrome-lab render  --out hub.png --scale 3
//   /tmp/chrome-lab render  --out today.png --scale 1 --baguette-today
//   /tmp/chrome-lab fit     --capture docs/features/chrome-bezel/assets/device-hub-watch4-1x.png
//   /tmp/chrome-lab capture --out hub-window.png [--zoom-in 6 | --actual-size]
//   /tmp/chrome-lab compare --out cmp.png [--nearest] [--height 600] a.png "A" b.png "B"
//
// Research code: not part of the baguette target, not tested, watch4-tuned
// where noted. The production design is in the doc's build sequence.

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import ApplicationServices

// MARK: - arguments

var argv = Array(CommandLine.arguments.dropFirst())
let command = argv.isEmpty ? "help" : argv.removeFirst()
func option(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    let v = argv[i + 1]; argv.removeSubrange(i...(i + 1)); return v
}
func flag(_ name: String) -> Bool {
    guard let i = argv.firstIndex(of: name) else { return false }
    argv.remove(at: i); return true
}
func fail(_ message: String) -> Never { FileHandle.standardError.write((message + "\n").data(using: .utf8)!); exit(1) }

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - images

func loadImage(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let im = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read \(path)") }
    return im
}
func savePNG(_ image: CGImage, _ path: String) {
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, image, nil)
    guard CGImageDestinationFinalize(d) else { fail("cannot write \(path)") }
}

/// Premultiplied RGBA, 0…1, row 0 at the top.
struct Raster {
    let width: Int, height: Int
    var px: [Float]
    init(width: Int, height: Int) { self.width = width; self.height = height; px = [Float](repeating: 0, count: width * height * 4) }
    init(_ image: CGImage) {
        self.init(width: image.width, height: image.height)
        var b = [UInt8](repeating: 0, count: width * height * 4)
        let c = CGContext(data: &b, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        px = b.map { Float($0) / 255 }
    }
    /// Draw with chrome points as units, top-left origin.
    static func drawing(width: Int, height: Int, pointScale k: Double, _ body: (CGContext) -> Void) -> Raster {
        var b = [UInt8](repeating: 0, count: width * height * 4)
        let c = CGContext(data: &b, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: k, y: -k)
        body(c)
        var r = Raster(width: width, height: height); r.px = b.map { Float($0) / 255 }; return r
    }
    var image: CGImage {
        var b = px.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
        let c = CGContext(data: &b, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return c.makeImage()!
    }
}

// MARK: - the chrome bundle

struct Input {
    let name, image, type, anchor, align: String
    let onTop: Bool
    let normal: CGPoint, rollover: CGPoint
}

struct Chrome {
    let dir: String
    let compositeName: String
    let devicePadding: (top: Double, left: Double, bottom: Double, right: Double)
    let inputs: [Input]

    init(id: String) {
        dir = "/Library/Developer/DeviceKit/Chrome/\(id).devicechrome/Contents/Resources/"
        guard let data = FileManager.default.contents(atPath: dir + "chrome.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["images"] as? [String: Any],
              let composite = images["composite"] as? String else { fail("no composite chrome at \(dir)") }
        compositeName = composite
        let p = images["devicePadding"] as? [String: Double] ?? [:]
        devicePadding = (p["top"] ?? 0, p["left"] ?? 0, p["bottom"] ?? 0, p["right"] ?? 0)
        func point(_ any: Any?) -> CGPoint { let d = any as? [String: Double] ?? [:]; return CGPoint(x: d["x"] ?? 0, y: d["y"] ?? 0) }
        inputs = (json["inputs"] as? [[String: Any]] ?? []).map { i in
            let offsets = i["offsets"] as? [String: Any] ?? [:]
            return Input(name: i["name"] as? String ?? "", image: i["image"] as? String ?? "",
                         type: i["type"] as? String ?? "button", anchor: i["anchor"] as? String ?? "right",
                         align: i["align"] as? String ?? "leading", onTop: i["onTop"] as? Bool ?? false,
                         normal: point(offsets["normal"]), rollover: point(offsets["rollover"]))
        }
    }
    func page(_ name: String) -> CGPDFPage {
        guard let doc = CGPDFDocument(URL(fileURLWithPath: dir + name + ".pdf") as CFURL), let p = doc.page(at: 1) else { fail("missing \(name).pdf") }
        return p
    }
    func size(_ name: String) -> CGSize { page(name).getBoxRect(.mediaBox).size }
    var caseSize: CGSize { size(compositeName) }
    var canvas: CGSize { CGSize(width: caseSize.width + devicePadding.left + devicePadding.right,
                                height: caseSize.height + devicePadding.top + devicePadding.bottom) }
    var caseOrigin: CGPoint { CGPoint(x: devicePadding.left, y: devicePadding.top) }

    /// Rest rectangle in canvas points — baguette's rule (design.md): left anchor
    /// centres x; right / top / bottom rest at `2N − R` on the protrusion axis.
    /// `restX` overrides a right-anchored input's x (Device Hub measures differently).
    func rect(_ input: Input, restX: Double? = nil, dx: Double = 0) -> CGRect {
        let s = size(input.image), o = caseOrigin, c = caseSize
        let rest = CGPoint(x: 2 * input.normal.x - input.rollover.x, y: 2 * input.normal.y - input.rollover.y)
        var r: CGRect
        switch input.anchor {
        case "left":  r = CGRect(x: o.x + input.rollover.x - s.width / 2, y: o.y + input.rollover.y, width: s.width, height: s.height)
        case "right": r = CGRect(x: o.x + c.width + (restX ?? rest.x), y: o.y + rest.y, width: s.width, height: s.height)
        case "top":
            let x = input.align == "trailing" ? o.x + c.width + rest.x - s.width : o.x + rest.x
            r = CGRect(x: x, y: o.y + rest.y - s.height, width: s.width, height: s.height)
        default:
            let x = input.align == "trailing" ? o.x + c.width + rest.x - s.width : o.x + rest.x
            r = CGRect(x: x, y: o.y + c.height + rest.y, width: s.width, height: s.height)
        }
        return r.offsetBy(dx: dx, dy: 0)
    }
}

func draw(_ page: CGPDFPage, in r: CGRect, _ c: CGContext) {
    let b = page.getBoxRect(.mediaBox)
    c.saveGState(); c.translateBy(x: r.minX, y: r.maxY); c.scaleBy(x: r.width / b.width, y: -r.height / b.height)
    c.drawPDFPage(page); c.restoreGState()
}

/// DeviceKit's `drawCrownLines(context:size:displayScale:)`, decoded — see the doc.
func drawCrownRidges(crown r: CGRect, art: CGPDFPage, scrollOffset: Double, pointScale k: Double, _ c: CGContext) {
    let w = r.width, h = r.height, artW = art.getBoxRect(.mediaBox).width
    let spacing = 3 * w / artW, cy = h / 2, phase = remainder(scrollOffset, spacing)
    // Mask: the crown art's alpha (`.destinationIn` in DeviceKit).
    let mw = max(1, Int(w * k)), mh = max(1, Int(h * k))
    let mask = CGContext(data: nil, width: mw, height: mh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
    let ab = art.getBoxRect(.mediaBox); mask.scaleBy(x: CGFloat(mw) / ab.width, y: CGFloat(mh) / ab.height); mask.drawPDFPage(art)
    c.saveGState()
    c.clip(to: r, mask: mask.makeImage()!)
    c.clip(to: CGRect(x: r.minX + 0.75 * w, y: r.minY, width: 0.25 * w, height: h))
    c.setLineWidth(w / artW); c.setLineCap(.round); c.setLineJoin(.miter); c.setMiterLimit(10)
    for dir in [-1.0, 1.0] {
        var y = cy + phase + (dir > 0 ? spacing : 0)
        while y > 1 && y < h - 1 {
            let closeness = cy <= 1e-6 ? 0 : max(0, 1 - abs(y - cy) / cy)
            let u = y / h * 2 - 1, bulge = min(1, max(0, 1 - u * u))
            let len = w * 0.25 * 0.85 * (0.4 + 0.6 * bulge), x1 = w * 0.875 - len / 2
            c.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.4 * (closeness * 0.8 + 0.2)))
            c.move(to: CGPoint(x: r.minX + x1, y: r.minY + y)); c.addLine(to: CGPoint(x: r.minX + x1 + len, y: r.minY + y)); c.strokePath()
            y += dir * spacing * max(0.2, min(1, log(max(closeness, 1e-6)) * 0.298671653 + 1.097005268))
        }
    }
    c.restoreGState()
}

// MARK: - the model

struct ModelOptions {
    var ridges = true
    var holdBack = true          // behind-the-case buttons only where the case is fully transparent
    var sideRestX: Double? = nil // e.g. -33.5, Device Hub's measured side-button rest on watch4
    var crownDX = 0.0            // e.g. 0.5, Device Hub's measured crown offset on watch4
    var scrollOffset = 0.0
}

/// The three layers, rasterized once at `pointScale` pixels per chrome point.
struct Layers {
    let behind: Raster, caseLayer: Raster, onTop: Raster
    init(chrome: Chrome, pointScale k: Double, options o: ModelOptions) {
        let w = Int((chrome.canvas.width * k).rounded()), h = Int((chrome.canvas.height * k).rounded())
        caseLayer = .drawing(width: w, height: h, pointScale: k) { c in
            draw(chrome.page(chrome.compositeName), in: CGRect(origin: chrome.caseOrigin, size: chrome.caseSize), c)
        }
        func inputs(onTop: Bool) -> Raster {
            .drawing(width: w, height: h, pointScale: k) { c in
                for i in chrome.inputs where i.onTop == onTop {
                    let isCrown = i.type == "crown"
                    let r = chrome.rect(i, restX: (i.type == "button" && i.anchor == "right") ? o.sideRestX : nil, dx: isCrown ? o.crownDX : 0)
                    draw(chrome.page(i.image), in: r, c)
                    if isCrown && o.ridges { drawCrownRidges(crown: r, art: chrome.page(i.image), scrollOffset: o.scrollOffset, pointScale: k, c) }
                }
            }
        }
        behind = inputs(onTop: false); onTop = inputs(onTop: true)
    }

    /// `under` = how much of a behind button shows beneath a partly transparent
    /// case pixel: 0 is Device Hub (hold-back), 1 is baguette today.
    func composite(under: Float, background: Float?) -> Raster {
        var out = Raster(width: caseLayer.width, height: caseLayer.height)
        for p in 0..<(out.width * out.height) {
            let i = p * 4, ac = caseLayer.px[i + 3]
            let m: Float = ac <= 0 ? 1 : under
            var rgb: [Float] = [0, 0, 0], a: Float = 0
            if let bg = background { rgb = [bg, bg, bg]; a = 1 }
            func over(_ src: [Float], _ sa: Float) { for j in 0..<3 { rgb[j] = src[j] + (1 - sa) * rgb[j] }; a = sa + (1 - sa) * a }
            over([behind.px[i] * m, behind.px[i + 1] * m, behind.px[i + 2] * m], behind.px[i + 3] * m)
            over([caseLayer.px[i], caseLayer.px[i + 1], caseLayer.px[i + 2]], ac)
            over([onTop.px[i], onTop.px[i + 1], onTop.px[i + 2]], onTop.px[i + 3])
            out.px[i] = rgb[0]; out.px[i + 1] = rgb[1]; out.px[i + 2] = rgb[2]; out.px[i + 3] = a
        }
        return out
    }
}

func modelOptions() -> ModelOptions {
    var o = ModelOptions()
    if flag("--baguette-today") { o.ridges = false; o.holdBack = false }
    if flag("--no-ridges") { o.ridges = false }
    if flag("--no-hold-back") { o.holdBack = false }
    if flag("--device-hub-rest") { o.sideRestX = -33.5; o.crownDX = 0.5 }
    if let v = option("--side-rest-x") { o.sideRestX = Double(v) }
    if let v = option("--crown-dx") { o.crownDX = Double(v)! }
    if let v = option("--scroll") { o.scrollOffset = Double(v)! }
    return o
}

// MARK: - render

func render() {
    let out = option("--out") ?? "chrome.png"
    let scale = Double(option("--scale") ?? "3")!
    let chrome = Chrome(id: option("--chrome") ?? "watch4")
    let transparent = flag("--transparent")
    let o = modelOptions()
    let layers = Layers(chrome: chrome, pointScale: scale, options: o)
    savePNG(layers.composite(under: o.holdBack ? 0 : 1, background: transparent ? nil : 1).image, out)
    print("wrote \(out) (\(layers.caseLayer.width)×\(layers.caseLayer.height) px, \(scale)× chrome points)")
}

// MARK: - fit

// Device Hub's watch4 at Physical Size on a 1× display: 0.6624 px per chrome point.
// Offsets are for assets/device-hub-watch4-1x.png (a crop of the window capture
// at window pixel (540, 440)): capture px = origin + chrome pt × scale.
let hubScale = 0.6624
let hubOrigin = (x: 10.25, y: 31.25)
let hubRegion = (x: 182...209, y: 78...200)   // crown, notch and side button

func gaussianBlur(_ r: Raster, sigma: Double) -> Raster {
    guard sigma > 0 else { return r }
    let rad = Int(ceil(sigma * 3))
    var k = (-rad...rad).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
    let s = k.reduce(0, +); k = k.map { $0 / s }
    var tmp = r, out = r
    for y in 0..<r.height { for x in 0..<r.width { for j in 0..<4 {
        var a: Float = 0
        for (t, kv) in k.enumerated() { a += r.px[(y * r.width + min(r.width - 1, max(0, x + t - rad))) * 4 + j] * kv }
        tmp.px[(y * r.width + x) * 4 + j] = a } } }
    for y in 0..<r.height { for x in 0..<r.width { for j in 0..<4 {
        var a: Float = 0
        for (t, kv) in k.enumerated() { a += tmp.px[(min(r.height - 1, max(0, y + t - rad)) * r.width + x) * 4 + j] * kv }
        out.px[(y * r.width + x) * 4 + j] = a } } }
    return out
}

/// Box-average the 8× model down to capture pixels, placed at `origin`.
func resample(_ hi: Raster, n: Int, origin: (x: Double, y: Double), width: Int, height: Int) -> Raster {
    var out = Raster(width: width, height: height)
    for py in 0..<height { for px in 0..<width {
        let hx0 = Int(((Double(px) - origin.x) * Double(n)).rounded()), hy0 = Int(((Double(py) - origin.y) * Double(n)).rounded())
        var acc: [Float] = [0, 0, 0, 0]
        for sy in 0..<n { for sx in 0..<n {
            let hx = hx0 + sx, hy = hy0 + sy
            if hx < 0 || hy < 0 || hx >= hi.width || hy >= hi.height { acc[0] += 1; acc[1] += 1; acc[2] += 1; acc[3] += 1; continue }
            for j in 0..<4 { acc[j] += hi.px[(hy * hi.width + hx) * 4 + j] } } }
        for j in 0..<4 { out.px[(py * width + px) * 4 + j] = acc[j] / Float(n * n) } } }
    return out
}

func rmse(_ a: Raster, _ b: Raster) -> Double {
    var e = 0.0, n = 0
    for y in hubRegion.y { for x in hubRegion.x { for j in 0..<3 {
        let d = Double(a.px[(y * a.width + x) * 4 + j] - b.px[(y * b.width + x) * 4 + j]); e += d * d; n += 1 } } }
    return (e / Double(n)).squareRoot() * 255
}

func fit() {
    guard let path = option("--capture") else { fail("fit needs --capture <Device Hub capture>") }
    let capture = Raster(loadImage(path))
    let chrome = Chrome(id: option("--chrome") ?? "watch4")
    let writeDir = option("--write")
    let n = 8
    let o = modelOptions()
    let layers = Layers(chrome: chrome, pointScale: hubScale * Double(n), options: o)
    func model(under: Float, dx: Double, dy: Double, sigma: Double) -> Raster {
        gaussianBlur(resample(layers.composite(under: under, background: 1), n: n,
                              origin: (hubOrigin.x + dx, hubOrigin.y + dy), width: capture.width, height: capture.height), sigma: sigma)
    }
    // Cheap pass first: alignment at no blur, then blur × hold-back at that alignment.
    var best = (err: Double.infinity, dx: 0.0, dy: 0.0, sigma: 0.0, under: Float(0))
    for dx in stride(from: -1.0, through: 1.0, by: 0.25) { for dy in stride(from: -1.0, through: 1.0, by: 0.25) {
        let e = rmse(model(under: 0, dx: dx, dy: dy, sigma: 0.7), capture)
        if e < best.err { best = (e, dx, dy, 0.7, 0) } } }
    print(String(format: "alignment: dx %+.2f dy %+.2f px", best.dx, best.dy))
    print("RMSE (0–255) over the crown, notch and side button — under = how much of a behind button shows beneath the case edge:")
    for sigma in [0.0, 0.5, 0.7, 1.0] {
        var line = String(format: "  blur σ %.1f px:", sigma)
        for under in [Float(0), 0.25, 0.5, 0.75, 1] {
            let e = rmse(model(under: under, dx: best.dx, dy: best.dy, sigma: sigma), capture)
            line += String(format: "  under %.2f → %5.2f", under, e)
            if e < best.err { best = (e, best.dx, best.dy, sigma, under) }
        }
        print(line)
    }
    print(String(format: "best: under %.2f, blur σ %.1f px, RMSE %.2f", best.under, best.sigma, best.err))
    if let dir = writeDir {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        savePNG(model(under: best.under, dx: best.dx, dy: best.dy, sigma: 0).image, dir + "/model-crisp.png")
        savePNG(model(under: best.under, dx: best.dx, dy: best.dy, sigma: best.sigma).image, dir + "/model-soft.png")
        print("wrote \(dir)/model-crisp.png, \(dir)/model-soft.png (same grid as the capture)")
    }
}

// MARK: - capture

func capture() {
    let out = option("--out") ?? "device-hub.png"
    let zoomIn = Int(option("--zoom-in") ?? "0")!
    let actual = flag("--actual-size")
    let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    guard let win = windows.first(where: { ($0["kCGWindowOwnerName"] as? String) == "DeviceHub" && ($0["kCGWindowLayer"] as? Int) == 0 && !(($0["kCGWindowName"] as? String) ?? "").isEmpty }),
          let id = win["kCGWindowNumber"] as? Int, let pid = win["kCGWindowOwnerPID"] as? Int32 else { fail("no Device Hub window") }
    if zoomIn > 0 || actual {
        guard AXIsProcessTrusted() else { fail("zooming needs Accessibility permission for this terminal") }
        let app = AXUIElementCreateApplication(pid)
        func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
        func find(_ e: AXUIElement, _ symbol: String, depth: Int = 0) -> AXUIElement? {
            if (attr(e, "AXDescription") as? String)?.contains(symbol) == true || (attr(e, "AXIdentifier") as? String) == symbol { return e }
            guard depth < 15 else { return nil }
            for child in attr(e, "AXChildren") as? [AXUIElement] ?? [] { if let hit = find(child, symbol, depth: depth + 1) { return hit } }
            return nil
        }
        func press(_ symbol: String) {
            guard let b = find(app, symbol) else { fail("no \(symbol) button in Device Hub") }
            AXUIElementPerformAction(b, kAXPressAction as CFString)
        }
        if actual { press("1.magnifyingglass") }
        for _ in 0..<zoomIn { press("plus.magnifyingglass") }
        Thread.sleep(forTimeInterval: 1)
    }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", String(id), out]
    try? p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { fail("screencapture failed (Screen Recording permission?)") }
    print("wrote \(out) (window \(id), \((win["kCGWindowName"] as? String) ?? ""))")
}

// MARK: - compare

func compare() {
    let out = option("--out") ?? "compare.png"
    let height = CGFloat(Double(option("--height") ?? "600")!)
    let nearest = flag("--nearest")
    guard argv.count >= 2, argv.count % 2 == 0 else { fail("compare needs pairs: <image> <label> …") }
    let items = stride(from: 0, to: argv.count, by: 2).map { (loadImage(argv[$0]), argv[$0 + 1]) }
    let pad: CGFloat = 24, labelH: CGFloat = 40
    let widths = items.map { CGFloat($0.0.width) * height / CGFloat($0.0.height) }
    let W = widths.reduce(pad) { $0 + $1 + pad }, H = height + labelH + pad * 2
    let c = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
    c.interpolationQuality = nearest ? .none : .high
    var x = pad
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 18, nil)
    for (i, (image, label)) in items.enumerated() {
        c.draw(image, in: CGRect(x: x, y: pad, width: widths[i], height: height))
        c.textPosition = CGPoint(x: x, y: pad + height + 12)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])), c)
        x += widths[i] + pad
    }
    savePNG(c.makeImage()!, out)
    print("wrote \(out)")
}

// MARK: -

switch command {
case "render": render()
case "fit": fit()
case "capture": capture()
case "compare": compare()
default:
    print("""
    chrome-lab render  --out <png> [--scale 3] [--chrome watch4] [--transparent]
                       [--baguette-today | --no-ridges | --no-hold-back] [--device-hub-rest]
                       [--side-rest-x <pt>] [--crown-dx <pt>] [--scroll <pt>]
    chrome-lab fit     --capture <png> [--chrome watch4] [--write <dir>] [render model flags]
    chrome-lab capture --out <png> [--zoom-in <n> | --actual-size]
    chrome-lab compare --out <png> [--height 600] [--nearest] <png> <label> [<png> <label> …]
    """)
}
