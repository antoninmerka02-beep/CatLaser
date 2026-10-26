// Tuya BLE protocol (v3) – port of the open-source ha_tuya_ble implementation
// https://github.com/PlusPlus-ua/ha_tuya_ble
//
// Packet layout (before fragmentation):
//   [security flag 1B][IV 16B][AES-128-CBC( seq 4B | responseTo 4B | code 2B | len 2B | data | CRC16 2B | zero pad )]
// Security flag 4 = login key  = MD5(local_key[0..<6])
// Security flag 5 = session key = MD5(local_key[0..<6] + srand)   (srand comes in the DEVICE_INFO response)
// Fragments (20 B GATT writes): [varint packetNum] (+ [varint totalLen][protocolVersion << 4] in packet 0) + payload

import Foundation
import CommonCrypto
import CryptoKit

enum TuyaCode: UInt16 {
    case deviceInfo = 0x0000
    case pair = 0x0001
    case sendDps = 0x0002
    case deviceStatus = 0x0003
    case unbind = 0x0005
    case deviceReset = 0x0006
    case sendDpsV4 = 0x0027

    case receiveDp = 0x8001
    case receiveTimeDp = 0x8003
    case receiveSignDp = 0x8004
    case receiveSignTimeDp = 0x8005
    case receiveDpV4 = 0x8006
    case receiveTimeDpV4 = 0x8007
    case time1Req = 0x8011
    case time2Req = 0x8012
}

enum DPType: UInt8 {
    case raw = 0, bool = 1, value = 2, string = 3, enumType = 4, bitmap = 5

    var name: String {
        switch self {
        case .raw: return "raw"
        case .bool: return "bool"
        case .value: return "value"
        case .string: return "string"
        case .enumType: return "enum"
        case .bitmap: return "bitmap"
        }
    }
}

struct TuyaMessage {
    let seq: UInt32
    let responseTo: UInt32
    let code: UInt16
    let data: [UInt8]

    var codeName: String {
        if let c = TuyaCode(rawValue: code) { return "\(c)" }
        return String(format: "0x%04x", code)
    }
}

struct TuyaDP {
    let id: UInt8
    let type: UInt8
    let value: [UInt8]
}

enum TuyaError: Error, CustomStringConvertible {
    case format(String)
    case crc
    case noKey(UInt8)
    case missingPacket(expected: Int, got: Int)
    case length

    var description: String {
        switch self {
        case .format(let s): return "chybný formát (\(s))"
        case .crc: return "nesedí CRC – nejspíš špatný klíč"
        case .noKey(let f): return "chybí klíč pro security flag \(f)"
        case .missingPacket(let e, let g): return "chybí fragment (čekal \(e), přišel \(g))"
        case .length: return "nesedí délka zprávy"
        }
    }
}

// MARK: - Byte helpers

extension Array where Element == UInt8 {
    mutating func appendBE32(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xff))
        append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 8) & 0xff))
        append(UInt8(v & 0xff))
    }

    mutating func appendBE16(_ v: UInt16) {
        append(UInt8((v >> 8) & 0xff))
        append(UInt8(v & 0xff))
    }

    func be32(_ i: Int) -> UInt32 {
        (UInt32(self[i]) << 24) | (UInt32(self[i + 1]) << 16) | (UInt32(self[i + 2]) << 8) | UInt32(self[i + 3])
    }

    func be16(_ i: Int) -> UInt16 {
        (UInt16(self[i]) << 8) | UInt16(self[i + 1])
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Crypto

enum TuyaCrypto {
    static func md5(_ bytes: [UInt8]) -> [UInt8] {
        Array(Insecure.MD5.hash(data: Data(bytes)))
    }

    static func randomBytes(_ n: Int) -> [UInt8] {
        (0..<n).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
    }

    /// AES-128-CBC without padding (data length must be a multiple of 16).
    static func aesCBC(encrypt: Bool, key: [UInt8], iv: [UInt8], data: [UInt8]) -> [UInt8]? {
        guard key.count == 16, iv.count == 16, data.count % 16 == 0 else { return nil }
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        let outCount = out.count
        var moved = 0
        let status = CCCrypt(
            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(0),
            key, key.count,
            iv,
            data, data.count,
            &out, outCount,
            &moved
        )
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        return Array(out.prefix(moved))
    }

    /// CRC-16/MODBUS
    static func crc16(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in data {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                let lsb = crc & 1
                crc >>= 1
                if lsb != 0 { crc ^= 0xA001 }
            }
        }
        return crc
    }

    static func varint(_ value: Int) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }

    static func unvarint(_ d: [UInt8], _ start: Int) throws -> (value: Int, next: Int) {
        var result = 0
        var offset = 0
        while offset < 5 {
            let p = start + offset
            guard p < d.count else { throw TuyaError.format("varint") }
            let b = d[p]
            result |= Int(b & 0x7f) << (offset * 7)
            offset += 1
            if b & 0x80 == 0 { break }
        }
        if offset > 4 { throw TuyaError.format("varint") }
        return (result, start + offset)
    }

    /// Decrypts the device UUID that Tuya BLE devices put into their advertisement.
    /// serviceData = service data of UUID A201, manufacturerBody = manufacturer data without the 2-byte company ID.
    static func advertisedUUID(serviceData: [UInt8], manufacturerBody: [UInt8]) -> String? {
        guard serviceData.count > 1, serviceData[0] == 0, manufacturerBody.count >= 6 + 16 else { return nil }
        let productId = Array(serviceData.dropFirst())
        let key = md5(productId)
        let enc = Array(manufacturerBody[6...])
        let n = enc.count / 16 * 16
        guard let dec = aesCBC(encrypt: false, key: key, iv: key, data: Array(enc.prefix(n))) else { return nil }
        let s = String(decoding: dec, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        return s.isEmpty ? nil : s
    }
}

// MARK: - Session

final class TuyaSession {
    static let mtu = 20

    let localKey6: [UInt8]
    let loginKey: [UInt8]
    private(set) var sessionKey: [UInt8]?
    private(set) var authKey: [UInt8]?
    var protocolVersion: UInt8 = 3

    private var seq: UInt32 = 1
    private var inBuf: [UInt8] = []
    private var expectedPacket = 0
    private var expectedLen = 0

    init(localKey: String) {
        localKey6 = Array(Array(localKey.utf8).prefix(6))
        loginKey = TuyaCrypto.md5(localKey6)
    }

    func reset() {
        seq = 1
        sessionKey = nil
        authKey = nil
        clearInput()
    }

    func clearInput() {
        inBuf = []
        expectedPacket = 0
        expectedLen = 0
    }

    /// Builds the 20-byte GATT packets for one message. Returns the sequence number used.
    func build(code: TuyaCode, data: [UInt8], responseTo: UInt32 = 0) throws -> (seq: UInt32, packets: [[UInt8]]) {
        let flag: UInt8
        let key: [UInt8]
        if code == .deviceInfo {
            flag = 4
            key = loginKey
        } else {
            guard let k = sessionKey else { throw TuyaError.noKey(5) }
            flag = 5
            key = k
        }

        let s = seq
        seq &+= 1

        var raw: [UInt8] = []
        raw.appendBE32(s)
        raw.appendBE32(responseTo)
        raw.appendBE16(code.rawValue)
        raw.appendBE16(UInt16(data.count))
        raw += data
        raw.appendBE16(TuyaCrypto.crc16(raw))
        while raw.count % 16 != 0 { raw.append(0) }

        let iv = TuyaCrypto.randomBytes(16)
        guard let enc = TuyaCrypto.aesCBC(encrypt: true, key: key, iv: iv, data: raw) else {
            throw TuyaError.format("AES encrypt")
        }
        let full: [UInt8] = [flag] + iv + enc

        var packets: [[UInt8]] = []
        var pos = 0
        var num = 0
        while pos < full.count {
            var p = TuyaCrypto.varint(num)
            if num == 0 {
                p += TuyaCrypto.varint(full.count)
                p.append(protocolVersion << 4)
            }
            let take = min(Self.mtu - p.count, full.count - pos)
            p += full[pos..<(pos + take)]
            packets.append(p)
            pos += take
            num += 1
        }
        return (s, packets)
    }

    /// Feeds one received notification. Returns a message once all fragments have arrived.
    func feed(_ chunk: [UInt8]) throws -> TuyaMessage? {
        let first = try TuyaCrypto.unvarint(chunk, 0)
        let num = first.value
        var pos = first.next

        if num < expectedPacket { clearInput() }
        guard num == expectedPacket else {
            let e = expectedPacket
            clearInput()
            throw TuyaError.missingPacket(expected: e, got: num)
        }
        if num == 0 {
            inBuf = []
            let len = try TuyaCrypto.unvarint(chunk, pos)
            expectedLen = len.value
            pos = len.next + 1 // skip protocol version byte
        }
        if pos < chunk.count { inBuf += chunk[pos...] }
        expectedPacket += 1

        if inBuf.count > expectedLen {
            clearInput()
            throw TuyaError.length
        }
        guard inBuf.count == expectedLen else { return nil }
        let buf = inBuf
        clearInput()
        return try decode(buf)
    }

    private func decode(_ buf: [UInt8]) throws -> TuyaMessage {
        guard buf.count >= 17 + 16 else { throw TuyaError.length }
        let flag = buf[0]
        let key: [UInt8]?
        switch flag {
        case 1: key = authKey
        case 4: key = loginKey
        case 5: key = sessionKey
        default: key = nil
        }
        guard let k = key else { throw TuyaError.noKey(flag) }

        let iv = Array(buf[1..<17])
        let enc = Array(buf[17...])
        guard enc.count % 16 == 0,
              let raw = TuyaCrypto.aesCBC(encrypt: false, key: k, iv: iv, data: enc),
              raw.count >= 12 else { throw TuyaError.format("AES decrypt") }

        let s = raw.be32(0)
        let r = raw.be32(4)
        let c = raw.be16(8)
        let len = Int(raw.be16(10))
        let end = 12 + len
        guard raw.count >= end else { throw TuyaError.length }
        if raw.count >= end + 2 {
            let crc = TuyaCrypto.crc16(Array(raw[0..<end]))
            guard crc == raw.be16(end) else { throw TuyaError.crc }
        }
        return TuyaMessage(seq: s, responseTo: r, code: c, data: Array(raw[12..<end]))
    }

    /// Processes the DEVICE_INFO response and derives the session key.
    func applyDeviceInfo(_ data: [UInt8]) throws {
        guard data.count >= 46 else { throw TuyaError.length }
        protocolVersion = data[2]
        let srand = Array(data[6..<12])
        sessionKey = TuyaCrypto.md5(localKey6 + srand)
        authKey = Array(data[14..<46])
    }

    func pairingRequest(uuid: String, deviceId: String) -> [UInt8] {
        var r: [UInt8] = Array(uuid.utf8) + localKey6 + Array(deviceId.utf8)
        while r.count < 44 { r.append(0) }
        return r
    }

    static func encodeDPs(_ dps: [TuyaDP]) -> [UInt8] {
        var out: [UInt8] = []
        for dp in dps {
            out += [dp.id, dp.type, UInt8(dp.value.count)]
            out += dp.value
        }
        return out
    }

    static func parseDPs(_ data: [UInt8], from start: Int) -> [TuyaDP] {
        var result: [TuyaDP] = []
        var pos = start
        while data.count - pos >= 4 {
            let id = data[pos]
            let type = data[pos + 1]
            let len = Int(data[pos + 2])
            pos += 3
            guard pos + len <= data.count else { break }
            result.append(TuyaDP(id: id, type: type, value: Array(data[pos..<(pos + len)])))
            pos += len
        }
        return result
    }
}
