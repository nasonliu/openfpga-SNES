# Exact test-source reverse patches

These 12 patches preserve nine public packaging baselines, four predecode
baselines (two are shared), and the pre-recovery SRAM negative baseline. Each is the exact forward delta from its recorded
baseline to current source; the test applies it in reverse. No historical commit
object or complete engineering history is created or needed.

Manifest entries in the neighboring fixture directories bind the current source,
patch and reconstructed baseline independently. Source notices remain unchanged.
The checked-in GPL source retains its original license. See the manifests and
`tests/pinned_source.py` for validation; these patches are never used by production
builds or packaging.
