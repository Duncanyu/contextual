// HookDomainFilter.swift
// Filters hook candidates by workflow domain to prevent domain mismatch.
//
// Approach: metadata-driven candidate filtering, NOT hardcoded chains.
// A small set of hooks that are inherently product/shopping-specific are
// restricted to browsing/research workflows. All other hooks remain universal.
//
// Logs:
//   [HookDomainFilter] workflow=debugging app=Xcode before=N after=N removed=[...]
//   [HookDomainFilter] removed hook=extract_product_specs reason=domain_mismatch workflow=debugging
//   [HookDomainFilter] kept_generic hook=present_result

import Foundation

enum HookDomainFilter {

    // MARK: - Domain-restricted hook sets

    /// Hooks that are only meaningful when a product or shopping page is visible.
    /// These should not appear in coding/debugging/writing/editing chains.
    static let shoppingOnlyHookIds: Set<String> = [
        "extract_product_specs",
        "extract_price_and_rating",
        "compare_product_specs",
        "identify_purchase_tradeoffs",
        "summarize_visible_reviews",
    ]

    /// Workflows where shopping/product-specific hooks are applicable.
    /// Hooks NOT in this set will be removed for any workflow in this list.
    static let shoppingApplicableWorkflows: Set<WorkflowType> = [
        .browsing, .research, .reviewing, .comparing, .studying, .organizing,
    ]

    // MARK: - Filter

    /// Removes hooks that are incompatible with the current workflow.
    /// Conservative: unknown workflow passes all hooks through (don't restrict when uncertain).
    ///
    /// - Parameters:
    ///   - candidates: Full list of candidate hooks to filter.
    ///   - workflow: The current inferred workflow.
    ///   - app: Active app name (for logging).
    /// - Returns: Filtered list. May equal input when no restrictions apply.
    static func filter(
        candidates: [HookCapabilityDefinition],
        workflow: WorkflowType,
        app: String
    ) -> [HookCapabilityDefinition] {
        // Conservative: unknown workflow → pass all through (don't over-restrict)
        guard workflow != .unknown else { return candidates }

        let before = candidates.count
        var removed: [String] = []

        let filtered = candidates.filter { hook in
            if shoppingOnlyHookIds.contains(hook.id) {
                if shoppingApplicableWorkflows.contains(workflow) {
                    return true
                } else {
                    removed.append(hook.id)
                    return false
                }
            }
            return true  // all non-shopping hooks are universally applicable
        }

        let after = filtered.count
        print("[HookDomainFilter] workflow=\(workflow.rawValue) app=\(app) before=\(before) after=\(after) removed=[\(removed.joined(separator: ","))]")

        if removed.isEmpty {
            print("[HookDomainFilter] no_domain_mismatch workflow=\(workflow.rawValue)")
        } else {
            for hookId in removed {
                print("[HookDomainFilter] removed hook=\(hookId) reason=domain_mismatch workflow=\(workflow.rawValue)")
            }
            // Log a sample of generic hooks that were kept to confirm filter ran
            let sampleKept = filtered.filter { !shoppingOnlyHookIds.contains($0.id) }.prefix(3).map(\.id)
            for hookId in sampleKept {
                print("[HookDomainFilter] kept_generic hook=\(hookId)")
            }
        }

        return filtered
    }
}
