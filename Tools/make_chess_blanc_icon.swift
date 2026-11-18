// make_chess_blanc_icon.swift — the Chess Blanc icon from the Blanc B (docs/brand/blanc-B-black-on-white.png):
// a dark 8×8 checkerboard, a blue spotlight, a soft blue halo, and the B in white on top.
//
//   swift Tools/make_chess_blanc_icon.swift docs/brand/blanc-B-black-on-white.png <out-icon.png> <out-mark.png>
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

let a = CommandLine.arguments
guard a.count == 4 else { fatalError("usage: make_chess_blanc_icon.swift B.png out-icon.png out-mark.png") }
let S: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext(options: [.workingColorSpace: space])

// 1. The B as a white shape on transparent: alpha = darkness, with a steep ramp so edges stay crisp.
guard let src = CIImage(contentsOf: URL(fileURLWithPath: a[1])) else { fatalError("can't read \(a[1])") }
let mono = src.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
let maskCI = mono.applyingFilter("CIColorMatrix", parameters: [
    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: -3.0, y: 0, z: 0, w: 0),
    "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 2.2),
]).applyingFilter("CIColorClamp")
let full = ci.createCGImage(maskCI, from: src.extent)!

// Tight bounds of the letter.
let w = full.width, h = full.height
let bctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
bctx.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = bctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
var x0 = w, y0 = h, x1 = 0, y1 = 0
for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 128 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
let letter = full.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1))!
let aspect = CGFloat(letter.width) / CGFloat(letter.height)

// Where the B sits: 56% of the icon tall, centred, a touch above the middle.
let bh = S * 0.56, bw = bh * aspect
let bRect = CGRect(x: (S - bw) / 2, y: (S - bh) / 2 + S * 0.01, width: bw, height: bh)

// 2. The ground: an 8×8 dark checkerboard.
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let q = S / 8
for r in 0..<8 { for c in 0..<8 {
    let lightSq = (r + c) % 2 == 0
    ctx.setFillColor(CGColor(srgbRed: lightSq ? 0.085 : 0.035, green: lightSq ? 0.09 : 0.037, blue: lightSq ? 0.11 : 0.045, alpha: 1))
    ctx.fill(CGRect(x: CGFloat(c) * q, y: CGFloat(r) * q, width: q, height: q))
}}
// 3. The blue spotlight behind the B, and a darker rim so the board falls away at the edges.
let centre = CGPoint(x: S / 2, y: S * 0.5)
let blue = CGColor(srgbRed: 0x5E / 255, green: 0xB8 / 255, blue: 1, alpha: 0.85)
let clear = CGColor(srgbRed: 0x5E / 255, green: 0xB8 / 255, blue: 1, alpha: 0)
ctx.drawRadialGradient(CGGradient(colorsSpace: space, colors: [blue, clear] as CFArray, locations: [0, 1])!,
                       startCenter: centre, startRadius: 0, endCenter: centre, endRadius: S * 0.6, options: [])
let rim = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.65)] as CFArray, locations: [0.55, 1])!
ctx.drawRadialGradient(rim, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: S * 0.75, options: [.drawsAfterEndLocation])

// 4. A soft blue halo shaped like the B, then the B itself.
let halo = CIImage(cgImage: letter)
    .applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.9),
        "inputBiasVector": CIVector(x: 0x5E / 255.0, y: 0xB8 / 255.0, z: 1, w: 0)])
    .composited(over: CIImage(color: .clear).cropped(to: CIImage(cgImage: letter).extent
        .insetBy(dx: -CGFloat(letter.height) * 0.3, dy: -CGFloat(letter.height) * 0.3)))
    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: CGFloat(letter.height) * 0.06])
    .cropped(to: CIImage(cgImage: letter).extent.insetBy(dx: -CGFloat(letter.height) * 0.3, dy: -CGFloat(letter.height) * 0.3))
let haloCG = ci.createCGImage(halo, from: halo.extent)!
let k = bh / CGFloat(letter.height)
ctx.draw(haloCG, in: CGRect(x: bRect.minX + halo.extent.minX * k, y: bRect.minY + halo.extent.minY * k,
                            width: halo.extent.width * k, height: halo.extent.height * k))
ctx.draw(letter, in: bRect)
let icon = ctx.makeImage()!

// 5. Write the icon flattened (the App Store wants no alpha) and the mark on its own.
func write(_ img: CGImage, _ path: String, flatten: Bool) {
    var out = img
    if flatten {
        let f = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        f.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        out = f.makeImage()!
    }
    try! NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
write(icon, a[2], flatten: true)
let m = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
m.draw(letter, in: bRect)
write(m.makeImage()!, a[3], flatten: false)
print("wrote \(a[2]) and \(a[3])")
