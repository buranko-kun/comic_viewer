import Foundation
import CryptoKit

/// Light obfuscation for catalog download links. `catalog-mirrors.json` is written as an AES-GCM
/// blob (by `split_catalog.py`) so the file-host URLs aren't readable by opening the file.
///
/// This is **obfuscation, not security**: the key below ships inside the app, so anyone who proxies
/// the app's network traffic can still observe the URLs at download time, and anyone who extracts
/// the key can decrypt the catalog. It only stops casual inspection of the shipped catalog files.
enum LinkCipher {
    /// AES-256 key — must stay in sync with `_KEY` in `split_catalog.py`.
    private static let key = SymmetricKey(
        data: Data(base64Encoded: "2KFDIj9Xldf/idWupU/8GfyqO641tswzgvM0bclNZ5g=")!)

    /// Prefix marking an encrypted mirrors file; followed by nonce(12) ‖ ciphertext ‖ tag(16).
    private static let magic = Data("CVMENC1\n".utf8)

    /// Decrypt an encrypted `catalog-mirrors.json` blob back to its JSON bytes. Returns nil when the
    /// data isn't an encrypted blob, so a plaintext mirrors file still loads unchanged.
    static func decryptCatalog(_ data: Data) -> Data? {
        guard data.starts(with: magic) else { return nil }
        let body = Data(data.dropFirst(magic.count))
        guard let box = try? AES.GCM.SealedBox(combined: body),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return plain
    }
}
