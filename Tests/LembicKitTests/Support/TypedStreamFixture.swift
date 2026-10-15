import Foundation

/// Builds `attributedBody` blobs in the typedstream format Messages writes.
enum TypedStreamFixture {
    static func body(_ runs: [(String, [String: Any])]) -> Data {
        let text = NSMutableAttributedString()
        for (string, attributes) in runs {
            let keyed = Dictionary(
                uniqueKeysWithValues: attributes.map { (NSAttributedString.Key($0.key), $0.value) })
            text.append(NSAttributedString(string: string, attributes: keyed))
        }
        return (Archiver() as any ArchiverShim).archive(text)
    }

    static func body(_ text: String) -> Data { body([(text, [:])]) }
}

private protocol ArchiverShim {
    func archive(_ root: Any) -> Data
}

// The protocol call keeps NSArchiver's deprecation warning out of every test.
private struct Archiver: ArchiverShim {
    @available(macOS, deprecated: 10.13)
    func archive(_ root: Any) -> Data { NSArchiver.archivedData(withRootObject: root) }
}
