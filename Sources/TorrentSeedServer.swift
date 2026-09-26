        }
    }

    private func handle(_ message: PeerMessage) {
        guard let seed else { return }

        switch message {
        case .extended(let extensionID, let payload):
            if extensionID == TorrentMetadataWire.handshakeExtensionID {
                if let peerID = TorrentMetadataWire.peerMetadataExtensionID(from: payload) {
                    peerMetadataID = peerID
                    print("[TorrentSeedPeer] peer ut_metadata extension id=\(peerID)")
                }
                return
            }

            guard extensionID == TorrentMetadataWire.localExtensionID,
                  let requestPiece = TorrentMetadataWire.metadataRequestPiece(from: payload) else {
                return
            }

            guard let metadataResponse = TorrentMetadataWire.metadataResponse(
                piece: requestPiece,
                metadata: seed.metadata
            ) else {
                print("[TorrentSeedPeer] rejecting invalid metadata piece=\(requestPiece)")
                return
            }

            guard let peerMetadataID else {
                print("[TorrentSeedPeer] cannot send ut_metadata piece=\(requestPiece): peer extension id unknown")
                return
            }

            print("[TorrentSeedPeer] sending ut_metadata piece=\(requestPiece) on peer extension id=\(peerMetadataID)")
            send(PeerMessage.extended(
                id: peerMetadataID,
                payload: metadataResponse
            ).encode())

        case .interested: