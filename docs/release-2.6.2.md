# Ari IME 2.6.2

Bug-fix release restoring the regression test suite and fixing two
candidate-window defects. Typing behavior changes only in the cases below.

## Fixes

- Cross-page candidate selection: picking a candidate on page 2 or later
  selected the same slot from page 1 instead of the entry shown on screen.
  The selection path now passes the global index straight to
  `chewing_cand_choose_by_index` rather than paging and remapping through a
  page-local remainder. The user-phrase promotion path received the same
  fix. Contributed by @afcidk.
- Raw-key revert for out-of-order Bopomofo: when a syllable was typed with
  keys out of canonical order (for example `ox` composing ㄜㄌ), the
  "raw keys" candidate entry displayed and exploded the canonicalized order
  (`xo`) instead of what was actually typed. Cells now record the typed key
  sequence alongside the canonical reading, and both the raw-keys entry and
  the revert-to-English action use it. Conversion results, phrasing,
  learning, and reverse lookup are unchanged. Contributed by @HongyiHank.

## Tests restored

The `test/` directory returns to the repository after being dropped during
the Ari IME identity release. It brings back the buffer regression suite
(`test_buffer.cpp`) plus shared test helpers, including a new
`test_candidate_paging` case that reproduces the cross-page pick defect and
verifies the fix.

## Packaging

CMake, Arch (`PKGBUILD`, `.SRCINFO`), Debian changelog, native release, and
the `@ari-ime/wasm` package are synchronized at `2.6.2`.

## Validation

- CI Check workflow: GCC/Clang release builds, sanitizers, bounded fuzz,
  package simulation (all green on both fixes)
- Ubuntu build workflow including the Debian package job
- Nix flake check
