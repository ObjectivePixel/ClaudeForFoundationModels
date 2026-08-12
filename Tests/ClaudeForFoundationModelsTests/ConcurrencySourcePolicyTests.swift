import Foundation
import Testing

@Suite("Concurrency source policy")
struct ConcurrencySourcePolicyTests {
  @Test
  func productionSourcesDoNotUseConcurrencyEscapeHatches() throws {
    let sources = packageRoot.appending(path: "Sources")
    let violations = try SourceConcurrencyPolicy.violations(in: [sources])

    #expect(violations.isEmpty, "Disallowed concurrency constructs: \(violations.joined(separator: ", "))")
  }

  private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

private enum SourceConcurrencyPolicy {
  private static let expressions = [
    #"\bTask\s*\{"#,
    #"Task\.detached"#,
    #"Async(?:Throwing)?Stream"#,
    #"withChecked(?:Throwing)?Continuation"#,
    #"DispatchQueue"#,
    #"MainActor\.assumeIsolated"#,
    #"@unchecked\s+Sendable"#,
  ].map { try! NSRegularExpression(pattern: $0) }

  static func violations(in roots: [URL]) throws -> [String] {
    try roots.flatMap { root in
      try FileManager.default.subpathsOfDirectory(atPath: root.path)
        .filter { $0.hasSuffix(".swift") }
        .flatMap { relativePath -> [String] in
          let source = try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
          let range = NSRange(source.startIndex..., in: source)
          return expressions.compactMap { expression in
            guard expression.firstMatch(in: source, range: range) != nil else { return nil }
            return relativePath + ":" + expression.pattern
          }
        }
    }
  }
}
