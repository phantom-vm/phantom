import Foundation

// MARK: - API Request/Response

struct APIRequest: Codable {
    let method: String
    let params: [String: AnyCodable]?
}

struct APIResponse: Codable {
    let result: AnyCodable?
    let error: APIError?

    init(result: AnyCodable?, error: APIError? = nil) {
        self.result = result
        self.error = error
    }
}

struct APIError: Codable {
    let code: String
    let message: String
}

// MARK: - Response Models

struct IPSWInfo: Codable {
    let id: String
    let path: String
    let size: Int
}

struct VMInfo: Codable {
    let id: String
    let path: String
    let state: String
}

// MARK: - AnyCodable

struct AnyCodable: Codable {
    let value: Any

    init<T>(_ value: T) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let int64 as Int64:
            try container.encode(int64)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
