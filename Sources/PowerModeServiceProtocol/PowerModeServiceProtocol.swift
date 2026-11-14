import Foundation
import Security

@objc public protocol PowerModeServiceProtocol {
    func ping(reply: @escaping (Bool) -> Void)
    func setPowerMode(_ mode: Int, onAC: Bool, reply: @escaping (Bool) -> Void)
}

public enum PowerModeServiceIdentity {
    public static let app = "com.willhsu.ring-a-bar"
    public static let helper = "com.willhsu.ring-a-bar.PowerMode"
    public static let plist = helper + ".plist"

    public static func requirement(for peer: String, requiringSelf own: String) -> String? {
        var running: SecCode?
        var executable: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &executable) == errSecSuccess, let executable,
              SecCodeCopySigningInformation(executable, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let signing = information as? [String: Any],
              signing[kSecCodeInfoIdentifier as String] as? String == own,
              let team = signing[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        return "anchor apple generic and identifier \"\(peer)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}
