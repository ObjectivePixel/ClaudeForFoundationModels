// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The HTTP seam ``ClaudeClient`` talks through. Production uses
/// ``URLSessionTransport``; tests inject a fake. Streaming is consumed in the
/// caller's task so cancellation and backpressure remain structured.
package protocol HTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
  func stream(
    for request: URLRequest,
    onResponse: (URLResponse) throws -> Void,
    onChunk: (Data) async throws -> Void
  ) async throws
}

/// `URLSession`-backed transport used in production.
package struct URLSessionTransport: HTTPTransport {
  private let session: URLSession

  package init(session: URLSession = .shared) {
    self.session = session
  }

  package func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.data(for: request)
  }

  package func stream(
    for request: URLRequest,
    onResponse: (URLResponse) throws -> Void,
    onChunk: (Data) async throws -> Void
  ) async throws {
    let (asyncBytes, response) = try await session.bytes(for: request)
    try onResponse(response)

    let chunkCapacity = 16 * 1_024
    var chunk = Data()
    chunk.reserveCapacity(chunkCapacity)
    for try await byte in asyncBytes {
      try Task.checkCancellation()
      chunk.append(byte)
      if chunk.count == chunkCapacity
        || byte == UInt8(ascii: "\n")
        || byte == UInt8(ascii: "\r")
      {
        try await onChunk(chunk)
        chunk.removeAll(keepingCapacity: true)
      }
    }
    if !chunk.isEmpty {
      try await onChunk(chunk)
    }
  }
}
