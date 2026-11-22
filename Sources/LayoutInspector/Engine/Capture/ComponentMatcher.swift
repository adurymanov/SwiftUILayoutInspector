#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import CoreGraphics
import Foundation

/// What matching a capture's components to the graph's views needs, as plain values: read from a live capture and
/// graph by ``ComponentGraph``, or loaded from a recorded fixture (`LAYOUT_INSPECTOR_MATCH_DUMP`) to replay offline.
struct MatchInput: Codable {
    struct View: Codable {
        var type: String
        /// The nearest app view around it, an index into ``MatchInput/views``.
        var parent: Int?
        /// Index of the hosting view whose tree holds it.
        var host: Int
        /// The box SwiftUI recorded for the first view its `body` produced, `[x, y, width, height]`.
        var frame: [Double]?
        /// The boxes of all the views its `body` produced, together.
        var bounds: [Double]?
        /// The strings it was built with (``ComponentGraph/strings(of:)``); in a recording only.
        var strings: [String]?
    }

    struct Component: Codable {
        /// ``InspectorNode/id`` of the captured node.
        var id: Int
        var type: String
        /// The nearest component around it, an index into ``MatchInput/components``.
        var parent: Int?
        /// Index of the hosting view of its capture root.
        var host: Int?
        /// ``InspectorNode/recordedFrame``.
        var box: [Double]?
        /// The strings of the texts inside it.
        var texts: [String]
        /// Its frame in the window: not used for matching, kept for reading a recording.
        var frame: [Double]?
    }

    /// In the order the graph lists them.
    var views: [View] = []
    /// In the order of the capture (outer before inner).
    var components: [Component] = []
}

extension CGRect {
    init?(_ values: [Double]?) {
        guard let values, values.count == 4 else { return nil }
        self.init(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    var values: [Double] { [minX, minY, width, height].map(Double.init) }
}

/// Ties components to views (see ``ComponentGraph``): from the outside in, each inside the view of the nearest
/// component around it that was told apart, then by the recorded box, the texts, and what is left shares a total.
struct ComponentMatcher {
    let input: MatchInput
    /// The strings a view was built with, read only when the texts have to decide.
    let strings: (Int) -> Set<String>

    private let byType: [String: [Int]]
    private let frames: [CGRect?]
    private let bounds: [CGRect?]

    init(_ input: MatchInput, strings: ((Int) -> Set<String>)? = nil) {
        self.input = input
        self.strings = strings ?? { Set(input.views[$0].strings ?? []) }
        var byType: [String: [Int]] = [:]
        for (index, view) in input.views.enumerated() { byType[view.type, default: []].append(index) }
        self.byType = byType
        frames = input.views.map { CGRect($0.frame) }
        bounds = input.views.map { CGRect($0.bounds) }
    }

    private struct Scope: Hashable {
        /// The view of the nearest component around that was told apart.
        var around: Int?
        var host: Int?
        var type: String
    }

    /// Views of each component that got any, by index into ``MatchInput/components``: one when it was told apart.
    func run() -> [Int: [Int]] {
        let components = input.components
        guard !input.views.isEmpty else { return [:] }
        // Components by how many components are around them: the outer ones are matched first.
        var levels: [[Int]] = []
        var depth = [Int](repeating: 0, count: components.count)
        for (index, component) in components.enumerated() {
            let level = component.parent.map { depth[$0] + (byType[components[$0].type] != nil ? 1 : 0) } ?? 0
            depth[index] = level
            guard byType[component.type] != nil else { continue }
            while levels.count <= level { levels.append([]) }
            levels[level].append(index)
        }

        var exact: [Int: Int] = [:]
        var owner: [Int: Int] = [:]
        var used = Set<Int>()
        var result: [Int: [Int]] = [:]
        /// The views of the components around `component` that were told apart, nearest first.
        func around(_ component: Int) -> [Int] {
            var result: [Int] = []
            var next = components[component].parent
            while let parent = next {
                if let view = exact[parent] { result.append(view) }
                next = components[parent].parent
            }
            return result
        }
        for level in levels {
            var groups: [Scope: [Int]] = [:]
            var order: [Scope] = []
            for component in level {
                let outer = around(component).first
                let scope = Scope(around: outer, host: outer == nil ? components[component].host : nil, type: components[component].type)
                if groups[scope] == nil { order.append(scope) }
                groups[scope, default: []].append(component)
            }
            // Scoped groups first: a group matched across the whole window takes only what they leave.
            for scope in order.sorted(by: { ($0.around == nil ? 1 : 0) < ($1.around == nil ? 1 : 0) }) {
                let members = groups[scope]!
                let outer = around(members[0])
                // A view inside a view already told apart belongs to that view's component: only a component inside it
                // can be that view. Of the views left, the ones inside the nearest component around come first, then
                // the ones beside it (``tier(of:outer:owner:)``).
                var tiers: [Int: [Int]] = [:]
                for view in byType[scope.type] ?? [] where !used.contains(view) {
                    let found = tier(of: view, outer: outer, owner: owner)
                    if found >= 0 { tiers[found, default: []].append(view) }
                }
                // Inside the nearest component around first. AttributeGraph doesn't always nest views the way the
                // capture does (a `TimelineView`'s content sits under the view that placed it, and a scroll view's
                // content in a navigation stack is a tree of its own, outside the screen's view), so then beside it,
                // inside the next component out, and at last outside all of them, in the component's own host first.
                // Away from the nearest component the views are told apart only while no other component of the type
                // waits in the same scope; otherwise they share one total.
                guard let tier = tiers.keys.min(), var candidates = tiers[tier] else { continue }
                if tier == 2 * outer.count, let host = components[members[0]].host {
                    let own = candidates.filter { input.views[$0].host == host }
                    if !own.isEmpty { candidates = own }
                }
                // Rivals: other waiting components of the type whose own candidates (the views at their nearest tier)
                // include one of these.
                var rivals: [Int] = []
                if tier > 0, tier < 2 * outer.count {
                    let free = (byType[scope.type] ?? []).filter { !used.contains($0) }
                    rivals = level.filter { other in
                        guard components[other].type == scope.type, result[other] == nil, !members.contains(other) else { return false }
                        let theirs = around(other)
                        let tiers = free.map { self.tier(of: $0, outer: theirs, owner: owner) }
                        guard let best = tiers.filter({ $0 >= 0 }).min() else { return false }
                        return zip(free, tiers).contains { view, tier in tier == best && candidates.contains(view) }
                    }
                }
                let mayTellApart = rivals.isEmpty
                // Copies of one view drawn twice at one place (a press effect over its content) count as one: the
                // first stands for them, the others belong to the same component.
                let (representatives, copies) = collapseCopies(candidates, members: members.count)
                let assigned = mayTellApart ? assign(members, representatives) : assignByBox(members, representatives, rivals: rivals)
                for (component, views) in assigned {
                    result[component] = views
                    let all = views + views.flatMap { copies[$0] ?? [] }
                    if views.count == 1 { exact[component] = views[0]; for view in all { owner[view] = component } }
                    used.formUnion(all)
                }
            }
        }
        return result
    }

    /// Candidates that are copies of another candidate, folded into the first of them: the representatives, and the
    /// copies of each. Not when that would leave fewer views than components: two equal components can be two equal
    /// views.
    private func collapseCopies(_ candidates: [Int], members: Int) -> ([Int], [Int: [Int]]) {
        guard candidates.count > 1 else { return (candidates, [:]) }
        var representatives: [Int] = []
        var copies: [Int: [Int]] = [:]
        for view in candidates {
            if let first = representatives.first(where: { isCopy(view, of: $0) }) {
                copies[first, default: []].append(view)
            } else {
                representatives.append(view)
            }
        }
        return representatives.count >= members ? (representatives, copies) : (candidates, [:])
    }

    /// `a` is drawn as a copy of `b` (a press effect drawing its content twice): same type, box and strings, the same
    /// views inside, and the view around each is the same one or again a copy.
    private func isCopy(_ a: Int, of b: Int, depth: Int = 0) -> Bool {
        let va = input.views[a], vb = input.views[b]
        guard a != b, depth < 8, let pa = va.parent, let pb = vb.parent, va.type == vb.type, same(frames[a], frames[b]),
              same(bounds[a], bounds[b]), strings(a) == strings(b) else { return false }
        guard pa == pb || isCopy(pa, of: pb, depth: depth + 1) else { return false }
        let inA = descendants(of: a), inB = descendants(of: b)
        return inA.count == inB.count && zip(inA, inB).allSatisfy { input.views[$0].type == input.views[$1].type && same(frames[$0], frames[$1]) }
    }

    private func same(_ a: CGRect?, _ b: CGRect?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): a.isClose(to: b)
        default: false
        }
    }

    /// The app views inside `view`, in the graph's order.
    private func descendants(of view: Int) -> [Int] {
        var result: [Int] = []
        var inside: Set<Int> = [view]
        // A view comes after the view around it in the graph's order.
        for index in (view + 1)..<input.views.count {
            guard let parent = input.views[index].parent, inside.contains(parent) else { continue }
            inside.insert(index)
            result.append(index)
        }
        return result
    }

    /// Where `view` is for a component with `outer` around it (the views of the components around it that were told
    /// apart, nearest first): 2k inside `outer[k]`, 2k + 1 beside it (under the view that declared it: content a
    /// container gets from its caller, like a grid's cards, sits in AttributeGraph under the caller), 2 × outer.count
    /// outside all; -1 inside a view another component owns.
    private func tier(of view: Int, outer: [Int], owner: [Int: Int]) -> Int {
        var next = input.views[view].parent
        while let index = next, owner[index] == nil {
            if let k = outer.firstIndex(where: { input.views[$0].parent == index }) { return 2 * k + 1 }
            next = input.views[index].parent
        }
        return next.map { view in outer.firstIndex(of: view).map { 2 * $0 } ?? -1 } ?? 2 * outer.count
    }

    /// Away from the nearest component, with other components of the type waiting for the same views: only a box that
    /// no rival has ties a component to a view; the rest share what is left.
    private func assignByBox(_ members: [Int], _ candidates: [Int], rivals: [Int]) -> [(Int, [Int])] {
        var left = candidates
        var result: [(Int, [Int])] = []
        var rest: [Int] = []
        for member in members.sorted() {
            let boxed = boxMatches(member, left)
            if boxed.count == 1, !rivals.contains(where: { boxMatches($0, [left[boxed[0]]]).count == 1 }),
               !members.contains(where: { $0 != member && boxMatches($0, [left[boxed[0]]]).count == 1 }) {
                result.append((member, [left.remove(at: boxed[0])]))
            } else {
                rest.append(member)
            }
        }
        if left.count > 1 { result += rest.map { ($0, left) } }
        return result
    }

    /// Indices into `views` of the views at the component's recorded box. A box of no size (a wrapper whose first
    /// view is an empty overlay) still has the place of its content.
    private func boxMatches(_ component: Int, _ views: [Int]) -> [Int] {
        guard let box = CGRect(input.components[component].box) else { return [] }
        let isPoint = box.width < 0.5 || box.height < 0.5
        return views.indices.filter { index in
            frames[views[index]].map { isPoint ? abs($0.minX - box.minX) <= 0.5 && abs($0.minY - box.minY) <= 0.5 : $0.isClose(to: box) } ?? false
        }
    }

    /// Ties `members` (components of one type in one scope) to `candidates` (views of that type there): one each when
    /// there is one of both, then by the recorded box, then by the texts; the rest share what is left.
    private func assign(_ members: [Int], _ candidates: [Int]) -> [(Int, [Int])] {
        if members.count == 1, candidates.count == 1, fits(members[0], candidates[0]) { return [(members[0], candidates)] }
        var left = candidates
        var result: [(Int, [Int])] = []
        // By the recorded box. Two views with one box (a copy at the same place) are left to the texts.
        var byText: [Int] = []
        for member in members.sorted() {
            let boxed = boxMatches(member, left)
            if boxed.count == 1 {
                result.append((member, [left.remove(at: boxed[0])]))
            } else {
                byText.append(member)
            }
        }
        guard !byText.isEmpty, !left.isEmpty else { return result }
        // As many components as views here, and all but one paired by their boxes: the last two belong together.
        if members.count == candidates.count, byText.count == 1, left.count == 1, fits(byText[0], left[0]) {
            return result + [(byText[0], left)]
        }
        var unmatched: [Int] = []
        // By text: the view whose own strings cover most of the component's texts, when that view is the only one.
        var strings = left.map { self.strings($0) }
        for member in byText {
            let texts = Set(input.components[member].texts)
            guard !texts.isEmpty else { unmatched.append(member); continue }
            let overlaps = strings.indices.map { fits(member, left[$0]) ? strings[$0].intersection(texts).count : 0 }
            let best = overlaps.max() ?? 0
            let tied = overlaps.indices.filter { overlaps[$0] == best }
            if best > 0, tied.count == 1 {
                result.append((member, [left.remove(at: tied[0])]))
                strings.remove(at: tied[0])
            } else if best > 0 {
                // Built with the same texts (a hidden copy, two identical labels): one total for those views.
                result.append((member, tied.map { left[$0] }))
            } else {
                unmatched.append(member)
            }
        }
        guard !unmatched.isEmpty, !left.isEmpty else { return result }
        // Nothing tells the rest apart, and the graph's order isn't the screen's: one total for them, rather than
        // counts that look exact on the wrong view. A view that can't be this one isn't counted in, and a component
        // that no view can be gets no count.
        for member in unmatched {
            let fitting = left.filter { fits(member, $0) }
            if fitting.count > 1 { result.append((member, fitting)) }
        }
        return result
    }

    /// The view can be the component: the component's recorded box lies on the views its `body` produced. The capture
    /// and the graph don't always take the same first view (a stack or its first child, a safe area inset before the
    /// content), but the box is always on one of them; it isn't when the capture named a node after a view that is
    /// somewhere else.
    private func fits(_ component: Int, _ view: Int) -> Bool {
        guard let box = CGRect(input.components[component].box), let bounds = bounds[view], box.width > 0, box.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return true
        }
        return box.insetBy(dx: -1, dy: -1).intersects(bounds)
    }

    // MARK: - Summary

    /// Components with any views, and how many of them were told apart: the share the inspector reports.
    static func summary(_ result: [Int: [Int]]) -> (views: Int, own: Int) {
        (result.count, result.values.filter { $0.count == 1 }.count)
    }
}

#endif
