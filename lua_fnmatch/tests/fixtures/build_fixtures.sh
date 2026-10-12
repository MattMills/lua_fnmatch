#!/bin/sh
# Builds the test fixtures from fixture.c: two x64 DLLs with their PDBs (clang, lld-link), and the
# .sig file of the reference build (stellar-fnmatch from the submodule). The outputs are
# committed, so the tests need none of these tools. Run this after changing fixture.c, or when
# the submodule's signatures change.
#
# Needs clang, lld-link and llvm-dlltool (LLVM 14 or newer), and cargo.
# FIXTURE_CARGO_TARGET_DIR reuses a cargo target directory for stellar-fnmatch.

set -eu
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

find_tool() {
    for t in "$@"; do
        if command -v "$t" >/dev/null 2>&1; then
            echo "$t"
            return
        fi
    done
    echo "missing: $1" >&2
    exit 1
}
clang=$(find_tool clang clang-18 clang-17 clang-16 clang-15 clang-14)
lld_link=$(find_tool lld-link lld-link-18 lld-link-17 lld-link-16 lld-link-15 lld-link-14)
dlltool=$(find_tool llvm-dlltool llvm-dlltool-18 llvm-dlltool-17 llvm-dlltool-16 llvm-dlltool-15 llvm-dlltool-14)

"$dlltool" -m i386:x86-64 -d kernel32.def -l "$work/kernel32.lib"

for v in 1 2; do
    define=""
    if [ "$v" = 2 ]; then
        define="-DFIXTURE_V2"
    fi
    # not -ffreestanding: it drops the unwind tables (.pdata)
    "$clang" --target=x86_64-pc-windows-msvc -O2 -g -gcodeview -fno-builtin \
        -fno-stack-protector -mno-stack-arg-probe $define -c fixture.c -o "$work/fixture_v$v.obj"
    "$lld_link" /dll /noentry /debug /Brepro /nodefaultlib /pdbaltpath:%_PDB% \
        /pdb:fixture_v$v.pdb /implib:"$work/fixture_v$v.lib" /out:fixture_v$v.dll \
        "$work/fixture_v$v.obj" "$work/kernel32.lib"
done

# the reference .sig file, written by stellar-fnmatch itself
target="${FIXTURE_CARGO_TARGET_DIR:-$work/target}"
CARGO_TARGET_DIR="$target" cargo build --release --quiet --manifest-path ../../lib/stellar-fnmatch/Cargo.toml
fnmatch="$target/release/stellar-fnmatch"
"$fnmatch" extract-one --exe fixture_v1.dll --pdb fixture_v1.pdb --id fixture_v1 --platform gog --out "$work/fixture_v1.fnx"
cat > "$work/corpus.json" <<EOF
{"builds": [{"id": "fixture_v1", "platform": "gog", "version": "1.0", "build_string": "", "commit": null,
 "build_date": null, "source": "", "exe_path": "", "pdb_path": null, "exe_md5": "", "exe_size": 0}],
 "skipped": []}
EOF
"$fnmatch" sigs --corpus "$work/corpus.json" --extract-dir "$work" --out-dir . --force
ls -l fixture_v1.dll fixture_v1.pdb fixture_v1.sig fixture_v2.dll fixture_v2.pdb
