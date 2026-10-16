import Foundation
import UIKit

struct BackgroundUploadTask: Equatable {
    let identifier: Int
    let description: String?
}

struct BackgroundUploadEvent: Equatable {
    let identifier: Int
    let description: String?
    let statusCode: Int?
    let errorDescription: String?

    var succeeded: Bool {
        errorDescription == nil && statusCode.map { (200..<300).contains($0) } == true
    }
}

@MainActor
protocol BackgroundUploadClient: AnyObject {
    var onEvents: (() -> Void)? { get set }
    func makeUpload(request: URLRequest, file: URL, description: String) throws -> BackgroundUploadTask
    func resume(_ identifier: Int)
    func cancel(_ identifier: Int)
    func tasks() async -> [BackgroundUploadTask]
    func drainEvents() -> [BackgroundUploadEvent]
    func requeueEvents(_ events: [BackgroundUploadEvent])
    func reconciliationDrained()
    func handleEvents(completion: @escaping () -> Void)
}

/// Process-wide owner of the one stable background session. Delegate results stay buffered
/// until the transfer ledger confirms that it has durably reconciled them.
final class BackgroundUploadCoordinator: NSObject, BackgroundUploadClient, URLSessionTaskDelegate, URLSessionDelegate {
    static let shared = BackgroundUploadCoordinator()
    static let identifier = "studio.otherstuff.PeteRecorder.background-uploads.v1"

    @MainActor var onEvents: (() -> Void)?
    private var events: [BackgroundUploadEvent] = []
    private var eventCompletion: (() -> Void)?
    private var delegateBatchFinished = false
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 7 * 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        _ = session
    }

    @MainActor
    func makeUpload(request: URLRequest, file: URL, description: String) throws -> BackgroundUploadTask {
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = description
        return BackgroundUploadTask(identifier: task.taskIdentifier, description: description)
    }

    @MainActor func resume(_ identifier: Int) {
        session.getAllTasks { tasks in tasks.first { $0.taskIdentifier == identifier }?.resume() }
    }

    @MainActor func cancel(_ identifier: Int) {
        session.getAllTasks { tasks in tasks.first { $0.taskIdentifier == identifier }?.cancel() }
    }

    @MainActor
    func tasks() async -> [BackgroundUploadTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks.map { BackgroundUploadTask(identifier: $0.taskIdentifier, description: $0.taskDescription) })
            }
        }
    }

    @MainActor func drainEvents() -> [BackgroundUploadEvent] {
        let drained = events
        events.removeAll()
        return drained
    }

    @MainActor func requeueEvents(_ events: [BackgroundUploadEvent]) {
        self.events.insert(contentsOf:events,at:0)
    }

    @MainActor func reconciliationDrained() { finishEventsIfPossible() }

    @MainActor func accept(_ event: BackgroundUploadEvent) {
        events.append(event)
        onEvents?()
    }

    @MainActor func finishDelegateEvents() {
        delegateBatchFinished = true
        onEvents?()
        finishEventsIfPossible()
    }

    @MainActor func handleEvents(completion: @escaping () -> Void) {
        eventCompletion = completion
        finishEventsIfPossible()
    }

    @MainActor private func finishEventsIfPossible() {
        guard delegateBatchFinished, events.isEmpty, let completion = eventCompletion else { return }
        eventCompletion = nil
        delegateBatchFinished = false
        completion()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let event = BackgroundUploadEvent(identifier: task.taskIdentifier,
                                          description: task.taskDescription,
                                          statusCode: (task.response as? HTTPURLResponse)?.statusCode,
                                          errorDescription: error?.localizedDescription)
        Task { @MainActor in
            accept(event)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            finishDelegateEvents()
        }
    }
}

final class RecorderAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploadCoordinator.identifier else {
            completionHandler()
            return
        }
        Task { @MainActor in BackgroundUploadCoordinator.shared.handleEvents(completion: completionHandler) }
    }
}
