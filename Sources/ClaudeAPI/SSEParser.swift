// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Incrementally parses `text/event-stream` chunks into ``StreamEvent`` values.
///
/// SSE frames are `event:` + one or more `data:` lines terminated by a blank
/// line. Lines are split here rather than with `AsyncSequence.lines`, which
/// swallows the blank separator — the frame must be emitted the moment its
/// blank line arrives, not when the next frame starts, or every event would be
/// delivered one frame late.
struct SSEParser {
  private let decoder = JSONDecoder()
  private var line: [UInt8] = []
  private var frameData = ""
  private var previousByteWasCR = false

  mutating func consume(_ chunk: Data) throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    for byte in chunk {
      switch byte {
      case UInt8(ascii: "\n") where previousByteWasCR:
        previousByteWasCR = false
      case UInt8(ascii: "\n"), UInt8(ascii: "\r"):
        previousByteWasCR = byte == UInt8(ascii: "\r")
        try handle(String(decoding: line, as: UTF8.self), events: &events)
        line.removeAll(keepingCapacity: true)
      default:
        previousByteWasCR = false
        line.append(byte)
      }
    }
    return events
  }

  mutating func finish() throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    if !line.isEmpty {
      try handle(String(decoding: line, as: UTF8.self), events: &events)
      line.removeAll(keepingCapacity: true)
    }
    try flush(into: &events)
    return events
  }

  private mutating func handle(_ line: String, events: inout [StreamEvent]) throws {
    if line.isEmpty {
      try flush(into: &events)
    } else if line.hasPrefix("data:") {
      let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
      frameData += frameData.isEmpty ? payload : "\n" + payload
    }
  }

  private mutating func flush(into events: inout [StreamEvent]) throws {
    guard !frameData.isEmpty else { return }
    let json = frameData
    frameData = ""
    guard json != "[DONE]" else { return }
    let event = try decoder.decode(StreamEvent.self, from: Data(json.utf8))
    if case .error(let apiError) = event {
      throw apiError
    }
    events.append(event)
  }
}
