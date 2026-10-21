import Foundation
import IMV2ActorCluster

// Offline output only. Publish the completed file with an atomic rename into
// each node's admission directory; never distribute this tool's private input.
enum ToolError: Error { case usage, invalidKey, oversizedInput }
func read(_ path: String, limit: Int) throws -> Data {
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? file.close() }
    let bytes = try file.read(upToCount: limit + 1) ?? Data()
    guard bytes.count <= limit else { throw ToolError.oversizedInput }
    return bytes
}
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 4 else {
    print("Usage: IMV2TrustAdmissionTool PREVIOUS_CONFIGURATION EXPANDED_CONFIGURATION AUTHORITY_PEM OUTPUT_PB")
    throw ToolError.usage
}
let pem = try read(arguments[2], limit: 4096)
guard let text = String(data: pem, encoding: .utf8) else { throw ToolError.invalidKey }
let lines = text.split(whereSeparator: \.isNewline).map(String.init)
guard lines.first == "-----BEGIN PRIVATE KEY-----", lines.last == "-----END PRIVATE KEY-----",
      let der = Data(base64Encoded: lines.dropFirst().dropLast().joined()), der.count == 48,
      Array(der.prefix(16)) == [0x30,0x2e,0x02,0x01,0x00,0x30,0x05,0x06,0x03,0x2b,0x65,0x70,0x04,0x22,0x04,0x20] else {
    throw ToolError.invalidKey
}
let packet = try V2ActorTrustAdmissionAuthoring.create(previous: read(arguments[0], limit: 4_194_304),
    expanded: read(arguments[1], limit: 4_194_304), privateKey: Data(der.suffix(32)))
try packet.write(to: URL(fileURLWithPath: arguments[3]), options: .withoutOverwriting)
print("Created signed authorization (\(packet.count) bytes); membership and placement are unchanged.")
