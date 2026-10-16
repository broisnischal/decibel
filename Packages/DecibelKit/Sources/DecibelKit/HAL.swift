import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public let operation: String

    public var description: String { "\(operation) failed (\(status.fourCharCode))" }
}

extension OSStatus {
    /// Core Audio errors are usually four printable characters, e.g. 'who?' or '!dev'.
    var fourCharCode: String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: self).bigEndian, Array.init)
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(self) }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
}

/// Thin typed accessors over AudioObjectGetPropertyData.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static let main = kAudioObjectPropertyElementMain

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = main) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    element: AudioObjectPropertyElement = main) -> Bool {
        var address = address(selector, scope: scope, element: element)
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                           element: AudioObjectPropertyElement = main) -> Bool {
        var address = address(selector, scope: scope, element: element)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(object, &address),
              AudioObjectIsPropertySettable(object, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = main, initial: T) throws -> T {
        var address = address(selector, scope: scope, element: element)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        try check(status, "Reading \(selector.propertyName)")
        return value
    }

    static func write<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         element: AudioObjectPropertyElement = main, value: T) throws {
        var address = address(selector, scope: scope, element: element)
        var value = value
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        try check(status, "Writing \(selector.propertyName)")
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        try check(status, "Reading \(selector.propertyName)")
        guard let value else { throw CoreAudioError(status: kAudioHardwareUnknownPropertyError, operation: "Reading \(selector.propertyName)") }
        return value.takeRetainedValue() as String
    }

    static func readArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, zero: T) throws -> [T] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "Sizing \(selector.propertyName)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](repeating: zero, count: count)
        let status = values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, "Reading \(selector.propertyName)")
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    /// The HAL's process object for a PID (used to exclude ourselves from the global tap).
    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        try check(status, "Looking up the Decibel audio process")
        return object
    }
}

extension AudioObjectPropertySelector {
    var propertyName: String { OSStatus(bitPattern: self).fourCharCode }
}

/// Keeps a HAL property listener registered for its lifetime. The handler runs on `queue`.
public final class AudioPropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    public init(object: AudioObjectID,
                selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                queue: DispatchQueue = .main,
                handler: @escaping () -> Void) throws {
        self.object = object
        self.address = HAL.address(selector, scope: scope)
        self.queue = queue
        self.block = { _, _ in handler() }
        try check(AudioObjectAddPropertyListenerBlock(object, &address, queue, block), "Listening for \(selector.propertyName)")
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
