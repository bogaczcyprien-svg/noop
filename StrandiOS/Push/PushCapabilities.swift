import Foundation

/// A receiver may only narrow the fixed protocol 1.0 registry, never name new data.
public struct PushCapabilities: Sendable {
    public let appendTables: Set<PushAppendTable>
    public let mutableTables: Set<PushMutableTable>
    public let protocolVersion: String
    public let receiverStateId: String

    public static let unscopedReceiverStateId = "00000000-0000-4000-8000-000000000000"
    public static let all = PushCapabilities(
        appendTables: Set(PushAppendTable.allCases),
        mutableTables: Set(PushMutableTable.allCases),
        protocolVersion: PushProtocol.version,
        receiverStateId: unscopedReceiverStateId
    )

    public init(appendTables: Set<PushAppendTable>, mutableTables: Set<PushMutableTable>, protocolVersion: String, receiverStateId: String) {
        self.appendTables = appendTables
        self.mutableTables = mutableTables
        self.protocolVersion = protocolVersion
        self.receiverStateId = receiverStateId
    }

    public var isEmpty: Bool { appendTables.isEmpty && mutableTables.isEmpty }

    public static func parse(_ data: Data) throws -> PushCapabilities {
        guard data.count <= PushProtocol.maxAckBytes else { throw PushProtocolError.invalid("capabilities exceed size limit") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PushProtocolError.invalid("capabilities are not valid JSON")
        }
        let required: Set<String> = ["type", "protocolVersion", "receiverStateId", "streams"]
        guard required.isSubset(of: Set(obj.keys)) else {
            throw PushProtocolError.invalid("capabilities are missing required protocol 1.0 members")
        }
        if !Set(obj.keys).isDisjoint(with: PushProtocol.forbiddenRemoteControlMembers) {
            throw PushProtocolError.invalid("capabilities contain forbidden remote-control metadata")
        }
        guard obj["type"] as? String == "capabilities", obj["protocolVersion"] as? String == PushProtocol.version else {
            throw PushProtocolError.invalid("unsupported capability document")
        }
        guard let receiverStateId = obj["receiverStateId"] as? String, isCanonicalUuid(receiverStateId) else {
            throw PushProtocolError.invalid("capabilities.receiverStateId must be a canonical UUID")
        }
        guard let streams = obj["streams"] as? [String] else {
            throw PushProtocolError.invalid("capabilities.streams must be an array")
        }
        var seen = Set<String>()
        var append = Set<PushAppendTable>()
        var mutable = Set<PushMutableTable>()
        for name in streams {
            guard seen.insert(name).inserted else { throw PushProtocolError.invalid("duplicate capability stream") }
            if let t = PushAppendTable(rawValue: name) {
                append.insert(t)
            } else if let t = PushMutableTable(rawValue: name) {
                mutable.insert(t)
            } else {
                throw PushProtocolError.invalid("unknown capability stream")
            }
        }
        return PushCapabilities(appendTables: append, mutableTables: mutable, protocolVersion: PushProtocol.version, receiverStateId: receiverStateId)
    }

    private static func isCanonicalUuid(_ value: String) -> Bool {
        guard let u = UUID(uuidString: value) else { return false }
        return u.uuidString.lowercased() == value
    }
}

public enum PushCapabilitiesResult: Sendable {
    case available(PushCapabilities)
    case rejected(reason: String, retryable: Bool, failure: PushFailure?)
}
