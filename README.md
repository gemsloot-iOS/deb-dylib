# deb-dylib

Automated **`.deb` → arm64 `.dylib`** pipeline for jailed / sideloaded iOS injection.

Drop a rootful or rootless Cydia/Sileo package into this repo (repo root or `debs/`), push to `main`, and GitHub Actions will extract the payload, keep the arm64 Mach-O slice, remap Substrate/ElleKit load commands to `@rpath` for tools like Ksign, Feather, ESign, or Sideloadly, ad-hoc sign the binary, and commit a ready-to-use `.dylib` under `dylibs/`.

## How it works

1. **Trigger** — Push any `*.deb`, or change `scripts/` / the workflow. You can also run the workflow manually (`workflow_dispatch`).
2. **Extract** — `scripts/convert_debs.sh` unpacks the Debian archive (`ar` + `data.tar.*` for gz/xz/zst/bz2/lzma), then finds Mach-O `.dylib` files (including DynamicLibraries / framework binaries).
3. **Patch** — Sets `@rpath/<name>.dylib` as the install ID and rewrites common absolute jailbreak paths:
   - `/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate`
   - `/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate`
   - `/usr/lib/libsubstrate.dylib`
   - `/var/jb/usr/lib/libsubstrate.dylib`
   - `/var/jb/usr/lib/libellekit.dylib`  
   → `@rpath/CydiaSubstrate.framework/CydiaSubstrate`  
   Sibling dylibs from the same `.deb` are remapped to `@rpath/<dep>.dylib`.
4. **Sign** — Strips the old signature, then ad-hoc signs with `ldid` and/or `codesign -s -`.
5. **Deliver** — Writes results to `dylibs/`, uploads the `extracted-ios-dylibs` Actions artifact, and commits back with `[skip ci]` so the workflow does not loop.

## Layout

```text
debs/          # optional drop folder for .deb packages
dylibs/        # converted .dylib outputs (+ .info.txt reports)
scripts/       # convert_debs.sh
.github/workflows/deb-to-dylib.yml
```

## Inspecting load commands

Each converted library gets a sidecar report:

```text
dylibs/TweakName.dylib
dylibs/TweakName.dylib.info.txt
```

Open the `.info.txt` file to review `lipo -info`, post-patch `otool -L`, and `codesign -dv` without a local macOS toolchain.

## Manual / local run

On a Mac with Xcode CLT (and preferably `brew install xz zstd ldid`):

```bash
bash scripts/convert_debs.sh
```

## Requirements

- GitHub Actions `macos-latest` runner (native `otool`, `install_name_tool`, `lipo`, `codesign`)
- Workflow permission: `contents: write` (commits into `dylibs/`)
