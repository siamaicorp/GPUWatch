import SwiftUI

/// The SIAM.AI mark.
///
/// Ships with a transparent keyed copy of the brand artwork so it can sit on
/// either the light or the dark surface without a white plate behind it. If the
/// asset is ever missing — a stripped bundle, a test host — the view falls back
/// to a symbol rather than drawing an empty box, because a broken image in a
/// header looks like a rendering bug.
struct BrandLogo: View {
    var height: CGFloat = 22

    var body: some View {
        Group {
            if let image = BrandAsset.logo(height: height) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: height)
            } else {
                Image(systemName: "waveform.path")
                    .font(.system(size: height * 0.7, weight: .semibold))
                    .foregroundStyle(DS.Status.brand)
                    .frame(height: height)
            }
        }
        .accessibilityLabel("SIAM.AI")
    }
}

/// Locates the brand artwork.
///
/// The images are a SwiftPM resource, so they live in the module bundle. In the
/// assembled `.app` that bundle sits in `Contents/Resources`, which
/// `Bundle.module` already searches; the `Bundle.main` lookup covers a bundle
/// that was assembled by hand without the resource bundle beside it.
enum BrandAsset {
    static func logo(height: CGFloat) -> NSImage? {
        // Two resolutions so the mark stays crisp on a Retina display.
        let name = height >= 32 ? "siamai-logo-528" : "siamai-logo-88"
        return image(named: name)
    }

    private static var cache: [String: NSImage] = [:]

    private static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        for bundle in [Bundle.module, Bundle.main] {
            if let url = bundle.url(forResource: name, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                cache[name] = image
                return image
            }
        }
        return nil
    }
}
