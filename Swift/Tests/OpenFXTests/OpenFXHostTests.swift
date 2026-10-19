// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import XCTest
import OpenFX
@testable import OpenFXHost
import OpenFXPlugin

final class PropertySuiteTests: XCTestCase {
  func testPropertySuiteRoundTrip() throws {
    let set = OFXPropertySet()
    let ref = OFXPropertySetRef(set.handle, suite: OFXHostSuites.property)

    try ref.set("int", 42)
    try ref.set("double", 1.5)
    try ref.set("string", "hello")
    try ref.set("strings", strings: ["a", "b", "c"])
    try ref.set("rect", rect: OfxRectI(x1: 1, y1: 2, x2: 3, y2: 4))

    XCTAssertEqual(try ref.int("int"), 42)
    XCTAssertEqual(try ref.double("double"), 1.5)
    XCTAssertEqual(try ref.string("string"), "hello")
    XCTAssertEqual(try ref.strings("strings"), ["a", "b", "c"])
    XCTAssertEqual(try ref.dimension("strings"), 3)
    XCTAssertTrue(try ref.rectI("rect").isEqual(to: OfxRectI(x1: 1, y1: 2, x2: 3, y2: 4)))

    // The Swift side sees the same values.
    XCTAssertEqual(set.int("int"), 42)
    XCTAssertEqual(set.strings("strings"), ["a", "b", "c"])
  }

  func testPropertySuiteErrors() {
    let set = OFXPropertySet()
    set.set("int", 1)
    set.define("ro", .int([1]), readOnly: true)
    let ref = OFXPropertySetRef(set.handle, suite: OFXHostSuites.property)

    XCTAssertThrowsError(try ref.int("missing")) { XCTAssertEqual($0 as? OFXStatus, .errUnknown) }
    XCTAssertThrowsError(try ref.int("int", at: 3)) { XCTAssertEqual($0 as? OFXStatus, .errBadIndex) }
    XCTAssertThrowsError(try ref.double("int")) { XCTAssertEqual($0 as? OFXStatus, .errValue) }
    XCTAssertThrowsError(try ref.set("ro", 2)) { XCTAssertEqual($0 as? OFXStatus, .errValue) }
  }

  func testStringPointerIsStable() throws {
    let set = OFXPropertySet()
    set.set("s", "stable")
    var p1: UnsafeMutablePointer<CChar>?
    var p2: UnsafeMutablePointer<CChar>?
    _ = OFXHostSuites.property.pointee.propGetString(set.handle, "s", 0, &p1)
    _ = OFXHostSuites.property.pointee.propGetString(set.handle, "s", 0, &p2)
    XCTAssertEqual(p1, p2)
    XCTAssertEqual(String(cString: p1!), "stable")
  }
}

final class ImageBufferTests: XCTestCase {
  func testDepthAndComponentConversion() {
    let buf = OFXImageBuffer(width: 2, height: 1, bitDepth: .float, components: .rgba)
    buf.setRGBA(x: 0, y: 0, [1, 0.5, 0, 1])
    buf.setRGBA(x: 1, y: 0, [0, 0, 1, 0.25])

    let bytes = buf.converted(to: .byte)
    let p = bytes.data.assumingMemoryBound(to: UInt8.self)
    XCTAssertEqual(Array(UnsafeBufferPointer(start: p, count: 8)), [255, 128, 0, 255, 0, 0, 255, 64])

    let alpha = buf.converted(to: .short, components: .alpha)
    XCTAssertEqual(alpha.rgba(x: 1, y: 0).w, 0.25, accuracy: 1e-4)

    let back = bytes.converted(to: .float)
    XCTAssertEqual(back.rgba(x: 0, y: 0).y, 128 / 255, accuracy: 1e-6)
  }

  #if canImport(CoreGraphics)
  func testCGImageRoundTripKeepsOrientation() throws {
    // Bottom row red, top row blue (OpenFX rows are bottom-up).
    let buf = OFXImageBuffer(width: 1, height: 2, bitDepth: .byte)
    buf.setRGBA(x: 0, y: 0, [1, 0, 0, 1])
    buf.setRGBA(x: 0, y: 1, [0, 0, 1, 1])
    let cg = try XCTUnwrap(buf.makeCGImage())
    let back = try XCTUnwrap(OFXImageBuffer(cgImage: cg, bitDepth: .byte))
    XCTAssertEqual(back.rgba(x: 0, y: 0), [1, 0, 0, 1])
    XCTAssertEqual(back.rgba(x: 0, y: 1), [0, 0, 1, 1])
  }
  #endif
}

final class InProcessPluginTests: XCTestCase {
  var host: OFXHost!
  var messages: [OFXMessage] = []

  override func setUp() {
    host = OFXHost(configuration: .init(name: "org.openeffects.tests", label: "Tests"))
    messages = []
    host.messageHandler = { [unowned self] in self.messages.append($0); return .ok }
    for p in testPluginRegistry.allPlugins { host.register(plugin: p) }
    GainPlugin.changes = []
  }

  private func source(width: Int = 4, height: Int = 3) -> OFXImageBuffer {
    let img = OFXImageBuffer(width: width, height: height, bitDepth: .float)
    img.fill([0.2, 0.4, 0.6, 1])
    return img
  }

  func testDescribe() throws {
    let plugin = try XCTUnwrap(host.plugin(withIdentifier: GainPlugin.identifier))
    XCTAssertEqual(plugin.versionMinor, 2)
    XCTAssertEqual(plugin.label, "Swift Gain")
    XCTAssertEqual(plugin.grouping, "Swift Tests")
    XCTAssertEqual(plugin.supportedContexts, [.filter, .general])
    XCTAssertEqual(plugin.preferredContext, .filter)

    let d = try plugin.descriptor(for: .filter)
    XCTAssertEqual(d.clips.map(\.name), ["Source", "Output"])
    XCTAssertEqual(d.parameters.map(\.name), ["gain", "tint", "invert", "channels", "hello"])
    let gain = try XCTUnwrap(d.parameter(named: "gain"))
    XCTAssertEqual(gain.type, .double)
    XCTAssertEqual(gain.defaultValue, .double(1))
    XCTAssertEqual(gain.maximum, .double(10))
    XCTAssertEqual(gain.displayMaximum, .double(4))
    XCTAssertEqual(d.parameter(named: "channels")?.choiceOptions, ["RGB", "Red only"])
    XCTAssertThrowsError(try plugin.descriptor(for: .generator))
  }

  func testRenderWithParameters() throws {
    let plugin = try XCTUnwrap(host.plugin(withIdentifier: GainPlugin.identifier))
    let instance = try plugin.createInstance(project: OFXProject(width: 4, height: 3))
    try instance.setInput(image: source())

    try instance.setValue(.double(2), for: "gain")
    try instance.setValue(.double([1, 0.5, 0]), for: "tint")
    XCTAssertEqual(GainPlugin.changes, ["Source", "gain", "tint"])

    let out = try instance.render(time: 0)
    XCTAssertEqual(out.width, 4)
    XCTAssertEqual(out.height, 3)
    XCTAssertEqual(out.bitDepth, .float)
    let px = out.rgba(x: 3, y: 2)
    XCTAssertEqual(px.x, 0.4, accuracy: 1e-5)
    XCTAssertEqual(px.y, 0.4, accuracy: 1e-5)
    XCTAssertEqual(px.z, 0, accuracy: 1e-5)
    XCTAssertEqual(px.w, 1, accuracy: 1e-5)

    try instance.setValue(.bool(true), for: "invert")
    try instance.setValue(.int(1), for: "channels")
    let inverted = try instance.render(time: 0).rgba(x: 0, y: 0)
    XCTAssertEqual(inverted.x, (1 - 0.2) * 2, accuracy: 1e-5)
    XCTAssertEqual(inverted.y, 0, accuracy: 1e-5)
  }

  func testIdentityPassesSourceThrough() throws {
    let plugin = try XCTUnwrap(host.plugin(withIdentifier: GainPlugin.identifier))
    let instance = try plugin.createInstance(project: OFXProject(width: 4, height: 3), preferredBitDepth: .byte)
    try instance.setInput(image: source())
    let out = try instance.render(time: 0)
    XCTAssertEqual(out.bitDepth, .byte)
    XCTAssertEqual(out.rgba(x: 1, y: 1).y, 102 / 255, accuracy: 1e-6)
  }

  func testKeyframesAreInterpolatedForRender() throws {
    let plugin = try XCTUnwrap(host.plugin(withIdentifier: GainPlugin.identifier))
    let instance = try plugin.createInstance(project: OFXProject(width: 2, height: 2, frameRange: 0...10))
    try instance.setInput(image: source(width: 2, height: 2))
    try instance.setValue(.double(0), for: "gain", at: 0)
    try instance.setValue(.double(2), for: "gain", at: 10)

    XCTAssertEqual(try instance.render(time: 0).rgba(x: 0, y: 0).x, 0, accuracy: 1e-5)
    XCTAssertEqual(try instance.render(time: 5).rgba(x: 0, y: 0).x, 0.2, accuracy: 1e-5)
    XCTAssertEqual(try instance.render(time: 10).rgba(x: 0, y: 0).x, 0.4, accuracy: 1e-5)
    XCTAssertEqual(instance.parameter(named: "gain")?.keyframeTimes, [0, 10])
  }

  func testPushButtonMessageAndPluginWrite() throws {
    let plugin = try XCTUnwrap(host.plugin(withIdentifier: GainPlugin.identifier))
    let instance = try plugin.createInstance(project: OFXProject(width: 2, height: 2))
    var written: [String] = []
    instance.onParameterChangedByPlugin = { written.append($0.name) }

    try instance.pressButton("hello")
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?.type, .message)
    XCTAssertEqual(messages.first?.text, "Hello from org.openeffects.swift.test.Gain at t=0.0")
    XCTAssertTrue(messages.first?.effect === instance)
    XCTAssertEqual(written, ["gain"])
    XCTAssertEqual(instance.parameter(named: "gain")?.value(), .double(2))
  }

  func testGenerator() throws {
    let plugin = try XCTUnwrap(host.plugin(withIdentifier: SolidPlugin.identifier))
    XCTAssertEqual(plugin.preferredContext, .generator)
    let instance = try plugin.createInstance(project: OFXProject(width: 3, height: 2))
    try instance.setValue(.double([0, 1, 0, 0.5]), for: "color")
    let out = try instance.render(time: 0)
    XCTAssertEqual(out.width, 3)
    XCTAssertEqual(out.rgba(x: 2, y: 1), [0, 1, 0, 0.5])
  }
}
