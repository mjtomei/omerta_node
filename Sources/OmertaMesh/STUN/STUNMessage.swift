// STUNMessage.swift - STUN protocol message encoding/decoding (RFC 5389)

import Foundation

/// STUN message types (RFC 5389)
public enum STUNMessageType: UInt16, Sendable {
    // Requests
    case bindingRequest = 0x0001

    // Success responses
    case bindingResponse = 0x0101

    // Error responses
    case bindingErrorResponse = 0x0111

    // Indications
    case bindingIndication = 0x0011
}

/// STUN attribute types (RFC 5389)
public enum STUNAttributeType: UInt16, Sendable {
    case mappedAddress = 0x0001
    case responseAddress = 0x0002  // Deprecated
    case changeRequest = 0x0003    // RFC 5780
    case sourceAddress = 0x0004    // Deprecated
    case changedAddress = 0x0005   // Deprecated
    case username = 0x0006
    case password = 0x0007         // Deprecated
    case messageIntegrity = 0x0008
    case errorCode = 0x0009
    case unknownAttributes = 0x000A
    case reflectedFrom = 0x000B    // Deprecated
    case realm = 0x0014
    case nonce = 0x0015
    case xorMappedAddress = 0x0020
    case software = 0x8022
    case alternateServer = 0x8023
    case fingerprint = 0x8028

    // RFC 5780 extensions
    case otherAddress = 0x802C
    case responseOrigin = 0x802B
}

/// STUN magic cookie (RFC 5389)
public let stunMagicCookie: UInt32 = 0x2112A442

/// A STUN protocol message
public struct STUNMessage: Sendable {
    /// Message type
    public let type: STUNMessageType

    /// Transaction ID (12 bytes)
    public let transactionId: Data

    /// Message attributes
    public var attributes: [STUNAttribute]

    /// Create a new STUN message
    public init(type: STUNMessageType, transactionId: Data? = nil, attributes: [STUNAttribute] = []) {
        self.type = type
        self.transactionId = transactionId ?? Self.generateTransactionId()
        self.attributes = attributes
    }

    /// Generate a random 12-byte transaction ID
    public static func generateTransactionId() -> Data {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in 0..<12 {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return Data(bytes)
    }

    /// Create a binding request
    public static func bindingRequest(changeIP: Bool = false, changePort: Bool = false) -> STUNMessage {
        var message = STUNMessage(type: .bindingRequest)

        if changeIP || changePort {
            var flags: UInt32 = 0
            if changeIP { flags |= 0x04 }
            if changePort { flags |= 0x02 }
            message.attributes.append(.changeRequest(changeIP: changeIP, changePort: changePort))
        }

        return message
    }

    /// Encode to wire format
    public func encode() -> Data {
        var data = Data()

        // Message type (2 bytes)
        data.append(UInt8(type.rawValue >> 8))
        data.append(UInt8(type.rawValue & 0xFF))

        // Message length (2 bytes) - calculated after attributes
        let attributeData = encodeAttributes()
        let length = UInt16(attributeData.count)
        data.append(UInt8(length >> 8))
        data.append(UInt8(length & 0xFF))

        // Magic cookie (4 bytes)
        data.append(contentsOf: withUnsafeBytes(of: stunMagicCookie.bigEndian) { Array($0) })

        // Transaction ID (12 bytes)
        data.append(transactionId)

        // Attributes
        data.append(attributeData)

        return data
    }

    private func encodeAttributes() -> Data {
        var data = Data()
        for attr in attributes {
            data.append(attr.encode())
        }
        return data
    }

    /// Decode from wire format
    public static func decode(from data: Data) throws -> STUNMessage {
        guard data.count >= 20 else {
            throw STUNError.messageTooShort
        }

        // Parse message type
        let typeRaw = UInt16(data[0]) << 8 | UInt16(data[1])
        guard let type = STUNMessageType(rawValue: typeRaw) else {
            throw STUNError.unknownMessageType(typeRaw)
        }

        // Parse message length
        let length = Int(UInt16(data[2]) << 8 | UInt16(data[3]))
        guard data.count >= 20 + length else {
            throw STUNError.messageTruncated
        }

        // Verify magic cookie
        let cookie = UInt32(data[4]) << 24 | UInt32(data[5]) << 16 |
                     UInt32(data[6]) << 8 | UInt32(data[7])
        guard cookie == stunMagicCookie else {
            throw STUNError.invalidMagicCookie
        }

        // Extract transaction ID
        let transactionId = Data(data[8..<20])

        // Parse attributes
        var attributes: [STUNAttribute] = []
        var offset = 20
        while offset + 4 <= 20 + length {
            let attrType = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            let attrLength = Int(UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3]))

            guard offset + 4 + attrLength <= data.count else {
                break
            }

            let attrData = Data(data[(offset + 4)..<(offset + 4 + attrLength)])
            if let attr = STUNAttribute.decode(type: attrType, data: attrData, transactionId: transactionId) {
                attributes.append(attr)
            }

            // Align to 4-byte boundary
            offset += 4 + ((attrLength + 3) & ~3)
        }

        return STUNMessage(type: type, transactionId: transactionId, attributes: attributes)
    }

    /// Get XOR-MAPPED-ADDRESS from response
    public var xorMappedAddress: (host: String, port: UInt16)? {
        for attr in attributes {
            if case .xorMappedAddress(let host, let port) = attr {
                return (host, port)
            }
        }
        return nil
    }

    /// Get MAPPED-ADDRESS from response (legacy)
    public var mappedAddress: (host: String, port: UInt16)? {
        for attr in attributes {
            if case .mappedAddress(let host, let port) = attr {
                return (host, port)
            }
        }
        return nil
    }

    /// Get OTHER-ADDRESS from response (RFC 5780)
    public var otherAddress: (host: String, port: UInt16)? {
        for attr in attributes {
            if case .otherAddress(let host, let port) = attr {
                return (host, port)
            }
        }
        return nil
    }
}

/// STUN attribute
public enum STUNAttribute: Sendable {
    case mappedAddress(host: String, port: UInt16)
    case xorMappedAddress(host: String, port: UInt16)
    case changeRequest(changeIP: Bool, changePort: Bool)
    case otherAddress(host: String, port: UInt16)
    case responseOrigin(host: String, port: UInt16)
    case errorCode(code: Int, reason: String)
    case software(String)
    case unknown(type: UInt16, data: Data)

    /// Encode attribute to wire format
    func encode() -> Data {
        var data = Data()

        switch self {
        case .changeRequest(let changeIP, let changePort):
            // Type
            data.append(contentsOf: [0x00, 0x03])
            // Length (4 bytes)
            data.append(contentsOf: [0x00, 0x04])
            // Value
            var flags: UInt32 = 0
            if changeIP { flags |= 0x04 }
            if changePort { flags |= 0x02 }
            data.append(contentsOf: withUnsafeBytes(of: flags.bigEndian) { Array($0) })

        default:
            // Only CHANGE-REQUEST needs to be encoded for our use case
            break
        }

        return data
    }

    /// Decode attribute from wire format
    static func decode(type: UInt16, data: Data, transactionId: Data) -> STUNAttribute? {
        guard let attrType = STUNAttributeType(rawValue: type) else {
            return .unknown(type: type, data: data)
        }

        switch attrType {
        case .mappedAddress:
            guard let (host, port) = decodeAddress(data: data, xor: false, transactionId: transactionId) else {
                return nil
            }
            return .mappedAddress(host: host, port: port)

        case .xorMappedAddress:
            guard let (host, port) = decodeAddress(data: data, xor: true, transactionId: transactionId) else {
                return nil
            }
            return .xorMappedAddress(host: host, port: port)

        case .otherAddress:
            guard let (host, port) = decodeAddress(data: data, xor: false, transactionId: transactionId) else {
                return nil
            }
            return .otherAddress(host: host, port: port)

        case .responseOrigin:
            guard let (host, port) = decodeAddress(data: data, xor: false, transactionId: transactionId) else {
                return nil
            }
            return .responseOrigin(host: host, port: port)

        case .errorCode:
            guard data.count >= 4 else { return nil }
            let classValue = Int(data[2]) & 0x07
            let number = Int(data[3])
            let code = classValue * 100 + number
            let reason = data.count > 4 ? String(data: Data(data[4...]), encoding: .utf8) ?? "" : ""
            return .errorCode(code: code, reason: reason)

        case .software:
            return .software(String(data: data, encoding: .utf8) ?? "")

        default:
            return .unknown(type: type, data: data)
        }
    }

    /// Decode an address attribute (MAPPED-ADDRESS or XOR-MAPPED-ADDRESS)
    private static func decodeAddress(data: Data, xor: Bool, transactionId: Data) -> (host: String, port: UInt16)? {
        guard data.count >= 8 else { return nil }

        let family = data[1]
        guard family == 0x01 else { return nil }  // IPv4 only for now

        var port = UInt16(data[2]) << 8 | UInt16(data[3])
        var addr = UInt32(data[4]) << 24 | UInt32(data[5]) << 16 |
                   UInt32(data[6]) << 8 | UInt32(data[7])

        if xor {
            port ^= UInt16(stunMagicCookie >> 16)
            addr ^= stunMagicCookie
        }

        let host = "\(addr >> 24).\((addr >> 16) & 0xFF).\((addr >> 8) & 0xFF).\(addr & 0xFF)"
        return (host, port)
    }
}

/// STUN-specific errors
public enum STUNError: Error, CustomStringConvertible {
    case messageTooShort
    case messageTruncated
    case unknownMessageType(UInt16)
    case invalidMagicCookie
    case bindFailed
    case invalidServerAddress(String)
    case timeout
    case noResponse
    case invalidResponse
    case transactionIdMismatch
    case noMappedAddress
    case insufficientServers
    case serverError(Int, String)

    public var description: String {
        switch self {
        case .messageTooShort:
            return "STUN message too short"
        case .messageTruncated:
            return "STUN message truncated"
        case .unknownMessageType(let type):
            return "Unknown STUN message type: 0x\(String(type, radix: 16))"
        case .invalidMagicCookie:
            return "Invalid STUN magic cookie"
        case .bindFailed:
            return "Failed to bind UDP socket"
        case .invalidServerAddress(let addr):
            return "Invalid server address: \(addr)"
        case .timeout:
            return "STUN request timed out"
        case .noResponse:
            return "No response received"
        case .invalidResponse:
            return "Invalid STUN response"
        case .transactionIdMismatch:
            return "Transaction ID mismatch"
        case .noMappedAddress:
            return "No mapped address in response"
        case .insufficientServers:
            return "Need at least 2 STUN servers for NAT detection"
        case .serverError(let code, let reason):
            return "STUN server error \(code): \(reason)"
        }
    }
}
