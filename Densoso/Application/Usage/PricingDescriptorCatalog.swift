import Foundation

enum PricingDescriptorCatalog {
    /// Conservative, versioned estimates from the published provider price lists.
    /// Cached tokens use the non-cached rate as an upper-bound estimate. No
    /// descriptor is supplied for Qwen ASR or vision, so those costs stay unknown.
    static let phase3Conservative = StaticPricingDescriptorSource(
        descriptors: [
            PricingDescriptor(
                provider: .deepSeek,
                model: "deepseek-flash",
                capability: .text,
                version: "deepseek-2026-09-10-peak-upper-bound",
                origin: .publishedPriceList(documentID: "deepseek-pricing", checkedOn: "2026-10-23"),
                currency: "USD",
                inputMicrosPerMillionTokens: 300_000,
                cachedInputMicrosPerMillionTokens: 300_000,
                outputMicrosPerMillionTokens: 1_200_000,
                audioMicrosPerSecond: nil
            ),
            PricingDescriptor(
                provider: .qwen,
                model: "qwen-flash",
                capability: .text,
                version: "qwen-flash-beijing-128k-2026-10-23-upper-bound",
                origin: .publishedPriceList(documentID: "qwen-flash-pricing", checkedOn: "2026-10-23"),
                currency: "CNY",
                inputMicrosPerMillionTokens: 150_000,
                cachedInputMicrosPerMillionTokens: 150_000,
                outputMicrosPerMillionTokens: 1_500_000,
                audioMicrosPerSecond: nil
            ),
        ]
    )
}
