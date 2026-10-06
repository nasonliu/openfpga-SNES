# Source test scope

## Plain-cartridge savestate experiment

The new suites and generated original fixtures are under `tests/savestate_*`.
Use installed tools on PATH; no simulator or vendor library is bundled.

```sh
python3 -m unittest discover -s tests -p test_savestate_sources.py -v
python3 -m unittest discover -s tests -p test_build_msu1.py -v
python3 tools/generate_savestate_rom.py
python3 tests/savestate_identity/run.py
bash tests/savestate_protocol/run.sh
python3 tests/savestate_storage/run.py
python3 tests/savestate_storage/run_request_stage.py
python3 tests/savestate_storage/run_pin_hold.py
python3 tests/savestate_storage/run_sram_clear.py --request-stage
python3 tests/savestate_storage/run_aram.py --request-stage
tclsh tests/savestate_storage/test_sram_load_policy.tcl
python3 tests/savestate_predecode/run.py
python3 tests/savestate_stage1/run.py --build-only
python3 tests/savestate_stage1/final_aram_variant/run.py
```

The predecode suite uses hash-checked exact reverse patches rather than
inaccessible historical Git objects. Git is required on PATH; no .git directory
is needed. Generated helper MIF/HEX files are ignored and recreated from the
pinned helper before the source-integrity and real-core tests. The real-core harness generates its original LoROM/HiROM
fixtures in the output directory. APF transport integration additionally needs
your licensed Quartus model directory, supplied explicitly:

```sh
python3 tests/savestate_protocol/run_integration.py --vendor-sim-dir "$QUARTUS_ROOTDIR/eda/sim_lib"
python3 tests/savestate_protocol/run_verilator.py --vendor-sim-dir "$QUARTUS_ROOTDIR/eda/sim_lib"
```

Read each suite's scope before interpreting a pass. These simulations are not
Pocket hardware or external SRAM/PSRAM timing qualification. A source import
alone is not evidence that every suite has passed on the current revision.

## Incomplete battery-save session matrix

`tests/savestate_backup_session/` preserves the earlier 14-case admission source.
Its reduced bench still uses a constant upload ACK and does not validate the new
host-native ACK interlock. State-first uploads, full 128 KiB/overflow rejection
and registered slot-ID cases remain incomplete. This export did not rerun that
matrix. Read its README before interpreting any old PASS result.

## Existing MSU/packaging source tests

From the repository root, these source tests are self-contained:

```sh
python3 -m unittest discover -s tests -p test_assets.py -v
python3 -m unittest discover -s tests -p test_standard_save_testrom.py -v
python3 -m unittest discover -s tests -p test_package_standard_msu1.py -v
python3 -m unittest discover -s tests -p test_standard_package_sources.py -v
```

They check packaging policy, Git source handling, the generated diagnostic
program, formats, simulated instruction behavior, and disposable save validator. They do not simulate the full SNES
or validate FPGA hardware. During local PR preparation, all 25 tests passed.
The PCM HDL class was not run because Icarus was unavailable in that Windows
environment. A local temporary-directory adapter was needed for its sandbox;
the checked-in test assertions were unchanged. The latest Linux clean-export
run needs no sandbox adapter: 15 asset tests, 10 save-validator tests, all 81
packaging-policy tests and 7 real-Git/fixture-integrity tests pass (113 total).
That export has no `.git` directory or engineering history. The dedicated
`MSU source tests` workflow runs these same commands.

Other tests and tools are retained engineering regression sources. Many need
Linux, HDL simulators, user-provided Quartus simulation models, and exact old
Git objects (including `b63f800`, `982f103`, `84d8d5e`, `3ddde3f`, `116961d`,
and `af743650`). Those engineering objects and generated evidence archives
are not included here. In particular, full unittest discovery, the aggregate
standard-memory runner, and historical package generation are not standalone
clean-checkout acceptance commands. Missing dependencies are not a pass.

The packaging-policy dependency is now supplied by [pinned source snapshots](fixtures/standard_package/README.md).
All original mutation/rejection assertions remain. The test-only source
provider does not alter production packaging, and separate real-Git tests
cover committed bytes, missing revisions, empty selections, object types and
symlink rejection. Other historical HDL comparisons still need their inputs;
this change does not claim those aggregate suites are standalone.

Before this fixture change, the final 81-test packaging suite was attempted in an isolated Linux
checkout carrying the verified 11-file final delta. Locally, 74 passed and
7 failed/errored because required historical Git objects were absent from the
available bundles (4 failures, 3 errors). That attempt was not a pass.
That earlier dependency failure is resolved by the 81/81 clean-export run
above. Historical complete-history verification is separate evidence.

See [the review guide](../docs/MSU1-STANDARD.md) for separately identified
historical qualification and limited real-hardware feedback.
