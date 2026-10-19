// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import OpenFX

/// The C suite tables handed to plug-ins through `fetchSuite`.
///
/// Suites are process-wide and stateless: every call reaches the right Swift
/// object through the handle it is given.
enum OFXHostSuites {
  static func installCallbacks() { _ = callbacksInstalled }

  private static let callbacksInstalled: Void = {
    OfxSwiftSetHostParamCallbacks(OfxSwiftHostParamCallbacks(
      getLayout: { h, kind, count in
        guard let param = OFXParameter.from(h) else { return kOfxStatErrBadHandle }
        let layout = param.type.valueLayout
        kind?.pointee = layout.kind
        count?.pointee = Int32(layout.count)
        return kOfxStatOK
      },
      getValue: { h, query, hasTime, time, time2, out in
        guard let param = OFXParameter.from(h), let out else { return kOfxStatErrBadHandle }
        switch query {
        case OfxSwiftParamQueryDerivative:
          param.fill(&out.pointee, with: .double(param.derivative(at: time)))
        case OfxSwiftParamQueryIntegral:
          param.fill(&out.pointee, with: .double(param.integral(from: time, to: time2)))
        default:
          param.fill(&out.pointee, with: param.value(at: hasTime != 0 ? time : nil))
        }
        return kOfxStatOK
      },
      setValue: { h, hasTime, time, value in
        guard let param = OFXParameter.from(h), let value else { return kOfxStatErrBadHandle }
        param.setValue(param.value(from: value.pointee), at: hasTime != 0 ? time : nil)
        if let instance = param.parameterSet?.effect as? OFXImageEffectInstance {
          instance.parameterChangedByPlugin(param)
        }
        return kOfxStatOK
      }))

    OfxSwiftSetHostMessageCallbacks(OfxSwiftHostMessageCallbacks(
      message: { handle, type, id, text, persistent in
        let effect = handle.flatMap { OFXImageEffect.from(OpaquePointer($0)) }
        guard let host = effect?.plugin.host ?? OFXHost.current else { return kOfxStatFailed }
        let message = OFXMessage(type: OFXMessageType(rawValue: type.map { String(cString: $0) } ?? kOfxMessageMessage),
                                 id: id.map { String(cString: $0) },
                                 text: text.map { String(cString: $0) } ?? "",
                                 isPersistent: persistent != 0, effect: effect)
        return host.post(message).rawValue
      },
      clearPersistentMessage: { _ in kOfxStatOK }))
  }()

  // MARK: fetchSuite

  static let fetchSuite: @convention(c) (OfxPropertySetHandle?, UnsafePointer<CChar>?, Int32) -> UnsafeRawPointer? = {
    _, name, version in
    guard let name else { return nil }
    switch (String(cString: name), version) {
    case (kOfxPropertySuite, 1): return UnsafeRawPointer(property)
    case (kOfxImageEffectSuite, 1): return UnsafeRawPointer(imageEffect)
    case (kOfxParameterSuite, 1): return UnsafeRawPointer(parameter)
    case (kOfxMemorySuite, 1): return UnsafeRawPointer(memory)
    case (kOfxMultiThreadSuite, 1): return UnsafeRawPointer(multiThread)
    case (kOfxMessageSuite, 1): return UnsafeRawPointer(messageV1)
    case (kOfxMessageSuite, 2): return UnsafeRawPointer(messageV2)
    case (kOfxProgressSuite, 1): return UnsafeRawPointer(progressV1)
    case (kOfxProgressSuite, 2): return UnsafeRawPointer(progressV2)
    case (kOfxTimeLineSuite, 1): return UnsafeRawPointer(timeLine)
    case (kOfxInteractSuite, 1): return UnsafeRawPointer(interact)
    default: return nil
    }
  }

  private static func make<T>(_ value: T) -> UnsafeMutablePointer<T> {
    let p = UnsafeMutablePointer<T>.allocate(capacity: 1)
    p.initialize(to: value)
    return p
  }

  // MARK: Property suite

  private typealias Storage = OFXPropertySet.Storage

  private static func setOne(_ h: OfxPropertySetHandle?, _ n: UnsafePointer<CChar>?, _ i: Int32,
                             _ kind: OFXPropertySet.Kind, _ write: (inout Storage, Int) -> Void) -> OfxStatus {
    guard let set = OFXPropertySet.from(h) else { return kOfxStatErrBadHandle }
    return set.suiteSet(n, index: i, count: 1, kind: kind, write: write)
  }

  private static func getOne(_ h: OfxPropertySetHandle?, _ n: UnsafePointer<CChar>?, _ i: Int32,
                             _ kind: OFXPropertySet.Kind, _ read: (Storage, Int) -> Void) -> OfxStatus {
    guard let set = OFXPropertySet.from(h) else { return kOfxStatErrBadHandle }
    return set.suiteGet(n, index: i, count: 1, kind: kind, read: read)
  }

  static let property = make(OfxPropertySuiteV1(
    propSetPointer: { h, n, i, v in
      setOne(h, n, i, .pointer) { s, i in if case .pointer(var a) = s { a[i] = v; s = .pointer(a) } }
    },
    propSetString: { h, n, i, v in
      setOne(h, n, i, .string) { s, i in
        if case .string(var a) = s { free(a[i]); a[i] = strdup(v ?? emptyCString)!; s = .string(a) }
      }
    },
    propSetDouble: { h, n, i, v in
      setOne(h, n, i, .double) { s, i in if case .double(var a) = s { a[i] = v; s = .double(a) } }
    },
    propSetInt: { h, n, i, v in
      setOne(h, n, i, .int) { s, i in if case .int(var a) = s { a[i] = v; s = .int(a) } }
    },
    propSetPointerN: { h, n, count, v in
      guard let set = OFXPropertySet.from(h), let v else { return kOfxStatErrBadHandle }
      return set.suiteSet(n, index: 0, count: count, kind: .pointer) { s, _ in
        if case .pointer(var a) = s { for k in 0..<Int(count) { a[k] = v[k] }; s = .pointer(a) }
      }
    },
    propSetStringN: { h, n, count, v in
      guard let set = OFXPropertySet.from(h), let v else { return kOfxStatErrBadHandle }
      return set.suiteSet(n, index: 0, count: count, kind: .string) { s, _ in
        if case .string(var a) = s {
          for k in 0..<Int(count) { free(a[k]); a[k] = strdup(v[k] ?? emptyCString)! }
          s = .string(a)
        }
      }
    },
    propSetDoubleN: { h, n, count, v in
      guard let set = OFXPropertySet.from(h), let v else { return kOfxStatErrBadHandle }
      return set.suiteSet(n, index: 0, count: count, kind: .double) { s, _ in
        if case .double(var a) = s { for k in 0..<Int(count) { a[k] = v[k] }; s = .double(a) }
      }
    },
    propSetIntN: { h, n, count, v in
      guard let set = OFXPropertySet.from(h), let v else { return kOfxStatErrBadHandle }
      return set.suiteSet(n, index: 0, count: count, kind: .int) { s, _ in
        if case .int(var a) = s { for k in 0..<Int(count) { a[k] = v[k] }; s = .int(a) }
      }
    },
    propGetPointer: { h, n, i, out in
      getOne(h, n, i, .pointer) { s, i in if case .pointer(let a) = s { out?.pointee = a[i] } }
    },
    propGetString: { h, n, i, out in
      getOne(h, n, i, .string) { s, i in if case .string(let a) = s { out?.pointee = a[i] } }
    },
    propGetDouble: { h, n, i, out in
      getOne(h, n, i, .double) { s, i in if case .double(let a) = s { out?.pointee = a[i] } }
    },
    propGetInt: { h, n, i, out in
      getOne(h, n, i, .int) { s, i in if case .int(let a) = s { out?.pointee = a[i] } }
    },
    propGetPointerN: { h, n, count, out in
      guard let set = OFXPropertySet.from(h), let out else { return kOfxStatErrBadHandle }
      return set.suiteGet(n, index: 0, count: count, kind: .pointer) { s, _ in
        if case .pointer(let a) = s { for k in 0..<Int(count) { out[k] = a[k] } }
      }
    },
    propGetStringN: { h, n, count, out in
      guard let set = OFXPropertySet.from(h), let out else { return kOfxStatErrBadHandle }
      return set.suiteGet(n, index: 0, count: count, kind: .string) { s, _ in
        if case .string(let a) = s { for k in 0..<Int(count) { out[k] = a[k] } }
      }
    },
    propGetDoubleN: { h, n, count, out in
      guard let set = OFXPropertySet.from(h), let out else { return kOfxStatErrBadHandle }
      return set.suiteGet(n, index: 0, count: count, kind: .double) { s, _ in
        if case .double(let a) = s { for k in 0..<Int(count) { out[k] = a[k] } }
      }
    },
    propGetIntN: { h, n, count, out in
      guard let set = OFXPropertySet.from(h), let out else { return kOfxStatErrBadHandle }
      return set.suiteGet(n, index: 0, count: count, kind: .int) { s, _ in
        if case .int(let a) = s { for k in 0..<Int(count) { out[k] = a[k] } }
      }
    },
    propReset: { h, n in
      OFXPropertySet.from(h)?.suiteReset(n) ?? kOfxStatErrBadHandle
    },
    propGetDimension: { h, n, count in
      OFXPropertySet.from(h)?.suiteDimension(n, count) ?? kOfxStatErrBadHandle
    }))

  // MARK: Image effect suite

  /// Memory handed out by `imageMemoryAlloc`.
  private final class ImageMemory {
    let pointer: UnsafeMutableRawPointer
    init(bytes: Int) { pointer = .allocate(byteCount: max(bytes, 1), alignment: 64) }
    deinit { pointer.deallocate() }
  }

  static let imageEffect = make(OfxImageEffectSuiteV1(
    getPropertySet: { h, out in
      guard let effect = OFXImageEffect.from(h) else { return kOfxStatErrBadHandle }
      out?.pointee = effect.properties.handle
      return kOfxStatOK
    },
    getParamSet: { h, out in
      guard let effect = OFXImageEffect.from(h) else { return kOfxStatErrBadHandle }
      out?.pointee = effect.parameterSet.handle
      return kOfxStatOK
    },
    clipDefine: { h, name, out in
      guard let effect = OFXImageEffect.from(h), let name else { return kOfxStatErrBadHandle }
      do {
        let clip = try effect.defineClip(String(cString: name))
        out?.pointee = clip.properties.handle
        return kOfxStatOK
      } catch { return OFXStatus.from(error) }
    },
    clipGetHandle: { h, name, clipOut, propsOut in
      guard let effect = OFXImageEffect.from(h), let name else { return kOfxStatErrBadHandle }
      guard let clip = effect.clip(named: String(cString: name)) else { return kOfxStatErrUnknown }
      clipOut?.pointee = clip.handle
      propsOut?.pointee = clip.properties.handle
      return kOfxStatOK
    },
    clipGetPropertySet: { h, out in
      guard let clip = OFXClip.from(h) else { return kOfxStatErrBadHandle }
      out?.pointee = clip.properties.handle
      return kOfxStatOK
    },
    clipGetImage: { h, time, _, out in
      guard let clip = OFXClip.from(h), let instance = clip.effect as? OFXImageEffectInstance else {
        return kOfxStatErrBadHandle
      }
      guard let image = instance.fetchImage(clip: clip, time: time) else { return kOfxStatFailed }
      out?.pointee = image.handle
      return kOfxStatOK
    },
    clipReleaseImage: { h in
      guard let image = OFXPropertySet.from(h) as? OFXImage,
            image.owner?.releaseImage(image) == true else { return kOfxStatErrBadHandle }
      return kOfxStatOK
    },
    clipGetRegionOfDefinition: { h, time, out in
      guard let clip = OFXClip.from(h), let instance = clip.effect as? OFXImageEffectInstance else {
        return kOfxStatErrBadHandle
      }
      out?.pointee = instance.clipRegionOfDefinition(clip, at: time)
      return kOfxStatOK
    },
    abort: { h in
      guard let instance = OFXImageEffect.from(h) as? OFXImageEffectInstance else { return 0 }
      return instance.abortRequested ? 1 : 0
    },
    imageMemoryAlloc: { _, bytes, out in
      let memory = ImageMemory(bytes: bytes)
      out?.pointee = OpaquePointer(Unmanaged.passRetained(memory).toOpaque())
      return kOfxStatOK
    },
    imageMemoryFree: { h in
      guard let h else { return kOfxStatErrBadHandle }
      Unmanaged<ImageMemory>.fromOpaque(UnsafeRawPointer(h)).release()
      return kOfxStatOK
    },
    imageMemoryLock: { h, out in
      guard let h else { return kOfxStatErrBadHandle }
      out?.pointee = Unmanaged<ImageMemory>.fromOpaque(UnsafeRawPointer(h)).takeUnretainedValue().pointer
      return kOfxStatOK
    },
    imageMemoryUnlock: { h in h == nil ? kOfxStatErrBadHandle : kOfxStatOK }))

  // MARK: Parameter suite

  static let parameter: UnsafeMutablePointer<OfxParameterSuiteV1> = {
    let p = make(OfxParameterSuiteV1(
      paramDefine: { h, type, name, out in
        guard let set = OFXParameterSet.from(h), let type, let name else { return kOfxStatErrBadHandle }
        let t = OFXParamType(rawValue: String(cString: type))
        guard t.valueLayout.kind != OfxSwiftParamValueKindNone || [.group, .page, .pushButton, .parametric].contains(t)
        else { return kOfxStatErrUnknown }
        do {
          let param = try set.define(type: t, name: String(cString: name))
          out?.pointee = param.properties.handle
          return kOfxStatOK
        } catch { return OFXStatus.from(error) }
      },
      paramGetHandle: { h, name, paramOut, propsOut in
        guard let set = OFXParameterSet.from(h), let name else { return kOfxStatErrBadHandle }
        guard let param = set[String(cString: name)] else { return kOfxStatErrUnknown }
        paramOut?.pointee = param.handle
        propsOut?.pointee = param.properties.handle
        return kOfxStatOK
      },
      paramSetGetPropertySet: { h, out in
        guard let set = OFXParameterSet.from(h) else { return kOfxStatErrBadHandle }
        out?.pointee = set.properties.handle
        return kOfxStatOK
      },
      paramGetPropertySet: { h, out in
        guard let param = OFXParameter.from(h) else { return kOfxStatErrBadHandle }
        out?.pointee = param.properties.handle
        return kOfxStatOK
      },
      paramGetValue: nil,
      paramGetValueAtTime: nil,
      paramGetDerivative: nil,
      paramGetIntegral: nil,
      paramSetValue: nil,
      paramSetValueAtTime: nil,
      paramGetNumKeys: { h, out in
        guard let param = OFXParameter.from(h) else { return kOfxStatErrBadHandle }
        out?.pointee = UInt32(param.keyframeTimes.count)
        return kOfxStatOK
      },
      paramGetKeyTime: { h, nth, out in
        guard let param = OFXParameter.from(h) else { return kOfxStatErrBadHandle }
        let times = param.keyframeTimes
        guard Int(nth) < times.count else { return kOfxStatErrBadIndex }
        out?.pointee = times[Int(nth)]
        return kOfxStatOK
      },
      paramGetKeyIndex: { h, time, direction, out in
        guard let param = OFXParameter.from(h) else { return kOfxStatErrBadHandle }
        let times = param.keyframeTimes
        let index: Int?
        switch direction {
        case 0: index = times.firstIndex(of: time)
        case ..<0: index = times.lastIndex { $0 < time }
        default: index = times.firstIndex { $0 > time }
        }
        guard let index else { return kOfxStatFailed }
        out?.pointee = Int32(index)
        return kOfxStatOK
      },
      paramDeleteKey: { h, time in
        guard let param = OFXParameter.from(h) else { return kOfxStatErrBadHandle }
        return param.deleteKeyframe(at: time) ? kOfxStatOK : kOfxStatErrBadIndex
      },
      paramDeleteAllKeys: { h in
        guard let param = OFXParameter.from(h) else { return kOfxStatErrBadHandle }
        param.deleteAllKeyframes()
        return kOfxStatOK
      },
      paramCopy: { to, from, offset, range in
        guard let dst = OFXParameter.from(to), let src = OFXParameter.from(from) else { return kOfxStatErrBadHandle }
        guard dst.type == src.type else { return kOfxStatErrValue }
        let keys = src.keyframeTimes.filter { t in range.map { t >= $0.pointee.min && t <= $0.pointee.max } ?? true }
        if keys.isEmpty {
          dst.setValue(src.value())
        } else {
          for t in keys { dst.setValue(src.value(at: t), at: t + offset) }
        }
        return kOfxStatOK
      },
      paramEditBegin: { h, _ in OFXParameterSet.from(h) == nil ? kOfxStatErrBadHandle : kOfxStatOK },
      paramEditEnd: { h in OFXParameterSet.from(h) == nil ? kOfxStatErrBadHandle : kOfxStatOK }))
    OfxSwiftInstallVariadicParamFunctions(p)
    return p
  }()

  // MARK: Memory suite

  static let memory = make(OfxMemorySuiteV1(
    memoryAlloc: { _, bytes, out in
      guard let out else { return kOfxStatErrBadHandle }
      var p: UnsafeMutableRawPointer?
      guard posix_memalign(&p, 64, max(bytes, 1)) == 0, let p else { return kOfxStatErrMemory }
      out.pointee = p
      return kOfxStatOK
    },
    memoryFree: { p in
      free(p)
      return kOfxStatOK
    }))

  // MARK: Multi-thread suite

  /// Thread-local state for `multiThreadIndex` / `multiThreadIsSpawnedThread`.
  /// Stores `index + 1` so that 0 means "not a spawned thread".
  private static let threadKey: pthread_key_t = {
    var key = pthread_key_t()
    pthread_key_create(&key, nil)
    return key
  }()

  private final class Mutex {
    let lock = NSRecursiveLock()
  }

  static let multiThread = make(OfxMultiThreadSuiteV1(
    multiThread: { fn, nThreads, arg in
      guard let fn else { return kOfxStatErrBadHandle }
      let n = max(nThreads, 1)
      let key = threadKey
      let previous = pthread_getspecific(key)
      // The arg pointer is the plug-in's business; pass it through as a bit pattern.
      let argBits = UInt(bitPattern: arg)
      DispatchQueue.concurrentPerform(iterations: Int(n)) { i in
        let saved = pthread_getspecific(key)
        pthread_setspecific(key, UnsafeRawPointer(bitPattern: UInt(i + 1)))
        fn(UInt32(i), n, UnsafeMutableRawPointer(bitPattern: argBits))
        pthread_setspecific(key, saved)
      }
      pthread_setspecific(key, previous)
      return kOfxStatOK
    },
    multiThreadNumCPUs: { out in
      out?.pointee = UInt32(ProcessInfo.processInfo.activeProcessorCount)
      return kOfxStatOK
    },
    multiThreadIndex: { out in
      let v = UInt(bitPattern: pthread_getspecific(threadKey))
      out?.pointee = v == 0 ? 0 : UInt32(v - 1)
      return kOfxStatOK
    },
    multiThreadIsSpawnedThread: {
      pthread_getspecific(threadKey) == nil ? 0 : 1
    },
    mutexCreate: { out, lockCount in
      guard let out else { return kOfxStatErrBadHandle }
      let m = Mutex()
      for _ in 0..<max(lockCount, 0) { m.lock.lock() }
      out.pointee = OpaquePointer(Unmanaged.passRetained(m).toOpaque())
      return kOfxStatOK
    },
    mutexDestroy: { h in
      guard let h else { return kOfxStatErrBadHandle }
      Unmanaged<Mutex>.fromOpaque(UnsafeRawPointer(h)).release()
      return kOfxStatOK
    },
    mutexLock: { h in
      guard let h else { return kOfxStatErrBadHandle }
      Unmanaged<Mutex>.fromOpaque(UnsafeRawPointer(h)).takeUnretainedValue().lock.lock()
      return kOfxStatOK
    },
    mutexUnLock: { h in
      guard let h else { return kOfxStatErrBadHandle }
      Unmanaged<Mutex>.fromOpaque(UnsafeRawPointer(h)).takeUnretainedValue().lock.unlock()
      return kOfxStatOK
    },
    mutexTryLock: { h in
      guard let h else { return kOfxStatErrBadHandle }
      return Unmanaged<Mutex>.fromOpaque(UnsafeRawPointer(h)).takeUnretainedValue().lock.try()
        ? kOfxStatOK : kOfxStatFailed
    }))

  // MARK: Message suites (variadic, filled in by the C shim)

  static let messageV1: UnsafeMutablePointer<OfxMessageSuiteV1> = {
    let p = make(OfxMessageSuiteV1(message: nil))
    OfxSwiftInstallVariadicMessageFunctions(p, nil)
    return p
  }()

  static let messageV2: UnsafeMutablePointer<OfxMessageSuiteV2> = {
    let p = make(OfxMessageSuiteV2(message: nil, setPersistentMessage: nil, clearPersistentMessage: nil))
    OfxSwiftInstallVariadicMessageFunctions(nil, p)
    return p
  }()

  // MARK: Progress suites

  private static func progress(_ h: UnsafeMutableRawPointer?, _ value: Double) -> OfxStatus {
    guard let instance = h.flatMap({ OFXImageEffect.from(OpaquePointer($0)) }) as? OFXImageEffectInstance else {
      return kOfxStatErrBadHandle
    }
    instance.onProgress?(value)
    // Returning ReplyNo tells the plug-in to stop.
    return instance.abortRequested ? kOfxStatReplyNo : kOfxStatOK
  }

  static let progressV1 = make(OfxProgressSuiteV1(
    progressStart: { h, _ in progress(h, 0) },
    progressUpdate: { h, v in progress(h, v) },
    progressEnd: { h in progress(h, 1) }))

  static let progressV2 = make(OfxProgressSuiteV2(
    progressStart: { h, _, _ in progress(h, 0) },
    progressUpdate: { h, v in progress(h, v) },
    progressEnd: { h in progress(h, 1) }))

  // MARK: Timeline suite

  private static func instance(_ h: UnsafeMutableRawPointer?) -> OFXImageEffectInstance? {
    h.flatMap { OFXImageEffect.from(OpaquePointer($0)) } as? OFXImageEffectInstance
  }

  static let timeLine = make(OfxTimeLineSuiteV1(
    getTime: { h, out in
      guard let i = instance(h) else { return kOfxStatErrBadHandle }
      out?.pointee = i.time
      return kOfxStatOK
    },
    gotoTime: { h, t in
      guard let i = instance(h) else { return kOfxStatErrBadHandle }
      i.setTime(t)
      return kOfxStatOK
    },
    getTimeBounds: { h, first, last in
      guard let i = instance(h) else { return kOfxStatErrBadHandle }
      first?.pointee = i.project.frameRange.lowerBound
      last?.pointee = i.project.frameRange.upperBound
      return kOfxStatOK
    }))

  // MARK: Interact suite (this host creates no interacts)

  static let interact = make(OfxInteractSuiteV1(
    interactSwapBuffers: { _ in kOfxStatErrBadHandle },
    interactRedraw: { _ in kOfxStatErrBadHandle },
    interactGetPropertySet: { _, _ in kOfxStatErrBadHandle }))
}

/// A static empty C string, for treating NULL string arguments as "".
private let emptyCString: UnsafePointer<CChar> = UnsafePointer(strdup("")!)
