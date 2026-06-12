# Phase 57: Liquid Integrity Audit

## 1. What is generalized and acceptable
- The classification architecture generally uses generic terms to map signals to workflows like `form_application`, `code_logs`, and `browser_research`.
- The Liquid Action Router accurately limits the visibility of certain items via limits such as `maxPrimary` and `maxPanel`.
- Signals like `urlHost`, `activeApp` are structured well to provide non-deterministic evidence of context.
- Output gating exists conceptually, filtering outputs depending on conditions, such as missing source quotes or too few items.

## 2. What is hardcoded or suspicious
**LiquidActionRouter.swift**
- The `deterministicRentalTerms` array is completely hardcoded to the specific testing dogfood case:
  `"zillow rental manager", "accommodation listing service", "room for rent", "room rentals & roommates", "kijiji", "rentals.ca", "occupancy agreement", "google docs", "rent", "rental", "listing", "room", "landlord", "tenant", "lease", "agreement", "utilities", "deposit", "kingston", "queen's", "queens"`.
  Project-specific and user-specific words like "zillow rental manager", "kijiji", "rentals.ca", "kingston", "queen's", and "182 Montreal" are extremely brittle.
- There's a direct logic branch enforcing rental actions:
  ```swift
  let hasDocument = lowerTitles.contains { title in
      title.contains("occupancy agreement")
          || title.contains("lease")
          || (title.contains("agreement") && title.contains("google docs"))
  }
  ```
  This immediately forces `rental_lease` workflow classification for any tab titled "occupancy agreement".

**LiquidActionExecution.swift**
- The formatter output gates and the output generators themselves are poor:
  - `flag_risky_clauses` does not explain *why* the clause is risky or suggest an ask/change. It simply outputs template text: `"- Review this clause for cost, liability, or termination exposure:\n> \(clause)"`.
  - Output gates like `OutputImportanceGate` let empty/template tables through for `compare_open_tabs` if the text isn't exactly filtered.
- Metadata-only failures are returning `.failedSilent` instead of proposing follow-up cards (for example in `liquidMetadataNote`).
- Follow-up action logic (e.g. `[FollowUpActionSet]`) is entirely missing in the current LiquidActionExecution layer. Thin output or `.captureNeeded` states simply abort instead of generating contextual follow-up cards.

## 3. What must be refactored
1. **Remove Hardcoded Strings**: Delete all specific rental sites ("kijiji", "rentals.ca", "zillow rental manager"), city names ("kingston"), university names ("queen's", "queens"), and specific project identifiers ("182 Montreal", "occupancy agreement") from the keyword lists. Replace them with broad, domain-general terms ("lease", "agreement", "tenant", "landlord", "rent", "rental").
2. **Remove Direct Mappings**: Eliminate the `deterministicRentalWorkflow` hardcoding `occupancy agreement` to `rental_lease`. It should rely on the generic frequency of semantic terms.
3. **Tighten Quality Gates**: 
   - Ensure `flag_risky_clauses` strictly checks for `why risky` and `ask/change` segments.
   - For `compare_open_tabs`, block template-only tables and empty tables.
4. **Follow-Up System**: Create a system that emits follow-up actions when an action returns thin output or requires full document capture. It should output `[FollowUpActionSet]`, `[FollowUpActionShown]`, `[FollowUpActionSelected]` logs.
5. **Readable Result Cards**: Sanitize result cards to hide debug jargon (e.g. `status=success`, `chars=624`, `browser_ax`). Ensure the titles match the content (e.g. "Check visible agreement text for risky clauses").
6. **Preserve Family Balance**: Ensure liquid workspace actions don't suppress other contextual families like friction (arrange windows) and music/focus actions. Adjust the `LiquidActionRouter` capacity reservation logic.

## 4. Whether Phase 55/56 violated architecture boundaries
- Phase 55/56 somewhat violated boundaries by inserting specific `if title.contains("occupancy agreement")` rules and specific string arrays directly into `LiquidActionRouter`. These should be generic signal classifiers, not hardcoded deterministic toolbars posing as liquid models.
- The `LiquidActionRouter` also began acting as a deterministic action forcing mechanism, which defeats the liquid goal.

## 5. Whether actions are actually liquid or deterministic toolbar rules
- At the moment, the rental and document workflows act more like deterministic toolbar rules because the presence of the exact dogfood keywords forces the entire workflow branch and the exact `flag_risky_clauses` actions. It lacks true liquid adaptability.
