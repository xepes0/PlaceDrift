import Foundation

struct MapShareCoordinate: Sendable {
    let latitude: Double
    let longitude: Double
}

enum MapProvider: Sendable {
    case apple
    case amap
    case baidu
    case unknown
}

enum MapShareCoordinateParser {
    private static let a = 6378245.0
    private static let ee = 0.00669342162296594323
    private static let xPi = Double.pi * 3000.0 / 180.0

    private static let mcBand: [Double] = [
        12890594.86, 8362377.87, 5591021.0, 3481989.83, 1678043.12, 0.0,
    ]

    private static let mc2ll: [[Double]] = [
        [1.410526172116255e-8, 0.00000898305509648872, -1.9939833816331, 200.9824383106796, -187.2403703815547, 91.6087516669843, -23.38765649603339, 2.57121317296198, -0.03801003308653, 17337981.2],
        [-7.435856389565537e-9, 0.000008983055097726239, -0.78625201886289, 96.32687599759846, -1.85204757529826, -59.36935905485877, 47.40033549296737, -16.50741931063887, 2.28786674699375, 10260144.86],
        [-3.030883460898826e-8, 0.00000898305509983578, 0.30071316287616, 59.74293618442277, 7.357984074871, -25.38371002664745, 13.45380521110908, -3.29883767235584, 0.32710905363475, 6856817.37],
        [-1.981981304930552e-8, 0.000008983055099779535, 0.03278182852591, 40.31678527705744, 0.65659298677257, -4.44255534477492, 0.85341911805263, 0.12923347998204, -0.04625736007561, 4482777.06],
        [3.09191371068437e-9, 0.000008983055096812155, 0.00006995724062, 23.10934304144901, -0.00023663490511, -0.6321817810242, -0.00663494467273, 0.03430082397953, -0.00466043876332, 2555164.4],
        [2.890871144776878e-9, 0.000008983055095805407, -3.068298e-8, 7.47137025468032, -0.00000353937994, -0.02145144861037, -0.00001234426596, 0.00010322952773, -0.00000323890364, 826088.5],
    ]

    static func provider(for url: URL) -> MapProvider {
        let host = (url.host ?? "").lowercased()
        let scheme = (url.scheme ?? "").lowercased()

        if host.contains("amap.com") || host.contains("gaode.com") || scheme.contains("amap") {
            return .amap
        }
        if host.contains("baidu.com") || scheme.contains("baidu") {
            return .baidu
        }
        if host.contains("apple.com") || host.contains("maps.apple") || scheme == "maps" {
            return .apple
        }
        return .unknown
    }

    static func parse(url: URL) -> MapShareCoordinate? {
        parse(text: url.absoluteString, providerHint: provider(for: url), allowBare: false)
    }

    static func parse(text: String, providerHint: MapProvider = .unknown, allowBare: Bool = false) -> MapShareCoordinate? {
        guard !text.isEmpty else { return nil }

        // Amap short-link redirects can contain nested percent-encoding. Keep the
        // original string and progressively decoded variants so both literal
        // commas and %2C / %252C forms can be recognized.
        var candidates = [text]
        var current = text
        for _ in 0..<3 {
            guard let decoded = current.removingPercentEncoding, decoded != current else { break }
            candidates.append(decoded)
            current = decoded
        }

        for candidate in candidates {
            let provider = providerHint == .unknown ? providerFromText(candidate) : providerHint

            if let coordinate = parseApple(candidate, provider: provider) {
                return coordinate
            }
            if let coordinate = parseAmap(candidate, provider: provider) {
                return coordinate
            }
            if let coordinate = parseBaidu(candidate, provider: provider) {
                return coordinate
            }
            if allowBare,
               let pair = firstMatch(#"(-?\d{1,3}\.\d{4,})\s*(?:,|%2C)\s*(-?\d{1,3}\.\d{4,})"#, in: candidate),
               let latitude = Double(pair[1]),
               let longitude = Double(pair[2]),
               let validated = validated(latitude: latitude, longitude: longitude) {
                return validated
            }
        }
        return nil
    }

    private static func providerFromText(_ text: String) -> MapProvider {
        let lower = text.lowercased()
        if lower.contains("amap.com") || lower.contains("gaode.com") || lower.contains("amapuri:") {
            return .amap
        }
        if lower.contains("baidu.com") || lower.contains("baidumap:") {
            return .baidu
        }
        if lower.contains("maps.apple") || lower.contains("apple.com/maps") {
            return .apple
        }
        return .unknown
    }

    private static func parseApple(_ text: String, provider: MapProvider) -> MapShareCoordinate? {
        guard provider == .apple || provider == .unknown else { return nil }
        guard let match = firstMatch(#"(?:^|[?&])(?:coordinate|ll|sll|center)=(-?\d{1,3}(?:\.\d+)?)(?:,|%2C)(-?\d{1,3}(?:\.\d+)?)"#, in: text),
              let latitude = Double(match[1]),
              let longitude = Double(match[2]) else { return nil }

        return validated(latitude: latitude, longitude: longitude)
    }

    private static func parseAmap(_ text: String, provider: MapProvider) -> MapShareCoordinate? {
        guard provider == .amap else { return nil }

        if let match = firstMatch(#"(?:^|[?&])p=[^,&%]*(?:,|%2C)(-?\d{1,3}(?:\.\d+)?)(?:,|%2C)(-?\d{1,3}(?:\.\d+)?)"#, in: text),
           let latitude = Double(match[1]),
           let longitude = Double(match[2]) {
            return fromGCJ02(latitude: latitude, longitude: longitude)
        }

        if let match = firstMatch(#"(?:^|[?&])q=(-?\d{1,3}(?:\.\d+)?)(?:,|%2C)(-?\d{1,3}(?:\.\d+)?)"#, in: text),
           let latitude = Double(match[1]),
           let longitude = Double(match[2]) {
            return fromGCJ02(latitude: latitude, longitude: longitude)
        }

        if let match = firstMatch(#"(?:^|[?&])(?:lnglat|position)=(-?\d{1,3}(?:\.\d+)?)(?:,|%2C)(-?\d{1,3}(?:\.\d+)?)"#, in: text),
           let longitude = Double(match[1]),
           let latitude = Double(match[2]) {
            return fromGCJ02(latitude: latitude, longitude: longitude)
        }

        return nil
    }

    private static func parseBaidu(_ text: String, provider: MapProvider) -> MapShareCoordinate? {
        guard provider == .baidu else { return nil }

        if let match = firstMatch(#"(?:^|[?&])(?:location|latlng)=(-?\d{1,3}(?:\.\d+)?)(?:,|%2C)(-?\d{1,3}(?:\.\d+)?)"#, in: text),
           let latitude = Double(match[1]),
           let longitude = Double(match[2]) {
            return fromBD09(latitude: latitude, longitude: longitude)
        }

        if let match = firstMatch(#"@(-?\d{6,9}(?:\.\d+)?)(?:,|%2C)(-?\d{6,9}(?:\.\d+)?)"#, in: text),
           let x = Double(match[1]),
           let y = Double(match[2]),
           let bd09 = bd09mcToBd09(x: x, y: y) {
            return fromBD09(latitude: bd09.latitude, longitude: bd09.longitude)
        }

        if let match = firstMatch(#"\"x\"\s*:\s*\"?(-?\d+(?:\.\d+)?)\"?\s*,\s*\"y\"\s*:\s*\"?(-?\d+(?:\.\d+)?)\"?"#, in: text),
           let x = Double(match[1]),
           let y = Double(match[2]),
           abs(x) > 100_000,
           abs(y) > 100_000,
           let bd09 = bd09mcToBd09(x: x, y: y) {
            return fromBD09(latitude: bd09.latitude, longitude: bd09.longitude)
        }

        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : nsText.substring(with: range)
        }
    }

    private static func validated(latitude: Double, longitude: Double) -> MapShareCoordinate? {
        guard latitude.isFinite,
              longitude.isFinite,
              (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude) else { return nil }
        return MapShareCoordinate(latitude: latitude, longitude: longitude)
    }

    private static func fromGCJ02(latitude: Double, longitude: Double) -> MapShareCoordinate? {
        let wgs84 = gcj02ToWgs84(latitude: latitude, longitude: longitude)
        return validated(latitude: wgs84.latitude, longitude: wgs84.longitude)
    }

    private static func fromBD09(latitude: Double, longitude: Double) -> MapShareCoordinate? {
        let gcj = bd09ToGcj02(latitude: latitude, longitude: longitude)
        let wgs84 = gcj02ToWgs84(latitude: gcj.latitude, longitude: gcj.longitude)
        return validated(latitude: wgs84.latitude, longitude: wgs84.longitude)
    }

    private static func outOfChina(latitude: Double, longitude: Double) -> Bool {
        longitude < 72.004 || longitude > 137.8347 || latitude < 0.8293 || latitude > 55.8271
    }

    private static func transformLatitude(x: Double, y: Double) -> Double {
        var result = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * Double.pi) + 20.0 * sin(2.0 * x * Double.pi)) * 2.0 / 3.0
        result += (20.0 * sin(y * Double.pi) + 40.0 * sin(y / 3.0 * Double.pi)) * 2.0 / 3.0
        result += (160.0 * sin(y / 12.0 * Double.pi) + 320.0 * sin(y * Double.pi / 30.0)) * 2.0 / 3.0
        return result
    }

    private static func transformLongitude(x: Double, y: Double) -> Double {
        var result = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * Double.pi) + 20.0 * sin(2.0 * x * Double.pi)) * 2.0 / 3.0
        result += (20.0 * sin(x * Double.pi) + 40.0 * sin(x / 3.0 * Double.pi)) * 2.0 / 3.0
        result += (150.0 * sin(x / 12.0 * Double.pi) + 300.0 * sin(x / 30.0 * Double.pi)) * 2.0 / 3.0
        return result
    }

    private static func gcj02ToWgs84(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        guard !outOfChina(latitude: latitude, longitude: longitude) else {
            return (latitude, longitude)
        }

        var dLat = transformLatitude(x: longitude - 105.0, y: latitude - 35.0)
        var dLon = transformLongitude(x: longitude - 105.0, y: latitude - 35.0)
        let radLat = latitude / 180.0 * Double.pi
        var magic = sin(radLat)
        magic = 1.0 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = dLat * 180.0 / ((a * (1.0 - ee)) / (magic * sqrtMagic) * Double.pi)
        dLon = dLon * 180.0 / (a / sqrtMagic * cos(radLat) * Double.pi)
        let mappedLat = latitude + dLat
        let mappedLon = longitude + dLon
        return (latitude * 2.0 - mappedLat, longitude * 2.0 - mappedLon)
    }

    private static func bd09ToGcj02(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        let x = longitude - 0.0065
        let y = latitude - 0.006
        let z = sqrt(x * x + y * y) - 0.00002 * sin(y * xPi)
        let theta = atan2(y, x) - 0.000003 * cos(x * xPi)
        return (z * sin(theta), z * cos(theta))
    }

    private static func bd09mcToBd09(x: Double, y: Double) -> (latitude: Double, longitude: Double)? {
        let absoluteY = abs(y)
        guard let index = mcBand.firstIndex(where: { absoluteY >= $0 }) else { return nil }
        let c = mc2ll[index]
        let xFactor = abs(x)
        let yFactor = absoluteY / c[9]

        var longitude = c[0] + c[1] * xFactor
        var latitude = c[2]
        latitude += c[3] * yFactor
        latitude += c[4] * pow(yFactor, 2)
        latitude += c[5] * pow(yFactor, 3)
        latitude += c[6] * pow(yFactor, 4)
        latitude += c[7] * pow(yFactor, 5)
        latitude += c[8] * pow(yFactor, 6)

        longitude *= x < 0 ? -1 : 1
        latitude *= y < 0 ? -1 : 1
        return (latitude, longitude)
    }
}

final class MapShareRedirectResolver: NSObject, URLSessionTaskDelegate {
    private var completion: ((MapShareCoordinate?) -> Void)?
    private var session: URLSession?
    private var finished = false
    private var originalProvider: MapProvider = .unknown

    func resolve(_ url: URL, completion: @escaping (MapShareCoordinate?) -> Void) {
        self.completion = completion
        self.finished = false
        self.originalProvider = MapShareCoordinateParser.provider(for: url)

        if let coordinate = MapShareCoordinateParser.parse(url: url) {
            finish(coordinate)
            return
        }

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            finish(nil)
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
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/24A5370h Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh-Hans;q=0.9,en;q=0.5", forHTTPHeaderField: "Accept-Language")

        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }

            if let http = response as? HTTPURLResponse,
               let rawLocation = http.value(forHTTPHeaderField: "Location"),
               let coordinate = self.coordinate(fromRedirectLocation: rawLocation, baseURL: http.url) {
                self.finish(coordinate)
                return
            }

            if let responseURL = response?.url {
                let provider = MapShareCoordinateParser.provider(for: responseURL)
                let hint = provider == .unknown ? self.originalProvider : provider
                if let coordinate = MapShareCoordinateParser.parse(
                    text: responseURL.absoluteString,
                    providerHint: hint,
                    allowBare: false
                ) {
                    self.finish(coordinate)
                    return
                }
            }

            if let data {
                let limited = data.prefix(512 * 1024)
                if let body = String(data: limited, encoding: .utf8) {
                    let responseProvider = response?.url.map(MapShareCoordinateParser.provider(for:)) ?? self.originalProvider
                    let provider = responseProvider == .unknown ? self.originalProvider : responseProvider
                    if let coordinate = MapShareCoordinateParser.parse(text: body, providerHint: provider, allowBare: false) {
                        self.finish(coordinate)
                        return
                    }
                }
            }

            self.finish(nil)
        }.resume()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let rawLocation = response.value(forHTTPHeaderField: "Location"),
           let coordinate = coordinate(fromRedirectLocation: rawLocation, baseURL: response.url) {
            finish(coordinate)
            completionHandler(nil)
            return
        }

        if let url = request.url {
            let provider = MapShareCoordinateParser.provider(for: url)
            let hint = provider == .unknown ? originalProvider : provider
            if let coordinate = MapShareCoordinateParser.parse(
                text: url.absoluteString,
                providerHint: hint,
                allowBare: false
            ) {
                finish(coordinate)
                completionHandler(nil)
                return
            }
        }

        completionHandler(request)
    }

    private func coordinate(fromRedirectLocation rawLocation: String, baseURL: URL?) -> MapShareCoordinate? {
        if let coordinate = MapShareCoordinateParser.parse(
            text: rawLocation,
            providerHint: originalProvider,
            allowBare: false
        ) {
            return coordinate
        }

        if let baseURL,
           let absoluteURL = URL(string: rawLocation, relativeTo: baseURL)?.absoluteURL {
            let provider = MapShareCoordinateParser.provider(for: absoluteURL)
            let hint = provider == .unknown ? originalProvider : provider
            return MapShareCoordinateParser.parse(
                text: absoluteURL.absoluteString,
                providerHint: hint,
                allowBare: false
            )
        }

        return nil
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
