# RGB565 scaling stride regression

## Source and defect

The report and suggested stride correction are from
[nebtu's RGB565 image-scaling report](https://github.com/koreader/koreader/issues/16298).
The reporter disclosed AI assistance. The follow-up confirms the issue also
occurs on a current nightly. Both fork base `0cdffb07f88b58ea8d7684c30faa3db0a4adf5f4`
and upstream base `007ac6a81e2de4822c8df7ce57b8dbb06aa3b8ea` contain the affected code.

`scaleBlitBuffer` converts RGB565 input to a temporary RGBA buffer. The old
code retains the original input stride, although the data pointer now belongs
to the RGBA allocation. An unpadded 12-pixel RGB565 row has stride 24; the
converted row has stride 48. Padded source rows can also exceed the converted
allocation's row length. Passing either old value does not describe the new
buffer. Reading `bb.stride` after conversion fixes the contract without
changing the surrounding ownership, exception, or cleanup paths.

## Native unit evidence (2026-10-30)

`spec/unit/mupdf_spec.lua` adds two tests. The first interposes only the
pixmap-construction boundary and verifies the actual buffer owner's stride
before forwarding to the real native backend. Old production code fails safely
at this Lua assertion (24 versus 48); invalid layout data never reaches native
code. The fixed code passes for BB8, BB8A, RGB24, RGB32, BB4 and RGB565.

The second test uses real MuPDF scaling with RGB565 source strides 24, 32 and
64. All three produce 6-by-4 output from 12-by-8 input, retain red/blue corner
pixels, preserve source ownership, and leave the complete source allocation
(including padding) unchanged. Both tests passed with prebuilt Linux emulator
MuPDF 1.27.2 libraries and this worktree's Lua modules. No native rebuild,
Android/macOS/Kindle run, or whole-suite pass is claimed.

In a prepared native base test installation, the targeted tests can be run with:

```sh
./spec/runtests --busted --filter='blitbuffer scaling' base spec/base/unit/mupdf_spec.lua
```

Local LuaCov evidence covers the changed production assignment: **1/1 (100%)**.
The reporter used an explicit absolute-prefix mapping because the isolated
read-only runtime loaded this worktree by its absolute Lua path. Whole coverage
is unmeasured; no baseline/history was written. Luacheck reports zero warnings
and errors for both changed Lua files.

Raw local evidence is retained in the implementation worktree under
`.agent-upstream-triage/`: `stride-negative.log`, `stride-positive.log`,
`unit.stats.out`, `coverage.json`, `lint.log`, and the executable native runner.
Initial loader-environment failures have separate `native-setup-*` names and
are not counted as defect reproduction.

## Companion emulator source and evidence

Core branch `test/rgb565-scaling-integration-main03`, commit
`f76d9115004eb61c46a993f0eac85a63802487bb`, adds a section to
`spec/integration/scenarios/17_document_regressions.lua`. Its parent is actual
core main `4db3dccf03f298f32b80becb6c71f87069fb6b7e`. It invokes the
real UI event loop and `RenderImage:scaleBlitBuffer`, with three RGB565 pitches,
backend layout guards, real native scaling and source preservation checks.

A fresh KOReader process loading old base source `0cdffb0` fails at the safe
Lua stride guard. Another fresh process loading the fixed module passes
**35/35 checks** (25 new checks plus 10 existing document checks). Both exit
normally and leave no background process. The execution reuses the existing
core `a2c` / base `7c4` compiled Linux emulator and explicitly preloads the
selected `ffi/mupdf.lua`; it is not a claim of a newly built cross-repository
package. Isolated scripts, profiles, logs and result JSON are retained in the
core worktree under `.agent-rgb565-integration/`.

The core test branch is pushed, but has no PR yet. Its base gitlink remains
unchanged. It must be coordinated with the actual merged base SHA later;
this evidence does not pin an unmerged base candidate to core main.
