// Draws Tanto's placeholder icon, a knob turned low on a dark tile, into an .iconset folder for iconutil.
//
// Usage: swift scripts/make-icon.swift FOLDER
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws the icon on a 1024-unit canvas scaled to `pixels`.
func icon(pixels: Int) -> CGImage {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("no bitmap context for \(pixels) pixels") }
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let dark = CGColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
    // The tile follows Apple's icon grid: 824 units with a 185-unit corner radius.
    context.addPath(
        CGPath(
            roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185,
            transform: nil))
    context.setFillColor(dark)
    context.fillPath()
    context.addEllipse(in: CGRect(x: 262, y: 262, width: 500, height: 500))
    context.setFillColor(CGColor(srgbRed: 0.88, green: 0.56, blue: 0.16, alpha: 1))
    context.fillPath()
    // The pointer at ten o'clock.
    let direction = CGPoint(x: -sin(Double.pi / 3), y: cos(Double.pi / 3))
    context.move(to: CGPoint(x: 512 + 40 * direction.x, y: 512 + 40 * direction.y))
    context.addLine(to: CGPoint(x: 512 + 200 * direction.x, y: 512 + 200 * direction.y))
    context.setStrokeColor(dark)
    context.setLineWidth(44)
    context.setLineCap(.round)
    context.strokePath()
    guard let image = context.makeImage() else { fatalError("no image for \(pixels) pixels") }
    return image
}

/// Writes `image` as a PNG file.
func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("cannot create \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else { fatalError("usage: swift scripts/make-icon.swift FOLDER") }
let folder = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    write(icon(pixels: points), to: folder.appending(path: "icon_\(points)x\(points).png"))
    write(icon(pixels: 2 * points), to: folder.appending(path: "icon_\(points)x\(points)@2x.png"))
}
