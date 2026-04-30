import XCTest
@testable import SkeenaSystem

/// Pure-function tests for the SMP: prefix-stripping logic on
/// EnvelopeBarcodeScanner. The scanner UI itself isn't testable in unit tests
/// (camera + VisionKit), so these guard the parsing contract that the rest of
/// the chat flow depends on.
final class EnvelopeBarcodeScannerTests: XCTestCase {

  func testParsePayload_stripsSmpPrefix() {
    XCTAssertEqual(EnvelopeBarcodeScanner.parsePayload("SMP:A7K3F9"), "A7K3F9")
  }

  func testParsePayload_isCaseInsensitiveOnPrefix() {
    XCTAssertEqual(EnvelopeBarcodeScanner.parsePayload("smp:A7K3F9"), "A7K3F9")
    XCTAssertEqual(EnvelopeBarcodeScanner.parsePayload("Smp:A7K3F9"), "A7K3F9")
  }

  func testParsePayload_passesThroughUnknownPrefix() {
    // Legacy or third-party labels (no SMP: prefix) should round-trip
    // unchanged so a researcher can still scan and the ID lands in the field.
    XCTAssertEqual(EnvelopeBarcodeScanner.parsePayload("LODGE-2026-001"), "LODGE-2026-001")
  }

  func testParsePayload_trimsWhitespace() {
    XCTAssertEqual(EnvelopeBarcodeScanner.parsePayload("  SMP:A7K3F9  "), "A7K3F9")
    XCTAssertEqual(EnvelopeBarcodeScanner.parsePayload("SMP: A7K3F9"), "A7K3F9")
  }

  func testParsePayload_emptyAfterPrefix() {
    XCTAssertEqual(EnvelopeBarcodeScanner.parsePayload("SMP:"), "")
  }
}
