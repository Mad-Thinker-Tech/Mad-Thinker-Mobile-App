import Combine
import XCTest
@testable import SkeenaSystem

/// Regression tests for `PendingUploadSummary` — locks in the contract that
/// `totalPending` reactively reflects the sum of pending counts across the
/// three upstream stores.
///
/// The aggregator is intentionally store-agnostic — it accepts count publishers
/// rather than the stores themselves — so these tests drive updates via
/// `CurrentValueSubject` without touching filesystem-backed singletons.
@MainActor
final class PendingUploadSummaryTests: XCTestCase {

  private var observations: CurrentValueSubject<Int, Never>!
  private var farmed: CurrentValueSubject<Int, Never>!
  private var catches: CurrentValueSubject<Int, Never>!
  private var summary: PendingUploadSummary!
  private var cancellables: Set<AnyCancellable>!

  override func setUp() {
    super.setUp()
    observations = CurrentValueSubject<Int, Never>(0)
    farmed = CurrentValueSubject<Int, Never>(0)
    catches = CurrentValueSubject<Int, Never>(0)
    summary = PendingUploadSummary(
      observations: observations.eraseToAnyPublisher(),
      farmedReports: farmed.eraseToAnyPublisher(),
      catchReports: catches.eraseToAnyPublisher()
    )
    cancellables = []
  }

  override func tearDown() {
    cancellables = nil
    summary = nil
    catches = nil
    farmed = nil
    observations = nil
    super.tearDown()
  }

  // MARK: - Helpers

  /// Wait for the summary's `totalPending` to reach an expected value.
  /// Updates arrive on the main run loop via `.receive(on: DispatchQueue.main)`.
  private func waitForTotal(_ expected: Int, timeout: TimeInterval = 1.0) {
    let exp = expectation(description: "totalPending == \(expected)")
    summary.totalPendingPublisher
      .filter { $0 == expected }
      .first()
      .sink { _ in exp.fulfill() }
      .store(in: &cancellables)
    wait(for: [exp], timeout: timeout)
  }

  // MARK: - Tests

  func testInitialState_allZero_totalIsZero() {
    waitForTotal(0)
  }

  func testSingleStore_increments_reflectedInTotal() {
    observations.send(3)
    waitForTotal(3)
  }

  func testAllStores_sumCorrectly() {
    observations.send(2)
    farmed.send(4)
    catches.send(1)
    waitForTotal(7)
  }

  func testStoreDecrement_totalFalls() {
    observations.send(5)
    waitForTotal(5)

    observations.send(2)
    waitForTotal(2)
  }

  func testAllDrainToZero_totalReturnsToZero() {
    observations.send(3)
    farmed.send(2)
    catches.send(4)
    waitForTotal(9)

    // Simulate uploads completing across all stores.
    observations.send(0)
    farmed.send(0)
    catches.send(0)
    waitForTotal(0)
  }

  func testOnlyOneStoreNonZero_othersStayZero() {
    farmed.send(1)
    waitForTotal(1)

    farmed.send(0)
    catches.send(1)
    waitForTotal(1)
  }
}
