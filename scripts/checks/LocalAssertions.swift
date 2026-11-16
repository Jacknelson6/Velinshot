import Foundation

// This tiny fallback executes the original XCTest scenario bodies on a
// Command Line Tools installation without XCTest. It is not XCTest.
class CoreCheckSuite {}
enum CheckLedger { static var failures: [String] = [] }
struct LocalCheckError: Error {}

private func check(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString, line: UInt) {
    if !condition { CheckLedger.failures.append("\(file):\(line): \(message())") }
}

private func shortValue(_ value: Any, depth: Int = 0) -> String {
    if depth > 3 { return String(describing: type(of: value)) }
    if let string = value as? String { return String(string.prefix(256)) }
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        return mirror.children.first.map { "Optional(\(shortValue($0.value, depth: depth + 1)))" } ?? "nil"
    }
    if mirror.displayStyle == .collection || mirror.displayStyle == .dictionary || mirror.displayStyle == .set {
        let prefix = mirror.children.prefix(8).map { shortValue($0.value, depth: depth + 1) }.joined(separator: ", ")
        return "\(type(of: value))(count: \(mirror.children.count), prefix: [\(prefix)])"
    }
    return String(String(describing: value).prefix(512))
}

private func evaluated<T>(_ operation: () throws -> T, file: StaticString, line: UInt) -> T? {
    do { return try operation() }
    catch { CheckLedger.failures.append("\(file):\(line): unexpected error \(error)"); return nil }
}

func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                                  _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let a = evaluated(lhs, file: file, line: line), let b = evaluated(rhs, file: file, line: line) else { return }
    check(a == b, "Expected \(shortValue(a)) == \(shortValue(b)). \(message)", file: file, line: line)
}

func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    if let result = evaluated(value, file: file, line: line) { check(result, "Expected true. \(message)", file: file, line: line) }
}

func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    if let result = evaluated(value, file: file, line: line) { check(!result, "Expected false. \(message)", file: file, line: line) }
}

func XCTAssertNil<T>(_ value: @autoclosure () throws -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { check(try value() == nil, "Expected nil. \(message)", file: file, line: line) }
    catch { CheckLedger.failures.append("\(file):\(line): unexpected error \(error)") }
}

func XCTAssertGreaterThan<T: Comparable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                                        _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let a = evaluated(lhs, file: file, line: line), let b = evaluated(rhs, file: file, line: line) else { return }
    check(a > b, "Expected \(a) > \(b). \(message)", file: file, line: line)
}

func XCTAssertLessThan<T: Comparable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                                     _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let a = evaluated(lhs, file: file, line: line), let b = evaluated(rhs, file: file, line: line) else { return }
    check(a < b, "Expected \(a) < \(b). \(message)", file: file, line: line)
}

func XCTAssertLessThanOrEqual<T: Comparable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                                            _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let a = evaluated(lhs, file: file, line: line), let b = evaluated(rhs, file: file, line: line) else { return }
    check(a <= b, "Expected \(a) <= \(b). \(message)", file: file, line: line)
}

func XCTAssertThrowsError<T>(_ operation: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath,
                             line: UInt = #line, _ handler: ((Error) -> Void)? = nil) {
    do { _ = try operation(); CheckLedger.failures.append("\(file):\(line): Expected an error. \(message)") }
    catch { handler?(error) }
}

func XCTAssertNoThrow<T>(_ operation: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    _ = evaluated(operation, file: file, line: line)
}

func XCTUnwrap<T>(_ operation: @autoclosure () throws -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = try operation() else {
        CheckLedger.failures.append("\(file):\(line): Expected a value. \(message)")
        throw LocalCheckError()
    }
    return value
}

func verifyLocalAssertions() {
    // Deliberately fail each supported assertion once before any product tests.
    // A broken assertion must stop the gate rather than create a false pass.
    let probes: [() -> Void] = [
        { XCTAssertEqual(1, 2) }, { XCTAssertTrue(false) }, { XCTAssertFalse(true) },
        { XCTAssertNil(Optional(1)) }, { XCTAssertGreaterThan(1, 2) },
        { XCTAssertLessThan(2, 1) }, { XCTAssertLessThanOrEqual(2, 1) },
        { XCTAssertThrowsError(1) }, noThrowAssertionProbe,
        { do { _ = try XCTUnwrap(Optional<Int>.none) } catch {} }
    ]
    for (index, probe) in probes.enumerated() {
        CheckLedger.failures.removeAll()
        probe()
        if CheckLedger.failures.isEmpty {
            print("ASSERTION RUNNER FAILURE: probe \(index) did not fail")
            exit(1)
        }
    }
    CheckLedger.failures.removeAll()
    print("Validated \(probes.count) assertion failure probes.")
}

private func throwingProbe() throws -> Int { throw LocalCheckError() }

private func noThrowAssertionProbe() {
    XCTAssertNoThrow(try throwingProbe())
}
