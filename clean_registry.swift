Created At: 2026-05-22T03:15:28Z
Completed At: 2026-05-22T03:15:28Z
File Path: `file:///Users/duncanyu/Documents/GitHub/contextual/Intelligence/HookCapabilityRegistry.swift`
Total Lines: 883
Total Bytes: 28699
Showing lines 1 to 800
The following code has been modified to include a line number before every line, in the format: <line_number>: <original_line>. Please note that any changes targeting the original code should remove the line number, colon, and leading space.
1: import Foundation
2: 
3: // MARK: - Output type
4: 
5: enum HookOutputType: String, Sendable, Equatable {
6: 	case metadata
7: 	case text
8: 	case bullets
9: 	case table
10: 	case checklist
11: 	case comparison
12: 	case debugReport = "debug_report"
13: 	case noOutput = "no_output"
14: }
15: 
16: // MARK: - Permission level
17: 
18: enum HookPermissionLevel: String, Sendable, Equatable {
19: 	/// No special permissions required.
20: 	case none
21: 	/// Requires user-granted accessibility permission.
22: 	case accessibility
23: 	/// Requires screen recording permission.
24: 	case screenRecording = "screen_recording"
25: 	/// Requires explicit user action to proceed.
26: 	case userConfirmation = "user_confirmation"
27: 	/// Not available — must never be executed without an explicit future bypass mechanism.
28: 	case unavailable
29: }
30: 
31: // MARK: - Definition
32: 
33: /// Declarative hook/capability definition.
34: ///
35: /// Hooks are allowed to be hardcoded. They are bounded building blocks that a hook composer
36: /// can chain into an executable plan without introducing arbitrary code execution.
37: struct HookCapabilityDefinition: Sendable, Equatable {
38: 	let id: String
39: 	let description: String
40: 	let category: HookCategory
41: 	let requiredContextTypes: [ContextRequirementType]
42: 	let permission: PermissionRequirement
43: 	let permissionLevel: HookPermissionLevel
44: 	let outputType: HookOutputType
45: 	let isImplemented: Bool
46: 	let mappedPrimitive: ExecutionPrimitive?
47: 	let safetyNotes: String
48: 	/// Preferred nex
<truncated 26635 bytes>
on(
757: 			id: "type_with_permission",
758: 			description: "Type text into the focused input (requires accessibility + user confirmation).",
759: 			category: .computerControl,
760: 			requiredContextTypes: [.none],
761: 			permission: .accessibility,
762: 			permissionLevel: .userConfirmation,
763: 			outputType: .noOutput,
764: 			isImplemented: false,
765: 			mappedPrimitive: nil,
766: 			safetyNotes: "High risk. Requires accessibility permission, explicit user review of text before typing."
767: 		),
768: 		HookCapabilityDefinition(
769: 			id: "scroll_with_permission",
770: 			description: "Scroll the current view (requires user confirmation).",
771: 			category: .computerControl,
772: 			requiredContextTypes: [.none],
773: 			permission: .accessibility,
774: 			permissionLevel: .userConfirmation,
775: 			outputType: .noOutput,
776: 			isImplemented: false,
777: 			mappedPrimitive: nil,
778: 			safetyNotes: "Requires user confirmation."
779: 		),
780: 		HookCapabilityDefinition(
781: 			id: "play_pause_media_with_permission",
782: 			description: "Toggle play/pause on the current media (requires user confirmation).",
783: 			category: .computerControl,
784: 			requiredContextTypes: [.none],
785: 			permission: .none,
786: 			permissionLevel: .userConfirmation,
787: 			outputType: .noOutput,
788: 			isImplemented: false,
789: 			mappedPrimitive: nil,
790: 			safetyNotes: "Low-risk media control. Still requires explicit user confirmation."
791: 		),
792: 		HookCapabilityDefinition(
793: 			id: "search_web_with_permission",
794: 			description: "Initiate a web search with a given query (requires user confirmation).",
795: 			category: .computerControl,
796: 			requiredContextTypes: [.none],
797: 			permission: .automation,
798: 			permissionLevel: .userConfirmation,
799: 			outputType: .noOutput,
800: 			isImplemented: false,
The above content does NOT show the entire file contents. If you need to view any lines of the file which were not shown to complete your task, call this tool again to view those lines.
