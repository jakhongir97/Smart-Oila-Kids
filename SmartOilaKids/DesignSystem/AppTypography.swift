import SwiftUI
import UIKit
import CoreText

enum AppTypography {
    static func unbounded(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        custom(
            family: "Unbounded",
            fallbackCandidates: ["Unbounded", "Unbounded-Variable"],
            size: size,
            fallbackWeight: weight
        )
    }

    static func sora(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        custom(
            family: "Sora",
            fallbackCandidates: ["Sora", "Sora-Variable"],
            size: size,
            fallbackWeight: weight
        )
    }

    static func roboto(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        custom(
            family: "Roboto",
            fallbackCandidates: ["Roboto", "Roboto-Variable"],
            size: size,
            fallbackWeight: weight
        )
    }

    // MARK: - Bolajon360 redesign role helpers
    // One place for the new type scale so screens don't hardcode raw sizes.
    static func title(_ size: CGFloat = 22) -> Font { unbounded(size, weight: .semibold) }
    static func heading(_ size: CGFloat = 18) -> Font { sora(size, weight: .semibold) }
    static func bodyText(_ size: CGFloat = 14) -> Font { roboto(size, weight: .regular) }
    static func bodyStrong(_ size: CGFloat = 14) -> Font { roboto(size, weight: .medium) }
    static func caption(_ size: CGFloat = 11) -> Font { roboto(size, weight: .regular) }
    static func buttonLabel(_ size: CGFloat = 16) -> Font { unbounded(size, weight: .regular) }

    private static func custom(
        family: String,
        fallbackCandidates: [String],
        size: CGFloat,
        fallbackWeight: Font.Weight
    ) -> Font {
        // Ensure font files are registered once before resolution.
        _ = registeredFontNames

        let normalizedFamily = family.lowercased()
        let dynamicCandidates = registeredFontNames
            .filter { $0.lowercased().contains(normalizedFamily) }
            .sorted()

        var candidates: [String] = []
        var visited = Set<String>()
        for candidate in fallbackCandidates + dynamicCandidates {
            if visited.insert(candidate).inserted {
                candidates.append(candidate)
            }
        }

        // Avoid applying .weight to custom variable fonts; it triggers noisy descriptor warnings in SwiftUI.
        for candidate in candidates where UIFont(name: candidate, size: size) != nil {
            return .custom(candidate, size: size)
        }

        return .system(size: size, weight: fallbackWeight)
    }

    private static let registeredFontNames: Set<String> = registerBundleFonts()
}

private extension AppTypography {
    static func registerBundleFonts() -> Set<String> {
        let bundle = Bundle.main
        let resources = ["Unbounded-Variable", "Sora-Variable", "Roboto-Variable"]
        let subdirectories: [String?] = [nil, "Fonts"]
        var discoveredNames = Set<String>()

        for resource in resources {
            for subdirectory in subdirectories {
                guard let url = bundle.url(forResource: resource, withExtension: "ttf", subdirectory: subdirectory) else {
                    continue
                }

                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)

                if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] {
                    for descriptor in descriptors {
                        if let postScript = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String {
                            discoveredNames.insert(postScript)
                        }
                        if let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String {
                            discoveredNames.insert(family)
                        }
                    }
                }
            }
        }

        return discoveredNames
    }
}
