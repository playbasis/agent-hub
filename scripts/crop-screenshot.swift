// Crops the bottom status strip off a Hub snapshot and scales it to a width.
// usage: swiftc -O scripts/crop-screenshot.swift -o crop && crop IN.png OUT.png STRIP_POINTS WIDTH
// The window is 1400 points wide, so the strip is scaled by the image width.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("crop-screenshot: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 5, let strip = Double(arguments[3]), let width = Int(arguments[4]), strip >= 0, width > 0 else {
    fail("usage: crop-screenshot IN.png OUT.png STRIP_POINTS WIDTH")
}
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(arguments[1])") }
let cut = Int((strip * Double(image.width) / 1_400).rounded())
guard cut < image.height, let cropped = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: image.height - cut)) else {
    fail("nothing left after cropping")
}
let height = max(1, Int((Double(cropped.height) * Double(width) / Double(cropped.width)).rounded()))
guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("cannot make a bitmap") }
context.interpolationQuality = .high
context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
guard let output = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("cannot write \(arguments[2])")
}
CGImageDestinationAddImage(destination, output, nil)
guard CGImageDestinationFinalize(destination) else { fail("cannot write \(arguments[2])") }
