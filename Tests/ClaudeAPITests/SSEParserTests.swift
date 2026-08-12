// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import ClaudeAPI

@Suite struct SSEParserTests {
  @Test func `an event is delivered as soon as its frame ends`() throws {
    var parser = SSEParser()
    let frame = "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":3}\n\n"
    let events = try parser.consume(Data(frame.utf8))

    let event = try #require(events.first)
    guard case .contentBlockStop(let index) = event else {
      Issue.record("expected contentBlockStop, got \(event)")
      return
    }
    #expect(index == 3)
  }

  @Test func `crlf line endings parse like lf`() throws {
    let events = try collect(
      "event: ping\r\ndata: {\"type\":\"ping\"}\r\n\r\n"
        + "event: message_stop\r\ndata: {\"type\":\"message_stop\"}\r\n\r\n"
    )
    #expect(events.count == 2)
  }

  @Test func `a final frame without a trailing blank line flushes at end of stream`() throws {
    let events = try collect("event: ping\ndata: {\"type\":\"ping\"}")
    #expect(events.count == 1)
  }

  @Test func `a frame split across chunks parses once complete`() throws {
    var parser = SSEParser()
    #expect(try parser.consume(Data("event: ping\nda".utf8)).isEmpty)
    #expect(try parser.consume(Data("ta: {\"type\":\"ping\"}\n".utf8)).isEmpty)
    #expect(try parser.consume(Data("\n".utf8)).count == 1)
  }

  @Test func `multiple frames in one chunk preserve order`() throws {
    let events = try collect(
      "data: {\"type\":\"ping\"}\n\n"
        + "data: {\"type\":\"message_stop\"}\n\n"
    )
    #expect(events.count == 2)
    #expect({ if case .ping = events[0] { true } else { false } }())
    #expect({ if case .messageStop = events[1] { true } else { false } }())
  }

  private func collect(_ body: String) throws -> [StreamEvent] {
    var parser = SSEParser()
    var events = try parser.consume(Data(body.utf8))
    events.append(contentsOf: try parser.finish())
    return events
  }
}
