#if canImport(XCTest)
import XCTest
typealias CoreTestBase = XCTestCase
#endif
#if !canImport(XCTest)
import Foundation
import Testing
class CoreTestBase {
    private var teardowns: [() throws -> Void] = []
    func addTeardownBlock(_ block: @escaping () throws -> Void) { teardowns.append(block) }
    deinit { for block in teardowns { try? block() } }
}
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) { do { let a = try lhs(), b = try rhs(); if a != b { Issue.record("Expected \(a) == \(b)", sourceLocation: SourceLocation(fileID: "LocaleShiftCoreTests/TestSupport.swift", filePath: String(describing: file), line: Int(line), column: 1)) } } catch { Issue.record("Unexpected error: \(error)") } }
func XCTAssertNotEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T) { do { let a = try lhs(), b = try rhs(); #expect(a != b) } catch { Issue.record("Unexpected error: \(error)") } }
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool) { do { let result = try value(); #expect(result) } catch { Issue.record("Unexpected error: \(error)") } }
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool) { do { let result = try value(); #expect(!result) } catch { Issue.record("Unexpected error: \(error)") } }
func XCTAssertNil<T>(_ value: @autoclosure () throws -> T?) { do { let result = try value(); #expect(result == nil) } catch { Issue.record("Unexpected error: \(error)") } }
func XCTAssertNotNil<T>(_ value: @autoclosure () throws -> T?) { do { let result = try value(); #expect(result != nil) } catch { Issue.record("Unexpected error: \(error)") } }
func XCTAssertGreaterThan<T: Comparable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T) { do { let a = try lhs(), b = try rhs(); #expect(a > b) } catch { Issue.record("Unexpected error: \(error)") } }
func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, _ handler: (Error) -> Void = { _ in }) {
    do { _ = try value(); Issue.record("Expected an error") } catch { handler(error) }
}
func XCTFail(_ message: String) { Issue.record(Comment(rawValue: message)) }
#endif
