import Foundation

/// Applications whose clips are never recorded, whatever markers they set.
///
/// `org.nspasteboard.ConcealedType` is the cooperative mechanism and it works —
/// but only for apps that bother. privacy.md calls the rest a "known gap"; this
/// narrows it for the category where the gap costs the most, by not trusting the
/// source to declare itself.
///
/// This is a denylist, so it is inherently incomplete. It does not help with an
/// API key copied out of a `.env` file, a token from a web dashboard, or a
/// password pasted into Slack — those still land in plaintext, and always will.
/// It closes the case where the content is *certainly* a credential and the app
/// simply failed to say so.
public enum SensitiveSources {

    public static let bundleIDs: Set<String> = [
        // 1Password
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        // Bitwarden
        "com.bitwarden.desktop",
        // Apple
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        // LastPass
        "com.lastpass.LastPass",
        "com.lastpass.lastpassmacdesktop",
        // Dashlane
        "com.dashlane.Dashlane",
        "com.dashlane.dashlanephonefinal",
        // KeePass family
        "org.keepassxc.keepassxc",
        "com.keepassx.keepassx",
        // Others
        "in.sinew.Enpass-Desktop",
        "com.nordsecurity.nordpass",
        "me.proton.pass.electron",
    ]

    public static func isSensitive(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }
}
