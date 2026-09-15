import Foundation

final class WLOCTunnelBridge {
    private let lock = NSLock()
    private var session: OpaquePointer?
    private var state: WLOCTunnelState = .idle
    private var failureStage: UInt32?
    private var errorCode: String?
    private var generation = UUID()
    private var endSignal: WLOCSessionEndSignal?

    func handles(_ data: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(WLOCProviderEnvelope.self, from: data) else {
            return false
        }
        return WLOCProviderMessageID.isWLOC(envelope.messageId)
    }

    func handle(_ data: Data) async -> Data {
        do {
            let envelope = try JSONDecoder().decode(WLOCProviderEnvelope.self, from: data)
            switch envelope.messageId {
            case WLOCProviderMessageID.set:
                let request = try JSONDecoder().decode(WLOCSetRequest.self, from: Data(envelope.messageParams.utf8))
                return encode(await set(request))
            case WLOCProviderMessageID.update:
                let request = try JSONDecoder().decode(WLOCUpdateRequest.self, from: Data(envelope.messageParams.utf8))
                return encode(update(request))
            case WLOCProviderMessageID.clear:
                let request = try JSONDecoder().decode(WLOCSimpleRequest.self, from: Data(envelope.messageParams.utf8))
                return encode(await clear(request))
            case WLOCProviderMessageID.status:
                let request = try JSONDecoder().decode(WLOCSimpleRequest.self, from: Data(envelope.messageParams.utf8))
                return encode(status(requestID: request.requestID))
            default:
                return encode(WLOCProviderResponse(
                    requestID: nil,
                    ok: false,
                    state: .failed,
                    failureStage: 255,
                    errorCode: "unsupported_command"
                ))
            }
        } catch {
            return encode(WLOCProviderResponse(
                requestID: nil,
                ok: false,
                state: .failed,
                failureStage: 255,
                errorCode: "decode_failed"
            ))
        }
    }

    func shutdown(timeoutSeconds: TimeInterval = 3) {
        let signal: WLOCSessionEndSignal?
        lock.lock()
        signal = endSignal
        if let session {
            state = .clearing
            wloc_location_session_cancel(session)
        }
        lock.unlock()
        _ = signal?.waitSync(timeoutSeconds: timeoutSeconds)
    }

    private func set(_ request: WLOCSetRequest) async -> WLOCProviderResponse {
        guard request.latitude.isFinite,
              request.longitude.isFinite,
              (-90.0...90.0).contains(request.latitude),
              (-180.0...180.0).contains(request.longitude)
        else {
            return failure(requestID: request.requestID, stage: 7, code: "invalid_coordinates")
        }
        guard let record = Data(base64Encoded: request.pairingRecordBase64), !record.isEmpty else {
            return failure(requestID: request.requestID, stage: 1, code: "pairing_record_failed")
        }
        guard request.remotePairingPort != 0,
              !request.serviceIdentifier.isEmpty,
              !request.authTag.isEmpty
        else {
            return failure(requestID: request.requestID, stage: 2, code: "service_identity_failed")
        }

        lock.lock()
        if let session, state == .active {
            let code = wloc_location_session_update(session, request.latitude, request.longitude)
            lock.unlock()
            if code == 0 {
                return WLOCProviderResponse(requestID: request.requestID, ok: true, state: .active)
            }
            return failure(requestID: request.requestID, stage: 7, code: "location_update_failed")
        }
        if state == .connecting || state == .clearing {
            let currentState = state
            lock.unlock()
            return WLOCProviderResponse(
                requestID: request.requestID,
                ok: false,
                state: currentState,
                failureStage: nil,
                errorCode: "session_busy"
            )
        }
        guard let newSession = wloc_location_session_create() else {
            lock.unlock()
            return failure(requestID: request.requestID, stage: 255, code: "location_engine_unavailable")
        }

        generation = UUID()
        let runGeneration = generation
        let startSignal = WLOCSessionStartSignal()
        let endSignal = WLOCSessionEndSignal()
        session = newSession
        self.endSignal = endSignal
        state = .connecting
        failureStage = nil
        errorCode = nil
        lock.unlock()

        let sessionBits = UInt(bitPattern: newSession)
        let contextBits = UInt(bitPattern: Unmanaged.passUnretained(startSignal).toOpaque())
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self,
                  let session = OpaquePointer(bitPattern: sessionBits),
                  let context = UnsafeMutableRawPointer(bitPattern: contextBits)
            else { return }

            var result = WLOCLocationResult()
            let code = record.withUnsafeBytes { bytes -> Int32 in
                guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return 2 }
                return request.peerAddress.withCString { peer in
                    request.serviceIdentifier.withCString { identifier in
                        request.authTag.withCString { authTag in
                            wloc_location_session_run(
                                session,
                                base,
                                record.count,
                                peer,
                                request.remotePairingPort,
                                identifier,
                                authTag,
                                request.latitude,
                                request.longitude,
                                wlocTunnelLocationStartedCallback,
                                context,
                                &result
                            )
                        }
                    }
                }
            }

            let stage = result.failure_stage
            wloc_location_result_destroy(&result)
            startSignal.engineEnded(code: code, failureStage: stage)

            self.lock.lock()
            if self.generation == runGeneration {
                self.session = nil
                self.endSignal = nil
                if code == 0 {
                    self.state = .idle
                    self.failureStage = nil
                    self.errorCode = nil
                } else {
                    self.state = .failed
                    self.failureStage = stage == 0 ? 255 : stage
                    self.errorCode = WLOCTunnelBridge.errorCode(for: self.failureStage ?? 255)
                }
            }
            self.lock.unlock()

            wloc_location_session_destroy(session)
            endSignal.finish(code: code, failureStage: stage)
        }

        let start = await startSignal.wait(timeoutSeconds: 20)
        switch start {
        case .started:
            lock.lock()
            if generation == runGeneration, session != nil {
                state = .active
            }
            let currentState = state
            lock.unlock()
            return WLOCProviderResponse(
                requestID: request.requestID,
                ok: currentState == .active,
                state: currentState,
                failureStage: currentState == .active ? nil : failureStage,
                errorCode: currentState == .active ? nil : errorCode
            )
        case .failed(let stage):
            return failure(
                requestID: request.requestID,
                stage: stage == 0 ? 255 : stage,
                code: Self.errorCode(for: stage == 0 ? 255 : stage)
            )
        case .timeout:
            lock.lock()
            if generation == runGeneration, let session {
                state = .clearing
                wloc_location_session_cancel(session)
            }
            lock.unlock()
            return failure(requestID: request.requestID, stage: 255, code: "location_start_timeout")
        }
    }

    private func update(_ request: WLOCUpdateRequest) -> WLOCProviderResponse {
        guard request.latitude.isFinite,
              request.longitude.isFinite,
              (-90.0...90.0).contains(request.latitude),
              (-180.0...180.0).contains(request.longitude)
        else {
            return failure(requestID: request.requestID, stage: 7, code: "invalid_coordinates")
        }

        lock.lock()
        guard let session, state == .active else {
            let currentState = state
            lock.unlock()
            return WLOCProviderResponse(
                requestID: request.requestID,
                ok: false,
                state: currentState,
                failureStage: failureStage,
                errorCode: "no_active_session"
            )
        }
        let code = wloc_location_session_update(session, request.latitude, request.longitude)
        lock.unlock()

        guard code == 0 else {
            return failure(requestID: request.requestID, stage: 7, code: "location_update_failed")
        }
        return WLOCProviderResponse(requestID: request.requestID, ok: true, state: .active)
    }

    private func clear(_ request: WLOCSimpleRequest) async -> WLOCProviderResponse {
        let signal: WLOCSessionEndSignal?
        lock.lock()
        guard let session else {
            state = .idle
            failureStage = nil
            errorCode = nil
            lock.unlock()
            return WLOCProviderResponse(requestID: request.requestID, ok: true, state: .idle)
        }
        state = .clearing
        signal = endSignal
        wloc_location_session_cancel(session)
        lock.unlock()

        guard let signal else {
            return failure(requestID: request.requestID, stage: 8, code: "clear_signal_missing")
        }
        let end = await signal.wait(timeoutSeconds: 20)
        switch end {
        case .finished(let code, let stage):
            if code == 0 {
                return WLOCProviderResponse(requestID: request.requestID, ok: true, state: .idle)
            }
            return failure(
                requestID: request.requestID,
                stage: stage == 0 ? 8 : stage,
                code: Self.errorCode(for: stage == 0 ? 8 : stage)
            )
        case .timeout:
            return failure(requestID: request.requestID, stage: 8, code: "clear_timeout")
        }
    }

    private func status(requestID: String) -> WLOCProviderResponse {
        lock.lock()
        defer { lock.unlock() }
        return WLOCProviderResponse(
            requestID: requestID,
            ok: state != .failed,
            state: state,
            failureStage: failureStage,
            errorCode: errorCode
        )
    }

    private func failure(requestID: String?, stage: UInt32, code: String) -> WLOCProviderResponse {
        WLOCProviderResponse(
            requestID: requestID,
            ok: false,
            state: .failed,
            failureStage: stage,
            errorCode: code
        )
    }

    private func encode(_ response: WLOCProviderResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data()
    }

    private static func errorCode(for stage: UInt32) -> String {
        switch stage {
        case 1: return "pairing_record_failed"
        case 2: return "service_identity_failed"
        case 3: return "pair_verify_failed"
        case 4: return "tls_psk_failed"
        case 5: return "rsd_failed"
        case 6: return "dvt_failed"
        case 7: return "location_failed"
        case 8: return "clear_failed"
        case 9: return "pairing_host_failed"
        case 10: return "cancelled"
        default: return "internal_error"
        }
    }
}

private enum WLOCStartWaitResult {
    case started
    case failed(UInt32)
    case timeout
}

private final class WLOCSessionStartSignal {
    private let condition = NSCondition()
    private var started = false
    private var ended = false
    private var failureStage: UInt32 = 0

    func markStarted() {
        condition.lock()
        if !ended { started = true }
        condition.broadcast()
        condition.unlock()
    }

    func engineEnded(code: Int32, failureStage: UInt32) {
        condition.lock()
        ended = true
        if code != 0 { self.failureStage = failureStage }
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeoutSeconds: TimeInterval) async -> WLOCStartWaitResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.waitSync(timeoutSeconds: timeoutSeconds)
                continuation.resume(returning: result)
            }
        }
    }

    private func waitSync(timeoutSeconds: TimeInterval) -> WLOCStartWaitResult {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !started && !ended {
            if !condition.wait(until: deadline) { return .timeout }
        }
        if started { return .started }
        return .failed(failureStage)
    }
}

private enum WLOCEndWaitResult {
    case finished(Int32, UInt32)
    case timeout
}

private final class WLOCSessionEndSignal {
    private let condition = NSCondition()
    private var finished = false
    private var code: Int32 = 0
    private var failureStage: UInt32 = 0

    func finish(code: Int32, failureStage: UInt32) {
        condition.lock()
        guard !finished else {
            condition.unlock()
            return
        }
        finished = true
        self.code = code
        self.failureStage = failureStage
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeoutSeconds: TimeInterval) async -> WLOCEndWaitResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.waitSyncResult(timeoutSeconds: timeoutSeconds))
            }
        }
    }

    func waitSync(timeoutSeconds: TimeInterval) -> Bool {
        switch waitSyncResult(timeoutSeconds: timeoutSeconds) {
        case .finished: return true
        case .timeout: return false
        }
    }

    private func waitSyncResult(timeoutSeconds: TimeInterval) -> WLOCEndWaitResult {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !finished {
            if !condition.wait(until: deadline) { return .timeout }
        }
        return .finished(code, failureStage)
    }
}

private let wlocTunnelLocationStartedCallback: WLOCLocationStartedCallback = { context in
    guard let context else { return }
    let signal = Unmanaged<WLOCSessionStartSignal>.fromOpaque(context).takeUnretainedValue()
    signal.markStarted()
}
