# Pinned predecode source baseline

The regression compares against four exact GPL source baselines from recorded
engineering revision `9e1fb498fa6ee75f5e88e3d63085c3f813f161c2`, before the
parallel ARAM selector. Small reverse patches reconstruct the old bytes from
hash-pinned current source. CPU/SNES share their exact packaging-baseline patches.

The manifest records current byte count/SHA-256/Git blob ID, patch SHA-256 and
reconstructed baseline byte count/SHA-256/Git blob ID. The test verifies inputs,
runs `git apply -R --check` then `git apply -R` in a disposable directory with no
`.git`, and verifies every reconstructed byte through the recorded hashes.
It never creates a historical commit or substitutes unchecked expected content.
All original source-preservation assertions remain. Changing production source
requires deliberately updating the exact reconstruction patch and its input pins.

Git must be on PATH, but no repository history, network or vendor models are
needed. The root GPL license and original notices apply. These are test inputs,
not a complete historical build tree or hardware evidence.
