// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import OpenFX
import OpenFXPlugin

/// A filter that multiplies RGB by `gain` and a `tint`, optionally inverting first.
/// Written against `OpenFXPlugin`, run in-process by `OpenFXHost` in the tests.
final class GainPlugin: OFXEffectPlugin {
  static let identifier = "org.openeffects.swift.test.Gain"
  static let versionMinor: UInt32 = 2

  /// Instance-changed notifications seen by any instance, for assertions.
  nonisolated(unsafe) static var changes: [String] = []

  static func describe(_ effect: OFXEffectRef) throws {
    try effect.setDescription(label: "Swift Gain", grouping: "Swift Tests",
                              contexts: [.filter, .general], pixelDepths: [.byte, .float])
  }

  static func describeInContext(_ effect: OFXEffectRef, context: OFXImageEffectContext) throws {
    try effect.defineClip(kOfxImageEffectSimpleSourceClipName)
    try effect.defineClip(kOfxImageEffectOutputClipName)
    try effect.defineDouble("gain", label: "Gain", default: 1, range: 0...10, displayRange: 0...4)
    try effect.defineRGB("tint", label: "Tint", default: [1, 1, 1])
    try effect.defineBoolean("invert", label: "Invert", default: false)
    try effect.defineChoice("channels", label: "Channels", options: ["RGB", "Red only"], default: 0)
    try effect.defineParameter(.pushButton, name: "hello", label: "Say Hello")
  }

  let effect: OFXEffectRef
  let source: OFXClipRef
  let output: OFXClipRef
  let gain: OFXParamRef
  let tint: OFXParamRef
  let invert: OFXParamRef
  let channels: OFXParamRef

  init(effect: OFXEffectRef) throws {
    self.effect = effect
    source = try effect.clip(kOfxImageEffectSimpleSourceClipName)
    output = try effect.clip(kOfxImageEffectOutputClipName)
    gain = try effect.parameter("gain")
    tint = try effect.parameter("tint")
    invert = try effect.parameter("invert")
    channels = try effect.parameter("channels")
  }

  func isIdentity(_ args: OFXRenderArguments) throws -> (clip: String, time: Double)? {
    let t = args.time
    if try gain.double(at: t) == 1, try tint.rgb(at: t) == [1, 1, 1], try !invert.bool(at: t),
       try channels.int(at: t) == 0 {
      return (kOfxImageEffectSimpleSourceClipName, t)
    }
    return nil
  }

  func instanceChanged(_ args: OFXInstanceChangedArguments) throws {
    GainPlugin.changes.append(args.name)
    if args.name == "hello" {
      effect.connection.post(.message, "Hello from \(GainPlugin.identifier) at t=\(args.time)",
                             effect: effect.handle)
      // Parameters can be written back by the plug-in.
      try gain.set(2.0)
    }
  }

  func render(_ args: OFXRenderArguments) throws {
    let t = args.time
    let g = try gain.double(at: t)
    let tintRGB = try tint.rgb(at: t)
    let inv = try invert.bool(at: t)
    let redOnly = try channels.int(at: t) == 1
    let scale = SIMD3<Float>(Float(g * tintRGB.x), Float(g * tintRGB.y), Float(g * tintRGB.z))

    try source.withImage(at: t) { src in
      try output.withImage(at: t) { dst in
        let w = args.renderWindow
        for y in Int(w.y1)..<Int(w.y2) {
          for x in Int(w.x1)..<Int(w.x2) {
            guard let s = src.pixelAddress(x: x, y: y), let d = dst.pixelAddress(x: x, y: y) else { continue }
            var rgb = read(s, depth: src.pixelDepth)
            let a = rgb.w
            if inv { rgb = SIMD4(a - rgb.x, a - rgb.y, a - rgb.z, a) }
            var out = SIMD3(rgb.x, rgb.y, rgb.z) * scale
            if redOnly { out.y = 0; out.z = 0 }
            write(SIMD4(out.x, out.y, out.z, a), to: d, depth: dst.pixelDepth)
          }
        }
      }
    }
  }

  private func read(_ p: UnsafeMutableRawPointer, depth: OFXBitDepth) -> SIMD4<Float> {
    if depth == .byte {
      let b = p.assumingMemoryBound(to: UInt8.self)
      return SIMD4(Float(b[0]), Float(b[1]), Float(b[2]), Float(b[3])) / 255
    }
    let f = p.assumingMemoryBound(to: Float.self)
    return SIMD4(f[0], f[1], f[2], f[3])
  }

  private func write(_ v: SIMD4<Float>, to p: UnsafeMutableRawPointer, depth: OFXBitDepth) {
    if depth == .byte {
      let b = p.assumingMemoryBound(to: UInt8.self)
      for i in 0..<4 { b[i] = UInt8(max(0, min(255, (v[i] * 255).rounded()))) }
    } else {
      let f = p.assumingMemoryBound(to: Float.self)
      for i in 0..<4 { f[i] = v[i] }
    }
  }
}

/// A generator that fills the output with a colour parameter.
final class SolidPlugin: OFXEffectPlugin {
  static let identifier = "org.openeffects.swift.test.Solid"

  static func describe(_ effect: OFXEffectRef) throws {
    try effect.setDescription(label: "Swift Solid", contexts: [.generator], pixelDepths: [.float])
  }

  static func describeInContext(_ effect: OFXEffectRef, context: OFXImageEffectContext) throws {
    try effect.defineClip(kOfxImageEffectOutputClipName)
    try effect.defineRGBA("color", label: "Color", default: [1, 0, 0, 1])
  }

  let effect: OFXEffectRef
  init(effect: OFXEffectRef) throws { self.effect = effect }

  func render(_ args: OFXRenderArguments) throws {
    let c = try effect.parameter("color").rgba(at: args.time)
    try effect.clip(kOfxImageEffectOutputClipName).withImage(at: args.time) { dst in
      for y in Int(dst.bounds.y1)..<Int(dst.bounds.y2) {
        for x in Int(dst.bounds.x1)..<Int(dst.bounds.x2) {
          let f = dst.pixelAddress(x: x, y: y)!.assumingMemoryBound(to: Float.self)
          f[0] = Float(c.x); f[1] = Float(c.y); f[2] = Float(c.z); f[3] = Float(c.w)
        }
      }
    }
  }
}

let testPluginRegistry = OFXPluginRegistry([GainPlugin.self, SolidPlugin.self])
