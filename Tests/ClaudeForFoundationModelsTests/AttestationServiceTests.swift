// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

#if canImport(DeviceCheck)
import DeviceCheck

@testable import ClaudeForFoundationModels

@Suite struct AttestationServiceTests {
  private let validKeyID = Data(repeating: 0x07, count: 32).base64EncodedString()
  private let validHash = Data(repeating: 0x08, count: 32)

  @Test func `invalid input replaces a key only after local validation`() {
    #expect(
      DeviceAttestationService.shouldReplaceKey(
        after: .invalidInput,
        keyID: validKeyID,
        clientDataHash: validHash
      )
    )
    #expect(
      !DeviceAttestationService.shouldReplaceKey(
        after: .invalidInput,
        keyID: "not-a-key",
        clientDataHash: validHash
      )
    )
    #expect(
      !DeviceAttestationService.shouldReplaceKey(
        after: .invalidInput,
        keyID: validKeyID,
        clientDataHash: Data(repeating: 0x08, count: 31)
      )
    )
  }

  @Test func `invalid key remains recoverable`() {
    #expect(
      DeviceAttestationService.shouldReplaceKey(
        after: .invalidKey,
        keyID: validKeyID,
        clientDataHash: validHash
      )
    )
  }

  @Test func `transient DeviceCheck failures do not replace the key`() {
    #expect(
      !DeviceAttestationService.shouldReplaceKey(
        after: .serverUnavailable,
        keyID: validKeyID,
        clientDataHash: validHash
      )
    )
    #expect(
      !DeviceAttestationService.shouldReplaceKey(
        after: .unknownSystemFailure,
        keyID: validKeyID,
        clientDataHash: validHash
      )
    )
  }

  @Test func `diagnostic names preserve the DeviceCheck code`() {
    #expect(DeviceAttestationService.codeName(.invalidInput) == "invalidInput")
    #expect(DeviceAttestationService.codeName(.invalidKey) == "invalidKey")
  }
}
#endif
