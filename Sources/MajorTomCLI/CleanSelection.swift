import Foundation
import MajorTomCore

/// Turns `clean`'s filters into the exact items to clean. A filter that can't be applied is an error, never a
/// fallback to a wider selection.
public enum CleanSelection {
    /// - Parameters:
    ///   - items: the rule's freshly scanned items.
    ///   - itemFilters: `--item` values (item id, or display name when that names exactly one item).
    ///   - flaggedOnly: `--flagged`.
    /// - Returns: the items to clean. Without filters: every cleanable item. With `--item`: exactly the named
    ///   items, each of which must be cleanable (and flagged, with `--flagged`).
    public static func select(from items: [Item], ruleID: String, itemFilters: [String],
                              flaggedOnly: Bool) throws(CLIError) -> [Item] {
        let hint = "(use `majortom scan --rule \(ruleID) --json` for ids)"
        guard !itemFilters.isEmpty else {
            let cleanable = items.filter(\.isCleanable)
            guard flaggedOnly else { return cleanable }
            let flagged = cleanable.filter(\.isFlagged)
            if flagged.isEmpty { throw CLIError("no flagged cleanable items in \(ruleID); nothing to clean") }
            return flagged
        }

        var selected: [Item] = []
        for filter in itemFilters {
            let item: Item
            if let byID = items.first(where: { $0.id == filter }) {
                item = byID
            } else {
                let byName = items.filter { $0.displayName == filter }
                if byName.isEmpty { throw CLIError("no item \(filter) in \(ruleID) \(hint)") }
                if byName.count > 1 {
                    throw CLIError("\(filter) matches \(byName.count) items in \(ruleID); give its id instead \(hint)")
                }
                item = byName[0]
            }
            if item.isProtected { throw CLIError("\(filter) is protected in \(ruleID) and can't be cleaned") }
            if !item.isCleanable { throw CLIError("\(filter) is report-only in \(ruleID) and can't be cleaned") }
            if flaggedOnly, !item.isFlagged { throw CLIError("\(filter) is not flagged in \(ruleID) (--flagged given)") }
            if !selected.contains(where: { $0.id == item.id }) { selected.append(item) }
        }
        return selected
    }
}
