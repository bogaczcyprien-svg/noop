import Foundation
import WhoopProtocol

/// "Check for updates": one call to this FORK's own `altstore-source.json` (the same manifest
/// SideStore itself reads to decide whether an update exists), reading the latest BUILD number and
/// comparing it to the installed one. Nothing about the user is sent.
///
/// Fork addition, replacing the upstream `ryanbr/noop` GitHub Releases endpoint entirely: this is a
/// personal fork the user follows instead of upstream, upstream's own releases are not relevant to
/// them, and — the real bug a Releases-API read would have had here — this fork's MARKETING version
/// (project.yml's `MARKETING_VERSION`, e.g. "12.0.0") stays THE SAME across several fork builds
/// (fork1, fork2, …), so comparing marketing versions would never notice fork2 was available while
/// fork1 was installed; they'd both read "12.0.0". `altstore-source.json`'s `buildVersion` is the
/// one number that actually increments every release, which is why it — not the Releases API's
/// `tag_name` — is what both SideStore and this checker key off of. Reading the SAME file SideStore
/// reads is also what keeps the two from ever disagreeing about what "latest" means (the project's
/// own "two readouts of one fact must not disagree" rule).
///
/// TWO callers share this, and the distinction matters to anyone auditing what the app does on its own:
///  - the Settings button, which runs only when tapped;
///  - `UpdateWatch`, the #1659 daily check, which runs at most once a day after onboarding and the Terms
///    gate. It is ON by default and switching it off in Settings stops the request entirely.
///
/// (Uses the network-client entitlement, which is otherwise only for the opt-in, off-by-default AI Coach.)
@MainActor
final class UpdateChecker: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case upToDate(version: String)
        case available(version: String, url: URL, ipaURL: URL?, notes: String)
        case failed
    }

    @Published var state: State = .idle

    private static let endpoint = URL(
        string: "https://raw.githubusercontent.com/bogaczcyprien-svg/noop/main/altstore-source.json")!

    /// One release read. Shared by the button and the automatic check (#1659) so there is exactly one
    /// copy of the endpoint, the headers and the parsing — a second copy is how the two would drift into
    /// disagreeing about what "latest" means.
    struct Release: Equatable {
        /// Marketing version for display ("12.0.0") — NOT what freshness is compared on; see `build`.
        let version: String
        /// `altstore-source.json`'s `buildVersion` — the one monotonically-increasing figure, compared
        /// against the installed `CFBundleVersion` via `VersionCheck.isNewer`.
        let build: String
        /// The release page, for a plain browser download (works on macOS too, and as a fallback when
        /// SideStore is not installed).
        let url: URL
        /// The `.ipa` itself, when the manifest carries one — `nil` only if the manifest is missing it,
        /// never fabricated. Feeds the one-tap `sidestore://install` action (iOS/SideStore only).
        let ipaURL: URL?
        let notes: String
    }

    static func fetchLatest() async -> Release? {
        do {
            var req = URLRequest(url: Self.endpoint, timeoutInterval: 12)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let apps = json["apps"] as? [[String: Any]], let app = apps.first,
                  let version = app["version"] as? String,
                  let buildVersion = app["buildVersion"] as? String,
                  let downloadURLString = app["downloadURL"] as? String,
                  let ipaURL = URL(string: downloadURLString)
            else { return nil }
            // The fork's own GitHub Release page for this build, for a plain browser download — the
            // tag is read off the download URL's own path (`.../releases/download/<tag>/<file>`)
            // rather than a second manifest field, so this can never name a DIFFERENT release than
            // the one just read.
            let tag = ipaURL.deletingLastPathComponent().lastPathComponent
            let releaseURL = URL(string: "https://github.com/bogaczcyprien-svg/noop/releases/tag/\(tag)")
                ?? ipaURL
            let notes = (app["versionDescription"] as? String).map(cleanNotes) ?? ""
            return Release(version: version, build: buildVersion, url: releaseURL,
                           ipaURL: ipaURL, notes: notes)
        } catch {
            return nil
        }
    }

    func check(currentBuild: String) {
        guard state != .checking else { return }
        state = .checking
        Task {
            guard let release = await Self.fetchLatest() else {
                state = .failed
                return
            }
            state = VersionCheck.isNewer(release.build, than: currentBuild)
                ? .available(version: release.version, url: release.url, ipaURL: release.ipaURL, notes: release.notes)
                : .upToDate(version: release.version)
        }
    }

    /// Turn a GitHub release body into a short, readable "what's new" for an inline preview: drop the
    /// "Downloads"/footer boilerplate, strip the heaviest markdown markers, and cap the length.
    static func cleanNotes(_ body: String) -> String {
        var s = body.components(separatedBy: "Downloads").first ?? body
        for marker in ["**", "## ", "# "] { s = s.replacingOccurrences(of: marker, with: "") }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 700 { s = String(s.prefix(700)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" }
        return s
    }
}

/// "Check for upstream updates": the ORIGINAL check this file used to do before it was redirected to
/// the fork's own manifest — reads `ryanbr/noop`'s public GitHub Releases, separately from (and in
/// ADDITION to) `UpdateChecker` above. At the user's explicit request to keep both: the fork checker
/// tells them when a NEW FORK BUILD is ready to one-tap install; this one tells them when UPSTREAM
/// has published a new release worth merging into the fork — informational only, no install action,
/// since installing upstream's own .ipa directly would replace every fork customization (intervals.icu,
/// the Stress/SpO2/Planned Training work, …) rather than carry them forward. Compared on MARKETING
/// version (not build), because that is genuinely what tracks upstream releases — the fork's build
/// number keeps incrementing across its OWN releases independently of whether upstream has moved.
@MainActor
final class UpstreamUpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(version: String)
        case available(version: String, url: URL, notes: String)
        case failed
    }

    @Published var state: State = .idle

    private static let endpoint = URL(string: "https://api.github.com/repos/ryanbr/noop/releases/latest")!

    func check(currentVersion: String) {
        guard state != .checking else { return }
        state = .checking
        Task {
            do {
                var req = URLRequest(url: Self.endpoint, timeoutInterval: 12)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String,
                      let urlString = json["html_url"] as? String,
                      let url = URL(string: urlString) else {
                    state = .failed
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let notes = UpdateChecker.cleanNotes(json["body"] as? String ?? "")
                state = VersionCheck.isNewer(latest, than: currentVersion)
                    ? .available(version: latest, url: url, notes: notes)
                    : .upToDate(version: latest)
            } catch {
                state = .failed
            }
        }
    }
}
