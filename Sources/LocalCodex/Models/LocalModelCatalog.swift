import Foundation

struct LocalModelOption: Codable, Equatable, Sendable {
    let id: String
    let label: String
    let detail: String
    let highMemory: Bool
}

enum LocalModelCatalog {
    static let defaultModelID = "mlx-community/Qwen3.8-27B-4bit"
    private static let visualGroundingModelIDs: Set<String> = [
        "lmstudio-community/Qwen3.5-9B-MLX-4bit",
        "lmstudio-community/Qwen3.5-4B-MLX-4bit",
    ]

    static let options: [LocalModelOption] = [
        LocalModelOption(
            id: defaultModelID,
            label: "Qwen3.8-27B · MLX 4-bit",
            detail: "16.1 GB model file. Current validated LocalCodex model.",
            highMemory: false
        ),
        LocalModelOption(
            id: "lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit",
            label: "Qwen3.6-35B-A3B · MLX 4-bit",
            detail: "20.4 GB model file. Very tight on this 24 GB Mac; download and load in LM Studio separately.",
            highMemory: true
        ),
        LocalModelOption(
            id: "lmstudio-community/Qwen3.5-9B-MLX-4bit",
            label: "Qwen3.5-9B · MLX 4-bit",
            detail: "5.98 GB model files. Lower-memory option; download and load in LM Studio separately.",
            highMemory: false
        ),
        LocalModelOption(
            id: "lmstudio-community/Qwen3.5-4B-MLX-4bit",
            label: "Qwen3.5-4B · MLX 4-bit",
            detail: "3.06 GB model files. Smallest option; download and load in LM Studio separately.",
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
}
