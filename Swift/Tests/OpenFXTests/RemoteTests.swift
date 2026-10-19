// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import XCTest
import OpenFXHost
import OpenFXPlugin
import OpenFXRemote

/// Runs the test plug-ins behind an `OFXRemoteServer` and uses them through an
/// `OFXRemoteClient`, over a real (anonymous, in-process) XPC connection. This
/// is the same path an app extension uses, minus ExtensionKit's process launch.
final class RemoteTests: XCTestCase {
  final class Listener: NSObject, NSXPCListenerDelegate {
    let server: OFXRemoteServer
    var accepted: [NSXPCConnection] = []
    init(server: OFXRemoteServer) { self.server = server }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
      accepted.append(c)
      return server.accept(c)
    }

    /// Simulates the plug-in process going away.
    func dropAll() {
      accepted.forEach { $0.invalidate() }
      accepted.removeAll()
    }
  }

  var pluginHost: OFXHost!
  var server: OFXRemoteServer!
  var listener: NSXPCListener!
  var delegate: Listener!
  var client: OFXRemoteClient!

  override func setUp() {
    pluginHost = OFXHost(configuration: .init(name: "org.openeffects.tests.extension"))
    for p in testPluginRegistry.allPlugins { pluginHost.register(plugin: p) }
    server = OFXRemoteServer(host: pluginHost, name: "Test Extension")
    delegate = Listener(server: server)
    listener = NSXPCListener.anonymous()
    listener.delegate = delegate
    listener.resume()
    let endpoint = listener.endpoint
    client = OFXRemoteClient(name: "Test Extension") { NSXPCConnection(listenerEndpoint: endpoint) }
    client.timeout = 10
    GainPlugin.changes = []
  }

  override func tearDown() {
    client.disconnect()
    listener.invalidate()
  }

  private func gain() throws -> OFXRemoteEffect {
    try XCTUnwrap(try client.loadEffects().effects.first { $0.identifier == GainPlugin.identifier })
  }

  private func source(_ rgba: SIMD4<Float> = [0.2, 0.4, 0.6, 1]) -> OFXImageBuffer {
    let img = OFXImageBuffer(width: 4, height: 3, bitDepth: .float)
    img.fill(rgba)
    return img
  }

  func testHelloDescribesPlugins() throws {
    let (effects, failures) = try client.loadEffects()
    XCTAssertEqual(failures, [])
    XCTAssertEqual(Set(effects.map(\.identifier)), [GainPlugin.identifier, SolidPlugin.identifier])
    let gain = try XCTUnwrap(effects.first { $0.identifier == GainPlugin.identifier })
    XCTAssertEqual(gain.label, "Swift Gain")
    XCTAssertEqual(gain.grouping, "Swift Tests")
    XCTAssertEqual(gain.versionMinor, 2)
    XCTAssertEqual(gain.preferredContext, .filter)
    XCTAssertEqual(gain.origin, "Test Extension")
  }

  func testRemoteRenderPullsFramesFromHost() throws {
    let instance = try gain().makeRemoteInstance(project: OFXProject(width: 4, height: 3))
    XCTAssertEqual(instance.inputClipNames, ["Source"])
    XCTAssertEqual(instance.parameters.map(\.name), ["gain", "tint", "invert", "channels", "hello"])
    XCTAssertEqual(instance.parameter(named: "gain")?.displayMaximum, .double(4))

    var requested: [Double] = []
    let src = source()
    try instance.setInput(kOfxImageEffectSimpleSourceClipName, source: { t in requested.append(t); return src })
    try instance.setValue(.double(2), for: "gain")
    try instance.setValue(.double([1, 0.5, 0]), for: "tint")

    let out = try instance.render(time: 7)
    XCTAssertEqual(requested, [7], "the plug-in process fetched the frame it needed, once")
    XCTAssertEqual(out.width, 4)
    XCTAssertEqual(out.bitDepth, .float)
    let px = out.rgba(x: 3, y: 2)
    XCTAssertEqual(px.x, 0.4, accuracy: 1e-5)
    XCTAssertEqual(px.y, 0.4, accuracy: 1e-5)
    XCTAssertEqual(px.z, 0, accuracy: 1e-5)
    XCTAssertEqual(GainPlugin.changes, ["Source", "gain", "tint"])
  }

  func testIdentityAndByteDepthAcrossProcesses() throws {
    let instance = try gain().makeRemoteInstance(project: OFXProject(width: 4, height: 3), preferredBitDepth: .byte)
    try instance.setInput(image: source())
    let out = try instance.render(time: 0)
    XCTAssertEqual(out.bitDepth, .byte)
    XCTAssertEqual(out.rgba(x: 0, y: 0).y, 102 / 255, accuracy: 1e-6)
  }

  func testKeyframesAreMirroredAndRendered() throws {
    let instance = try gain().makeRemoteInstance(project: OFXProject(width: 4, height: 3, frameRange: 0...10))
    try instance.setInput(image: source())
    try instance.setValue(.double(0), for: "gain", at: 0)
    try instance.setValue(.double(2), for: "gain", at: 10)
    XCTAssertEqual(instance.parameter(named: "gain")?.value(at: 5), .double(1), "local mirror interpolates")
    XCTAssertEqual(try instance.render(time: 5).rgba(x: 0, y: 0).x, 0.2, accuracy: 1e-5)
    XCTAssertEqual(try instance.render(time: 10).rgba(x: 0, y: 0).x, 0.4, accuracy: 1e-5)
  }

  func testPluginEditsAndMessagesComeBack() throws {
    let instance = try gain().makeRemoteInstance(project: OFXProject(width: 4, height: 3))
    let gotMessage = expectation(description: "message")
    var message: OFXRemoteMessage?
    client.onMessage = { message = $0; gotMessage.fulfill() }
    var written: [String] = []
    instance.onParameterChangedByPlugin = { written.append($0.name) }

    try instance.pressButton("hello")
    wait(for: [gotMessage], timeout: 5)
    XCTAssertEqual(message?.text, "Hello from org.openeffects.swift.test.Gain at t=0.0")
    XCTAssertEqual(message?.source, "Swift Gain")
    XCTAssertEqual(written, ["gain"])
    XCTAssertEqual(instance.parameter(named: "gain")?.value(), .double(2), "the mirror has the plug-in's write")
  }

  func testGeneratorOverXPC() throws {
    let solid = try XCTUnwrap(try client.loadEffects().effects.first { $0.identifier == SolidPlugin.identifier })
    let instance = try solid.makeRemoteInstance(project: OFXProject(width: 3, height: 2))
    try instance.setValue(.double([0, 1, 0, 0.5]), for: "color")
    XCTAssertEqual(try instance.render(time: 0).rgba(x: 2, y: 1), [0, 1, 0, 0.5])
  }

  func testInstanceSurvivesPluginProcessRestart() throws {
    let instance = try gain().makeRemoteInstance(project: OFXProject(width: 4, height: 3, frameRange: 0...10))
    try instance.setInput(image: source())
    try instance.setValue(.double(3), for: "gain")
    try instance.setValue(.bool(true), for: "invert")
    let before = try instance.render(time: 0).rgba(x: 1, y: 1)

    // The "extension" goes away (crash, or the system reclaimed it).
    delegate.dropAll()
    Thread.sleep(forTimeInterval: 0.2)

    // The next render reconnects, re-creates the instance and replays its state.
    let after = try instance.render(time: 0).rgba(x: 1, y: 1)
    XCTAssertEqual(after, before)
    XCTAssertEqual(after.x, (1 - 0.2) * 3, accuracy: 1e-5)
    XCTAssertEqual(delegate.accepted.count, 1, "a new connection was made")
  }

  func testWorksThroughTheEffectProtocols() throws {
    let effect: any OFXEffect = try gain()
    let instance = try effect.makeInstance(project: OFXProject(width: 4, height: 3))
    try instance.setInput(image: source())
    try instance.setValue(.double(0.5), for: "gain")
    XCTAssertEqual(try instance.render(time: 0).rgba(x: 0, y: 0).z, 0.3, accuracy: 1e-5)
  }
}
