// make_icon.swift — Blanc Chess's icon: the Blanc Notes B with its lower bowl closed solid white and a knight
// cut out of it, where Blanc Notes has its piano keys. Black ground, one soft spotlight low behind the mark.
//
//   swift Tools/make_icon.swift <blanc-notes-icon-1024.png> <knight.svg> <out-icon.png> <out-mark.png>
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
guard a.count == 5 else { fatalError("usage: make_icon.swift bn-icon.png knight.svg out-icon.png out-mark.png") }
let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
guard let source = CIImage(contentsOf: URL(fileURLWithPath: a[1])) else { fatalError("can't read \(a[1])") }
let extent = source.extent
let S = extent.width   // 1024

// 1. Lift the white B out of the Blanc Notes icon (same ramp as Blanc Notes' make-icon.swift).
let mono = source.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
let markCI = mono.applyingFilter("CIColorMatrix", parameters: [
    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 4.0, y: 0, z: 0, w: 0),
    "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: -2.2),
]).applyingFilter("CIColorClamp").cropped(to: extent)
guard let markCG = ci.createCGImage(markCI, from: extent) else { fatalError("mark") }

// 2. Draw the mark, close the piano counter into a solid bowl, then cut the knight out of it.
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("ctx") }
ctx.draw(markCG, in: CGRect(x: 0, y: 0, width: S, height: S))
// Measured on the 1024 icon (top-left origin): lower counter x 394–618, y 494–776. CoreGraphics is y-up.
func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
    CGRect(x: x0 / 1024 * S, y: S - y1 / 1024 * S, width: (x1 - x0) / 1024 * S, height: (y1 - y0) / 1024 * S)
}
// Close the counter: the piano keys and the gaps between them become one solid white bowl…
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(rect(392, 490, 624, 777))

// …and the knight is cut out of it: our own piece art as a silhouette, standing on a white base.
guard let svg = NSImage(contentsOf: URL(fileURLWithPath: a[2])) else { fatalError("can't read \(a[2])") }
let kSize = 250.0 / 1024 * S
var kRect = CGRect(x: 0, y: 0, width: kSize, height: kSize)
guard let knight = svg.cgImage(forProposedRect: &kRect, context: nil, hints: nil) else { fatalError("knight") }
// Centred in the counter (x 394–618, y 495–776 on the 1024 icon, top-left origin), a hair above middle.
let kTop = 640.0 / 1024 * S - kSize * 0.52
let kDraw = CGRect(x: 506 / 1024 * S - kSize * 0.52, y: S - kTop - kSize, width: kSize, height: kSize)
ctx.saveGState()
ctx.clip(to: kDraw, mask: knight)
ctx.clear(kDraw)
ctx.restoreGState()
guard let finalMark = ctx.makeImage() else { fatalError("final") }

// 3. Ground: black, one mint spotlight low behind the mark.
let markImage = CIImage(cgImage: finalMark)
let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
let glow = CIFilter.radialGradient()
glow.center = CGPoint(x: S * 0.5, y: S * 0.34)
glow.radius0 = 0
glow.radius1 = Float(S * 0.52)
glow.color0 = CIColor(red: 0x5C / 255.0, green: 0xE0 / 255.0, blue: 0xA5 / 255.0, alpha: 0.5)
glow.color1 = CIColor(red: 0x5C / 255.0, green: 0xE0 / 255.0, blue: 0xA5 / 255.0, alpha: 0)
let icon = markImage.composited(over: glow.outputImage!.cropped(to: extent).composited(over: black))

func write(_ image: CIImage, _ path: String, alpha: Bool) {
    guard let cg = ci.createCGImage(image, from: extent, format: alpha ? .RGBA8 : .RGBA8, colorSpace: space),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("can't write \(path)")
    }
    var out = cg
    if !alpha, let flat = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
        flat.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        out = flat.makeImage() ?? cg
    }
    CGImageDestinationAddImage(dest, out, nil)
    CGImageDestinationFinalize(dest)
}
write(icon, a[3], alpha: false)
write(markImage, a[4], alpha: true)
print("wrote \(a[3]) and \(a[4])")
