// CloisterHandler.swift - Handler for incoming cloister requests
//
// Handles network key negotiation and invite sharing requests from peers.

import Foundation
import Crypto
import Logging

/// Handler for incoming cloister (private network) requests
public actor CloisterHandler {
    /// The channel provider for receiving requests and sending responses
    private let provider: any ChannelProvider

    /// Request handler (decides whether to accept negotiation)
    private var requestHandler: (@Sendable (PeerId, String) async -> Bool)?

    /// Invite handler (decides whether to accept shared invites)
    private var inviteHandler: (@Sendable (PeerId, String?) async -> Bool)?

    /// Callback when a new network key is derived
    private var networkKeyCallback: (@Sendable (CloisterResult) async -> Void)?

    /// Logger
    private let logger = Logger(label: "io.omerta.mesh.services.cloister.handler")

    /// Whether the handler is running
    private var isRunning: Bool = false

    /// Initialize with a channel provider
    public init(provider: any ChannelProvider) {
        self.provider = provider
    }

    // MARK: - Lifecycle

    /// Start listening for cloister requests
    public func start() async throws {
        guard !isRunning else {
            throw ServiceError.alreadyRunning
        }

        // Register negotiation request handler
        try await provider.onChannel(CloisterChannels.negotiate) { [weak self] fromPeerId, data in
            await self?.handleNegotiationRequest(data, from: fromPeerId)
        }

        // Register invite share handler
        try await provider.onChannel(CloisterChannels.share) { [weak self] fromPeerId, data in
            await self?.handleInviteShare(data, from: fromPeerId)
        }

        isRunning = true
        logger.info("Cloister handler started")
    }

    /// Stop listening for cloister requests
    public func stop() async {
        await provider.offChannel(CloisterChannels.negotiate)
        await provider.offChannel(CloisterChannels.share)
        isRunning = false
        logger.info("Cloister handler stopped")
    }

    // MARK: - Configuration

    /// Set the request handler for negotiation requests
    /// - Parameter handler: Async closure that decides whether to accept
    ///   Parameters: (fromPeerId, networkName) -> accept?
    public func setRequestHandler(_ handler: @escaping @Sendable (PeerId, String) async -> Bool) {
        requestHandler = handler
    }

    /// Set the invite handler for shared invites
    /// - Parameter handler: Async closure that decides whether to accept
    ///   Parameters: (fromPeerId, networkNameHint) -> accept?
    public func setInviteHandler(_ handler: @escaping @Sendable (PeerId, String?) async -> Bool) {
        inviteHandler = handler
    }

    /// Set a callback for when network keys are successfully derived
    /// - Parameter callback: Called with the derived network key result
    public func setNetworkKeyCallback(_ callback: @escaping @Sendable (CloisterResult) async -> Void) {
        networkKeyCallback = callback
    }

    // MARK: - Internal

    private func handleNegotiationRequest(_ data: Data, from peerId: PeerId) async {
        guard let request = try? JSONCoding.decoder.decode(CloisterRequest.self, from: data) else {
            logger.warning("Failed to decode cloister request from \(peerId.prefix(8))...")
            return
        }

        logger.debug("Received cloister request from \(peerId.prefix(8))..., networkName: \(request.networkName)")

        // Check if we should accept
        let accepted: Bool
        if let handler = requestHandler {
            accepted = await handler(peerId, request.networkName)
        } else {
            // Default: reject if no handler
            accepted = false
            logger.warning("No cloister request handler set, rejecting request from \(peerId.prefix(8))...")
        }

        if !accepted {
            await sendNegotiationResponse(
                requestId: request.requestId,
                to: peerId,
                accepted: false,
                rejectReason: "Request not accepted"
            )
            return
        }

        // Generate our ephemeral X25519 keypair
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKeyData = Data(privateKey.publicKey.rawRepresentation)

        do {
            let theirPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.ephemeralPublicKey)

            // Derive shared secret using X25519
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: theirPublicKey)

            // Derive network key using HKDF
            let networkKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data(),
                sharedInfo: Data("omerta-network-key".utf8),
                outputByteCount: 32
            )

            let networkKeyData = networkKey.withUnsafeBytes { Data($0) }

            // Compute network ID
            let hash = SHA256.hash(data: networkKeyData)
            let networkId = hash.prefix(8).map { String(format: "%02x", $0) }.joined()

            // Create confirmation (prove we derived the same key)
            let confirmationData = try ChaChaPoly.seal(
                Data("confirmed".utf8),
                using: networkKey
            ).combined

            // Send response with our public key
            await sendNegotiationResponse(
                requestId: request.requestId,
                to: peerId,
                accepted: true,
                publicKey: publicKeyData,
                confirmation: confirmationData
            )

            // Notify about the new network key
            let result = CloisterResult(
                networkKey: networkKeyData,
                networkId: networkId,
                networkName: request.networkName,
                sharedWith: peerId
            )

            if let callback = networkKeyCallback {
                await callback(result)
            }

            logger.info("Successfully negotiated network key with \(peerId.prefix(8))..., networkId: \(networkId)")

        } catch {
            logger.error("Key exchange failed with \(peerId.prefix(8))...: \(error)")
            await sendNegotiationResponse(
                requestId: request.requestId,
                to: peerId,
                accepted: false,
                rejectReason: "Key exchange failed"
            )
        }
    }

    private func sendNegotiationResponse(
        requestId: UUID,
        to peerId: PeerId,
        accepted: Bool,
        publicKey: Data? = nil,
        confirmation: Data? = nil,
        rejectReason: String? = nil
    ) async {
        let response = CloisterResponse(
            requestId: requestId,
            accepted: accepted,
            ephemeralPublicKey: publicKey,
            encryptedConfirmation: confirmation,
            rejectReason: rejectReason
        )

        do {
            let responseData = try JSONCoding.encoder.encode(response)
            let responseChannel = CloisterChannels.response(for: peerId)
            try await provider.sendOnChannel(responseData, to: peerId, channel: responseChannel)
        } catch {
            logger.error("Failed to send cloister response to \(peerId.prefix(8))...: \(error)")
        }
    }

    private func handleInviteShare(_ data: Data, from peerId: PeerId) async {
        guard let share = try? JSONCoding.decoder.decode(NetworkInviteShare.self, from: data) else {
            logger.warning("Failed to decode invite share from \(peerId.prefix(8))...")
            return
        }

        logger.debug("Received invite share from \(peerId.prefix(8))..., hint: \(share.networkNameHint ?? "none")")

        // Check if we should accept
        let accepted: Bool
        if let handler = inviteHandler {
            accepted = await handler(peerId, share.networkNameHint)
        } else {
            accepted = false
            logger.warning("No invite handler set, rejecting invite from \(peerId.prefix(8))...")
        }

        // Generate our ephemeral keypair for key derivation
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKeyData = Data(privateKey.publicKey.rawRepresentation)

        if !accepted {
            await sendInviteAck(
                requestId: share.requestId,
                to: peerId,
                accepted: false,
                publicKey: publicKeyData,
                rejectReason: "Invite not accepted"
            )
            return
        }

        do {
            let theirPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: share.ephemeralPublicKey)

            // Derive shared secret
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: theirPublicKey)

            // Derive symmetric key for invite decryption
            let inviteKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data(),
                sharedInfo: Data("omerta-invite-key".utf8),
                outputByteCount: 32
            )

            // Decrypt the invite
            let sealedBox = try ChaChaPoly.SealedBox(combined: share.encryptedInvite)
            let networkKey = try ChaChaPoly.open(sealedBox, using: inviteKey)

            // Compute network ID
            let hash = SHA256.hash(data: networkKey)
            let networkId = hash.prefix(8).map { String(format: "%02x", $0) }.joined()

            // Send ack
            await sendInviteAck(
                requestId: share.requestId,
                to: peerId,
                accepted: true,
                publicKey: publicKeyData,
                joinedNetworkId: networkId
            )

            // Notify about the new network key
            let result = CloisterResult(
                networkKey: networkKey,
                networkId: networkId,
                networkName: share.networkNameHint ?? "shared-network",
                sharedWith: peerId
            )

            if let callback = networkKeyCallback {
                await callback(result)
            }

            logger.info("Successfully received invite from \(peerId.prefix(8))..., networkId: \(networkId)")

        } catch {
            logger.error("Failed to process invite from \(peerId.prefix(8))...: \(error)")
            await sendInviteAck(
                requestId: share.requestId,
                to: peerId,
                accepted: false,
                publicKey: publicKeyData,
                rejectReason: "Failed to decrypt invite"
            )
        }
    }

    private func sendInviteAck(
        requestId: UUID,
        to peerId: PeerId,
        accepted: Bool,
        publicKey: Data,
        joinedNetworkId: String? = nil,
        rejectReason: String? = nil
    ) async {
        let ack = NetworkInviteAck(
            requestId: requestId,
            ephemeralPublicKey: publicKey,
            accepted: accepted,
            joinedNetworkId: joinedNetworkId,
            rejectReason: rejectReason
        )

        do {
            let ackData = try JSONCoding.encoder.encode(ack)
            let ackChannel = CloisterChannels.shareAck(for: peerId)
            try await provider.sendOnChannel(ackData, to: peerId, channel: ackChannel)
        } catch {
            logger.error("Failed to send invite ack to \(peerId.prefix(8))...: \(error)")
        }
    }
}
