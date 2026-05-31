import Foundation

/// Roll-up of the engine's *judgment* about the current evidence, before any
/// artifact is chosen. This is the load-bearing structure for Phase 20D —
/// every downstream stage consumes this rather than branching on workflow
/// names.
public struct ContextJudgment: Sendable, Codable, Equatable {

    /// How the candidate entities relate to each other.
    public enum EntityRelationship: String, Sendable, Codable {
        case sameCategory
        case relatedDomain
        case differentCategory
        case unrelated
        case insufficientEvidence
    }

    /// Whether the user's apparent comparison is even meaningful.
    public enum ComparisonValidity: String, Sendable, Codable {
        case direct
        case partial
        case invalid
        case notApplicable
    }

    /// The kind of decision the user seems to be making.
    public enum DecisionType: String, Sendable, Codable {
        case productChoice
        case knowledgeAcquisition
        case diagnostic
        case unclear
    }

    public let entities: [String]
    public let relationship: EntityRelationship
    public let comparisonValidity: ComparisonValidity
    public let decisionType: DecisionType
    public let missingInformation: [String]
    /// Plain-text evidence trail the engine can show / the model can read.
    public let rationale: [String]
    /// 0..1 — how strong the available evidence is, not how certain the
    /// relationship is.
    public let confidence: Double
    /// Set to true when at least one pair of entities had numeric facts in
    /// incompatible unit dimensions (mAh vs W, for instance). The engine
    /// surfaces this in the rendered output so the model cannot fabricate a
    /// cross-dimension comparison.
    public let incompatibleUnitsDetected: Bool

    public init(
        entities: [String],
        relationship: EntityRelationship,
        comparisonValidity: ComparisonValidity,
        decisionType: DecisionType,
        missingInformation: [String],
        rationale: [String],
        confidence: Double,
        incompatibleUnitsDetected: Bool
    ) {
        self.entities = entities
        self.relationship = relationship
        self.comparisonValidity = comparisonValidity
        self.decisionType = decisionType
        self.missingInformation = missingInformation
        self.rationale = rationale
        self.confidence = max(0.0, min(confidence, 1.0))
        self.incompatibleUnitsDetected = incompatibleUnitsDetected
    }

    /// Conservative default — no evidence, no claims.
    public static let empty = ContextJudgment(
        entities: [],
        relationship: .insufficientEvidence,
        comparisonValidity: .notApplicable,
        decisionType: .unclear,
        missingInformation: [],
        rationale: ["no_entities"],
        confidence: 0.0,
        incompatibleUnitsDetected: false
    )

    /// Canonical Phase 20D log line.
    public func log() {
        let confStr = String(format: "%.2f", confidence)
        print("[JudgmentLayer] relationship=\(relationship.rawValue)")
        print("[JudgmentLayer] comparison_validity=\(comparisonValidity.rawValue)")
        print("[JudgmentLayer] decision_type=\(decisionType.rawValue)")
        if !rationale.isEmpty {
            print("[JudgmentLayer] rationale=\(rationale.prefix(4).joined(separator: " | "))")
        }
        print("[JudgmentLayer] confidence=\(confStr)")
        if incompatibleUnitsDetected {
            print("[JudgmentLayer] rejected_comparison reason=incompatible_units")
        }
    }
}

// MARK: - Numeric unit dimensions

/// Coarse physical dimensions for numeric facts. Used by the Judgment Layer to
/// reject cross-dimension comparisons (e.g. "24,000 mAh > 140 W").
///
/// This is the exact mechanism that prevents the Phase 20C demo failure where
/// the model compared a battery capacity (mAh) to an output power (W) as if
/// they ranked against each other.
public enum NumericUnitDimension: String, Sendable, Codable {
    case power           // W, kW, mW
    case energyStorage   // Wh, kWh
    case chargeCapacity  // mAh, Ah
    case price           // $, USD, EUR, …
    case rating          // /5, stars
    case storage         // GB, TB, MB
    case length          // inch, cm, mm
    case weight          // lb, kg, oz, g
    case unknown
}

public struct ExtractedNumericFact: Sendable, Equatable {
    public let label: String         // "capacity" / "wattage" / "price" / …
    public let raw: String           // "24,000 mAh"
    public let value: Double
    public let unit: String          // "mAh"
    public let dimension: NumericUnitDimension

    public init(label: String, raw: String, value: Double, unit: String, dimension: NumericUnitDimension) {
        self.label = label
        self.raw = raw
        self.value = value
        self.unit = unit
        self.dimension = dimension
    }
}

public enum NumericUnitClassifier {

    /// Classify a unit string to a physical dimension. Case-insensitive.
    public static func dimension(forUnit unit: String) -> NumericUnitDimension {
        let u = unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch u {
        case "w", "kw", "mw":                                return .power
        case "wh", "kwh":                                     return .energyStorage
        case "mah", "ah":                                     return .chargeCapacity
        case "$", "usd", "eur", "gbp", "jpy", "cad", "aud":   return .price
        case "/5", "stars", "star":                           return .rating
        case "mb", "gb", "tb":                                return .storage
        case "in", "inch", "inches", "cm", "mm", "m", "ft":   return .length
        case "lb", "lbs", "kg", "oz", "g":                    return .weight
        default:                                              return .unknown
        }
    }

    /// Extract `(value, unit, dimension)` tuples from a free-form text string.
    /// Returns at most 6 facts (keeps prompts compact).
    public static func extractFacts(from text: String, label: String = "fact") -> [ExtractedNumericFact] {
        // Match: optional currency, digits with optional comma/decimal, optional whitespace, optional unit token.
        let pattern = #"(\$|€|£|¥)?\s*([0-9]{1,3}(?:[,0-9]{0,9})(?:\.[0-9]+)?)\s*(mAh|Ah|kWh|Wh|kW|mW|W|GB|TB|MB|inch|inches|in\b|cm|mm|m\b|ft\b|lb|lbs|kg|oz|g\b|USD|EUR|GBP|JPY|CAD|AUD|/5|stars?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        var out: [ExtractedNumericFact] = []
        for m in matches {
            guard m.numberOfRanges >= 4 else { continue }
            let currencyRange = m.range(at: 1)
            let valueRange = m.range(at: 2)
            let unitRange = m.range(at: 3)
            guard valueRange.location != NSNotFound else { continue }
            let valueStr = ns.substring(with: valueRange).replacingOccurrences(of: ",", with: "")
            guard let value = Double(valueStr) else { continue }
            var unit: String = ""
            if unitRange.location != NSNotFound {
                unit = ns.substring(with: unitRange)
            } else if currencyRange.location != NSNotFound {
                unit = ns.substring(with: currencyRange)
            }
            let dim = NumericUnitClassifier.dimension(forUnit: unit)
            // Skip uninteresting bare integers with no unit.
            if dim == .unknown && unit.isEmpty { continue }
            // Skip 1-2 digit standalone values (often just years/version numbers).
            if dim == .unknown { continue }
            let raw = (currencyRange.location != NSNotFound ? ns.substring(with: currencyRange) : "")
                    + valueStr + (unit.isEmpty ? "" : " \(unit)")
            out.append(ExtractedNumericFact(label: label, raw: raw, value: value, unit: unit, dimension: dim))
            if out.count >= 6 { break }
        }
        return out
    }
}
