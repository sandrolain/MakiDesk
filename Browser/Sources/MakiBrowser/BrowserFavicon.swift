import CoreGraphics
import Foundation
import ImageIO

struct BrowserFavicon: Sendable {
    var color: BrowserColor
    var data: Data
}

/// Downloads and decodes a favicon off the main thread. Only the site's own
/// icon is fetched, in an ephemeral session, with a small size cap; no remote
/// favicon service is involved.
@MainActor
final class BrowserFaviconProvider {
    private let session: URLSession
    private var cache: [URL: BrowserFavicon] = [:]
    private var order: [URL] = []
    private let cacheLimit = 100

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
    }

    func favicon(at url: URL) async -> BrowserFavicon? {
        if let cached = cache[url] {
            touch(url)
            return cached
        }

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode) == false {
                return nil
            }
            guard data.count <= 512 * 1024 else { return nil }

            let result = await Task.detached(priority: .utility) {
                Self.decode(data)
            }.value
            guard let result else { return nil }

            cache[url] = result
            order.append(url)
            while order.count > cacheLimit {
                let removed = order.removeFirst()
                cache.removeValue(forKey: removed)
            }
            return result
        } catch {
            return nil
        }
    }

    private func touch(_ url: URL) {
        order.removeAll { $0 == url }
        order.append(url)
    }

    nonisolated private static func decode(_ data: Data) -> BrowserFavicon? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return BrowserFavicon(color: dominantColor(of: image), data: data)
    }

    nonisolated private static func dominantColor(of image: CGImage) -> BrowserColor {
        let width = 32
        let height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return BrowserColor(red: 0.42, green: 0.52, blue: 0.68) }

        var buckets: [(weight: Double, red: Double, green: Double, blue: Double)] =
            Array(repeating: (0, 0, 0, 0), count: 12)

        var index = 0
        while index < pixels.count {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            let a = Double(pixels[index + 3]) / 255
            index += 4

            guard a > 0.15 else { continue }
            let maxValue = max(r, g, b)
            let minValue = min(r, g, b)
            let saturation = maxValue == 0 ? 0 : (maxValue - minValue) / maxValue
            guard maxValue > 0.10, saturation > 0.12 else { continue }
            guard !(maxValue > 0.92 && saturation < 0.10) else { continue }

            let hue = hueValue(red: r, green: g, blue: b, maxValue: maxValue, minValue: minValue)
            let bucket = min(11, Int(hue * 12))
            let weight = a * saturation
            buckets[bucket].weight += weight
            buckets[bucket].red += r * weight
            buckets[bucket].green += g * weight
            buckets[bucket].blue += b * weight
        }

        guard let best = buckets.max(by: { $0.weight < $1.weight }), best.weight > 0 else {
            return BrowserColor(red: 0.42, green: 0.52, blue: 0.68)
        }

        let red = best.red / best.weight
        let green = best.green / best.weight
        let blue = best.blue / best.weight
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let saturation = maxValue == 0 ? 0 : (maxValue - minValue) / maxValue
        let hue = hueValue(red: red, green: green, blue: blue,
                           maxValue: maxValue, minValue: minValue)
        return BrowserColor.hsb(hue: hue,
                                saturation: min(0.80, max(0.42, saturation)),
                                brightness: min(0.72, max(0.42, maxValue)))
    }

    nonisolated private static func hueValue(red: Double, green: Double, blue: Double,
                                             maxValue: Double, minValue: Double) -> Double {
        let delta = maxValue - minValue
        guard delta > 0 else { return 0 }
        let hue: Double
        if maxValue == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxValue == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        let normalized = hue < 0 ? hue + 6 : hue
        return (normalized / 6).truncatingRemainder(dividingBy: 1)
    }
}
