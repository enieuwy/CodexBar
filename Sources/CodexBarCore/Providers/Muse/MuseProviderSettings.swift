import Foundation

public struct MuseProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum MuseProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.muse
    public typealias Section = MuseProviderSettings
}

extension ProviderSettingsSnapshot {
    public static func make(muse: MuseProviderSettings?) -> Self {
        self.make(muse, for: MuseProviderSettingsKey.self)
    }
}
