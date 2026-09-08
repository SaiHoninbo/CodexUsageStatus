#if canImport(Sparkle)
import AppKit
import Foundation
import Sparkle

/// The single runtime update authority. Sparkle owns download, signature
/// validation, installation, termination and relaunch; the product only
/// projects its lifecycle into the existing update state model.
@MainActor
final class SparkleUpdateEngine: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    var onStateChange: ((AppUpdateState) -> Void)?

    private lazy var controller: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }()
    private var started = false
    private var currentRelease: AppUpdateRelease?

    func start() {
        guard !started else { return }
        started = true
        controller.startUpdater()
    }

    func probeForUpdateInformation() {
        if !started { start() }
        controller.updater.checkForUpdateInformation()
    }

    func beginForegroundUpdateFlow() {
        if !started { start() }
        controller.updater.checkForUpdates()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let release = makeRelease(from: item)
        currentRelease = release
        onStateChange?(.available(release))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        onStateChange?(.error(error.localizedDescription))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        onStateChange?(.upToDate)
    }

    func updater(
        _ updater: SPUUpdater,
        willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        currentRelease = makeRelease(from: item)
        onStateChange?(.downloading(progress: nil))
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        currentRelease = makeRelease(from: item)
        onStateChange?(.verifying(currentRelease))
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        currentRelease = makeRelease(from: item)
        onStateChange?(.verifying(currentRelease))
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        currentRelease = makeRelease(from: item)
        onStateChange?(.verifying(currentRelease))
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        currentRelease = makeRelease(from: item)
        onStateChange?(.installing(currentRelease))
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        onStateChange?(.relaunching(currentRelease))
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        onStateChange?(.error(error.localizedDescription))
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        if let error {
            onStateChange?(.error(error.localizedDescription))
        }
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { true }

    private func makeRelease(from item: SUAppcastItem) -> AppUpdateRelease {
        let candidateURL = item.infoURL ?? item.releaseNotesURL
        let url = AppUpdateReleasePolicy.safeReleaseURL(candidateURL)
        return AppUpdateRelease(
            version: item.displayVersionString,
            tagName: "v\(item.displayVersionString)",
            name: item.title ?? "Codex Usage Status \(item.displayVersionString)",
            releaseURL: url,
            notes: item.itemDescription ?? "",
            publishedAt: item.date
        )
    }
}
#endif
