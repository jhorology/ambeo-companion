import CoreGraphics
import XCTest

@testable import AmbeoCore

final class SystemEventMonitorTests: XCTestCase {
  func testUserDisableFinishesStreamAndSuppressesPendingRecovery() async {
    let (stream, continuation) = AsyncStream<SystemEvent>.makeStream()
    let context = SystemEventMonitor.Context(
      shouldIntercept: { _ in false },
      continuation: continuation
    )
    // A timeout recovery must not override a subsequent user disable.
    context.handleDisabledEvent(.tapDisabledByTimeout)
    context.handleDisabledEvent(.tapDisabledByUserInput)
    context.handleDisabledEvent(.tapDisabledByUserInput)

    XCTAssertTrue(context.isStopped)
    XCTAssertFalse(context.takeReenableRequest())
    let finished = expectation(description: "Revocation ends the consumer")
    let consumer = Task {
      for await _ in stream { XCTFail("Disabled monitor emitted an event") }
      finished.fulfill()
    }
    await fulfillment(of: [finished], timeout: 1)
    consumer.cancel()
  }

  func testTimeoutRecoveryIsDeferredAndConsumedOnce() {
    let (_, continuation) = AsyncStream<SystemEvent>.makeStream()
    let context = SystemEventMonitor.Context(
      shouldIntercept: { _ in false },
      continuation: continuation
    )
    context.handleDisabledEvent(.tapDisabledByTimeout)

    XCTAssertFalse(context.isStopped)
    XCTAssertTrue(context.takeReenableRequest())
    XCTAssertFalse(context.takeReenableRequest())
    continuation.finish()
  }

  func testCancellationPreventsLateTimeoutFromReenablingTap() {
    let (_, continuation) = AsyncStream<SystemEvent>.makeStream()
    let context = SystemEventMonitor.Context(
      shouldIntercept: { _ in false },
      continuation: continuation
    )
    context.stop()
    context.handleDisabledEvent(.tapDisabledByTimeout)

    XCTAssertTrue(context.isStopped)
    XCTAssertFalse(context.takeReenableRequest())
    continuation.finish()
  }
}
