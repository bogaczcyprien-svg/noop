#if os(iOS)
import BackgroundTasks
import Foundation

/// Periodic fallback push, mirroring `HealthWritebackBackgroundScheduler`'s pattern. Fresh BLE
/// offloads also trigger a push immediately via the app's offload-completion hook; this covers data
/// already banked locally when the app has been closed for a while.
@MainActor
enum PushBackgroundScheduler {
    static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".selfhostedpush"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            schedule()
            let worker = Task { @MainActor in
                await PushRunner.shared.runIfConfigured()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { worker.cancel() }
        }
    }

    static func schedule(now: Date = Date()) {
        guard SelfHostedPushSettings.shared.isEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
            return
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = now.addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }
}
#endif
