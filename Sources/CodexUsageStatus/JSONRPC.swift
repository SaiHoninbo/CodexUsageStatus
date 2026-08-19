import Foundation

struct JSONRPCMessage {
    let object: [String: Any]

    var id: Int? {
        if let value = object["id"] as? Int { return value }
        if let value = object["id"] as? NSNumber { return value.intValue }
        return nil
    }

    var method: String? { object["method"] as? String }

    var result: Any? { object["result"] }

    var errorMessage: String? {
        guard let error = object["error"] as? [String: Any] else { return nil }
        if let message = error["message"] as? String { return message }
        return "JSON-RPC error"
    }
}

enum JSONRPCCodec {
    static func encodeRequest(id: Int, method: String, params: Any? = nil) throws -> Data {
        var object: [String: Any] = [
            "id": id,
            "method": method
        ]
        if let params { object["params"] = params }
        return try JSONSerialization.data(withJSONObject: object, options: []) + Data([0x0A])
    }

    static func encodeNotification(method: String, params: Any? = nil) throws -> Data {
        var object: [String: Any] = [
            "method": method
        ]
        if let params { object["params"] = params }
        return try JSONSerialization.data(withJSONObject: object, options: []) + Data([0x0A])
    }

    static func decodeLine(_ data: Data) throws -> JSONRPCMessage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "CodexUsageStatus.JSONRPC", code: 1, userInfo: [NSLocalizedDescriptionKey: "JSON-RPC message is not an object"])
        }
        return JSONRPCMessage(object: object)
    }
}

final class JSONLineBuffer {
    private var data = Data()

    func append(_ incoming: Data) -> [Data] {
        data.append(incoming)
        var lines: [Data] = []
        while let newlineIndex = data.firstIndex(of: 0x0A) {
            let line = data[..<newlineIndex]
            data.removeSubrange(...newlineIndex)
            if !line.isEmpty {
                lines.append(Data(line))
            }
        }
        return lines
    }
}
