# Pinned packaging-policy fixtures

These snapshots make the 81 historical packaging-policy tests runnable from a
clean checkout. They contain original upstream/derived GPL source and package
configuration only. No ROM, save, vendor simulator, build report or compiled
FPGA image is included. The root repository's LICENSE applies.

The manifest records file size, SHA-256, Git blob ID, source revision and storage
location. Files identical to this reviewed checkout are reused only after all
three checks pass. Ten differing historical source blobs are stored once under
their SHA-256 names. They were extracted from retained Git objects, not rebuilt
from the candidate implementation. Each registered hardware inventory matched
the pre-existing `standard_msu1_reviewed_sources.json` fingerprint.

One exception is explicit: hardware identity `30f55d5` lacks a local commit
object. Its hardware-only snapshot comes from its registered build revision
`0da938e`; the complete inventory matches the already-recorded SHA-256
`e639440406e489e7ac46dce032baa1b13ef7878593a88f40860742255601a723`.
This establishes the tested hardware-file equivalence, not the missing commit's
metadata, parentage or full tree. No fake Git object is created.

The test-only provider replaces the source transport for packaging policy
tests; none of their rejection or mutation assertions is removed. Separate
real-Git tests exercise production commit/type/path/blob handling. The actual
packaging CLI does not import this provider and still requires genuine Git
evidence. This fixture does not make other historical HDL suites standalone.

## Savestate branch independence

The savestate branch modifies nine formerly shared checkout paths. Their exact
pre-existing bytes are reconstructed with small reverse patches rather than
large duplicated source files. The expected baseline bytes were verified from
public base `44442443508356dbc362c6c34304a51cc5b5ba16` against every already
registered size, SHA-256 and Git blob ID. These expected identities are unchanged.
The original ten historical full-source fixture blobs are retained unchanged.

The test-only reconstruction verifies current source and patch hashes, runs
`git apply -R --check` and applies the reverse patch in a disposable directory
with no `.git`, then validates the exact old bytes. The cache is keyed by complete
source and patch bytes; hashes are checked on every call. No assertion, rejection
oracle or hardware inventory is weakened. Production packaging does not use
this helper and still requires authentic Git evidence.
