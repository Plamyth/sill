# iPad keyboard viewport defect — 2026-10-18

Task owner: this writer, exclusive ipad-full-duplex-20261018 worktree. Starting source matched canonical 738d2d9 after cherry-picking test-only fixes 4643786/21479b8. No canonical writes, apps, device, audio or volume changes. Parent owns SDK build/physical acceptance and independent review.

pstack Bug fix / Fix Root Causes: inspect safe-area ownership; reproduce through synthetic exact keyboard geometry; change the opt-out boundary rather than translate touches. Model the Domain: test shape is window bounds + keyboard rectangle + safe-area regions -> proposed panel geometry. Production video and input continue sharing measured bounds.

- [x] Reproduce it yourself on the matching surface via the driver skill: skip actual driver, explicitly prohibited; use synthetic geometry model and label limitation.
- [x] Binary-search the cause: StreamScreen's default all-region bottom opt-out includes keyboard. ContentView opt-out belongs only to Color background sibling. No video/input mapping discrepancy found.
- [x] Plan the fix: iPad container-only opt-out; retain intentional phone behavior. No signature change or new production type. Findings/plan sent before implementation.
- [ ] Verify on the same surface: synthetic before/after; physical remains parent gate.
- [ ] Stage the commits so the failing repro lands before the fix in git history.
- [ ] Run Opening a PR: skip remote publication; parent cherry-picks isolated commits and owns independent review.
