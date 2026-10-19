import Foundation
import CoreGraphics

struct WorkspaceWindow: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var appName: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var tint: String
    var systemID: String?

    init(id: UUID = UUID(), title: String, appName: String,
         x: Double, y: Double, width: Double = 300, height: Double = 190,
         tint: String = "blue", systemID: String? = nil) {
        self.id = id
        self.title = title
        self.appName = appName
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.tint = tint
        self.systemID = systemID
    }
}

struct Viewport {
    var origin = CGPoint.zero
    var zoom: CGFloat = 1

    func canvasPoint(from world: CGPoint) -> CGPoint {
        CGPoint(x: (world.x - origin.x) * zoom,
                y: (world.y - origin.y) * zoom)
    }

    func worldPoint(from canvas: CGPoint) -> CGPoint {
        CGPoint(x: canvas.x / zoom + origin.x,
                y: canvas.y / zoom + origin.y)
    }
}
