import Darwin

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Reads a sysctl whose value is a C struct (e.g. `kern.boottime` → `timeval`).
    static func raw<T>(_ name: String, into value: inout T) -> Bool {
        var size = MemoryLayout<T>.size
        return withUnsafeMutablePointer(to: &value) {
            sysctlbyname(name, $0, &size, nil, 0) == 0
        }
    }

    static func value<T: FixedWidthInteger>(_ name: String) -> T? {
        var value = T.zero
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
