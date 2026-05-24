import Foundation

struct HookChainIOValidationResult: Sendable, Equatable {
    let isValid: Bool
    let failedHookId: String?
    let missingInputs: Set<HookIOKey>
    let availableAtFailure: Set<HookIOKey>
    let finalAvailableOutputs: Set<HookIOKey>
    let trace: [String]
}

enum HookChainIOValidator {
    
    /// Maps the current context snapshot to a set of initial HookIOKey inputs.
    static func initialInputs(from snapshot: CanonicalGeneratedExecutionContextSnapshot) -> Set<HookIOKey> {
        var keys: Set<HookIOKey> = []
        var sources: [String] = []
        
        // App/window metadata available -> current_context, app_identifier, window_title
        if !snapshot.activeApp.isEmpty || !snapshot.windowTitle.isEmpty {
            keys.insert(.current_context)
            keys.insert(.app_identifier)
            keys.insert(.window_title)
            sources.append("metadata")
        }
        
        // Selected text available -> selected_text
        if let selected = snapshot.selectedText, !selected.isEmpty {
            keys.insert(.selected_text)
            sources.append("selected_text")
        }
        
        // Clipboard text available -> clipboard_text
        if let clipboard = snapshot.clipboardText, !clipboard.isEmpty {
            keys.insert(.clipboard_text)
            sources.append("clipboard_text")
        }
        
        // OCR text available -> ocr_text, page_text
        if let ocr = snapshot.recentOCRExcerpt, !ocr.isEmpty {
            keys.insert(.ocr_text)
            keys.insert(.page_text)
            sources.append("ocr_text")
        }
        
        // AX window text available -> ax_window_text, page_text
        if let summary = snapshot.contextSummary, summary.contains("ax=") {
            keys.insert(.ax_window_text)
            keys.insert(.page_text)
            sources.append("ax_window_text")
        }
        
        // Visual descriptor available -> visual_descriptor
        if snapshot.visualContextAvailability.hasUsableVisual {
            keys.insert(.visual_descriptor)
            sources.append("visual_descriptor")
        }
        
        let sortedSources = sources.sorted().joined(separator: ",")
        let sortedKeys = keys.map(\.rawValue).sorted().joined(separator: ",")
        print("[HookIOInitialInputs] sources=[\(sortedSources)] keys=[\(sortedKeys)]")
        
        return keys
    }
    
    /// Validates a chain of hook IDs starting with a set of initial available inputs.
    static func validate(
        hookIds: [String],
        initialAvailableInputs: Set<HookIOKey>,
        registry: HookCapabilityRegistry = .shared
    ) -> HookChainIOValidationResult {
        print("[HookIOValidation] started chain=[\(hookIds.joined(separator: ","))]")
        
        var available = initialAvailableInputs
        var trace: [String] = []
        
        if hookIds.isEmpty {
            print("[HookIOValidation] result=fail hook=none missing=[empty_chain]")
            return HookChainIOValidationResult(
                isValid: false,
                failedHookId: nil,
                missingInputs: [],
                availableAtFailure: available,
                finalAvailableOutputs: available,
                trace: ["empty chain"]
            )
        }
        
        for (index, hookId) in hookIds.enumerated() {
            let stepNum = index + 1
            trace.append("step=\(stepNum) hook=\(hookId)")
            
            guard let definition = registry.definition(for: hookId) else {
                print("[HookIOValidation] step=\(stepNum) hook=\(hookId) is unknown")
                print("[HookIOValidation] result=fail hook=\(hookId) missing=[unknown_hook]")
                return HookChainIOValidationResult(
                    isValid: false,
                    failedHookId: hookId,
                    missingInputs: [],
                    availableAtFailure: available,
                    finalAvailableOutputs: available,
                    trace: trace + ["unknown hook: \(hookId)"]
                )
            }
            
            // 1. Verify required inputs are satisfied
            let missing = Set(definition.requires.filter { !available.contains($0) })
            if !missing.isEmpty {
                let requiredStr = definition.requires.map(\.rawValue).sorted().joined(separator: ",")
                let availableStr = available.map(\.rawValue).sorted().joined(separator: ",")
                let missingStr = missing.map(\.rawValue).sorted().joined(separator: ",")
                
                print("[HookIOValidation] step=\(stepNum) hook=\(hookId) requires=[\(requiredStr)] available=[\(availableStr)] missing=[\(missingStr)]")
                print("[HookIOValidation] result=fail hook=\(hookId) missing=[\(missingStr)]")
                
                return HookChainIOValidationResult(
                    isValid: false,
                    failedHookId: hookId,
                    missingInputs: missing,
                    availableAtFailure: available,
                    finalAvailableOutputs: available,
                    trace: trace + ["missing required inputs: \(missingStr)"]
                )
            }
            
            // 2. Specialized presentation hook validations
            if definition.category == .presentation {
                if hookId == "present_table" {
                    if !available.contains(.table) && !available.contains(.comparison_table) {
                        let availableStr = available.map(\.rawValue).sorted().joined(separator: ",")
                        print("[HookIOValidation] step=\(stepNum) hook=present_table requires=[table/comparison_table] available=[\(availableStr)] missing=[table]")
                        print("[HookIOValidation] result=fail hook=present_table missing=[table]")
                        
                        return HookChainIOValidationResult(
                            isValid: false,
                            failedHookId: hookId,
                            missingInputs: [.table],
                            availableAtFailure: available,
                            finalAvailableOutputs: available,
                            trace: trace + ["missing table or comparison_table for present_table"]
                        )
                    }
                } else if hookId == "present_tradeoff_summary" {
                    let presentables: Set<HookIOKey> = [.tradeoffs, .key_claims, .comparison_summary]
                    if available.intersection(presentables).isEmpty {
                        let availableStr = available.map(\.rawValue).sorted().joined(separator: ",")
                        print("[HookIOValidation] step=\(stepNum) hook=present_tradeoff_summary requires=[tradeoffs/key_claims/comparison_summary] available=[\(availableStr)] missing=[tradeoffs]")
                        print("[HookIOValidation] result=fail hook=present_tradeoff_summary missing=[tradeoffs]")
                        
                        return HookChainIOValidationResult(
                            isValid: false,
                            failedHookId: hookId,
                            missingInputs: [.tradeoffs],
                            availableAtFailure: available,
                            finalAvailableOutputs: available,
                            trace: trace + ["missing presentable input for present_tradeoff_summary"]
                        )
                    }
                } else if hookId == "present_recommendation" {
                    let presentables: Set<HookIOKey> = [.recommendation, .comparison_summary, .tradeoffs]
                    if available.intersection(presentables).isEmpty {
                        let availableStr = available.map(\.rawValue).sorted().joined(separator: ",")
                        print("[HookIOValidation] step=\(stepNum) hook=present_recommendation requires=[recommendation/comparison_summary/tradeoffs] available=[\(availableStr)] missing=[recommendation]")
                        print("[HookIOValidation] result=fail hook=present_recommendation missing=[recommendation]")
                        
                        return HookChainIOValidationResult(
                            isValid: false,
                            failedHookId: hookId,
                            missingInputs: [.recommendation],
                            availableAtFailure: available,
                            finalAvailableOutputs: available,
                            trace: trace + ["missing presentable input for present_recommendation"]
                        )
                    }
                }
            }
            
            // 3. Add produced outputs to available set
            let prevAvailable = available
            available.formUnion(definition.produces) // ensure backup compatibility
            
            let requiredStr = definition.requires.map(\.rawValue).sorted().joined(separator: ",")
            let prevAvailableStr = prevAvailable.map(\.rawValue).sorted().joined(separator: ",")
            let producedStr = definition.produces.map(\.rawValue).sorted().joined(separator: ",")
            let availableAfterStr = available.map(\.rawValue).sorted().joined(separator: ",")
            
            print("[HookIOValidation] step=\(stepNum) hook=\(hookId) requires=[\(requiredStr)] available=[\(prevAvailableStr)] missing=[]")
            print("[HookIOValidation] step=\(stepNum) produced=[\(producedStr)] available_after=[\(availableAfterStr)]")
        }
        
        let finalAvailableStr = available.map(\.rawValue).sorted().joined(separator: ",")
        print("[HookIOValidation] result=pass final_available=[\(finalAvailableStr)]")
        
        return HookChainIOValidationResult(
            isValid: true,
            failedHookId: nil,
            missingInputs: [],
            availableAtFailure: [],
            finalAvailableOutputs: available,
            trace: trace
        )
    }
}
