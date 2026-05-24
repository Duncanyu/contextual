import Foundation

enum HookChainRepairEngine {
    
    /// Bounded symbolic repair of a hook chain by inserting producers for missing required/presentation inputs.
    static func repair(
        originalHookIds: [String],
        initialAvailableInputs: Set<HookIOKey>,
        registry: HookCapabilityRegistry = .shared
    ) -> [String]? {
        print("[HookRepair] started chain=[\(originalHookIds.joined(separator: ","))]")
        
        var chain = originalHookIds
        var insertions = 0
        let maxInsertions = 3
        let maxPasses = 2
        
        for pass in 1...maxPasses {
            print("[HookRepair] pass=\(pass) current_chain=[\(chain.joined(separator: ","))]")
            
            var available = initialAvailableInputs
            var insertionMadeThisPass = false
            
            var i = 0
            while i < chain.count {
                let hookId = chain[i]
                guard let definition = registry.definition(for: hookId) else {
                    i += 1
                    continue
                }
                
                // 1. Gather missing inputs
                var missing: Set<HookIOKey> = []
                for req in definition.requires {
                    // Check if any available key is compatible with req
                    let satisfied = available.contains { HookIOSemanticBridge.isCompatible(from: $0, to: req) }
                    if !satisfied {
                        missing.insert(req)
                    }
                }
                
                // 2. Specialized presentation checks
                if definition.category == .presentation {
                    if hookId == "present_table" {
                        if !available.contains(.table) && !available.contains(.comparison_table) {
                            missing.insert(.table)
                        }
                    } else if hookId == "present_tradeoff_summary" {
                        let presentables: Set<HookIOKey> = [.key_claims, .comparison_summary]
                        if available.intersection(presentables).isEmpty {
                            // missing tradeoffs
                            missing.insert(.key_claims) // using key_claims as a proxy for tradeoffs
                        }
                    } else if hookId == "present_recommendation" {
                        let presentables: Set<HookIOKey> = [.comparison_summary, .key_claims]
                        if available.intersection(presentables).isEmpty {
                            missing.insert(.comparison_summary)
                        }
                    }
                }
                
                if !missing.isEmpty {
                    let missingSorted = missing.map(\.rawValue).sorted().joined(separator: ",")
                    print("[HookRepairStep] hook=\(hookId) missing=[\(missingSorted)]")
                    
                    // Attempt to satisfy the first missing key in the list
                    if let missingKey = missing.sorted(by: { $0.rawValue < $1.rawValue }).first {
                        if let producer = findBestProducer(for: missingKey, targetHook: definition, currentChain: chain, registry: registry) {
                            if insertions >= maxInsertions {
                                print("[HookRepairResult] fail reason=max_insertions_exceeded")
                                return nil
                            }
                            
                            print("[HookRepairStep] inserting producer=\(producer.id) before hook=\(hookId) to satisfy missing=\(missingKey.rawValue)")
                            chain.insert(producer.id, at: i)
                            insertions += 1
                            insertionMadeThisPass = true
                            // Restart validation pass from the beginning to re-accumulate outputs properly
                            break
                        } else {
                            print("[HookRepairResult] fail reason=no_producer_found key=\(missingKey.rawValue)")
                            return nil
                        }
                    }
                }
                
                // Accumulate outputs
                available.formUnion(definition.produces)
                i += 1
            }
            
            // If validation traversed the entire chain without making any new insertions, we are satisfied!
            if !insertionMadeThisPass {
                break
            }
        }
        
        // Final verification pass using the validator
        print("[HookRepairValidation] revalidating chain=[\(chain.joined(separator: ","))]")
        let validation = HookChainIOValidator.validate(hookIds: chain, initialAvailableInputs: initialAvailableInputs, registry: registry)
        if validation.isValid {
            print("[HookRepairResult] pass repaired_chain=[\(chain.joined(separator: ","))]")
            return chain
        } else {
            print("[HookRepairResult] fail reason=validation_failed_after_repair")
            return nil
        }
    }
    
    /// Finds the best implemented capability to produce a target required key.
    private static func findBestProducer(
        for missingKey: HookIOKey,
        targetHook: HookCapabilityDefinition,
        currentChain: [String],
        registry: HookCapabilityRegistry
    ) -> HookCapabilityDefinition? {
        var bestCandidate: HookCapabilityDefinition? = nil
        var bestScore = -1000.0
        
        for definition in registry.all {
            // Must be implemented
            guard definition.isImplemented else { continue }
            
            // Avoid duplicate insertions
            guard !currentChain.contains(definition.id) else { continue }
            
            // Safe execution modes only (one_shot or observe_once; exclude confirmation_required, external_control, interactive_loop)
            let mode = definition.executionMode
            guard mode == .one_shot || mode == .observe_once else { continue }
            
            // Check compatibility score
            var bestBridgeScore = 0.0
            for output in definition.produces {
                let score = HookIOSemanticBridge.compatibilityScore(from: output, to: missingKey)
                if score > bestBridgeScore {
                    bestBridgeScore = score
                }
            }
            
            guard bestBridgeScore >= 0.70 else { continue }
            
            // Scoring algorithm
            var score = bestBridgeScore * 100.0
            
            // Semantic tags overlap (gives preference to relevant domain capabilities)
            let tagIntersection = definition.semanticTags.intersection(targetHook.semanticTags)
            score += Double(tagIntersection.count) * 10.0
            
            // Category match
            if definition.category == targetHook.category {
                score += 5.0
            }
            
            // Shortest insertion count (penalize large lists of required inputs)
            score -= Double(definition.requires.count) * 2.0
            
            // Execution mode complexity preference (favor one_shot over observe_once)
            if mode == .one_shot {
                score += 5.0
            } else if mode == .observe_once {
                score += 2.0
            }
            
            // Relationship-based planning hints (commonNext, commonPrev, pairsWell)
            if definition.commonNextHookIds.contains(targetHook.id) {
                score += 20.0
            }
            if targetHook.commonPrevHookIds.contains(definition.id) {
                score += 20.0
            }
            if targetHook.pairsWellWithHookIds.contains(definition.id) || definition.pairsWellWithHookIds.contains(targetHook.id) {
                score += 20.0
            }
            
            print("[HookRepairCandidate] hook=\(definition.id) score=\(score) missing=\(missingKey.rawValue)")
            
            if score > bestScore {
                bestScore = score
                bestCandidate = definition
            } else if abs(score - bestScore) < 0.001, let best = bestCandidate {
                // Alphabetical tie-breaker to ensure perfect determinism
                if definition.id < best.id {
                    bestCandidate = definition
                }
            }
        }
        
        return bestCandidate
    }
    
    /// Startup repair capability and reachability audit.
    static func auditStartupRepair(registry: HookCapabilityRegistry = .shared) {
        // 1. Graph size: implemented producers
        let producers = registry.all.filter {
            $0.isImplemented && !$0.produces.isEmpty
        }
        let graphSize = producers.count
        
        // 2. Bridge count: count compatible semantic bridge links
        var bridgeCount = 0
        let allKeys = HookIOKey.allCases
        for src in allKeys {
            for tgt in allKeys where src != tgt {
                if HookIOSemanticBridge.isCompatible(from: src, to: tgt) {
                    bridgeCount += 1
                }
            }
        }
        
        // 3. Repairable hooks: implemented hooks with inputs that can be solved by a producer
        var repairableCount = 0
        for hook in registry.all where hook.isImplemented {
            if !hook.requires.isEmpty {
                var canSatisfyAllInputs = true
                for req in hook.requires {
                    let hasProducer = registry.all.contains { prod in
                        prod.isImplemented && prod.produces.contains { HookIOSemanticBridge.isCompatible(from: $0, to: req) }
                    }
                    if !hasProducer {
                        canSatisfyAllInputs = false
                    }
                }
                if canSatisfyAllInputs {
                    repairableCount += 1
                }
            }
        }
        
        // 4. Unreachable outputs: required inputs with absolutely zero available producers
        var unreachableKeys: Set<HookIOKey> = []
        for hook in registry.all where hook.isImplemented {
            for req in hook.requires {
                let hasProducer = registry.all.contains { prod in
                    prod.isImplemented && prod.produces.contains { HookIOSemanticBridge.isCompatible(from: $0, to: req) }
                }
                if !hasProducer {
                    unreachableKeys.insert(req)
                }
            }
        }
        let unreachableCount = unreachableKeys.count
        
        print("[HookRepairAudit] graph_size=\(graphSize) bridges=\(bridgeCount) repairable=\(repairableCount) unreachable=\(unreachableCount)")
        if unreachableCount > 0 {
            let unreachableList = unreachableKeys.map(\.rawValue).sorted().joined(separator: ",")
            print("[HookRepairAudit] unreachable_keys=[\(unreachableList)]")
        }
    }
}
