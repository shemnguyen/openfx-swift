// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import IOSurface
import OpenFXHost

/// Moves `OFXImageBuffer`s between processes as IOSurfaces.
///
/// The sender copies its pixels into a new surface once; the receiver wraps the
/// surface's memory in place, so the frame crosses XPC without being copied.
enum OFXSurfaceFrames {
  /// Copies `buffer` into a new IOSurface. Returns nil for empty buffers.
  static func makeSurface(from buffer: OFXImageBuffer) -> (IOSurface, OFXWire.Frame)? {
    guard buffer.width > 0, buffer.height > 0 else { return nil }
    let bpp = buffer.bytesPerPixel
    let rowBytes = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, buffer.width * bpp)
    guard let surface = IOSurface(properties: [
      .width: buffer.width,
      .height: buffer.height,
      .bytesPerElement: bpp,
      .bytesPerRow: rowBytes,
      .allocSize: rowBytes * buffer.height,
    ]) else { return nil }

    surface.lock(options: [], seed: nil)
    let base = surface.baseAddress
    let copyBytes = buffer.width * bpp
    for row in 0..<buffer.height {
      memcpy(base + row * surface.bytesPerRow, buffer.row(Int(buffer.bounds.y1) + row), copyBytes)
    }
    surface.unlock(options: [], seed: nil)

    let b = buffer.bounds
    let frame = OFXWire.Frame(bounds: [b.x1, b.y1, b.x2, b.y2], bitDepth: buffer.bitDepth.rawValue,
                              components: buffer.components.rawValue,
                              premultiplication: buffer.premultiplication.rawValue,
                              pixelAspectRatio: buffer.pixelAspectRatio)
    return (surface, frame)
  }

  /// Wraps a received surface as an image buffer. The surface stays locked
  /// (read-only when `readOnly`) for as long as the buffer is alive.
  static func buffer(from surface: IOSurface, frame: OFXWire.Frame, readOnly: Bool) throws -> OFXImageBuffer {
    guard frame.bounds.count == 4 else { throw OFXRemoteError.badReply("frame bounds") }
    let bounds = OfxRectI(x1: frame.bounds[0], y1: frame.bounds[1], x2: frame.bounds[2], y2: frame.bounds[3])
    let depth = OFXBitDepth(rawValue: frame.bitDepth)
    let components = OFXImageComponents(rawValue: frame.components)
    guard depth.bytesPerComponent > 0, components.count > 0,
          surface.width >= bounds.width, surface.height >= bounds.height,
          surface.bytesPerRow >= bounds.width * depth.bytesPerComponent * components.count
    else { throw OFXRemoteError.badReply("frame does not match its surface") }

    let lock = SurfaceLock(surface, readOnly: readOnly)
    let buffer = OFXImageBuffer(wrapping: surface.baseAddress, bounds: bounds, rowBytes: surface.bytesPerRow,
                                bitDepth: depth, components: components,
                                premultiplication: OFXPremultiplication(rawValue: frame.premultiplication),
                                owner: lock)
    buffer.pixelAspectRatio = frame.pixelAspectRatio
    return buffer
  }
}

/// Holds an IOSurface's CPU lock for its lifetime.
final class SurfaceLock {
  let surface: IOSurface
  private let options: IOSurfaceLockOptions

  init(_ surface: IOSurface, readOnly: Bool) {
    self.surface = surface
    self.options = readOnly ? .readOnly : []
    surface.lock(options: options, seed: nil)
  }

  deinit { surface.unlock(options: options, seed: nil) }
}
