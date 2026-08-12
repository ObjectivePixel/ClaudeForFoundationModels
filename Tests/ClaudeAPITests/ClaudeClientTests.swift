// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import ClaudeAPI

/// Drives `ClaudeClient` through an injected fake transport so request building,
/// HTTP error mapping, and SSE parsing are exercised without a network. Each
/// test owns its transport, so the suite runs in parallel.
@Suite struct ClaudeClientTests {

  // MARK: - Non-streaming

  @Test func `send builds the request and decodes the response`() async throws {
    let transport = MockTransport(
      headers: ["Content-Type": "application/json"],
      body: Data(
        #"""
        {"id":"msg_1","model":"m","role":"assistant","content":[{"type":"text","text":"Hi"}],"stop_reason":"end_turn","usage":{"input_tokens":3,"output_tokens":1}}
        """#
        .utf8
      )
    )

    let response = try await client(transport)
      .send(
        MessagesRequest(model: "m", maxTokens: 256, messages: [.user("hi")])
      )

    #expect(response.content == [.text("Hi")])
    #expect(response.stopReason == .endTurn)

    let request = try #require(await transport.lastRequest())
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path() == "/v1/messages")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
    #expect(
      request.value(forHTTPHeaderField: "User-Agent")?.contains("ClaudeForFoundationModels/")
        == true
    )

    // The request goes straight to the transport, so its httpBody is intact
    // (URLSession would have moved it into httpBodyStream).
    let body = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "m")
    #expect(json["max_tokens"] as? Int == 256)
    #expect(json["stream"] as? Bool == false)  // send() forces non-streaming
    #expect((json["messages"] as? [[String: Any]])?.count == 1)
  }

  @Test func `caller headers merge over the defaults`() async throws {
    // This is the mechanism `.proxied(headers:)` rides on: the executor passes
    // its auth headers as `headers:`, and the client merges them over its
    // defaults without dropping `x-api-key` / `anthropic-version`.
    let transport = MockTransport(
      body: Data(
        #"{"id":"m","model":"m","role":"assistant","content":[],"stop_reason":"end_turn","usage":{"output_tokens":0}}"#
          .utf8
      )
    )

    _ = try await client(transport)
      .send(
        MessagesRequest(model: "m", messages: [.user("hi")]),
        headers: ["X-App-Token": "abc", "anthropic-beta": "feature-1"]
      )

    let request = try #require(await transport.lastRequest())
    #expect(request.value(forHTTPHeaderField: "X-App-Token") == "abc")
    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "feature-1")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
  }

  @Test func `send maps an error envelope to a typed APIError`() async throws {
    let transport = MockTransport(
      status: 429,
      body: Data(
        #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"},"request_id":"req_envelope"}"#
          .utf8
      )
    )

    let error = try await #require(throws: APIError.self) {
      try await client(transport).send(MessagesRequest(model: "m", messages: [.user("hi")]))
    }
    #expect(error.kind == .rateLimit)
    #expect(error.requestID == "req_envelope")
  }

  @Test func `send falls back to the request-id header when the body has no envelope`() async throws
  {
    let transport = MockTransport(
      status: 500,
      headers: ["request-id": "req_header"],
      body: Data("<html>upstream blew up</html>".utf8)
    )

    let error = try await #require(throws: APIError.self) {
      try await client(transport).send(MessagesRequest(model: "m", messages: [.user("hi")]))
    }
    #expect(error.kind == .api)
    #expect(error.requestID == "req_header")
    #expect(error.message.contains("HTTP 500"))
  }

  // MARK: - Streaming

  @Test func `stream parses frames, surfaces ping, and ends on message_stop`() async throws {
    let transport = MockTransport(
      body: sse([
        [
          "event: content_block_delta",
          #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#,
        ],
        ["event: ping", #"data: {"type":"ping"}"#],
        [
          "event: content_block_delta",
          #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#,
        ],
        ["event: message_stop", #"data: {"type":"message_stop"}"#],
      ])
    )

    var events: [StreamEvent] = []
    try await client(transport).stream(
      MessagesRequest(model: "m", messages: [.user("hi")])
    ) { event in
      events.append(event)
    }

    let texts = events.compactMap {
      if case .contentBlockDelta(_, .text(let t)) = $0 { t } else { nil }
    }
    #expect(texts == ["Hel", "lo"])
    #expect(events.contains { if case .ping = $0 { true } else { false } })
    #expect(events.contains { if case .messageStop = $0 { true } else { false } })
  }

  @Test func `stream concatenates a multi-line data frame`() async throws {
    let transport = MockTransport(
      body: sse([
        [
          "event: content_block_delta",
          #"data: {"type":"content_block_delta","index":0,"delta":"#,
          #"data: {"type":"text_delta","text":"multi"}}"#,
        ]
      ])
    )

    var texts: [String] = []
    try await client(transport).stream(
      MessagesRequest(model: "m", messages: [.user("hi")])
    ) { event in
      if case .contentBlockDelta(_, .text(let t)) = event { texts.append(t) }
    }
    #expect(texts == ["multi"])
  }

  @Test func `stream throws when the body carries an SSE error event`() async throws {
    let transport = MockTransport(
      body: sse([
        [
          "event: error",
          #"data: {"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}"#,
        ]
      ])
    )

    let error = try await #require(throws: APIError.self) {
      try await client(transport).stream(
        MessagesRequest(model: "m", messages: [.user("hi")])
      ) { _ in }
    }
    #expect(error.kind == .overloaded)
  }

  @Test func `a non-envelope error body classifies by HTTP status`() async throws {
    let transport = MockTransport(status: 401, body: Data("<html>denied</html>".utf8))

    let error = try await #require(throws: APIError.self) {
      try await client(transport).stream(
        MessagesRequest(model: "m", messages: [.user("hi")])
      ) { _ in }
    }
    #expect(error.kind == .authentication)
  }

  @Test func `stream maps a 4xx error body instead of parsing it as SSE`() async throws {
    let transport = MockTransport(
      status: 400,
      body: Data(
        #"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#.utf8
      )
    )

    let error = try await #require(throws: APIError.self) {
      try await client(transport).stream(
        MessagesRequest(model: "m", messages: [.user("hi")])
      ) { _ in }
    }
    #expect(error.kind == .invalidRequest)
  }

  @Test func `stream consumer can accumulate text snapshots`() async throws {
    let transport = MockTransport(
      body: sse([
        [
          "event: content_block_delta",
          #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#,
        ],
        [
          "event: content_block_delta",
          #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#,
        ],
        ["event: message_stop", #"data: {"type":"message_stop"}"#],
      ])
    )

    var snapshots: [String] = []
    var accumulated = ""
    try await client(transport).stream(
      MessagesRequest(model: "m", messages: [.user("hi")])
    ) { event in
      if case .contentBlockDelta(_, .text(let text)) = event {
        accumulated += text
        snapshots.append(accumulated)
      }
    }
    #expect(snapshots == ["Hel", "Hello"])
  }

  @Test func `streaming waits for the event consumer before reading the next chunk`() async throws {
    let first = sse([["data: {\"type\":\"ping\"}"]])
    let second = sse([["data: {\"type\":\"message_stop\"}"]])
    let flow = StreamFlowRecorder()
    let transport = ChunkedTransport(chunks: [first, second], flow: flow)

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await self.client(transport).stream(
          MessagesRequest(model: "m", messages: [.user("hi")])
        ) { _ in
          let isFirst = await flow.consumerBegan()
          if isFirst { try await Task.sleep(for: .milliseconds(100)) }
        }
      }

      while await flow.consumerCount == 0 {
        try await Task.sleep(for: .milliseconds(1))
      }
      try await Task.sleep(for: .milliseconds(20))
      let chunksStartedWhileConsumerWasSuspended = await flow.chunkCount
      #expect(chunksStartedWhileConsumerWasSuspended == 1)
      try await group.waitForAll()
    }

    let finalChunkCount = await flow.chunkCount
    #expect(finalChunkCount == 2)
  }

  @Test func `cancelling the caller cancels streaming in the same task tree`() async throws {
    let flow = StreamFlowRecorder()
    let transport = ChunkedTransport(
      chunks: [sse([["data: {\"type\":\"ping\"}"]])],
      flow: flow
    )

    let cancellationObserved = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
      group.addTask {
        do {
          try await self.client(transport).stream(
            MessagesRequest(model: "m", messages: [.user("hi")])
          ) { _ in
            _ = await flow.consumerBegan()
            try await Task.sleep(for: .seconds(10))
          }
          return false
        } catch is CancellationError {
          return true
        } catch {
          return false
        }
      }

      while await flow.consumerCount == 0 {
        try? await Task.sleep(for: .milliseconds(1))
      }
      group.cancelAll()
      return await group.reduce(false) { $0 || $1 }
    }

    #expect(cancellationObserved)
  }

  // MARK: - Helpers

  private func client(
    _ transport: any HTTPTransport,
    auth: Configuration.Auth = .apiKey("sk-test")
  ) -> ClaudeClient {
    ClaudeClient(
      configuration: .init(auth: auth, baseURL: URL(string: "https://stub.test")!),
      transport: transport
    )
  }

  /// A `text/event-stream` body: each frame is its lines followed by the
  /// blank line that terminates it, exactly as the API frames them.
  private func sse(_ frames: [[String]]) -> Data {
    Data(frames.map { $0.joined(separator: "\n") + "\n\n" }.joined().utf8)
  }
}

/// An `HTTPTransport` that returns a canned response and records the request it received.
private final class MockTransport: HTTPTransport {
  let status: Int
  let headers: [String: String]
  let body: Data

  private let captured = RequestCapture()

  init(status: Int = 200, headers: [String: String] = [:], body: Data) {
    self.status = status
    self.headers = headers
    self.body = body
  }

  func lastRequest() async -> URLRequest? { await captured.lastRequest }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    await captured.record(request)
    return (body, response(for: request))
  }

  func stream(
    for request: URLRequest,
    onResponse: (URLResponse) throws -> Void,
    onChunk: (Data) async throws -> Void
  ) async throws {
    await captured.record(request)
    try onResponse(response(for: request))
    try await onChunk(body)
  }

  private func response(for request: URLRequest) -> URLResponse {
    HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
  }
}

private actor RequestCapture {
  private(set) var lastRequest: URLRequest?

  func record(_ request: URLRequest) {
    lastRequest = request
  }
}

private actor StreamFlowRecorder {
  private(set) var chunkCount = 0
  private(set) var consumerCount = 0

  func chunkBegan() {
    chunkCount += 1
  }

  func consumerBegan() -> Bool {
    consumerCount += 1
    return consumerCount == 1
  }
}

private final class ChunkedTransport: HTTPTransport {
  private let chunks: [Data]
  private let flow: StreamFlowRecorder

  init(chunks: [Data], flow: StreamFlowRecorder) {
    self.chunks = chunks
    self.flow = flow
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    (chunks.reduce(into: Data()) { $0.append($1) }, response(for: request))
  }

  func stream(
    for request: URLRequest,
    onResponse: (URLResponse) throws -> Void,
    onChunk: (Data) async throws -> Void
  ) async throws {
    try onResponse(response(for: request))
    for chunk in chunks {
      try Task.checkCancellation()
      await flow.chunkBegan()
      try await onChunk(chunk)
    }
  }

  private func response(for request: URLRequest) -> URLResponse {
    HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: [:]
    )!
  }
}
