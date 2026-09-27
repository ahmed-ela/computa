import Foundation

struct LocalModelOption: Codable, Equatable, Sendable {
    let id: String
    let label: String
    let detail: String
    let highMemory: Bool
}

enum LocalModelCatalog {
    static let defaultModelID = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
    private static let visualGroundingModelIDs: Set<String> = [
        "lmstudio-community/Qwen3.5-9B-MLX-4bit",
        "lmstudio-community/Qwen3.5-4B-MLX-4bit",
    ]

    static let options: [LocalModelOption] = [
        LocalModelOption(
            id: "mlx-community/Qwen3.8-27B-4bit",
            label: "Qwen3.8-27B · MLX 4-bit",
            detail: "16.1 GB model file. Requires an explicitly configured external local server; not supported by the built-in MLX backend.",
            highMemory: false
        ),
        LocalModelOption(
            id: "lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit",
            label: "Qwen3.6-35B-A3B · MLX 4-bit",
            detail: "20.4 GB model file. Very tight on this 24 GB Mac. Requires an external local server; not supported by the built-in MLX backend.",
            highMemory: true
        ),
        LocalModelOption(
            id: "lmstudio-community/Qwen3.5-9B-MLX-4bit",
            label: "Qwen3.5-9B · MLX 4-bit",
            detail: "5.98 GB model files. Runs in Mactopus's headless MLX backend using existing local weights.",
            highMemory: false
        ),
        LocalModelOption(
            id: "lmstudio-community/Qwen3.5-4B-MLX-4bit",
            label: "Qwen3.5-4B · MLX 4-bit",
            detail: "3.06 GB model files. Fast, lower-memory default. Runs in Mactopus's headless MLX backend using existing local weights.",
            highMemory: false
        ),
    ]

    static func option(for id: String) -> LocalModelOption? {
        options.first { $0.id == id }
    }

    /// The resident three-model visual cascade needs several additional GB of
    /// unified memory. Keep it off for the 27B and 35B language models on the
    /// supported 24 GB machine instead of relying on memory pressure or OOM.
    static func supportsResidentVisualGrounding(_ id: String) -> Bool {
        visualGroundingModelIDs.contains(id)
    }

    static func supportsHeadlessMLX(_ id: String) -> Bool {
        visualGroundingModelIDs.contains(id)
    }
}
