// Run against a running signed AppleCam process under a sandbox denying reads
// of its app bundle. This exercises OS signing state; it cannot be a unit test.
// xcrun swiftc Tests/Integration/producer-dynamic-signature.swift -o work/producer-signature-test
// sandbox-exec -p '(version 1)(allow default)(deny file-read* (subpath "/Applications/AppleCam.app"))' work/producer-signature-test PID
import Foundation
import Security

func check(_ condition: Bool, _ message: String) {
    guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    fatalError("Provide the running, signed AppleCam host PID")
}
var diskCode: SecCode?
let diskStatus = SecCodeCopyGuestWithAttributes(nil,
    [kSecGuestAttributePid: pid] as CFDictionary, [], &diskCode)
check(diskStatus != errSecSuccess, "sandbox must reproduce the ordinary code-lookup failure")
var code: SecCode?
let status = SecCodeCopyGuestWithAttributes(nil,
    [kSecGuestAttributePid: pid, kSecGuestAttributeDynamicCode: true] as CFDictionary, [], &code)
check(status == errSecSuccess && code != nil, "dynamic lookup failed: \(status)")
func accepts(identifier: String, team: String) -> Bool {
    var requirement: SecRequirement?
    let rule = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    let result = SecRequirementCreateWithString(rule as CFString, [], &requirement)
    check(result == errSecSuccess && requirement != nil, "invalid test requirement")
    return SecCodeCheckValidity(code!, [], requirement) == errSecSuccess
}
check(accepts(identifier: "com.vanguardsignals.AppleCam", team: "M8QBZK948M"), "signed host rejected")
check(!accepts(identifier: "com.vanguardsignals.NotAppleCam", team: "M8QBZK948M"), "wrong identifier accepted")
check(!accepts(identifier: "com.vanguardsignals.AppleCam", team: "ZZZZZZZZZZ"), "wrong team accepted")
print("PASS: sandbox failure reproduced; dynamic signing accepts the host and rejects incorrect identifier/team.")
