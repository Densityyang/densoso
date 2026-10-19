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
                version: "deepseek-2026-09-01-conservative",
                origin: .publishedPriceList(documentID: "deepseek-pricing", checkedOn: "2026-09-01"),
                currency: "USD",
                inputMicrosPerMillionTokens: 440_000,
                cachedInputMicrosPerMillionTokens: 440_000,
                outputMicrosPerMillionTokens: 1_320_000,
                audioMicrosPerSecond: nil
            ),
            PricingDescriptor(
                provider: .qwen,
                model: "qwen-flash",
                capability: .text,
                version: "qwen-flash-2026-09-01-conservative",
                origin: .publishedPriceList(documentID: "qwen-flash-pricing", checkedOn: "2026-09-01"),
                currency: "CNY",
                inputMicrosPerMillionTokens: 150_000,
                cachedInputMicrosPerMillionTokens: 150_000,
                outputMicrosPerMillionTokens: 1_500_000,
                audioMicrosPerSecond: nil
            ),
        ]
    )
}
