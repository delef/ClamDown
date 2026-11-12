// Checks an EdDSA (Ed25519) signature the way Sparkle does, against the public key an app carries.
// Usage: swift scripts/lib/ed25519-verify.swift <base64-public-key> <file> <base64-signature>
// Exits 0 when the signature is valid, 1 when it is not.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4,
      let keyData = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[3]),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
      let file = try? Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe) else {
    FileHandle.standardError.write(Data("usage: ed25519-verify.swift <base64-public-key> <file> <base64-signature>\n".utf8))
    exit(2)
}
exit(publicKey.isValidSignature(signature, for: file) ? 0 : 1)
