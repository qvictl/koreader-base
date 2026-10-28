# Native font lifecycle measurement

The candidate fixes three strong-reference retention paths: unused LVArray tail
slots in the font instance cache, lazy fallback/list-marker cycles (including
synthetic proxies), and LVDocView members released after its earlier collection.
No cross-size FT_Face sharing is introduced.

## Matched host experiment (2026-10-28)

Three interleaved baseline/candidate pairs, three open/20-page/close cycles per
fresh process. Both variants used the same full-feature native CMake build and
frontend ba9cdf3b, the same 34 MB privately supplied Chinese EPUB, Zhuque Fangsong
technical-preview font and Noto CJK/Arabic fallbacks, 1072×1448 at 300 dpi,
low-memory profile, storage factor 4, clock/battery header disabled and footer
disabled. Build environment: Ubuntu 26.04, HarfBuzz headers 12.3.2,
libunibreak 6.1 and LunaSVG 2.3.9 with the existing base patches. Both processes
actually loaded the identical bundled FreeType 2.15.0 and HarfBuzz 14.5.1
libraries (confirmed from process maps and runtime version functions). Native baseline
engine f335f7a9; candidate engine 99a24af plus base's post-delete collection.

Values below are medians across the three processes, in MiB (1024² bytes).
RSS/PSS are sampled after forced Lua collection and a 0.5 s event-loop wait;
these rows precede any diagnostic malloc_trim. The timing column includes that
wait for closing. The complete measurements are in
[font-lifecycle-2026-10-28.json](font-lifecycle-2026-10-28.json).

| Stage | RSS before → after | PSS before → after | Live faces before → after | Time ms before → after |
|---|---:|---:|---:|---:|
| Browser | 55.9 → 56.0 | 53.6 → 53.8 | 0 → 0 | — |
| First open | 153.0 → 143.7 | 112.4 → 111.0 | 24 → 12 | 831 → 822 |
| First 20 page turns | 157.2 → 157.5 | 115.6 → 114.4 | 24 → 26 | 323 → 319 |
| First close | 85.6 → 69.2 | 78.9 → 65.9 | 6 → 0 | 750 → 731 |
| Second close | 89.3 → 72.4 | 81.0 → 68.2 | 5 → 0 | 560 → 564 |
| Third close | 91.9 → 73.8 | 82.7 → 69.5 | 7 → 0 | 551 → 559 |

Closed-book savings are 16.4–18.0 MiB RSS and 12.8–13.3 MiB PSS. Maximum process
high-water RSS across the sampled processes is 165.7 → 160.2 MiB. The first
paged RSS does not improve; the principal benefit is releasing memory on close.
All 18 page-21 PNGs have SHA-256
`55c28619c884fe3031d00aa7cc9e56e04ce4217b7d331243e09d19ac356b1da5`.

The observer uses FT_Face generic finalizers, so actual destruction is counted
whether invoked by FT_Done_Face or inside FT_Done_FreeType. At every book-close
sample library-cleanup releases are zero, baseline retained faces are 6/5/7,
and candidate retained faces are zero. The native font regression also requires
zero live faces before font-manager shutdown, and fails against the old engine
when a deleted middle cache entry leaves a hidden reference in a tail slot.

## Reproduction and limits

Build baseline and candidate with identical dependency versions, feature flags
and optimization; only the font lifecycle patch and wrapper collection differ.
Use the companion KOReader `tools/benchmark_font_memory.sh` with the same
`--book`, `--font` and frontend commit for both runtimes. It records RSS/PSS,
FreeType finalizers, timings, screenshots and real ReaderUI close/reopen checks.
Set FONT_BENCH_EXPECT_ZERO=1 only for the fixed runtime. The book is private and
is not included in either repository; the regular integration scenario uses a
public synthetic CJK EPUB instead.

These are Linux host emulator measurements, not Kindle measurements. Allocator
behavior, binary features and font selection affect the benefit on a roughly
488 MB Kindle. C++ changes require rebuilt native binaries and cannot be shipped
as a Lua-only backport. FT_Face sharing across sizes remains separate research:
FT_Size state, variable-font coordinates and thread safety require independent
validation.
