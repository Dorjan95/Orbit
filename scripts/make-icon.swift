import AppKit
import CoreGraphics
import Foundation

let output = CommandLine.arguments.dropFirst().first ?? "build/Orbit.iconset"
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for (points, scale) in [
  (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
] {
  let size = points * scale
  let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
  let outer = CGPath(
    roundedRect: CGRect(x: 35, y: 35, width: 954, height: 954), cornerWidth: 225, cornerHeight: 225,
    transform: nil)
  context.addPath(outer)
  context.setFillColor(CGColor(red: 0.04, green: 0.055, blue: 0.06, alpha: 1))
  context.fillPath()
  context.addPath(outer)
  context.setStrokeColor(CGColor(red: 0.18, green: 0.23, blue: 0.13, alpha: 1))
  context.setLineWidth(5)
  context.strokePath()
  for (index, height) in [120, 275, 465, 610, 400, 220, 100].enumerated() {
    let rect = CGRect(
      x: CGFloat(225 + index * 83), y: CGFloat(512 - height / 2), width: 45, height: CGFloat(height)
    )
    context.addPath(
      CGPath(roundedRect: rect, cornerWidth: 22.5, cornerHeight: 22.5, transform: nil))
    context.setFillColor(CGColor(red: 0.76, green: 1, blue: 0.25, alpha: 1))
    context.fillPath()
  }
  let image = context.makeImage()!
  let bitmap = NSBitmapImageRep(cgImage: image)
  let suffix = scale == 2 ? "@2x" : ""
  try bitmap.representation(using: .png, properties: [:])!.write(
    to: URL(fileURLWithPath: output).appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
  )
}
