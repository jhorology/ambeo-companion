import CoreAudio
import Foundation
import Logging
import Observation

public struct AudioDevice: Sendable, Identifiable, Hashable {
  public let id: AudioDeviceID
  public let uid: String
  public let name: String
}

public struct AudioPhysicalFormat: Sendable, Identifiable, Hashable, Codable {
  public var id: String { displayName }
  public let channels: UInt32
  public let bitDepth: UInt32
  public let sampleRate: Double
  public let formatID: UInt32

  public init(
    channels: UInt32,
    bitDepth: UInt32,
    sampleRate: Double,
    formatID: UInt32 = kAudioFormatLinearPCM
  ) {
    self.channels = channels
    self.bitDepth = bitDepth
    self.sampleRate = sampleRate
    self.formatID = formatID
  }

  enum CodingKeys: String, CodingKey {
    case channels, bitDepth, sampleRate, formatID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.channels = try container.decode(UInt32.self, forKey: .channels)
    self.bitDepth = try container.decode(UInt32.self, forKey: .bitDepth)
    self.sampleRate = try container.decode(Double.self, forKey: .sampleRate)
    self.formatID =
      try container.decodeIfPresent(UInt32.self, forKey: .formatID) ?? kAudioFormatLinearPCM
  }

  public var displayName: String {
    let hz = sampleRate / 1000.0
    let hzString =
      hz.truncatingRemainder(dividingBy: 1) == 0
      ? String(format: "%.0f", hz)
      : String(format: "%.1f", hz)
    return "\(channels)ch \(bitDepth)-bit \(hzString)kHz"
  }

  public var distanceFrom48kHz: Double {
    abs(sampleRate - 48000.0)
  }

  public var isAtmosOrMultichannel: Bool {
    channels > 2
      || formatID == 1_836_344_180  // 'mat$' Dolby MAT 2.0
      || formatID == 1_836_344_107  // 'mat+'
      || formatID == 1_667_509_043  // 'cea3' Dolby Digital Plus
      || formatID == 1_667_588_915  // 'cmlp' TrueHD
  }
}

// extension Notification.Name {
//   static let audioDeviceChanged = Notification.Name(
//     "io.github.jhorology.AmbeoCompanion.audioDeviceChanged"
//   )
// }

public final class AudioDeviceMonitor: Sendable {
  public static let shared = AudioDeviceMonitor()

  private init() {}

  public var defaultDeviceStream: AsyncStream<AudioDevice?> {
    AsyncStream { continuation in
      class StreamContext: @unchecked Sendable {
        weak var monitor: AudioDeviceMonitor?
        let continuation: AsyncStream<AudioDevice?>.Continuation

        init(monitor: AudioDeviceMonitor, continuation: AsyncStream<AudioDevice?>.Continuation) {
          self.monitor = monitor
          self.continuation = continuation
        }
      }

      let context = StreamContext(monitor: self, continuation: continuation)
      let bridge = Unmanaged.passRetained(context).toOpaque()

      // --- Sendableエラー対策 ---
      nonisolated(unsafe) let safeBridge = bridge

      let listener: AudioObjectPropertyListenerProc = { _, _, _, refcon in
        guard let refcon = refcon else { return noErr }
        let ctx = Unmanaged<StreamContext>.fromOpaque(refcon).takeUnretainedValue()
        ctx.continuation.yield(ctx.monitor?.currentDefaultDevice)
        return noErr
      }

      let address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )

      var mutableAddress = address
      AudioObjectAddPropertyListener(
        AudioObjectID(kAudioObjectSystemObject),
        &mutableAddress,
        listener,
        safeBridge  // safeBridgeを使用
      )

      continuation.yield(currentDefaultDevice)

      continuation.onTermination = { @Sendable _ in
        var addr = address
        AudioObjectRemovePropertyListener(
          AudioObjectID(kAudioObjectSystemObject),
          &addr,
          listener,
          safeBridge  // safeBridgeを使用
        )
        Unmanaged<StreamContext>.fromOpaque(safeBridge).release()
      }
    }
  }

  public var allOutputDevices: [AudioDevice] {
    let deviceIDs = systemProperty(
      selector: kAudioHardwarePropertyDevices,
      type: AudioDeviceID.self
    )
    return deviceIDs.compactMap { id in
      if !hasOutput(for: id) { return nil }
      guard let uid = uid(for: id) else { return nil }
      return AudioDevice(id: id, uid: uid, name: name(for: id) ?? "Unknown")
    }
  }

  public var currentDefaultDevice: AudioDevice? {
    let ids = systemProperty(
      selector: kAudioHardwarePropertyDefaultOutputDevice,
      type: AudioDeviceID.self
    )
    guard let id = ids.first, id != kAudioObjectUnknown else { return nil }
    guard let uid = uid(for: id) else { return nil }
    return AudioDevice(id: id, uid: uid, name: name(for: id) ?? "Unknown")
  }

  public func audioDevice(withUid uid: String) -> AudioDevice? {
    allOutputDevices.first { $0.uid == uid }
  }

  public func checkHogged(for id: AudioDeviceID) -> Bool {
    let isHogged =
      property(for: id, selector: kAudioDevicePropertyHogMode, type: pid_t.self).first ?? -1
      != -1
    return isHogged
  }

  public func supportedFormats(for id: AudioDeviceID) -> [AudioPhysicalFormat] {
    let streamIds = property(
      for: id,
      selector: kAudioDevicePropertyStreams,
      scope: kAudioDevicePropertyScopeOutput,
      type: AudioStreamID.self
    )
    guard let streamId = streamIds.first else { return [] }

    let ranges = property(
      for: streamId,
      selector: kAudioStreamPropertyAvailablePhysicalFormats,
      type: AudioStreamRangedDescription.self
    )

    let formats = ranges.compactMap { range -> AudioPhysicalFormat? in
      let asbd = range.mFormat

      // exclude non LPCM format
      guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

      return AudioPhysicalFormat(
        channels: asbd.mChannelsPerFrame,
        bitDepth: asbd.mBitsPerChannel,
        sampleRate: asbd.mSampleRate,
        formatID: asbd.mFormatID
      )
    }

    // sort order by sampleRate, channnels, bitDepth
    return Array(Set(formats)).sorted {
      if $0.sampleRate != $1.sampleRate { return $0.sampleRate < $1.sampleRate }
      if $0.channels != $1.channels { return $0.channels < $1.channels }
      return $0.bitDepth < $1.bitDepth
    }
  }

  public func currentPhysicalFormat(for id: AudioDeviceID) -> AudioPhysicalFormat? {
    let streamIds = property(
      for: id,
      selector: kAudioDevicePropertyStreams,
      scope: kAudioDevicePropertyScopeOutput,
      type: AudioStreamID.self
    )
    guard let streamId = streamIds.first else { return nil }

    var address = AudioObjectPropertyAddress(
      mSelector: kAudioStreamPropertyPhysicalFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let getStatus = AudioObjectGetPropertyData(streamId, &address, 0, nil, &size, &asbd)
    guard getStatus == noErr else { return nil }

    return AudioPhysicalFormat(
      channels: asbd.mChannelsPerFrame,
      bitDepth: asbd.mBitsPerChannel,
      sampleRate: asbd.mSampleRate,
      formatID: asbd.mFormatID
    )
  }

  public func formatStream(for id: AudioDeviceID) -> AsyncStream<AudioPhysicalFormat?> {
    AsyncStream { continuation in
      let streamIds = self.property(
        for: id,
        selector: kAudioDevicePropertyStreams,
        scope: kAudioDevicePropertyScopeOutput,
        type: AudioStreamID.self
      )
      guard let streamId = streamIds.first else {
        continuation.yield(nil)
        continuation.finish()
        return
      }

      final class StreamContext: @unchecked Sendable {
        weak var monitor: AudioDeviceMonitor?
        let deviceId: AudioDeviceID
        let continuation: AsyncStream<AudioPhysicalFormat?>.Continuation

        init(
          monitor: AudioDeviceMonitor,
          deviceId: AudioDeviceID,
          continuation: AsyncStream<AudioPhysicalFormat?>.Continuation
        ) {
          self.monitor = monitor
          self.deviceId = deviceId
          self.continuation = continuation
        }
      }

      let context = StreamContext(
        monitor: self,
        deviceId: id,
        continuation: continuation
      )
      let bridge = Unmanaged.passRetained(context).toOpaque()
      nonisolated(unsafe) let safeBridge = bridge

      let listener: AudioObjectPropertyListenerProc = { _, _, _, refcon in
        guard let refcon else { return noErr }
        let ctx = Unmanaged<StreamContext>.fromOpaque(refcon).takeUnretainedValue()
        let format = ctx.monitor?.currentPhysicalFormat(for: ctx.deviceId)
        ctx.continuation.yield(format)
        return noErr
      }

      let address = AudioObjectPropertyAddress(
        mSelector: kAudioStreamPropertyPhysicalFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )

      var mutableAddress = address
      AudioObjectAddPropertyListener(
        streamId,
        &mutableAddress,
        listener,
        safeBridge
      )

      continuation.yield(self.currentPhysicalFormat(for: id))

      continuation.onTermination = { @Sendable _ in
        var addr = address
        AudioObjectRemovePropertyListener(
          streamId,
          &addr,
          listener,
          safeBridge
        )
        Unmanaged<StreamContext>.fromOpaque(safeBridge).release()
      }
    }
  }

  public func fallback(format: AudioPhysicalFormat, for id: AudioDeviceID) {
    let streamIds = property(
      for: id,
      selector: kAudioDevicePropertyStreams,
      type: AudioStreamID.self
    )
    guard let streamId = streamIds.first else { return }

    var address = AudioObjectPropertyAddress(
      mSelector: kAudioStreamPropertyPhysicalFormat,  // 💡 物理フォーマットを直接指定
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

    // load currnt status
    let getStatus = AudioObjectGetPropertyData(streamId, &address, 0, nil, &size, &asbd)
    guard getStatus == noErr else { return }

    asbd.mSampleRate = format.sampleRate
    asbd.mChannelsPerFrame = format.channels
    asbd.mBitsPerChannel = format.bitDepth

    let bytesPerSample = format.bitDepth / 8
    asbd.mBytesPerFrame = bytesPerSample * format.channels
    asbd.mBytesPerPacket = asbd.mBytesPerFrame * asbd.mFramesPerPacket

    let setStatus = AudioObjectSetPropertyData(
      streamId,
      &address,
      0,
      nil,
      size,
      &asbd
    )

    if setStatus == noErr {
      Logger.audio.info("Successfully forced fallback: \(format.displayName)")
    } else {
      Logger.audio.error("Failed to set fallback format: \(setStatus)")
    }
  }

  // --- Private Helpers for C language world ---

  private func name(for id: AudioDeviceID) -> String? {
    let names = property(
      for: id,
      selector: kAudioDevicePropertyDeviceNameCFString,
      type: CFString.self
    )
    return names.first as String?
  }

  private func uid(for id: AudioDeviceID) -> String? {
    let uids = property(for: id, selector: kAudioDevicePropertyDeviceUID, type: CFString.self)
    return uids.first as String?
  }

  private func hasOutput(for id: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
    return size > 0
  }

  private func systemProperty<T>(selector: AudioObjectPropertySelector, type: T.Type) -> [T] {
    property(for: AudioObjectID(kAudioObjectSystemObject), selector: selector, type: type)
  }

  private func property<T>(
    for id: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    type: T.Type
  ) -> [T] {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )

    var size: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
    guard sizeStatus == noErr, size > 0 else { return [] }

    let count = Int(size) / MemoryLayout<T>.size

    return [T](unsafeUninitializedCapacity: count) { buffer, initializedCount in
      let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer.baseAddress!)
      if status == noErr {
        initializedCount = count
      } else {
        initializedCount = 0
      }
    }
  }
}
