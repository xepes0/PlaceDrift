import Foundation

struct MapShareCoordinate: Sendable {
    let latitude: Double
    let longitude: Double
}

enum AppleMapsCoordinateParser {
    static func parse(url: URL) -> MapShareCoordinate? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let keys = ["coordinate", "ll", "center"]

        for key in keys {
            if let value = components.queryItems?.first(where: { $0.name.lowercased() == key })?.value,
               let coordinate = parsePair(value) {
                return coordinate
            }
        }

        return nil
    }

    static func parsePair(_ value: String) -> MapShareCoordinate? {
        let parts = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",", maxSplits: 1)
        guard
            parts.count == 2,
            let latitude = Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
            let longitude = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
            latitude.isFinite,
            longitude.isFinite,
            (-90.0...90.0).contains(latitude),
            (-180.0...180.0).contains(longitude)
        else { return nil }

        return MapShareCoordinate(latitude: latitude, longitude: longitude)
    }
}

final class AppleMapsRedirectResolver: NSObject, URLSessionTaskDelegate {
    private var completion: ((MapShareCoordinate?) -> Void)?
    private var session: URLSession?
    private var finished = false

    func resolve(_ url: URL, completion: @escaping (MapShareCoordinate?) -> Void) {
        self.completion = completion
        self.finished = false

        if let coordinate = AppleMapsCoordinateParser.parse(url: url) {
            finish(coordinate)
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10

        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        self.session = session

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] _, response, _ in
            guard let self else { return }
            let coordinate = response?.url.flatMap(AppleMapsCoordinateParser.parse(url:))
            self.finish(coordinate)
        }.resume()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let url = request.url,
           let coordinate = AppleMapsCoordinateParser.parse(url: url) {
            finish(coordinate)
            completionHandler(nil)
            return
        }

        completionHandler(request)
    }

    private func finish(_ coordinate: MapShareCoordinate?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            let completion = self.completion
            self.completion = nil
            self.session?.invalidateAndCancel()
            self.session = nil
            completion?(coordinate)
        }
    }
}
