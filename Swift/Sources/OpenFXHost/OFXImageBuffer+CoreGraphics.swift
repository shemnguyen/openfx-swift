// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
import OpenFX

extension OFXImageBuffer {
  /// Creates an RGBA buffer from a `CGImage`, flipping rows into OpenFX's bottom-up order.
  ///
  /// The pixels are premultiplied (as CoreGraphics draws them) and converted to `bitDepth`.
  public convenience init?(cgImage: CGImage, bitDepth: OFXBitDepth = .float) {
    let w = cgImage.width, h = cgImage.height
    guard w > 0, h > 0 else { return nil }
    let staging = OFXImageBuffer(width: w, height: h, bitDepth: .byte, components: .rgba)
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: staging.data, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: staging.rowBytes, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // CGBitmapContext memory is top row first; flip so row 0 is the bottom.
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

    self.init(bounds: staging.bounds, bitDepth: bitDepth, components: .rgba)
    copyPixels(from: staging)
  }

  /// Renders the buffer into an 8-bit sRGB `CGImage`.
  public func makeCGImage() -> CGImage? {
    guard width > 0, height > 0 else { return nil }
    // Expand to 8-bit RGBA with origin at 0,0, then flip into CoreGraphics' top-down order.
    let staging = OFXImageBuffer(width: width, height: height, bitDepth: .byte, components: .rgba)
    let shifted = OFXImageBuffer(wrapping: data, bounds: OfxRectI(x1: 0, y1: 0, x2: Int32(width), y2: Int32(height)),
                                 rowBytes: rowBytes, bitDepth: bitDepth, components: components)
    staging.copyPixels(from: shifted)

    let bytesPerRow = width * 4
    var flipped = Data(count: bytesPerRow * height)
    flipped.withUnsafeMutableBytes { dst in
      for y in 0..<height {
        memcpy(dst.baseAddress! + (height - 1 - y) * bytesPerRow, staging.row(y), bytesPerRow)
      }
    }
    let alpha: CGImageAlphaInfo
    switch (components, premultiplication) {
    case (.rgb, _), (_, .opaque): alpha = .noneSkipLast
    case (_, .unpremultiplied): alpha = .last
    default: alpha = .premultipliedLast
    }
    guard let provider = CGDataProvider(data: flipped as CFData) else { return nil }
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: bytesPerRow, space: space, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }
}
#endif
