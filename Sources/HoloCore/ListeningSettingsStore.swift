import Foundation

/// Machine-level preferences that survive relaunch. Kept out of `HoloProfile`
/// so the profile schema (and its version gate) is untouched by spec 01.
///
/// Both files are versioned the same way profiles are: a version that is not
/// the current one is treated as absent and replaced by defaults, never
/// decoded on a best-effort basis.
public final class ListeningSettingsStore {
    private struct VersionEnvelope: Decodable {
        var version: Int
    }

    public let fileURL: URL

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) throws {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = try Self.defaultDirectory(fileManager: fileManager)
                .appendingPathComponent("listening-settings.json")
        }
    }

    public func load() throws -> ListeningTierSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ListeningTierSettings()
        }
        let data = try Data(contentsOf: fileURL)
        let envelope = try JSONDecoder().decode(VersionEnvelope.self, from: data)
        guard envelope.version == ListeningTierSettings.currentVersion else {
            return ListeningTierSettings()
        }
        return try JSONDecoder().decode(ListeningTierSettings.self, from: data).sanitized()
    }

    public func save(_ settings: ListeningTierSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings.sanitized()).write(to: fileURL, options: .atomic)
    }

    static func defaultDirectory(fileManager: FileManager) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("Holo", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

public final class PrivilegedActionConsentStore {
    private struct VersionEnvelope: Decodable {
        var version: Int
    }

    public let fileURL: URL

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) throws {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = try ListeningSettingsStore.defaultDirectory(fileManager: fileManager)
                .appendingPathComponent("privileged-action-consent.json")
        }
    }

    public func load() throws -> PrivilegedActionConsent {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PrivilegedActionConsent()
        }
        let data = try Data(contentsOf: fileURL)
        let envelope = try JSONDecoder().decode(VersionEnvelope.self, from: data)
        guard envelope.version == PrivilegedActionConsent.currentVersion else {
            // A consent record we cannot read must not be assumed to grant
            // anything. Starting empty costs the user one confirmation.
            return PrivilegedActionConsent()
        }
        return try JSONDecoder().decode(PrivilegedActionConsent.self, from: data)
    }

    public func save(_ consent: PrivilegedActionConsent) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(consent).write(to: fileURL, options: .atomic)
    }
}
