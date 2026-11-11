import Foundation

public enum DockerFormatting {
    /// Docker prints sizes with decimal units (`900MB`, `1.02GB`, `475kB`).
    /// This parser is for display totals and prune estimates, never for exact
    /// accounting; a value it cannot read is `nil`, not zero.
    public static func bytes(from text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed.uppercased() != "N/A" else { return nil }
        var number = ""
        var unit = ""
        for character in trimmed {
            if character.isNumber || character == "." || character == "," {
                if unit.isEmpty { number.append(character) }
            } else {
                unit.append(character)
            }
        }
        let normalized = number.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized) else { return nil }
        let multiplier: Double
        switch unit.trimmingCharacters(in: .whitespaces).uppercased() {
        case "", "B": multiplier = 1
        case "KB": multiplier = 1_000
        case "MB": multiplier = 1_000_000
        case "GB": multiplier = 1_000_000_000
        case "TB": multiplier = 1_000_000_000_000
        case "KIB": multiplier = 1_024
        case "MIB": multiplier = 1_048_576
        case "GIB": multiplier = 1_073_741_824
        case "TIB": multiplier = 1_099_511_627_776
        default: return nil
        }
        return Int64((value * multiplier).rounded())
    }

    public static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        if bytes == 0 { return "0B" }
        let units = ["B", "kB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1_000, index < units.count - 1 {
            value /= 1_000
            index += 1
        }
        if index == 0 { return "\(Int(value))B" }
        let digits = value >= 100 ? 0 : value >= 10 ? 1 : 2
        return String(format: "%.\(digits)f%@", value, units[index])
    }

    /// A tolerant, display-only parse of `docker ps` port strings. Handles
    /// `127.0.0.1:8888->8080/tcp`, `[::]:8080->80/tcp`, `8080/tcp`, and lists.
    public static func ports(from text: String) -> [DockerPortMapping] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed != "<none>" else { return [] }
        return trimmed
            .split(separator: ",", omittingEmptySubsequences: true)
            .compactMap { parsePort(String($0).trimmingCharacters(in: .whitespaces)) }
    }

    private static func parsePort(_ text: String) -> DockerPortMapping? {
        guard text.isEmpty == false else { return nil }
        let arrow = "->"
        if let range = text.range(of: arrow) {
            let hostPart = String(text[..<range.lowerBound])
            let containerPart = String(text[range.upperBound...])
            guard let container = parseContainerPort(containerPart) else { return nil }
            let (ip, port) = parseHostPort(hostPart)
            return DockerPortMapping(hostIP: ip, hostPort: port,
                                     containerPort: container.port, proto: container.proto)
        }
        guard let container = parseContainerPort(text) else { return nil }
        return DockerPortMapping(hostIP: nil, hostPort: nil,
                                 containerPort: container.port, proto: container.proto)
    }

    private static func parseContainerPort(_ text: String) -> (port: Int, proto: String)? {
        let parts = text.split(separator: "/", maxSplits: 1)
        guard let port = Int(parts[0]) else { return nil }
        let proto = parts.count == 2 ? String(parts[1]) : "tcp"
        return (port, proto)
    }

    private static func parseHostPort(_ text: String) -> (String?, Int?) {
        guard text.isEmpty == false else { return (nil, nil) }
        guard let colon = text.lastIndex(of: ":") else {
            return (nil, Int(text))
        }
        let ip = String(text[..<colon])
        let portText = String(text[text.index(after: colon)...])
        return (ip.isEmpty ? nil : ip, Int(portText))
    }

    public static func relativeAge(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    /// A compact label for a container's state; the model keeps the raw value.
    public static func healthLabel(_ health: DockerHealth) -> String? {
        switch health {
        case .healthy: return "healthy"
        case .unhealthy: return "unhealthy"
        case .starting: return "starting"
        default: return nil
        }
    }
}
