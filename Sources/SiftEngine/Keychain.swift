import Foundation
import Security
import SiftCore

// The one place a credential lives, and the reason `ConnectionSpec` can be plain JSON on disk.
//
// Everything else Sift persists is readable text: the connections config, the `_sift_sources`
// staging catalog, `stage.duckdb` itself. So the secret half of a connection cannot be "encoded"
// into one of them — it has to be somewhere else entirely, owned by the OS, with the app holding
// no copy it could accidentally write down.
//
// **This file stores bytes and does not know what they mean.** The payload is the caller's shape:
//
//   * azure + `connectionString` — the Azure connection string as UTF-8, handed straight to
//     `createSecretSQL(_:secretValue:)` as a bound `?` parameter.
//   * s3 — the key material as JSON, keyed the way `ConnectionSpec` names it. Only the *secret*
//     half: the key id is `ConnectionSpec.accountName` and is deliberately not a secret (MEASURED,
//     spike §6c — `duckdb_secrets()` prints `key_id` in the clear and redacts `secret`).
//   * azure + `credentialChain` stores **nothing**. The whole point of the chain is that DuckDB
//     asks the Azure CLI and the environment, so Sift never holds a credential at all — an absent
//     item is the correct, expected state for that kind, which is why `get` returning `nil` is not
//     an error.
//
// One concrete type, no protocol, no injectable store, no mock. A mock keychain proves the mock
// works; `KeychainTests` does real add/read/update/delete round trips against the real Security
// framework under a test-only service name (see the seam at the bottom of this file).

/// A Keychain operation Sift could not complete.
///
/// Carries **both** halves of what the Security framework said, because they serve two different
/// readers: the numeric `OSStatus` is the only part that can be matched on — `errSecInteractionNotAllowed`
/// is a decision (the keychain is locked; ask the user to unlock it), not a nuisance — and
/// `SecCopyErrorMessageString`'s text is the only part worth showing a human. Both in one sentence,
/// per the house contract; `SiftError` is what keeps `localizedDescription` from replacing it with
/// Foundation's "The operation couldn't be completed."
public struct KeychainError: SiftError, Equatable {
    /// The verb the sentence opens with: "save", "read", "delete".
    public let action: String
    public let status: OSStatus

    public init(action: String, status: OSStatus) {
        self.action = action
        self.status = status
    }

    /// The Security framework's own words for this status, with the trailing period removed so it
    /// can sit inside a larger sentence. Apple returns `"OSStatus <n>"` for codes it has no text
    /// for, and — rarely — nothing at all, which is the only case this file has to word itself.
    public var message: String {
        guard let text = SecCopyErrorMessageString(status, nil) as String? else {
            return "the Security framework gave no reason"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }

    public var description: String {
        "could not \(action) this connection's credential in the Keychain: \(message) "
            + "(OSStatus \(status))"
    }
}

/// Add, read and remove one connection's credential. Namespaced by service, keyed by account.
public enum Keychain {
    /// The service every Sift credential is filed under — one string, so a user can find all of
    /// them in Keychain Access at once. The *account* (a connection's UUID) is what distinguishes
    /// items; a per-kind or per-connection service would scatter them for no gain.
    public static let service = "dev.sift.connections"

    // MARK: - The three operations

    /// Store `data` for `account`, adding it or replacing what is already there.
    ///
    /// `account` is the connection's `UUID.uuidString`, never its name: names are editable and
    /// duplicable ("prod" twice), and the item has to survive a rename. `label` is the human end of
    /// that trade — it is what Keychain Access shows in its Name column, so pass
    /// `"Sift — <connection name>"` and a user auditing their keychain sees which saved connection
    /// an item belongs to instead of 32 hex digits.
    public static func set(_ data: Data, account: String, label: String) throws {
        try set(data, account: account, label: label, in: service)
    }

    /// The stored bytes, or `nil` when there is no item for `account`.
    ///
    /// Absence is not an error, and this is the contract line that matters most: a
    /// `credentialChain` connection never stores one, and a user is free to delete an item from
    /// Keychain Access by hand. Both are states the Connections UI has to render, not failures.
    public static func get(account: String) throws -> Data? {
        try get(account: account, in: service)
    }

    /// Remove `account`'s item. Deleting one that is not there **succeeds**.
    ///
    /// Every caller's actual intent is "make sure this credential is gone" — deleting a connection,
    /// switching it to `credentialChain`, cleaning up a half-finished save. Making each of them
    /// swallow one specific `OSStatus` is how one of them ends up swallowing all of them.
    public static func delete(account: String) throws {
        try delete(account: account, in: service)
    }

    // MARK: - The seam the tests use

    // The same three with the service name as a parameter, `internal` rather than public on
    // purpose: tests write under `dev.sift.connections.test`, so a test run can never add,
    // overwrite or delete an item the app reads — the two namespaces do not intersect. Keeping the
    // *public* API to exactly three functions means no shipping caller can file a real credential
    // anywhere but `service`.

    static func set(_ data: Data, account: String, label: String, in service: String) throws {
        let identity = item(account: account, in: service)
        var fresh = identity
        fresh[kSecAttrLabel as String] = label
        fresh[kSecValueData as String] = data

        let added = SecItemAdd(fresh as CFDictionary, nil)
        if added == errSecSuccess { return }
        // 🔴 The update branch is not a nicety, it is half the method. A generic password is keyed
        // on (service, account), so the SECOND save for a connection — every credential rotation,
        // every typo correction — is `errSecDuplicateItem`. An add-only `set` would refuse all of
        // them while the first save still looked like it worked, and the app would go on opening
        // that connection with the old, wrong secret.
        guard added == errSecDuplicateItem else {
            throw KeychainError(action: "save", status: added)
        }
        let changes: [String: Any] = [
            kSecAttrLabel as String: label,
            kSecValueData as String: data,
        ]
        let updated = SecItemUpdate(identity as CFDictionary, changes as CFDictionary)
        guard updated == errSecSuccess else {
            throw KeychainError(action: "save", status: updated)
        }
    }

    static func get(account: String, in service: String) throws -> Data? {
        var query = item(account: account, in: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(action: "read", status: status) }
        // `nil` already means "nothing saved", so an item that comes back as something other than
        // bytes has to throw rather than borrow that answer: "no credential saved" sends the user
        // to the Connections sheet to type one, "the credential is unreadable" does not.
        guard let data = found as? Data else {
            throw KeychainError(action: "read", status: errSecDecode)
        }
        return data
    }

    static func delete(account: String, in service: String) throws {
        let status = SecItemDelete(item(account: account, in: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(action: "delete", status: status)
        }
    }

    /// The (class, service, account) triple that identifies one item — the primary key of a generic
    /// password, and therefore both the query that reads one and the base of the attributes that
    /// write one.
    ///
    /// No `kSecAttrAccessible`: on macOS's file-based keychain it is ignored unless the item opts
    /// into the data-protection keychain, so spelling it here would look like a decision while
    /// changing nothing. Default accessibility — readable while the user's keychain is unlocked —
    /// is what a desktop app that opens a connection on the user's behalf actually wants.
    private static func item(account: String, in service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
