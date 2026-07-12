#!/usr/bin/env bash
#
# mayhem/build.sh — build guillotiere's cargo-fuzz target as a sanitized libFuzzer
# binary (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), plus the project's
# own test suite (normal flags) so mayhem/test.sh only RUNS it.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
# The first (online) build populates the cargo registry under $CARGO_HOME; the
# offline re-run resolves crates from that cache (CARGO_NET_OFFLINE=true is
# exported by the rlenv runtime — do NOT hard-code --offline here).
#
# Sanitizers: Rust uses -Zsanitizer=address via RUSTFLAGS, not the C/C++
# $SANITIZER_FLAGS/$CFLAGS from the base ENV (rustc ignores clang flags). The
# libfuzzer-sys C++ runtime IS compiled by the cc crate, which reads
# CFLAGS/CXXFLAGS below (-gdwarf-3 keeps its DWARF < 4 too).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# DWARF < 4 contract (§6.2 item 10): rustc defaults to DWARF 4+ — pin version 3.
RUST_DEBUG_FLAGS="${RUST_DEBUG_FLAGS:--Cdebuginfo=1 -Zdwarf-version=3}"
# cc-crate compiles (libfuzzer-sys runtime) must carry DWARF 3 as well.
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

# The prebuilt rustc ASan runtime archive ships DWARF 5 CUs and lands FIRST in
# .debug_info; Mayhem's triage reads the first CU. Prepend an empty clang
# -gdwarf-3 anchor object via a linker wrapper so a DWARF 3 CU sits at offset 0
# (the fleet-playbook first-CU recipe; Rust code itself is DWARF 3 via
# -Zdwarf-version above).
printf 'void mayhem_dwarf_anchor(void) {}\n' > /tmp/mayhem-anchor.c
clang -c -gdwarf-3 -O0 -o /tmp/mayhem-anchor.o /tmp/mayhem-anchor.c
cat > /tmp/mayhem-cc-wrapper.sh <<'EOF'
#!/usr/bin/env bash
exec cc /tmp/mayhem-anchor.o "$@"
EOF
chmod +x /tmp/mayhem-cc-wrapper.sh

FUZZ_RUSTFLAGS="--cfg fuzzing -Zsanitizer=address $RUST_DEBUG_FLAGS -Cforce-frame-pointers -Clinker=/tmp/mayhem-cc-wrapper.sh"

# Additive mayhem/fuzz crate (upstream's fuzz/ pins libfuzzer-sys 0.3 / arbitrary
# 0.4, which don't build on the pinned nightly — same harness, updated deps).
FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$FUZZ_RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  RUSTFLAGS="$FUZZ_RUSTFLAGS" cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# Build the project's TEST suite with its NORMAL flags (no sanitizers) so
# mayhem/test.sh only RUNS it. --all-features covers the feature-gated tests
# (recording behind "serialization", extra asserts behind "checks").
echo "=== building the upstream test suite (cargo test --no-run) ==="
env -u RUSTFLAGS cargo test --workspace --all-features --no-run

echo "build.sh complete"
