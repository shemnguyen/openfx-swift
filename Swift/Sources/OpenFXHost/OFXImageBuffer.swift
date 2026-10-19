// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import OpenFX

/// A block of pixels in OpenFX layout: rows run bottom-to-top, and pixel
/// `(x, y)` in image coordinates lives at
/// `data + (y - bounds.y1) * rowBytes + (x - bounds.x1) * bytesPerPixel`.
///
/// Supports byte, short and float depths with RGBA, RGB or Alpha components.
public final class OFXImageBuffer: @unchecked Sendable {
  public let bounds: OfxRectI
  public let bitDepth: OFXBitDepth
  public let components: OFXImageComponents
  public let rowBytes: Int
  public let data: UnsafeMutableRawPointer
  public var premultiplication: OFXPremultiplication
  public var pixelAspectRatio: Double = 1

  public var width: Int { bounds.width }
  public var height: Int { bounds.height }
  public var bytesPerPixel: Int { bitDepth.bytesPerComponent * components.count }
  public var byteCount: Int { rowBytes * height }

  private let ownsMemory: Bool
  /// Keeps memory owned elsewhere (e.g. a locked IOSurface) alive for as long as the buffer.
  private let owner: AnyObject?

  /// Allocates a zero-filled buffer.
  public init(bounds: OfxRectI, bitDepth: OFXBitDepth = .float, components: OFXImageComponents = .rgba,
              premultiplication: OFXPremultiplication = .premultiplied) {
    precondition(bitDepth.bytesPerComponent > 0 && bitDepth != .half, "unsupported bit depth \(bitDepth)")
    precondition(components.count > 0, "unsupported components \(components)")
    self.bounds = bounds
    self.bitDepth = bitDepth
    self.components = components
    self.premultiplication = premultiplication
    let bpp = bitDepth.bytesPerComponent * components.count
    // Round rows up to 16 bytes so rows start aligned for SIMD-minded plug-ins.
    self.rowBytes = (max(bounds.width, 0) * bpp + 15) & ~15
    let size = max(rowBytes * max(bounds.height, 0), 16)
    self.data = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 64)
    self.data.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    self.ownsMemory = true
    self.owner = nil
  }

  public convenience init(width: Int, height: Int, bitDepth: OFXBitDepth = .float,
                          components: OFXImageComponents = .rgba,
                          premultiplication: OFXPremultiplication = .premultiplied) {
    self.init(bounds: OfxRectI(x1: 0, y1: 0, x2: Int32(width), y2: Int32(height)),
              bitDepth: bitDepth, components: components, premultiplication: premultiplication)
  }

  /// Wraps memory owned elsewhere. The memory must outlive the buffer; pass the
  /// object that owns it as `owner` to have the buffer keep it alive.
  public init(wrapping data: UnsafeMutableRawPointer, bounds: OfxRectI, rowBytes: Int,
              bitDepth: OFXBitDepth, components: OFXImageComponents,
              premultiplication: OFXPremultiplication = .premultiplied, owner: AnyObject? = nil) {
    self.data = data
    self.bounds = bounds
    self.rowBytes = rowBytes
    self.bitDepth = bitDepth
    self.components = components
    self.premultiplication = premultiplication
    self.ownsMemory = false
    self.owner = owner
  }

  deinit {
    if ownsMemory { data.deallocate() }
  }

  /// Address of the first byte of row `y` (in image coordinates).
  @inline(__always)
  public func row(_ y: Int) -> UnsafeMutableRawPointer {
    data + (y - Int(bounds.y1)) * rowBytes
  }

  /// Address of pixel `(x, y)` (in image coordinates).
  @inline(__always)
  public func pixelAddress(x: Int, y: Int) -> UnsafeMutableRawPointer {
    row(y) + (x - Int(bounds.x1)) * bytesPerPixel
  }

  /// Reads pixel `(x, y)` as normalised RGBA floats.
  public func rgba(x: Int, y: Int) -> SIMD4<Float> {
    var out = [Float](repeating: 0, count: 4)
    readRow(y: y, from: x, count: 1, into: &out)
    return SIMD4(out[0], out[1], out[2], out[3])
  }

  /// Writes pixel `(x, y)` from normalised RGBA floats.
  public func setRGBA(x: Int, y: Int, _ v: SIMD4<Float>) {
    writeRow(y: y, from: x, count: 1, rgba: [v.x, v.y, v.z, v.w])
  }

  /// Fills the whole buffer with one colour.
  public func fill(_ v: SIMD4<Float>) {
    let line = (0..<width).flatMap { _ in [v.x, v.y, v.z, v.w] }
    for y in Int(bounds.y1)..<Int(bounds.y2) {
      writeRow(y: y, from: Int(bounds.x1), count: width, rgba: line)
    }
  }

  /// A copy of this buffer in another depth / component layout.
  public func converted(to bitDepth: OFXBitDepth, components: OFXImageComponents? = nil) -> OFXImageBuffer {
    let dst = OFXImageBuffer(bounds: bounds, bitDepth: bitDepth, components: components ?? self.components,
                             premultiplication: premultiplication)
    dst.pixelAspectRatio = pixelAspectRatio
    dst.copyPixels(from: self)
    return dst
  }

  /// Copies the overlapping region of `source` into this buffer, converting as needed.
  public func copyPixels(from source: OFXImageBuffer) {
    let region = bounds.intersection(source.bounds)
    guard !region.isEmpty else { return }
    let n = region.width
    if source.bitDepth == bitDepth && source.components == components {
      let bytes = n * bytesPerPixel
      for y in Int(region.y1)..<Int(region.y2) {
        memcpy(pixelAddress(x: Int(region.x1), y: y),
               source.pixelAddress(x: Int(region.x1), y: y), bytes)
      }
      return
    }
    var scratch = [Float](repeating: 0, count: n * 4)
    for y in Int(region.y1)..<Int(region.y2) {
      source.readRow(y: y, from: Int(region.x1), count: n, into: &scratch)
      writeRow(y: y, from: Int(region.x1), count: n, rgba: scratch)
    }
  }

  // MARK: Row conversion

  /// Reads `count` pixels of row `y` starting at `x` into `out` as RGBA floats.
  func readRow(y: Int, from x: Int, count: Int, into out: inout [Float]) {
    let src = pixelAddress(x: x, y: y)
    let nc = components.count
    out.withUnsafeMutableBufferPointer { o in
      func expand(_ load: (Int) -> Float) {
        for i in 0..<count {
          let b = i * nc
          switch nc {
          case 4:
            o[i * 4] = load(b); o[i * 4 + 1] = load(b + 1)
            o[i * 4 + 2] = load(b + 2); o[i * 4 + 3] = load(b + 3)
          case 3:
            o[i * 4] = load(b); o[i * 4 + 1] = load(b + 1)
            o[i * 4 + 2] = load(b + 2); o[i * 4 + 3] = 1
          default:
            let a = load(b)
            o[i * 4] = a; o[i * 4 + 1] = a; o[i * 4 + 2] = a; o[i * 4 + 3] = a
          }
        }
      }
      switch bitDepth {
      case .byte:
        let p = src.assumingMemoryBound(to: UInt8.self)
        expand { Float(p[$0]) / 255 }
      case .short:
        let p = src.assumingMemoryBound(to: UInt16.self)
        expand { Float(p[$0]) / 65535 }
      default:
        let p = src.assumingMemoryBound(to: Float.self)
        expand { p[$0] }
      }
    }
  }

  /// Writes `count` RGBA float pixels into row `y` starting at `x`.
  func writeRow(y: Int, from x: Int, count: Int, rgba: [Float]) {
    let dst = pixelAddress(x: x, y: y)
    let nc = components.count
    rgba.withUnsafeBufferPointer { s in
      func pack(_ store: (Int, Float) -> Void) {
        for i in 0..<count {
          let b = i * nc
          switch nc {
          case 4:
            store(b, s[i * 4]); store(b + 1, s[i * 4 + 1])
            store(b + 2, s[i * 4 + 2]); store(b + 3, s[i * 4 + 3])
          case 3:
            store(b, s[i * 4]); store(b + 1, s[i * 4 + 1]); store(b + 2, s[i * 4 + 2])
          default:
            store(b, s[i * 4 + 3])
          }
        }
      }
      switch bitDepth {
      case .byte:
        let p = dst.assumingMemoryBound(to: UInt8.self)
        pack { p[$0] = UInt8(max(0, min(255, ($1 * 255).rounded()))) }
      case .short:
        let p = dst.assumingMemoryBound(to: UInt16.self)
        pack { p[$0] = UInt16(max(0, min(65535, ($1 * 65535).rounded()))) }
      default:
        let p = dst.assumingMemoryBound(to: Float.self)
        pack { p[$0] = $1 }
      }
    }
  }
}
