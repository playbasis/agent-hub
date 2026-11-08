// Deterministic crop/scale only. Artwork and alpha come from image generation.
import AppKit
import ImageIO

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2 else { fatalError("usage: swift normalize-skill-portraits.swift input.png output.png") }
let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[0]) as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let w = image.width, h = image.height
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
var rows = [Int](repeating: 0, count: h), cols = [Int](repeating: 0, count: w)
for y in 0..<h { for x in 0..<w where pixels[(y * w + x) * 4 + 3] >= 128 { rows[y] += 1; cols[x] += 1 } }
let xs = cols.indices.filter { cols[$0] > max(3, h / 100) }
let ys = rows.indices.filter { rows[$0] > max(3, w / 100) }
guard let left = xs.first, let right = xs.last, let bottom = ys.first, let top = ys.last else { fatalError("Empty alpha") }
// Bitmap rows start at the top; CGContext drawing coordinates start below.
let minX = max(0, left - 2), maxX = min(w, right + 3)
let minY = max(0, h - 1 - top - 2), maxY = min(h, h - bottom + 2)
let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
// Draw the original into a transparent square with a consistent visible extent.
let size = 256, extent: CGFloat = 216
let scale = extent / max(bounds.width, bounds.height)
let output = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                       space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
output.interpolationQuality = .high
output.translateBy(x: (CGFloat(size) - bounds.width * scale) / 2, y: (CGFloat(size) - bounds.height * scale) / 2)
output.scaleBy(x: scale, y: scale)
output.translateBy(x: -bounds.minX, y: -bounds.minY)
// Clip isolated generation speckles outside the meaningful alpha bounds.
output.clip(to: bounds)
output.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
let result = output.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, result, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("PNG write failed") }
print("Normalized \(URL(fileURLWithPath: args[1]).lastPathComponent): 256×256 RGBA sRGB")
