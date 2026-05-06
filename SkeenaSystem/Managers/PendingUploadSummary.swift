// Bend Fly Shop

import Combine
import Foundation

/// Aggregates the "pending upload" count across `ObservationStore`,
/// `FarmedReportStore`, and `CatchReportStore`. Drives the upload badge
/// on the Activities tab in `RoleAwareToolbar`.
///
/// Initialiser accepts three count publishers instead of the store instances
/// directly, so tests can drive reactive updates via `CurrentValueSubject`
/// without depending on filesystem-backed singletons.
///
/// Explicitly `nonisolated` to match its upstream stores and avoid the
/// iOS 26.2 sim `swift_task_deinitOnExecutorMainActorBackDeploy` double-free.
nonisolated final class PendingUploadSummary: ObservableObject {
  static let shared: PendingUploadSummary = PendingUploadSummary(
    observations: ObservationStore.shared.observationsPublisher
      .map { $0.filter { $0.status == .savedLocally }.count }
      .eraseToAnyPublisher(),
    farmedReports: FarmedReportStore.shared.reportsPublisher
      .map { $0.filter { $0.status == .savedLocally }.count }
      .eraseToAnyPublisher(),
    catchReports: CatchReportStore.shared.reportsPublisher
      .map { $0.filter { $0.status == .savedLocally }.count }
      .eraseToAnyPublisher()
  )

  // Manual publisher (see `CatchReportStore` for the rationale — `@Published`
  // is incompatible with the class-level `nonisolated`).
  private let _totalPending = CurrentValueSubject<Int, Never>(0)
  private(set) var totalPending: Int {
    get { _totalPending.value }
    set {
      objectWillChange.send()
      _totalPending.send(newValue)
    }
  }
  var totalPendingPublisher: AnyPublisher<Int, Never> { _totalPending.eraseToAnyPublisher() }

  private var cancellables = Set<AnyCancellable>()

  init(
    observations: AnyPublisher<Int, Never>,
    farmedReports: AnyPublisher<Int, Never>,
    catchReports: AnyPublisher<Int, Never>
  ) {
    Publishers.CombineLatest3(observations, farmedReports, catchReports)
      .map { $0 + $1 + $2 }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] total in
        self?.totalPending = total
      }
      .store(in: &cancellables)
  }
}
