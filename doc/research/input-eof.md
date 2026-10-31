# Native input EOF regression (2026-10-31)

Upstream report: [koreader-base#2504](https://github.com/koreader/koreader-base/issues/2504)
(Kindle Scribe, repeated `EPIPE` after `lipc-wait-event` exited). The issue was closed
as `not_planned`, not recorded as fixed. The fork's `cc2be6a552998ca3ee379c1eec56db29df53beb9`
still retains an input descriptor after `read` returns zero.

A pipe at EOF stays readable to `select`. Returning `EPIPE` without removing it
therefore repeatedly wakes the frontend and can starve later input descriptors
and timer callbacks. The same poll also discarded events already read before EOF.
This is reproducible with owned local pipes, independent of Kindle firmware.

The change closes/retires the EOF descriptor through the existing dense-array
helper and returns already-read events using their original descriptor identity.
An empty EOF still reports `EPIPE` once. Live pipes at `EAGAIN` are unchanged.
Both EOF returns also include the retired descriptor as a fourth result; the
third remains reserved for an expired timerfd. Companion core code consumes
this metadata before dispatch, removing all path aliases without closing the
descriptor again. Otherwise the frontend registry would suppress reopening
that path, or close an unrelated input after the OS reused its descriptor.
This **does not restart a terminated powerd/lipc listener** or prove the cause of
that listener's termination; missing power events still require restarting KOReader.

## Tests

`spec/unit/input_eof_spec.lua` loads a Linux-emulator-only fixture compiled from
actual `input/input.c`, with only the hardware event generator unavailable. It
uses the real Lua C API, Linux `select`, pipes, reads, closes and timerfd; it does
not mock readiness or duplicate the poller algorithm.

The six tests cover empty EOF closure/one-shot error; preservation of 1, 256 and
257 final events and original fd identity; the next ready input after dense-array
repacking; a still-registered live pipe; and timer delivery after the highest
input fd closes. All resources are owned by the test.

On the Linux x86-64 host, compiling the fixture against the old source gave
**0 successes, 6 assertion failures, 0 errors**. Recompiling after the change gave
**6 successes, 0 failures, 0 errors**. The compile also passed
`-O2 -fvisibility=hidden -Wall -Wextra -Werror`. The executable is the fork's
`v2026.10.q1_emulator` LuaJIT; the input shared library was rebuilt locally from
this exact source, not reused from that release. Standard LuaJIT 2.1 public
headers were the build input. No device was modified and no Kindle native build
or hardware resume verification is claimed.

The CMake target `koreader-input-test` builds only for the Linux emulator and is
not part of Kindle/device binaries. Native/build changes select the full unit
suite through the existing selector. Lua-only diff coverage does not measure
this C change; the native regression assertions and normal CI build are the
relevant evidence. Companion [core PR63](https://github.com/qvictl/koreader/pull/63) adds
`35_native_input_eof`: real ReaderUI, frontend input translation and UIManager
page turns with owned pipes and the actual rebuilt native poller. The old module
fails the fd-closure assertion. After the cross-repository registry correction,
the scenario passes 12/12 assertions plus two page-turn waits in three isolated
runs (1.0 s, 1.1 s and 1.0 s), including actual OS descriptor reuse and protection
of the replacement input from a late close of the old path. The new module with
old frontend code fails at the registry-cleanup assertion. No fake powerd service
is started.
The companion stays draft until it pins the actual base main merge commit.

Normal [CI 41160236077](https://github.com/qvictl/koreader-base/actions/runs/41160236077)
compiled this fixture, passed its binary check and all **38/38 complete unit
suites**, including `input_eof`; required lint/tests-policy/coverage also passed
at the initial native candidate `b640fd21`. These CI results predate the fourth
return-value correction: they are not evidence for the revised head. Locally,
the corrected native module passes all six tests (including retirement metadata)
under the same strict compiler flags. Core's five adjacent input suites pass
79 tests; its repository coverage reporter measures 100% (5/5) changed executable
Lua lines. Fresh CI and review remain required for the revised head.
