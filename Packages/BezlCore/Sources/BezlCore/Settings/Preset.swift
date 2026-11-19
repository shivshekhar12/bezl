import Foundation

/// A named, shareable look. Exported as `.bezl.json`.
public struct Preset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var look: LookSettings
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, look: LookSettings, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.look = look
        self.isBuiltIn = isBuiltIn
    }

    public static let fileExtension = "bezl.json"

    public func exportData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        var copy = self
        copy.isBuiltIn = false
        return try e.encode(copy)
    }

    /// Imports a preset; always assigns a fresh id so imports never collide.
    public static func importing(_ data: Data) throws -> Preset {
        var p = try JSONDecoder().decode(Preset.self, from: data)
        p.id = UUID()
        p.isBuiltIn = false
        p.look = p.look.sanitized
        return p
    }

    public static let builtIns: [Preset] = {
        func make(_ id: String, _ name: String, _ edit: (inout LookSettings) -> Void) -> Preset {
            var look = LookSettings()
            edit(&look)
            return Preset(id: UUID(uuidString: id)!, name: name, look: look, isBuiltIn: true)
        }
        return [
            make("00000000-0000-0000-0000-00000000E001", "Ember") {
                $0.primary = RGB(hex: 0xFF6A2B); $0.secondary = RGB(hex: 0xFF2D55)
                $0.colorSource = .manual; $0.thickness = 7; $0.glow = 0.6
            },
            make("00000000-0000-0000-0000-00000000E002", "Lagoon") {
                $0.primary = RGB(hex: 0x00C2C7); $0.secondary = RGB(hex: 0x3A6BFF)
                $0.colorSource = .manual; $0.thickness = 5; $0.glow = 0.7; $0.rotationSpeed = 1
            },
            make("00000000-0000-0000-0000-00000000E003", "Neon") {
                $0.primary = RGB(hex: 0xFF2BD6); $0.secondary = RGB(hex: 0x2BFFB1)
                $0.colorSource = .manual; $0.thickness = 3; $0.glow = 0.45; $0.beatStrength = 1
            },
            make("00000000-0000-0000-0000-00000000E004", "Paper") {
                $0.primary = RGB(hex: 0xFFE8C2); $0.secondary = RGB(hex: 0xFFC48A)
                $0.colorSource = .manual; $0.motion = .breathe; $0.thickness = 2; $0.glow = 0.35
                $0.intensity = 0.6
            },
        ]
    }()
}
