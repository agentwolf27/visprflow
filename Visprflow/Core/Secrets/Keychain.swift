import Foundation
import Security

/// Secrets the app may hold. Values are entered by the user in the setup window and
/// stored in the login keychain under the app's service name. They never touch disk in plain text.
enum SecretKey: String, CaseIterable, Sendable {
    case anthropicAPIKey = "anthropic-api-key"
    case groqAPIKey = "groq-api-key"
    case elevenLabsAPIKey = "elevenlabs-api-key"

    var label: String {
        switch self {
        case .anthropicAPIKey: "Anthropic API key"
        case .groqAPIKey: "Groq API key"
        case .elevenLabsAPIKey: "ElevenLabs API key"
        }
    }
}

enum Keychain {
    static let service = "com.vish.visprflow"

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    static func get(_ key: SecretKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure(status: status)
        }
    }

    static func set(_ value: String, for key: SecretKey) throws {
        let data = Data(value.utf8)
        let query = baseQuery(for: key)
        // Set accessibility on update as well, so an item written by an older build is corrected.
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Failure(status: addStatus) }
        default:
            throw Failure(status: status)
        }
    }

    static func delete(_ key: SecretKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(status: status)
        }
    }

    private static func baseQuery(for key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}
