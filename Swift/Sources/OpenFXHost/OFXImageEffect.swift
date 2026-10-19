// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import OpenFX

/// An image effect descriptor (global or per-context). Its handle is the
/// `OfxImageEffectHandle` given to plug-ins. Instances are `OFXImageEffectInstance`.
public class OFXImageEffect: @unchecked Sendable {
  public let properties: OFXPropertySet
  public private(set) var parameterSet: OFXParameterSet!
  public private(set) var clips: [OFXClip] = []
  public unowned let plugin: OFXImageEffectPlugin

  init(plugin: OFXImageEffectPlugin, properties: OFXPropertySet) {
    self.plugin = plugin
    self.properties = properties
    self.parameterSet = OFXParameterSet(effect: self)
  }

  public var handle: OfxImageEffectHandle { OpaquePointer(Unmanaged.passUnretained(self).toOpaque()) }

  static func from(_ handle: OfxImageEffectHandle?) -> OFXImageEffect? {
    guard let handle else { return nil }
    return Unmanaged<OFXImageEffect>.fromOpaque(UnsafeRawPointer(handle)).takeUnretainedValue()
  }

  /// The time parameter reads default to; only meaningful for instances.
  var currentTime: Double? { nil }

  public func clip(named name: String) -> OFXClip? { clips.first { $0.name == name } }
  public var parameters: [OFXParameter] { parameterSet.parameters }
  public func parameter(named name: String) -> OFXParameter? { parameterSet[name] }

  func defineClip(_ name: String) throws -> OFXClip {
    guard clip(named: name) == nil else { throw OFXStatus.errExists }
    let clip = OFXClip(name: name, properties: OFXClip.descriptorProperties(name: name), effect: self)
    clips.append(clip)
    return clip
  }

  func addClip(_ clip: OFXClip) { clips.append(clip) }

  // MARK: Descriptor properties

  public var label: String {
    for key in [kOfxPropLabel, kOfxPropLongLabel, kOfxPropShortLabel] {
      if let s = properties.string(key), !s.isEmpty { return s }
    }
    return plugin.identifier
  }
  public var grouping: String { properties.string(kOfxImageEffectPluginPropGrouping) ?? "" }
  public var pluginDescription: String { properties.string(kOfxPropPluginDescription) ?? "" }
  public var supportedContexts: [OFXImageEffectContext] {
    properties.strings(kOfxImageEffectPropSupportedContexts).map(OFXImageEffectContext.init(rawValue:))
  }
  public var supportedPixelDepths: [OFXBitDepth] {
    properties.strings(kOfxImageEffectPropSupportedPixelDepths).map(OFXBitDepth.init(rawValue:))
  }

  static func descriptorProperties(plugin: OFXImageEffectPlugin) -> OFXPropertySet {
    let p = OFXPropertySet(debugName: "effect \(plugin.identifier)")
    p.set(kOfxPropType, kOfxTypeImageEffect)
    p.set(kOfxPropLabel, "")
    p.set(kOfxPropShortLabel, "")
    p.set(kOfxPropLongLabel, "")
    p.set(kOfxPropPluginDescription, "")
    p.define(kOfxPropVersion, .int([Int(plugin.versionMajor), Int(plugin.versionMinor)]), readOnly: true)
    p.set(kOfxPropVersionLabel, "\(plugin.versionMajor).\(plugin.versionMinor)")
    p.define(kOfxPluginPropFilePath, .string([plugin.filePath ?? ""]), readOnly: true)
    p[kOfxImageEffectPropSupportedContexts] = .string([])
    p[kOfxImageEffectPropSupportedPixelDepths] = .string([])
    p.set(kOfxImageEffectPluginPropGrouping, "")
    p.set(kOfxImageEffectPluginPropSingleInstance, false)
    p.set(kOfxImageEffectPluginRenderThreadSafety, kOfxImageEffectRenderInstanceSafe)
    p.set(kOfxImageEffectPluginPropHostFrameThreading, false)
    p.set(kOfxImageEffectPluginPropOverlayInteractV1, pointer: nil)
    p.set(kOfxImageEffectPropSupportsMultiResolution, true)
    p.set(kOfxImageEffectPropSupportsTiles, true)
    p.set(kOfxImageEffectPropTemporalClipAccess, false)
    p.set(kOfxImageEffectPluginPropFieldRenderTwiceAlways, true)
    p.set(kOfxImageEffectPropSupportsMultipleClipDepths, false)
    p.set(kOfxImageEffectPropSupportsMultipleClipPARs, false)
    p[kOfxImageEffectPropClipPreferencesSlaveParam] = .string([])
    p.set(kOfxImageEffectPropOpenGLRenderSupported, "false")
    return p
  }
}

/// Project settings an effect instance renders within.
public struct OFXProject: Sendable {
  public var width: Int
  public var height: Int
  public var pixelAspectRatio: Double = 1
  public var frameRate: Double = 24
  /// First and last frame (inclusive).
  public var frameRange: ClosedRange<Double> = 0...0

  public init(width: Int, height: Int, pixelAspectRatio: Double = 1, frameRate: Double = 24,
              frameRange: ClosedRange<Double> = 0...0) {
    self.width = width
    self.height = height
    self.pixelAspectRatio = pixelAspectRatio
    self.frameRate = frameRate
    self.frameRange = frameRange
  }

  public var extent: OfxRectI { OfxRectI(x1: 0, y1: 0, x2: Int32(width), y2: Int32(height)) }
}

/// A live instance of an image effect plug-in.
///
/// Typical use:
/// ```swift
/// let instance = try plugin.createInstance(context: .filter, project: OFXProject(width: w, height: h))
/// instance.setInput(image: sourceBuffer)
/// try instance.setValue(.double(0.5), for: "scale")
/// let output = try instance.render(time: 0)
/// ```
///
/// Instances can be used from any thread: renders and edits on one instance
/// are serialised internally. Use several instances to render in parallel.
public final class OFXImageEffectInstance: OFXImageEffect, @unchecked Sendable {
  public let context: OFXImageEffectContext
  public private(set) var project: OFXProject
  public let preferredBitDepth: OFXBitDepth

  /// Called when the plug-in changes a parameter value itself (e.g. in instanceChanged).
  public var onParameterChangedByPlugin: ((OFXParameter) -> Void)?
  /// Called for progress suite updates (0...1) during long renders.
  public var onProgress: ((Double) -> Void)?
  /// Set to request the plug-in abandon the current render (polled through `abort`).
  public var abortRequested: Bool {
    get { stateLock.locked { _abort } }
    set { stateLock.locked { _abort = newValue } }
  }

  private var _abort = false
  private var _time: Double = 0
  private let stateLock = NSRecursiveLock()
  private let renderLock = NSLock()
  private var created = false

  // Per-render state.
  private var renderOutput: OFXImageBuffer?
  private var outstandingImages: [ObjectIdentifier: OFXImage] = [:]
  private var sourceCache: [String: OFXImageBuffer] = [:]
  private var imageCounter = 0

  override var currentTime: Double? { stateLock.locked { _time } }
  public var time: Double { stateLock.locked { _time } }

  init(plugin: OFXImageEffectPlugin, descriptor: OFXImageEffect, context: OFXImageEffectContext,
       project: OFXProject, preferredBitDepth: OFXBitDepth) {
    self.context = context
    self.project = project
    self.preferredBitDepth = preferredBitDepth
    self._time = project.frameRange.lowerBound

    let props = OFXPropertySet(debugName: "instance \(plugin.identifier)")
    props.copyProperties(from: descriptor.properties)
    super.init(plugin: plugin, properties: props)

    props.set(kOfxPropType, kOfxTypeImageEffectInstance)
    props.define(kOfxImageEffectPropContext, .string([context.rawValue]), readOnly: true)
    props.set(kOfxPropInstanceData, pointer: nil)
    props.set(kOfxPropIsInteractive, false)
    props.set(kOfxImageEffectInstancePropSequentialRender, false)
    applyProjectProperties()

    parameterSet.instantiate(from: descriptor.parameterSet,
                             projectSize: (Double(project.width), Double(project.height)))
    for d in descriptor.clips {
      let cp = OFXPropertySet(debugName: "clip \(d.name)")
      cp.copyProperties(from: d.properties)
      let clip = OFXClip(name: d.name, properties: cp, effect: self)
      cp.set(kOfxImageClipPropConnected, clip.isOutput)
      cp.set(kOfxImagePropPixelAspectRatio, project.pixelAspectRatio)
      cp.set(kOfxImageEffectPropFrameRate, project.frameRate)
      cp.set(kOfxImageEffectPropUnmappedFrameRate, project.frameRate)
      cp.set(kOfxImageEffectPropFrameRange, doubles: [project.frameRange.lowerBound, project.frameRange.upperBound])
      cp.set(kOfxImageEffectPropUnmappedFrameRange, doubles: [project.frameRange.lowerBound, project.frameRange.upperBound])
      cp.set(kOfxImageClipPropFieldOrder, kOfxImageFieldNone)
      cp.set(kOfxImageClipPropContinuousSamples, false)
      cp.set(kOfxImageEffectPropPreMultiplication, kOfxImagePreMultiplied)
      addClip(clip)
    }
    applyDefaultClipFormats()
  }

  deinit {
    if created {
      _ = plugin.callAction(.destroyInstance, handle: self, inArgs: nil, outArgs: nil)
    }
  }

  /// Runs `kOfxActionCreateInstance` and the initial clip preferences.
  func create() throws {
    let stat = plugin.callAction(.createInstance, handle: self, inArgs: nil, outArgs: nil)
    guard stat == kOfxStatOK || stat == kOfxStatReplyDefault else { throw OFXStatus(stat) }
    created = true
    try updateClipPreferences()
  }

  // MARK: Inputs

  /// The names of the input (non-output) clips.
  public var inputClipNames: [String] { clips.filter { !$0.isOutput }.map(\.name) }

  /// Connects an input clip to a frame source.
  public func setInput(_ clipName: String = kOfxImageEffectSimpleSourceClipName,
                       source: OFXClipSource?) throws {
    guard let clip = clip(named: clipName), !clip.isOutput else { throw OFXStatus.errUnknown }
    renderLock.lock()
    defer { renderLock.unlock() }
    let wasConnected = clip.isConnected
    clip.source = source
    clip.properties.set(kOfxImageClipPropConnected, source != nil)
    if wasConnected != (source != nil) {
      instanceChanged(type: kOfxTypeClip, name: clipName, reason: kOfxChangeUserEdited)
      try updateClipPreferences()
    }
  }

  /// Connects an input clip to a single still image, used at every time.
  public func setInput(_ clipName: String = kOfxImageEffectSimpleSourceClipName,
                       image: OFXImageBuffer?) throws {
    try setInput(clipName, source: image.map { img in { _ in img } })
  }

  // MARK: Parameters

  /// Sets a parameter (optionally as a keyframe) and tells the plug-in, like a user edit would.
  public func setValue(_ value: OFXParameterValue, for name: String, at time: Double? = nil) throws {
    guard let param = parameter(named: name) else { throw OFXStatus.errUnknown }
    renderLock.lock()
    defer { renderLock.unlock() }
    param.setValue(value, at: time)
    instanceChanged(type: kOfxTypeParameter, name: name, reason: kOfxChangeUserEdited, time: time)
    if properties.strings(kOfxImageEffectPropClipPreferencesSlaveParam).contains(name) {
      try updateClipPreferences()
    }
  }

  /// Presses a push button parameter.
  public func pressButton(_ name: String) throws {
    guard let param = parameter(named: name), param.type == .pushButton else { throw OFXStatus.errUnknown }
    renderLock.lock()
    defer { renderLock.unlock() }
    instanceChanged(type: kOfxTypeParameter, name: name, reason: kOfxChangeUserEdited)
  }

  func parameterChangedByPlugin(_ param: OFXParameter) {
    onParameterChangedByPlugin?(param)
  }

  /// Moves the instance to a new time (used as the default for parameter reads and the timeline suite).
  public func setTime(_ time: Double) { stateLock.locked { _time = time } }

  public func updateProject(_ project: OFXProject) throws {
    renderLock.lock()
    defer { renderLock.unlock() }
    self.project = project
    applyProjectProperties()
    try updateClipPreferences()
  }

  // MARK: Rendering

  /// The region the effect produces pixels for at `time`, in canonical coordinates.
  public func regionOfDefinition(at time: Double) throws -> OfxRectD {
    renderLock.lock()
    defer { renderLock.unlock() }
    return try computeRegionOfDefinition(at: time)
  }

  /// Renders one frame.
  ///
  /// The plug-in renders its region of definition clipped to the project extent.
  /// By default the result is a full project-sized frame (transparent outside
  /// that region); pass `cropToRegionOfDefinition` to get just the rendered region.
  public func render(time: Double, interactive: Bool = false,
                     cropToRegionOfDefinition: Bool = false) throws -> OFXImageBuffer {
    renderLock.lock()
    defer {
      endRenderState()
      renderLock.unlock()
    }
    setTime(time)
    abortRequested = false

    let rod = try computeRegionOfDefinition(at: time)
    var window = rod.enclosingRectI.intersection(project.extent)
    if window.isEmpty { window = project.extent }
    let bounds = cropToRegionOfDefinition ? window : project.extent

    guard let output = clip(named: kOfxImageEffectOutputClipName) else { throw OFXStatus.errBadHandle }

    if let (clipName, identityTime) = try identity(at: time, window: window),
       let clip = clip(named: clipName), let source = try sourceImage(for: clip, at: identityTime) {
      let out = OFXImageBuffer(bounds: bounds, bitDepth: output.pixelDepth, components: output.components,
                               premultiplication: source.premultiplication)
      out.copyPixels(from: source)
      return out
    }

    let out = OFXImageBuffer(bounds: bounds, bitDepth: output.pixelDepth, components: output.components,
                             premultiplication: output.premultiplication)
    renderOutput = out

    let seqArgs = OFXPropertySet(debugName: "sequence args")
    seqArgs.set(kOfxImageEffectPropFrameRange, doubles: [time, time])
    seqArgs.set(kOfxImageEffectPropFrameStep, 1.0)
    seqArgs.set(kOfxPropIsInteractive, interactive)
    seqArgs.set(kOfxImageEffectPropRenderScale, doubles: [1, 1])
    seqArgs.set(kOfxImageEffectPropSequentialRenderStatus, false)
    seqArgs.set(kOfxImageEffectPropInteractiveRenderStatus, interactive)
    seqArgs.set(kOfxImageEffectPropOpenGLEnabled, false)
    var stat = plugin.callAction(.beginSequenceRender, handle: self, inArgs: seqArgs, outArgs: nil)
    guard stat == kOfxStatOK || stat == kOfxStatReplyDefault else { throw OFXStatus(stat) }
    defer { _ = plugin.callAction(.endSequenceRender, handle: self, inArgs: seqArgs, outArgs: nil) }

    let args = OFXPropertySet(debugName: "render args")
    args.set(kOfxPropTime, time)
    args.set(kOfxImageEffectPropFieldToRender, kOfxImageFieldNone)
    args.set(kOfxImageEffectPropRenderWindow, rect: window)
    args.set(kOfxImageEffectPropRenderScale, doubles: [1, 1])
    args.set(kOfxImageEffectPropSequentialRenderStatus, false)
    args.set(kOfxImageEffectPropInteractiveRenderStatus, interactive)
    args.set(kOfxImageEffectPropRenderQualityDraft, false)
    args.set(kOfxImageEffectPropOpenGLEnabled, false)
    stat = plugin.callAction(.render, handle: self, inArgs: args, outArgs: nil)
    guard stat == kOfxStatOK else { throw OFXStatus(stat) }
    return out
  }

  private func endRenderState() {
    stateLock.locked {
      renderOutput = nil
      outstandingImages.removeAll()
      sourceCache.removeAll()
    }
  }

  private func computeRegionOfDefinition(at time: Double) throws -> OfxRectD {
    let fallback = try defaultRegionOfDefinition(at: time)
    let inArgs = OFXPropertySet(debugName: "rod in")
    inArgs.set(kOfxPropTime, time)
    inArgs.set(kOfxImageEffectPropRenderScale, doubles: [1, 1])
    let outArgs = OFXPropertySet(debugName: "rod out")
    outArgs.set(kOfxImageEffectPropRegionOfDefinition, rect: fallback)
    let stat = plugin.callAction(.getRegionOfDefinition, handle: self, inArgs: inArgs, outArgs: outArgs)
    switch stat {
    case kOfxStatOK: return outArgs.rectD(kOfxImageEffectPropRegionOfDefinition) ?? fallback
    case kOfxStatReplyDefault: return fallback
    default: throw OFXStatus(stat)
    }
  }

  private func defaultRegionOfDefinition(at time: Double) throws -> OfxRectD {
    if context == .generator { return project.extent.asDouble }
    var rod = OfxRectD(x1: 0, y1: 0, x2: 0, y2: 0)
    for clip in clips where !clip.isOutput && clip.isConnected {
      if let image = try sourceImage(for: clip, at: time) { rod = rod.union(image.bounds.asDouble) }
    }
    return rod.isEmpty ? project.extent.asDouble : rod
  }

  private func identity(at time: Double, window: OfxRectI) throws -> (String, Double)? {
    let inArgs = OFXPropertySet(debugName: "identity in")
    inArgs.set(kOfxPropTime, time)
    inArgs.set(kOfxImageEffectPropFieldToRender, kOfxImageFieldNone)
    inArgs.set(kOfxImageEffectPropRenderWindow, rect: window)
    inArgs.set(kOfxImageEffectPropRenderScale, doubles: [1, 1])
    let outArgs = OFXPropertySet(debugName: "identity out")
    outArgs.set(kOfxPropName, "")
    outArgs.set(kOfxPropTime, time)
    let stat = plugin.callAction(.isIdentity, handle: self, inArgs: inArgs, outArgs: outArgs)
    switch stat {
    case kOfxStatOK:
      guard let name = outArgs.string(kOfxPropName), !name.isEmpty else { return nil }
      return (name, outArgs.double(kOfxPropTime) ?? time)
    case kOfxStatReplyDefault: return nil
    default: throw OFXStatus(stat)
    }
  }

  // MARK: Clip preferences

  private static let hostDepths: [OFXBitDepth] = [.float, .short, .byte]

  /// Picks the depth the clips run at: the preferred one if the plug-in supports it, else the deepest.
  private var negotiatedDepth: OFXBitDepth {
    let supported = supportedPixelDepths.filter { Self.hostDepths.contains($0) }
    if supported.isEmpty || supported.contains(preferredBitDepth) { return preferredBitDepth }
    return Self.hostDepths.first { supported.contains($0) } ?? preferredBitDepth
  }

  private func negotiatedComponents(for clip: OFXClip) -> OFXImageComponents {
    let supported = clip.supportedComponents
    for c in [OFXImageComponents.rgba, .rgb, .alpha] where supported.isEmpty || supported.contains(c) {
      return c
    }
    return .rgba
  }

  private func applyDefaultClipFormats() {
    let depth = negotiatedDepth
    for clip in clips {
      let comps = negotiatedComponents(for: clip)
      clip.properties.set(kOfxImageEffectPropPixelDepth, depth.rawValue)
      clip.properties.set(kOfxImageClipPropUnmappedPixelDepth, depth.rawValue)
      clip.properties.set(kOfxImageEffectPropComponents, comps.rawValue)
      clip.properties.set(kOfxImageClipPropUnmappedComponents, comps.rawValue)
    }
  }

  private func updateClipPreferences() throws {
    applyDefaultClipFormats()
    let outArgs = OFXPropertySet(debugName: "clip preferences")
    for clip in clips {
      outArgs.set("OfxImageClipPropComponents_" + clip.name, clip.components.rawValue)
      outArgs.set("OfxImageClipPropDepth_" + clip.name, clip.pixelDepth.rawValue)
      outArgs.set("OfxImageClipPropPAR_" + clip.name, project.pixelAspectRatio)
    }
    outArgs.set(kOfxImageEffectPropFrameRate, project.frameRate)
    outArgs.set(kOfxImageClipPropFieldOrder, kOfxImageFieldNone)
    outArgs.set(kOfxImageEffectPropPreMultiplication, kOfxImagePreMultiplied)
    outArgs.set(kOfxImageClipPropContinuousSamples, false)
    outArgs.set(kOfxImageEffectFrameVarying, false)

    let stat = plugin.callAction(.getClipPreferences, handle: self, inArgs: nil, outArgs: outArgs)
    guard stat == kOfxStatOK || stat == kOfxStatReplyDefault else { throw OFXStatus(stat) }
    guard stat == kOfxStatOK else { return }

    for clip in clips {
      if let s = outArgs.string("OfxImageClipPropDepth_" + clip.name),
         Self.hostDepths.contains(OFXBitDepth(rawValue: s)) {
        clip.properties.set(kOfxImageEffectPropPixelDepth, s)
      }
      if let s = outArgs.string("OfxImageClipPropComponents_" + clip.name),
         OFXImageComponents(rawValue: s).count > 0 {
        clip.properties.set(kOfxImageEffectPropComponents, s)
      }
      if let par = outArgs.double("OfxImageClipPropPAR_" + clip.name) {
        clip.properties.set(kOfxImagePropPixelAspectRatio, par)
      }
    }
    if let output = clip(named: kOfxImageEffectOutputClipName) {
      if let premult = outArgs.string(kOfxImageEffectPropPreMultiplication) {
        output.properties.set(kOfxImageEffectPropPreMultiplication, premult)
      }
      if let rate = outArgs.double(kOfxImageEffectPropFrameRate) {
        output.properties.set(kOfxImageEffectPropFrameRate, rate)
      }
    }
  }

  private func applyProjectProperties() {
    let p = properties
    p.set(kOfxImageEffectPropProjectSize, doubles: [Double(project.width), Double(project.height)])
    p.set(kOfxImageEffectPropProjectOffset, doubles: [0, 0])
    p.set(kOfxImageEffectPropProjectExtent, doubles: [Double(project.width), Double(project.height)])
    p.set(kOfxImageEffectPropProjectPixelAspectRatio, project.pixelAspectRatio)
    p.set(kOfxImageEffectInstancePropEffectDuration, project.frameRange.upperBound - project.frameRange.lowerBound + 1)
    p.set(kOfxImageEffectPropFrameRate, project.frameRate)
  }

  // MARK: Instance changed

  private func instanceChanged(type: String, name: String, reason: String, time: Double? = nil) {
    let begin = OFXPropertySet(debugName: "begin changed")
    begin.set(kOfxPropChangeReason, reason)
    _ = plugin.callAction(.beginInstanceChanged, handle: self, inArgs: begin, outArgs: nil)

    let args = OFXPropertySet(debugName: "instance changed")
    args.set(kOfxPropType, type)
    args.set(kOfxPropName, name)
    args.set(kOfxPropChangeReason, reason)
    args.set(kOfxPropTime, time ?? self.time)
    args.set(kOfxImageEffectPropRenderScale, doubles: [1, 1])
    _ = plugin.callAction(.instanceChanged, handle: self, inArgs: args, outArgs: nil)

    _ = plugin.callAction(.endInstanceChanged, handle: self, inArgs: begin, outArgs: nil)
  }

  // MARK: Image effect suite support

  /// The source frame for `clip` at `time`, converted to the clip's negotiated format.
  func sourceImage(for clip: OFXClip, at time: Double) throws -> OFXImageBuffer? {
    let key = "\(clip.name)@\(time)"
    if let cached = stateLock.locked({ sourceCache[key] }) { return cached }
    guard clip.isConnected, let source = clip.source, let raw = try source(time) else { return nil }
    var image = raw
    if raw.bitDepth != clip.pixelDepth || raw.components != clip.components {
      image = raw.converted(to: clip.pixelDepth, components: clip.components)
    }
    stateLock.locked { sourceCache[key] = image }
    return image
  }

  /// Implements `clipGetImage`.
  func fetchImage(clip: OFXClip, time: Double) -> OFXImage? {
    let buffer: OFXImageBuffer?
    if clip.isOutput {
      buffer = stateLock.locked { renderOutput }
    } else {
      buffer = try? sourceImage(for: clip, at: time)
    }
    guard let buffer else { return nil }
    return stateLock.locked {
      imageCounter += 1
      let image = OFXImage(buffer: buffer, clipName: clip.name, time: time,
                           uniqueID: "\(clip.name):\(time):\(imageCounter)")
      image.owner = self
      outstandingImages[ObjectIdentifier(image)] = image
      return image
    }
  }

  /// Implements `clipReleaseImage`.
  func releaseImage(_ image: OFXPropertySet) -> Bool {
    stateLock.locked { outstandingImages.removeValue(forKey: ObjectIdentifier(image)) != nil }
  }

  /// Implements `clipGetRegionOfDefinition`.
  func clipRegionOfDefinition(_ clip: OFXClip, at time: Double) -> OfxRectD {
    if clip.isOutput {
      if let out = stateLock.locked({ renderOutput }) { return out.bounds.asDouble }
      return project.extent.asDouble
    }
    if let image = try? sourceImage(for: clip, at: time) { return image.bounds.asDouble }
    return OfxRectD(x1: 0, y1: 0, x2: 0, y2: 0)
  }
}
