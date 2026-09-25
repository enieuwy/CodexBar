import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
import Security

struct KeychainPartitionPreflightTests {
    /// Hex-encoded XML property list in the form securityd stores for an item's partition ACL entry.
    private static let partitionDescription =
        "3c3f786d6c2076657273696f6e3d22312e302220656e636f64696e673d225554462d38223f3e0a3c21444f43545950452070"
            + "6c697374205055424c494320222d2f2f4170706c652f2f44544420504c49535420312e302f2f454e222022687474703a2f"
            + "2f7777772e6170706c652e636f6d2f445444732f50726f70657274794c6973742d312e302e647464223e0a3c706c6973"
            + "742076657273696f6e3d22312e30223e0a3c646963743e0a093c6b65793e506172746974696f6e733c2f6b65793e0a09"
            + "3c61727261793e0a09093c737472696e673e7465616d69643a414141414141414141413c2f737472696e673e0a09093c"
            + "737472696e673e6170706c652d746f6f6c3a3c2f737472696e673e0a093c2f61727261793e0a3c2f646963743e0a3c2f"
            + "706c6973743e0a"

    @Test
    func `partition ACL descriptions decode to their partition IDs`() {
        #expect(KeychainAccessPreflight.partitionIDs(fromACLDescription: Self.partitionDescription)
            == ["teamid:AAAAAAAAAA", "apple-tool:"])
        #expect(KeychainAccessPreflight.partitionIDs(fromACLDescription: Self.partitionDescription.uppercased())
            == ["teamid:AAAAAAAAAA", "apple-tool:"])
    }

    @Test
    func `malformed partition ACL descriptions are unreadable rather than empty`() {
        let notAPropertyList = Data("Partitions".utf8).map { String(format: "%02x", $0) }.joined()
        let wrongKey = Self.partitionDescription.replacingOccurrences(
            of: "506172746974696f6e73",
            with: "506172746974696f6e58")
        for description in ["", "abc", "zz", notAPropertyList, wrongKey, "example.credentials"] {
            #expect(KeychainAccessPreflight.partitionIDs(fromACLDescription: description) == nil)
        }
    }

    @Test
    func `partition list must name the caller`() {
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            partitionIDs: ["teamid:BBBBBBBBBB", "teamid:AAAAAAAAAA"],
            callerPartitionID: "teamid:AAAAAAAAAA") == .allowed)
        // The #3798 transition: the owning CLI rewrote the partitions to its own tool identity.
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            partitionIDs: ["apple-tool:"],
            callerPartitionID: "teamid:AAAAAAAAAA") == .rejected)
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            partitionIDs: [],
            callerPartitionID: "teamid:AAAAAAAAAA") == .rejected)
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            partitionIDs: ["teamid:aaaaaaaaaa"],
            callerPartitionID: "teamid:AAAAAAAAAA") == .rejected)
    }

    @Test
    func `unreadable partitions or an unknown caller cannot prove a prompt free read`() {
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            partitionIDs: nil,
            callerPartitionID: "teamid:AAAAAAAAAA") == .indeterminate)
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            partitionIDs: ["teamid:AAAAAAAAAA"],
            callerPartitionID: nil) == .indeterminate)
    }

    @Test
    func `a trusted application still needs a matching partition`() {
        typealias Evaluation = KeychainAccessPreflight.DecryptACLEvaluation
        let cases: [(Evaluation, Evaluation, Evaluation)] = [
            (.allowed, .allowed, .allowed),
            (.allowed, .rejected, .rejected),
            (.allowed, .indeterminate, .indeterminate),
            (.indeterminate, .allowed, .indeterminate),
            (.indeterminate, .rejected, .rejected),
            (.rejected, .allowed, .rejected),
            (.rejected, .indeterminate, .rejected),
        ]
        for (applications, partitions, expected) in cases {
            #expect(KeychainAccessPreflight.combineDecryptACLEvaluations(
                applications: applications,
                partitions: partitions) == expected)
        }
    }

    @Test
    func `caller partition IDs follow the signing identity`() {
        let cdhash = Data([0x81, 0xCF, 0x1C, 0x00, 0x0A])
        #expect(KeychainAccessPreflight.partitionID(signingInformation: [
            kSecCodeInfoTeamIdentifier as String: "AAAAAAAAAA",
            kSecCodeInfoFlags as String: NSNumber(value: SecCodeSignatureFlags.runtime.rawValue),
            kSecCodeInfoUnique as String: cdhash,
        ]) == "teamid:AAAAAAAAAA")
        #expect(KeychainAccessPreflight.partitionID(signingInformation: [
            kSecCodeInfoFlags as String: NSNumber(value: SecCodeSignatureFlags.adhoc.rawValue | 0x20000),
            kSecCodeInfoUnique as String: cdhash,
        ]) == "cdhash:81cf1c000a")
        // Signed without a team and not ad hoc: securityd's identity for it is not derivable here.
        #expect(KeychainAccessPreflight.partitionID(signingInformation: [
            kSecCodeInfoFlags as String: NSNumber(value: 0),
            kSecCodeInfoUnique as String: cdhash,
        ]) == nil)
        #expect(KeychainAccessPreflight.partitionID(signingInformation: [:]) == nil)
    }
}
#endif
