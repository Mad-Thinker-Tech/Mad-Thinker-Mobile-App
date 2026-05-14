// Bend Fly Shop
//
// Connectivity service backed by `NWPathMonitor`. Exposes a Combine publisher
// and a synchronous snapshot accessor that consumers (future SyncCoordinator,
// OfflineBanner, etc.) can read from any thread.
//
// This is a foundational, non-behavioral service: nothing in the app reads
// from it yet. It is wired up early in `AppRootView.task` so the first
// reading is available before any consumer subscribes.
//
// Explicitly `nonisolated`: the project sets SWIFT_DEFAULT_ACTOR_ISOLATION =
// MainActor, which would otherwise make this class `@MainActor`. Path-monitor
// callbacks fire on a background queue and the snapshot accessor is read
// from off-MainActor upload code, so MainActor isolation is the wrong fit
// and routes deinit through `swift_task_deinitOnExecutorMainActorBackDeploy`,
// which has been observed to crash on iOS 26.2 sim teardown.

import Combine
import Foundation
import Network

nonisolated final class NetworkMonitor: @unchecked Sendable {

  nonisolated(unsafe) static let shared = NetworkMonitor()

  private let _isOnline = CurrentValueSubject<Bool, Never>(true)
  private let pathMonitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "NetworkMonitor")

  /// Publisher of connectivity state. Emits the current value on subscribe.
  var isOnlinePublisher: AnyPublisher<Bool, Never> {
    _isOnline.eraseToAnyPublisher()
  }

  /// Synchronous snapshot for off-MainActor consumers (e.g. upload code).
  var isOnlineSnapshot: Bool {
    _isOnline.value
  }

  private init() {
    pathMonitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      let online = path.status == .satisfied
      if self._isOnline.value != online {
        self._isOnline.send(online)
        AppLogging.log("[NetworkMonitor] online=\(online)", level: .info, category: .network)
      }
    }
    pathMonitor.start(queue: queue)
  }

  /// Test seam: forces the snapshot/publisher to the given value so unit tests
  /// can exercise the offline branches in `AuthService` / `CommunityService`
  /// without toggling real network. Mirrors the `AuthService.resetSharedForTests`
  /// convention. Tests must reset to `true` in `tearDown` to avoid leaking
  /// offline state into sibling tests via the shared singleton. The real
  /// `NWPathMonitor` may overwrite this on the next path transition — fine in
  /// practice since unit tests don't transition the host network.
  nonisolated func setOnlineSnapshotForTests(_ online: Bool) {
    if _isOnline.value != online {
      _isOnline.send(online)
    }
  }
}
