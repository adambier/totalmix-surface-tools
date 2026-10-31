import Foundation
#if canImport(TotalMixOSC)
import TotalMixOSC
#endif

/// Which channels a surface's strips walk through.
public enum ViewKind: Hashable, Codable, Sendable {
    /// Inputs and playbacks: the channels whose levels go into submixes.
    case sources
    /// Outputs: their own faders, monitoring outputs first, then sends.
    case outputs
}

/// The order of the channels, and which ones a performance leaves out, as chosen in the app.
/// TotalMix cannot reorder its channels; this can, in any order (playbacks among inputs, for
/// example).
///
/// For each view, the strips show:
/// 1. the channels in the chosen order, in that order;
/// 2. then any other channel, in TotalMix's order: one not yet placed, such as a channel just
///    unhidden in TotalMix or one of a different interface, so that none goes missing;
/// 3. but never a channel the layout hides, or one TotalMix hides from this OSC remote.
///
/// In the outputs view the assigned monitoring outputs always come before the sends; the chosen
/// order applies within each group. With no chosen order, the monitoring outputs follow the order
/// of `MonitoringRole` (Main Out, Main Out B, Phones 1–4, cue).
public struct PerformanceLayout: Hashable, Codable, Sendable {
    /// The sources (inputs and playbacks), in the order chosen; empty for TotalMix's order.
    public var sourceOrder: [ChannelRef]
    /// The outputs, in the order chosen; empty for TotalMix's order.
    public var outputOrder: [ChannelRef]
    /// Channels the performance leaves out, of either view.
    public var hidden: Set<ChannelRef>
    /// Whether the first playback in the sources view starts a new page, with blank strips after
    /// the inputs before it (Adam, 2026-10-30). Off by default.
    public var playbacksOnNewPage: Bool

    /// A layout; the default shows every channel in TotalMix's order.
    public init(sourceOrder: [ChannelRef] = [], outputOrder: [ChannelRef] = [], hidden: Set<ChannelRef> = [],
                playbacksOnNewPage: Bool = false) {
        self.sourceOrder = sourceOrder
        self.outputOrder = outputOrder
        self.hidden = hidden
        self.playbacksOnNewPage = playbacksOnNewPage
    }

    private enum CodingKeys: String, CodingKey {
        case sourceOrder, outputOrder, hidden, playbacksOnNewPage
    }

    /// Reads a saved layout; a missing field is empty, so layouts saved by older versions still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceOrder = try container.decodeIfPresent([ChannelRef].self, forKey: .sourceOrder) ?? []
        outputOrder = try container.decodeIfPresent([ChannelRef].self, forKey: .outputOrder) ?? []
        hidden = try container.decodeIfPresent(Set<ChannelRef>.self, forKey: .hidden) ?? []
        playbacksOnNewPage = try container.decodeIfPresent(Bool.self, forKey: .playbacksOnNewPage) ?? false
    }

    /// The strips of a view on a surface with pages of `pageSize` strips: the view's channels, with
    /// `nil` for a blank strip. Blank strips come only from `playbacksOnNewPage`: they fill the rest
    /// of the page before the first playback in the sources view, when anything comes before it.
    public func strips(_ view: ViewKind, in mirror: MixerMirror, pageSize: Int) -> [ChannelRef?] {
        let channels: [ChannelRef?] = self.channels(view, in: mirror)
        guard view == .sources, playbacksOnNewPage, pageSize > 1,
              let first = channels.firstIndex(where: { $0?.bus == .playback }), first % pageSize != 0 else {
            return channels
        }
        let blanks = pageSize - first % pageSize
        return Array(channels[..<first]) + Array(repeating: nil, count: blanks) + Array(channels[first...])
    }

    /// The channels of a view, as the strips show them (see the type's description).
    public func channels(_ view: ViewKind, in mirror: MixerMirror) -> [ChannelRef] {
        switch view {
        case .sources:
            let available = mirror.visibleChannels(.input) + mirror.visibleChannels(.playback)
            return arrange(available, sourceOrder)
        case .outputs:
            let available = mirror.visibleChannels(.output)
            var monitoring: [ChannelRef] = []
            for role in MonitoringRole.allCases {
                guard let output = mirror.monitoring[role] else { continue }
                let ref = ChannelRef(.output, output)
                if available.contains(ref) && !monitoring.contains(ref) { monitoring.append(ref) }
            }
            let arranged = arrange(available, outputOrder)
            if outputOrder.isEmpty {
                return monitoring.filter { !hidden.contains($0) } + arranged.filter { !monitoring.contains($0) }
            }
            return arranged.filter { monitoring.contains($0) } + arranged.filter { !monitoring.contains($0) }
        }
    }

    /// The channels of a view that the chosen order does not place yet (new to the layout), in
    /// TotalMix's order, for the app to point out. Hidden channels are not counted.
    public func unplaced(_ view: ViewKind, in mirror: MixerMirror) -> [ChannelRef] {
        let order = view == .sources ? sourceOrder : outputOrder
        guard !order.isEmpty else { return [] }
        let available = view == .sources
            ? mirror.visibleChannels(.input) + mirror.visibleChannels(.playback)
            : mirror.visibleChannels(.output)
        return available.filter { !order.contains($0) && !hidden.contains($0) }
    }

    /// The chosen order's available channels, then the rest in TotalMix's order, minus hidden ones.
    private func arrange(_ available: [ChannelRef], _ order: [ChannelRef]) -> [ChannelRef] {
        let availableSet = Set(available)
        var seen: Set<ChannelRef> = []
        var result: [ChannelRef] = []
        for ref in order where availableSet.contains(ref) && !hidden.contains(ref) && seen.insert(ref).inserted {
            result.append(ref)
        }
        for ref in available where !hidden.contains(ref) && !seen.contains(ref) {
            result.append(ref)
        }
        return result
    }
}
