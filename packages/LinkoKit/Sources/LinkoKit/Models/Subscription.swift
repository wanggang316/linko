import Foundation

/// An imported node subscription and the nodes it produced on last refresh.
public struct Subscription: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var url: URL
    public var lastUpdated: Date?
    public var nodes: [ProxyNode]

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        lastUpdated: Date? = nil,
        nodes: [ProxyNode] = []
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.lastUpdated = lastUpdated
        self.nodes = nodes
    }
}
