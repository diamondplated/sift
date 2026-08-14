import Foundation
import Security
import Testing
@testable import SiftEngine

// Real round trips against the real Security framework — add, read, update, read, delete, read-nil
// — because the only interesting question about this code is whether the OS agrees with it, and a
// mocked `SecItem*` cannot be wrong about that in either direction.
//
// **Everything here writes under `dev.sift.connections.test`.** The app reads
// `dev.sift.connections`. The two namespaces do not intersect, so no test run can add, overwrite or
// delete a credential a user actually saved — the reason `Keychain`'s internal seam takes a service
// name at all. Every item is cleaned up in a `defer`, and every account is a fresh `UUID`, so a
// crashed run strands at most one item and parallel tests cannot collide. Nothing here is
// `.serialized`.
//
// **The honest skip.** A locked or headless login keychain answers `errSecInteractionNotAllowed`
// (-25308) or `errSecNotAvailable` (-25291) to every call, and that is an environment fact, not a
// defect. One probe runs a real save-and-delete before the suite; if it comes back with one of
// those two, the round-trip tests report as *skipped with the OSStatus in the message* rather than
// failing — and rather than being replaced by a stub that would pass on a machine where the real
// thing cannot work. Any OTHER failure leaves the tests enabled, so a genuine defect still goes red
// with its own sentence.

/// Where every test in this file writes. Derived from `Keychain.service` so it moves with it, and
/// pinned below to be different from it.
private let testService = Keychain.service + ".test"

private struct KeychainAvailability: Sendable {
    let usable: Bool
    let note: Comment
}

/// One real save-and-delete, run once per test process, answering the only question a mock could
/// not: does *this* machine's keychain accept these calls at all?
private let keychain: KeychainAvailability = {
    let account = "availability-probe-" + UUID().uuidString
    defer { try? Keychain.delete(account: account, in: testService) }
    do {
        try Keychain.set(
            Data("probe".utf8), account: account, label: "Sift — availability probe",
            in: testService
        )
        return KeychainAvailability(usable: true, note: "")
    } catch let error as KeychainError
        where error.status == errSecInteractionNotAllowed || error.status == errSecNotAvailable {
        return KeychainAvailability(
            usable: false,
            note: Comment(
                rawValue: "this machine's Keychain will not hold an item — OSStatus "
                    + "\(error.status): \(error.message)"
            )
        )
    } catch {
        // Not one of the two environment statuses, so it is a real defect: leave every test
        // enabled and let it fail with its own message rather than hiding behind a skip.
        return KeychainAvailability(usable: true, note: "")
    }
}()

private let requiresKeychain = ConditionTrait.enabled(if: keychain.usable, keychain.note)

// MARK: - The round trip

@Test(requiresKeychain)
func aCredentialSurvivesAddReadUpdateReadAndDelete() throws {
    let account = UUID().uuidString
    defer { try? Keychain.delete(account: account, in: testService) }

    #expect(try Keychain.get(account: account, in: testService) == nil,
            "an account that was never saved must read as absent, not as empty bytes")

    // The shape a real azure `connectionString` connection stores: the string, UTF-8.
    let first = Data("DefaultEndpointsProtocol=https;AccountName=acct;AccountKey=one".utf8)
    try Keychain.set(first, account: account, label: "Sift — round trip", in: testService)
    #expect(try Keychain.get(account: account, in: testService) == first)

    let second = Data("DefaultEndpointsProtocol=https;AccountName=acct;AccountKey=two".utf8)
    try Keychain.set(second, account: account, label: "Sift — round trip", in: testService)
    // 🔴 The credential-rotation case. `SecItemAdd` alone answers `errSecDuplicateItem` here, so an
    // add-only `set` fails this line — and in the app it would leave DuckDB authenticating with a
    // key the user had already replaced.
    #expect(try Keychain.get(account: account, in: testService) == second,
            "the second save must replace the first, not be refused or stored beside it")

    try Keychain.delete(account: account, in: testService)
    #expect(try Keychain.get(account: account, in: testService) == nil,
            "a deleted credential must read as absent")
}

@Test(requiresKeychain)
func twoConnectionsDoNotShareOneItem() throws {
    let alpha = UUID().uuidString
    let beta = UUID().uuidString
    defer {
        try? Keychain.delete(account: alpha, in: testService)
        try? Keychain.delete(account: beta, in: testService)
    }

    try Keychain.set(Data("alpha".utf8), account: alpha, label: "Sift — alpha", in: testService)
    try Keychain.set(Data("beta".utf8), account: beta, label: "Sift — beta", in: testService)
    #expect(try Keychain.get(account: alpha, in: testService) == Data("alpha".utf8))
    #expect(try Keychain.get(account: beta, in: testService) == Data("beta".utf8))

    try Keychain.delete(account: alpha, in: testService)
    #expect(try Keychain.get(account: alpha, in: testService) == nil)
    #expect(try Keychain.get(account: beta, in: testService) == Data("beta".utf8),
            "deleting one connection's credential must not touch another's")
}

@Test(requiresKeychain)
func deletingACredentialThatIsNotThereSucceeds() throws {
    // No `#expect`: a throw from a `throws` test is already a failure, and this test's entire
    // assertion is that the next line does not throw. Drop `errSecItemNotFound` from `delete`'s
    // guard and it does.
    try Keychain.delete(account: UUID().uuidString, in: testService)
}

// MARK: - What Keychain Access shows

/// The item's `kSecAttrLabel`, read straight from the Security framework rather than through
/// `Keychain` — an oracle the code under test cannot satisfy by agreeing with itself.
private func storedLabel(_ account: String) throws -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: testService,
        kSecAttrAccount as String: account,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var found: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &found)
    guard status == errSecSuccess else {
        throw KeychainError(action: "read the attributes of", status: status)
    }
    return (found as? [String: Any])?[kSecAttrLabel as String] as? String
}

@Test(requiresKeychain)
func theLabelReachesTheItemAndFollowsARename() throws {
    let account = UUID().uuidString
    defer { try? Keychain.delete(account: account, in: testService) }

    try Keychain.set(Data("x".utf8), account: account, label: "Sift — prod warehouse",
                     in: testService)
    #expect(try storedLabel(account) == "Sift — prod warehouse",
            "the label is the only thing making a UUID-keyed item legible in Keychain Access")

    try Keychain.set(Data("y".utf8), account: account, label: "Sift — archive warehouse",
                     in: testService)
    #expect(try storedLabel(account) == "Sift — archive warehouse",
            "renaming a connection must rename its keychain item, not leave the old name behind")
}

// MARK: - The error sentence, and the namespace

// No keychain needed for either of these: they are about what this module says, not what the OS
// does, so they run everywhere including a machine where the round trips skip.

@Test func aKeychainFailureCarriesBothTheOSStatusAndSecuritysOwnWords() {
    let error = KeychainError(action: "save", status: errSecInteractionNotAllowed)

    #expect(error.status == errSecInteractionNotAllowed)
    // The number, so a caller reading a bug report can match on the same thing code matches on.
    #expect(error.description.contains("-25308"))
    // And the human half. This is the mutation guard: drop the `SecCopyErrorMessageString` call
    // and hand back the number alone, or a hardcoded "keychain error", and this line goes red.
    #expect(error.message.lowercased().contains("interaction"),
            "expected the Security framework's own text, got: \(error.message)")
    #expect(error.description.contains(error.message))
    #expect(!error.message.hasSuffix("."), "the framework's trailing period must be trimmed")

    // One sentence on BOTH string paths — `SiftError`'s whole reason for existing.
    #expect(error.localizedDescription == error.description)
    #expect((error as NSError).localizedDescription == error.description)
    #expect(!error.description.contains("The operation couldn"),
            "a Foundation dump replaced the sentence")
}

@Test func anUnknownStatusStillProducesASentence() {
    // Apple has no text for most numbers and answers `"OSStatus <n>"`; the sentence must survive
    // that, and must never come out with an empty middle.
    let error = KeychainError(action: "read", status: -999_999)
    #expect(!error.message.isEmpty)
    #expect(error.description.contains("-999999"))
    #expect(!error.description.contains(": (OSStatus"), "the message half went missing")
}

@Test func testsNeverWriteWhereTheAppReads() {
    #expect(Keychain.service == "dev.sift.connections")
    #expect(testService == "dev.sift.connections.test")
    #expect(testService != Keychain.service,
            "point the tests at the app's own service and every run edits real credentials")
}
