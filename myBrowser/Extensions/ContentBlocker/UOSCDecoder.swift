import Foundation

/// A value produced by uBlock Origin's storage serializer.
///
/// The on-disk form is an original reading of the `UOSC_1` / `UOSC/lz4_1` layout
/// (base-88 lengths, UTF-16 string sizes, LZ4 block payload). It is not a copy of
/// uBO's decoder. The sparse byte tail keeps the final 1–3 bytes; the reference
/// decoder drops them when the buffer length is not a multiple of 4.
nonisolated indirect enum UOSCValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case undefined
    case array([UOSCValue])
    case object([String: UOSCValue])
    case bytes(Data)

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var int: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var bytes: Data? {
        if case .bytes(let value) = self { return value }
        return nil
    }

    var object: [String: UOSCValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// A string, a UTF-8 byte buffer, or a newline-joined string array.
    var text: String? {
        switch self {
        case .string(let value):
            return value
        case .bytes(let data):
            return String(data: data, encoding: .utf8)
        case .array(let values):
            let lines = values.compactMap(\.string)
            guard lines.count == values.count else { return nil }
            return lines.joined(separator: "\n")
        default:
            return nil
        }
    }

    var stringList: [String]? {
        switch self {
        case .array(let values):
            let lines = values.compactMap(\.string)
            return lines.count == values.count ? lines : nil
        case .string(let value):
            if value.contains("\n") {
                return value.split(whereSeparator: \.isNewline).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
            }
            return [value]
        default:
            return nil
        }
    }
}

nonisolated enum UOSCDecoder {
    private static let safeCharacters = Array("&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]^_`abcdefghijklmnopqrstuvwxyz{|}~".utf16)
    private static let digit: [UInt16: Int] = {
        var map: [UInt16: Int] = [:]
        for (index, unit) in safeCharacters.enumerated() {
            map[unit] = index
        }
        return map
    }()

    private enum Kind {
        static let stringSmall = 1
        static let stringLarge = 2
        static let zero = 3
        static let intSmallPos = 4
        static let intSmallNeg = 5
        static let intLargePos = 6
        static let intLargeNeg = 7
        static let boolFalse = 8
        static let boolTrue = 9
        static let null = 10
        static let undefined = 11
        static let float = 12
        static let regexp = 13
        static let date = 14
        static let reference = 15
        static let objectSmall = 16
        static let objectLarge = 17
        static let arraySmall = 18
        static let arrayLarge = 19
        static let setSmall = 20
        static let setLarge = 21
        static let mapSmall = 22
        static let mapLarge = 23
        static let arrayBuffer = 24
        static let int8 = 25
        static let uint8 = 26
        static let uint8Clamped = 27
        static let int16 = 28
        static let uint16 = 29
        static let int32 = 30
        static let uint32 = 31
        static let float32 = 32
        static let float64 = 33
        static let dataView = 34
    }

    /// Decodes a serialized value. A compressed payload is inflated and decoded again.
    static func decode(_ text: String) -> UOSCValue? {
        if text.hasPrefix("UOSC/lz4_1 ") {
            guard let wrapper = decodePayload(text, prefixCount: "UOSC/lz4_1 ".utf16.count),
                  let object = wrapper.object,
                  let size = object["size"]?.int,
                  let data = object["data"]?.bytes,
                  let inflated = lz4Decode(data, outputSize: size),
                  let inner = String(data: inflated, encoding: .utf8) else { return nil }
            return decode(inner)
        }
        guard text.hasPrefix("UOSC_1 ") else { return nil }
        return decodePayload(text, prefixCount: "UOSC_1 ".utf16.count)
    }

    private static func decodePayload(_ text: String, prefixCount: Int) -> UOSCValue? {
        let units = Array(text.utf16)
        guard prefixCount <= units.count else { return nil }
        let reader = Reader(units: units, index: prefixCount)
        guard let value = reader.readValue(), !reader.failed, reader.index == units.count else { return nil }
        return value
    }

    /// Standard LZ4 block decode. Returns nil when the block is truncated or the match is out of range.
    static func lz4Decode(_ input: Data, outputSize: Int) -> Data? {
        guard outputSize >= 0, outputSize <= 64_000_000 else { return nil }
        if outputSize == 0 { return Data() }
        var output = [UInt8](repeating: 0, count: outputSize)
        let source = [UInt8](input)
        var inIndex = 0
        var outIndex = 0
        while inIndex < source.count {
            let token = Int(source[inIndex])
            inIndex += 1
            var literalLength = token >> 4
            if literalLength == 15 {
                while true {
                    guard inIndex < source.count else { return nil }
                    let extra = Int(source[inIndex])
                    inIndex += 1
                    literalLength += extra
                    if extra != 255 { break }
                }
            }
            if literalLength > 0 {
                guard inIndex + literalLength <= source.count, outIndex + literalLength <= outputSize else { return nil }
                for _ in 0..<literalLength {
                    output[outIndex] = source[inIndex]
                    outIndex += 1
                    inIndex += 1
                }
                if inIndex == source.count { break }
            }
            guard inIndex + 1 < source.count else { return nil }
            let matchOffset = Int(source[inIndex]) | (Int(source[inIndex + 1]) << 8)
            inIndex += 2
            guard matchOffset > 0, matchOffset <= outIndex else { return nil }
            var matchLength = (token & 0x0F) + 4
            if matchLength == 19 {
                while true {
                    guard inIndex < source.count else { return nil }
                    let extra = Int(source[inIndex])
                    inIndex += 1
                    matchLength += extra
                    if extra != 255 { break }
                }
            }
            guard outIndex + matchLength <= outputSize else { return nil }
            var matchIndex = outIndex - matchOffset
            for _ in 0..<matchLength {
                output[outIndex] = output[matchIndex]
                outIndex += 1
                matchIndex += 1
            }
        }
        guard outIndex == outputSize else { return nil }
        return Data(output)
    }

    private final class Reader {
        let units: [UInt16]
        var index: Int
        var failed = false
        var refs: [Int: UOSCValue] = [:]
        var nextRef = 1

        init(units: [UInt16], index: Int) {
            self.units = units
            self.index = index
        }

        var end: Int { units.count }

        func readValue() -> UOSCValue? {
            guard !failed, index < end else {
                failed = true
                return nil
            }
            let type = digit[units[index]] ?? -1
            index += 1
            switch type {
            case Kind.stringSmall:
                guard let count = readDigit() else { return fail() }
                return readRaw(count).map(UOSCValue.string)
            case Kind.stringLarge:
                guard let count = readLargeUint() else { return fail() }
                return readRaw(count).map(UOSCValue.string)
            case Kind.zero:
                return .int(0)
            case Kind.intSmallPos:
                return readDigit().map(UOSCValue.int)
            case Kind.intSmallNeg:
                return readDigit().map { .int(-$0) }
            case Kind.intLargePos:
                return readLargeUint().map(UOSCValue.int)
            case Kind.intLargeNeg:
                return readLargeUint().map { .int(-$0) }
            case Kind.boolFalse:
                return .bool(false)
            case Kind.boolTrue:
                return .bool(true)
            case Kind.null:
                return .null
            case Kind.undefined:
                return .undefined
            case Kind.float:
                guard let count = readLargeUint(), let text = readRaw(count), let value = Double(text) else { return fail() }
                return .double(value)
            case Kind.date:
                return readValue()
            case Kind.regexp:
                _ = readValue()
                _ = readValue()
                return fail()
            case Kind.reference:
                guard let id = readLargeUint(), let value = refs[id] else { return fail() }
                return value
            case Kind.objectSmall, Kind.objectLarge:
                return readObject(large: type == Kind.objectLarge)
            case Kind.arraySmall, Kind.arrayLarge:
                return readArray(large: type == Kind.arrayLarge)
            case Kind.setSmall, Kind.setLarge:
                return readArray(large: type == Kind.setLarge)
            case Kind.mapSmall, Kind.mapLarge:
                return readMap(large: type == Kind.mapLarge)
            case Kind.arrayBuffer:
                return readBuffer()
            case Kind.int8, Kind.uint8, Kind.uint8Clamped, Kind.int16, Kind.uint16, Kind.int32, Kind.uint32, Kind.float32, Kind.float64, Kind.dataView:
                return readView()
            default:
                return fail()
            }
        }

        private func fail() -> UOSCValue? {
            failed = true
            return nil
        }

        private func readDigit() -> Int? {
            guard index < end, let value = digit[units[index]] else { return failInt() }
            index += 1
            return value
        }

        private func failInt() -> Int? {
            failed = true
            return nil
        }

        /// Least-significant digit first, terminated by a space.
        private func readLargeUint() -> Int? {
            guard index < end, let first = digit[units[index]] else { return failInt() }
            index += 1
            var value = first
            var place = 1
            while index < end {
                let unit = units[index]
                index += 1
                if unit == 32 { return value }
                guard let next = digit[unit] else { return failInt() }
                let (scaled, overflow) = place.multipliedReportingOverflow(by: 88)
                if overflow { return failInt() }
                place = scaled
                let (added, addOverflow) = value.addingReportingOverflow(scaled * next)
                if addOverflow { return failInt() }
                value = added
            }
            return failInt()
        }

        private func readRaw(_ count: Int) -> String? {
            guard count >= 0, index + count <= end else { return failString() }
            let start = index
            index += count
            if count == 0 { return "" }
            return units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return nil }
                return String(utf16CodeUnits: base + start, count: count)
            }
        }

        private func failString() -> String? {
            failed = true
            return nil
        }

        private func readObject(large: Bool) -> UOSCValue? {
            guard let size = large ? readLargeUint() : readDigit() else { return fail() }
            let id = nextRef
            nextRef += 1
            refs[id] = .object([:])
            var fields: [String: UOSCValue] = [:]
            fields.reserveCapacity(size)
            for _ in 0..<size {
                guard let key = readValue()?.string, let value = readValue() else { return fail() }
                fields[key] = value
            }
            let object = UOSCValue.object(fields)
            refs[id] = object
            return object
        }

        private func readArray(large: Bool) -> UOSCValue? {
            guard let size = large ? readLargeUint() : readDigit() else { return fail() }
            let id = nextRef
            nextRef += 1
            refs[id] = .array([])
            var values: [UOSCValue] = []
            values.reserveCapacity(size)
            for _ in 0..<size {
                guard let value = readValue() else { return fail() }
                values.append(value)
            }
            let array = UOSCValue.array(values)
            refs[id] = array
            return array
        }

        private func readMap(large: Bool) -> UOSCValue? {
            guard let size = large ? readLargeUint() : readDigit() else { return fail() }
            let id = nextRef
            nextRef += 1
            var pairs: [UOSCValue] = []
            for _ in 0..<size {
                guard let key = readValue(), let value = readValue() else { return fail() }
                pairs.append(.array([key, value]))
            }
            let array = UOSCValue.array(pairs)
            refs[id] = array
            return array
        }

        private func readBuffer() -> UOSCValue? {
            guard let byteLength = readLargeUint(), byteLength >= 0, byteLength <= 64_000_000 else { return fail() }
            _ = readValue()
            guard let dense = readValue(), let encoded = readValue()?.string else { return fail() }
            let bytes: Data
            if case .bool(true) = dense {
                bytes = denseBytes(encoded, byteLength: byteLength)
            } else {
                bytes = sparseBytes(encoded, byteLength: byteLength)
            }
            let id = nextRef
            nextRef += 1
            let value = UOSCValue.bytes(bytes)
            refs[id] = value
            return value
        }

        private func readView() -> UOSCValue? {
            guard let offset = readLargeUint(), let length = readLargeUint() else { return fail() }
            let id = nextRef
            nextRef += 1
            guard let buffer = readValue()?.bytes else { return fail() }
            let start = min(max(offset, 0), buffer.count)
            let end = min(start + max(length, 0), buffer.count)
            let view = UOSCValue.bytes(buffer.subdata(in: start..<end))
            refs[id] = view
            return view
        }

        private func denseBytes(_ text: String, byteLength: Int) -> Data {
            let chars = Array(text.utf16)
            var data = [UInt8](repeating: 0, count: byteLength)
            let remainder = chars.count % 5
            let full = chars.count - remainder
            var out = 0
            var cursor = 0
            while cursor + 4 < full && out + 3 < data.count {
                var value = 0
                var place = 1
                for step in 0..<5 {
                    value += (digit[chars[cursor + step]] ?? 0) * place
                    place *= 88
                }
                data[out] = UInt8(value & 0xFF)
                data[out + 1] = UInt8((value >> 8) & 0xFF)
                data[out + 2] = UInt8((value >> 16) & 0xFF)
                data[out + 3] = UInt8((value >> 24) & 0xFF)
                out += 4
                cursor += 5
            }
            if remainder >= 2, out < data.count, full + 1 < chars.count {
                var value = (digit[chars[full]] ?? 0) + (digit[chars[full + 1]] ?? 0) * 88
                if remainder > 2, full + 2 < chars.count {
                    value += (digit[chars[full + 2]] ?? 0) * 7_744
                }
                if remainder > 3, full + 3 < chars.count {
                    value += (digit[chars[full + 3]] ?? 0) * 681_472
                }
                data[out] = UInt8(value & 255)
                if value != 0, out + 1 < data.count {
                    value >>= 8
                    data[out + 1] = UInt8(value & 255)
                    if value != 0, out + 2 < data.count {
                        value >>= 8
                        data[out + 2] = UInt8(value & 255)
                    }
                }
            }
            return Data(data)
        }

        /// Sparse base-88 words, then a `!` and the trailing bytes. Those trailing bytes are kept.
        private func sparseBytes(_ text: String, byteLength: Int) -> Data {
            let chars = Array(text.utf16)
            var data = [UInt8](repeating: 0, count: byteLength)
            let space: UInt16 = 32
            let sentinel: UInt16 = 33
            var cursor = 0
            var word = 0
            let words = byteLength / 4

            func readNumber(first: UInt16) -> Int {
                var value = digit[first] ?? 0
                var place = 1
                while cursor < chars.count {
                    let unit = chars[cursor]
                    cursor += 1
                    if unit == space { break }
                    place *= 88
                    value += place * (digit[unit] ?? 0)
                }
                return value
            }

            while cursor < chars.count && word < words {
                let unit = chars[cursor]
                cursor += 1
                if unit == space {
                    word += 1
                    continue
                }
                if unit == sentinel {
                    cursor -= 1
                    break
                }
                let value = readNumber(first: unit) & 0xFFFFFFFF
                let offset = word * 4
                if offset + 3 < data.count {
                    data[offset] = UInt8(value & 0xFF)
                    data[offset + 1] = UInt8((value >> 8) & 0xFF)
                    data[offset + 2] = UInt8((value >> 16) & 0xFF)
                    data[offset + 3] = UInt8((value >> 24) & 0xFF)
                }
                word += 1
            }
            guard cursor < chars.count, chars[cursor] == sentinel else { return Data(data) }
            cursor += 1
            var byteIndex = word * 4
            while cursor < chars.count && byteIndex < data.count {
                let unit = chars[cursor]
                cursor += 1
                if unit == space {
                    byteIndex += 1
                    continue
                }
                data[byteIndex] = UInt8(readNumber(first: unit) & 0xFF)
                byteIndex += 1
            }
            return Data(data)
        }
    }
}
