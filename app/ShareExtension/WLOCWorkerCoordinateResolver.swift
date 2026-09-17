import Foundation

/// Mirrors the proven WLOC Shortcut path: send the complete shared text to
/// /api/parse instead of reducing the share payload to one URL first.
final class WLOCWorkerCoordinateResolver {
    private let endpoint = URL(string: "https://wloc.xepesw.workers.dev/api/parse")!
    private var task: URLSessionDataTask?

    func resolve(rawSharedInput: String, completion: @escaping (MapShareCoordinate?) -> Void) {
        let input = rawSharedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            completion(nil)
            return
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "u", value: input),
        ]
        guard let url = components?.url else {
            completion(nil)
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        task = session.dataTask(with: request) { data, response, _ in
            defer { session.finishTasksAndInvalidate() }

            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                let data,
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let latitude = Self.doubleValue(object["lat"]),
                let longitude = Self.doubleValue(object["lon"]),
                latitude.isFinite,
                longitude.isFinite,
                (-90.0...90.0).contains(latitude),
                (-180.0...180.0).contains(longitude)
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let coordinate = MapShareCoordinate(latitude: latitude, longitude: longitude)
            DispatchQueue.main.async { completion(coordinate) }
        }
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
