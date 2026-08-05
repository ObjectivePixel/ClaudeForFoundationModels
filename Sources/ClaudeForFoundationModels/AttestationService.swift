// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import OSLog

#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// Seam over `DCAppAttestService` so attestation flows are testable and the
/// `isSupported == false` path (simulators, hardware without Secure Enclave)
/// is mockable.
protocol AttestationService: Sendable {
  var isSupported: Bool { get }
  /// Generates a new key pair in the Secure Enclave; returns an opaque key ID.
  func generateKey() async throws -> String
  /// Runs once per key and includes an Apple round-trip of roughly 3–8
  /// seconds. Produces a CBOR attestation object signed by Apple vouching
  /// for the key.
  func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
  /// Runs locally and quickly on each request. Signs `clientDataHash`
  /// with the attested key; the signature includes a monotonic counter for
  /// replay protection.
  func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

#if canImport(DeviceCheck)
struct DeviceAttestationService: AttestationService {
  private static let logger = Logger(
    subsystem: "com.anthropic.ClaudeForFoundationModels",
    category: "AppAttest"
  )

  init() {}
  var isSupported: Bool { DCAppAttestService.shared.isSupported }
  func generateKey() async throws -> String {
    do {
      return try await DCAppAttestService.shared.generateKey()
    } catch let error as DCError {
      Self.log(error, operation: "generateKey")
      throw error
    }
  }
  func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
    do {
      return try await DCAppAttestService.shared.attestKey(
        keyID,
        clientDataHash: clientDataHash
      )
    } catch let error as DCError {
      Self.log(error, operation: "attestKey")
      throw error
    }
  }
  func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
    do {
      return try await DCAppAttestService.shared.generateAssertion(
        keyID,
        clientDataHash: clientDataHash
      )
    } catch let error as DCError {
      Self.log(error, operation: "generateAssertion")
      if Self.shouldReplaceKey(
        after: error.code,
        keyID: keyID,
        clientDataHash: clientDataHash
      ) {
        // `.invalidKey` directly identifies an unusable key. Some valid,
        // previously attested keys instead surface `.invalidInput` from
        // `generateAssertion`. Once the inputs have been validated locally,
        // both conditions require the same bounded replacement path.
        throw AppAttestError.keyInvalidated
      }
      throw error
    }
  }

  static func shouldReplaceKey(
    after code: DCError.Code,
    keyID: String,
    clientDataHash: Data
  ) -> Bool {
    switch code {
    case .invalidKey:
      return true
    case .invalidInput:
      return decodeBase64Loose(keyID)?.count == 32 && clientDataHash.count == 32
    default:
      return false
    }
  }

  static func codeName(_ code: DCError.Code) -> String {
    switch code {
    case .unknownSystemFailure: "unknownSystemFailure"
    case .featureUnsupported: "featureUnsupported"
    case .invalidInput: "invalidInput"
    case .invalidKey: "invalidKey"
    case .serverUnavailable: "serverUnavailable"
    @unknown default: "unknown"
    }
  }

  private static func log(_ error: DCError, operation: String) {
    let name = codeName(error.code)
    let message =
      "App Attest \(operation) failed: "
      + "DeviceCheck \(name) (code \(error.code.rawValue))"
    logger.error("\(message, privacy: .public)")
  }

  private static func decodeBase64Loose(_ string: String) -> Data? {
    var normalized =
      string
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    if normalized.count % 4 != 0 {
      normalized += String(repeating: "=", count: 4 - normalized.count % 4)
    }
    return Data(base64Encoded: normalized)
  }
}
#endif
