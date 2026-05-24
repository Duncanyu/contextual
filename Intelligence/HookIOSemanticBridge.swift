import Foundation

enum HookIOSemanticBridge {
    
    /// Returns the semantic compatibility score from a source key to a target required key.
    /// Range: 0.0 (incompatible) to 1.0 (exact match).
    static func compatibilityScore(from source: HookIOKey, to target: HookIOKey) -> Double {
        if source == target {
            return 1.0
        }
        
        switch (source, target) {
        // table ↔ comparison_table
        case (.table, .comparison_table):
            return 0.95
        case (.comparison_table, .table):
            return 0.95
            
        // comparison_summary → key_claims
        case (.comparison_summary, .key_claims):
            return 0.90
            
        // product_specs → product_attributes
        case (.product_specs, .product_attributes):
            return 0.80
            
        // ocr_text / ax_window_text → page_text
        case (.ocr_text, .page_text):
            return 0.90
        case (.ax_window_text, .page_text):
            return 0.90
            
        default:
            return 0.0
        }
    }
    
    /// Returns true if a source output key can satisfy a target required input key.
    static func isCompatible(from source: HookIOKey, to target: HookIOKey) -> Bool {
        return compatibilityScore(from: source, to: target) >= 0.70
    }
}
