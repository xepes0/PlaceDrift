import Foundation
import UIKit

@MainActor
final class PlaceDriftShortcutMapResolver {
    private var redirectResolver: MapShareRedirectResolver?
    private var baiduResolver: BaiduWebViewCoordinateResolver?

    func resolve(_ rawInput: String) async -> MapShareCoordinate? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if let direct = MapShareCoordinateParser.parse(
            text: input,
            providerHint: .unknown,
            allowBare: true
        ) {
            return direct
        }

        let urls = Self.extractURLs(from: input)
        for url in urls {
            if let direct = MapShareCoordinateParser.parse(url: url) {
                return direct
            }
        }

        for url in urls {
            if let resolved = await resolveRedirect(url) {
                return resolved
            }
        }

        if let baiduURL = urls.first(where: { MapShareCoordinateParser.provider(for: $0) == .baidu }),
           let container = await activeContainerView(),
           let resolved = await resolveBaidu(baiduURL, in: container) {
            return resolved
        }

        return nil
    }

    private func resolveRedirect(_ url: URL) async -> MapShareCoordinate? {
        await withCheckedContinuation { continuation in
            let resolver = MapShareRedirectResolver()
            redirectResolver = resolver
            resolver.resolve(url) { [weak self] coordinate in
                Task { @MainActor in
                    self?.redirectResolver = nil
                    continuation.resume(returning: coordinate)
                }
            }
        }
    }

    private func resolveBaidu(_ url: URL, in container: UIView) async -> MapShareCoordinate? {
        await withCheckedContinuation { continuation in
            let resolver = BaiduWebViewCoordinateResolver()
            baiduResolver = resolver
            resolver.resolve(url, in: container) { [weak self] coordinate in
                Task { @MainActor in
                    self?.baiduResolver = nil
                    continuation.resume(returning: coordinate)
                }
            }
        }
    }

    private func activeContainerView() async -> UIView? {
        for _ in 0..<25 {
            if let view = Self.currentRootView() {
                return view
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private static func currentRootView() -> UIView? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive {
            if let window = scene.windows.first(where: { $0.isKeyWindow }),
               let root = window.rootViewController?.view {
                return root
            }
            if let root = scene.windows.first?.rootViewController?.view {
                return root
            }
        }
        return nil
    }

    private static func extractURLs(from text: String) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()

        if let whole = URL(string: text), whole.scheme != nil, seen.insert(whole.absoluteString).inserted {
            urls.append(whole)
        }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let url = match?.url else { return }
                if seen.insert(url.absoluteString).inserted {
                    urls.append(url)
                }
            }
        }
        return urls
    }
}
