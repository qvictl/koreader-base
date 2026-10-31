# copyFile: report I/O failures before callers remove sources

## Evidence

The review of [KOReader PR 65](https://github.com/qvictl/koreader/pull/65)
identified a pre-existing error-contract gap in `ffi/util.lua` at base
`cc2be6a552998ca3ee379c1eec56db29df53beb9`. `copyFile` returns nil on success and an
error string on open failure, but ignores read errors, writes and close results.
A destination-open failure also leaves the source stream open until collection.

Real Linux subprocess tests lower only the disposable child's `RLIMIT_FSIZE`
to zero and ignore its `SIGXFSZ`. They independently verify the stdio failure
stage before exercising the actual helper:

- A 16 KiB write fails with `File too large` after the destination is created.
- A 1 KiB buffered write succeeds, then close fails with `File too large`.
- Original `copyFile` returns nil in both cases and leaves a zero-byte file.
- Reading a directory on Linux raises a real read error; the original helper
  mistakes it for EOF and again returns success with an empty destination.

No device, full filesystem, user file or parent process limit is modified.
Portable stream facades also inject read/write/source-close/target-close errors
around owned real files, so failures and descriptor cleanup are covered in the
parent's unit-coverage statistics. Kernel probes are independent of those facades.

## Change and compatibility

Retain the nil-on-success/error-string contract. Check read, write and both
close results; close the source immediately if destination open fails. Prefer
the first I/O failure when later cleanup also reports an error. On failed copy,
attempt to remove an incomplete regular destination, but never unlink symlinks or
special targets such as device nodes. Source-close failure alone still returns an
error but retains the completed target when its writes and close succeeded.
Copying still uses bounded 8 KiB chunks. Destination symlinks retain the existing
in-place write behavior; preserving the link does not restore its referent after
a failed write.

Existing callers that check nil/error now reject detected write/close/read
failures instead of treating them as successful copies. Inspection covers
DocSettings migration/custom covers and cloud snapshot publication. Statistics,
news downloader, default-settings and cover-image callers that ignore the return
value keep their existing API behavior; they do not gain error UI here. Successful
copy behavior, overwriting and source/destination path interpretation are unchanged.

This still overwrites the destination **in place**. It does not preserve an old
destination atomically, perform fsync, guarantee cleanup succeeds, or protect
same-inode aliases. An error is returned even when cleanup cannot remove the
partial destination. It is not a power-loss durability claim. KOReader PR 65's
separate identical-path guard and checked main-save result remain necessary.

## Local validation

- **90/90 related native tests** in five complete utility suites, including twelve
  new cases; original production fails ten new cases and passes the two ordinary
  copy/source-open controls.
- **37/38 complete base suites pass, 504 successful cases**. The only remaining
  failure is the existing live Internet HTTP case. The generated POSIX declaration
  suite passes all eleven variants after reproducing the standard ffi symlink /
  ffi-cdecl layout in the owned runtime. No test or gate was weakened.
- **16/17 changed executable lines covered (94.1%)**; unchanged diff80 gate passes.
  The uncovered line is the multiline assignment anchor, not an untested error
  branch. Lua lint reports zero warnings/errors. Whole coverage is unmeasured.
- All 155 front suites also attempted against core main `1d97693` plus local
  PR 65 with the corrected helper overlay: **152 pass, 2,184 successful cases**.
  Remaining unchanged host blockers are unavailable msgfmt, prohibited getifaddrs
  and four live translator DNS errors. This is not a clean full-suite claim;
  required remote CI and review must cover the final head.
- KOReader scenario `44_sidecar_copy_io_failure`, staged locally for PR 65's
  eventual pin update: **13/13**, three fresh runs. Actual ReaderUI bookmarks,
  main-sidecar persistence, kernel-limited large-cover writes and buffered custom
  metadata closes, source-byte retention, partial-file removal, unrestricted
  retry, reopening and page turns are exercised. Only fault timing is controlled:
  the real main-settings writer completes before the child lowers its own limit.
  Original base helper fails the source-cover preservation check.
- Existing sidecar scenario 42 also passes **32/32** in three fresh runs with
  this helper overlay. After the cleanup-boundary corrections, scenarios 16/42/44
  pass three more fresh runs each: **3×58/58 checks**.
- Formal review found two cleanup-boundary issues: source-close-only errors
  removed completed targets, and following symlinks for the type check removed
  the link on a write failure. Both have negative regression evidence against
  `71a1e850` (2/12 failures), and are corrected without changing the return API.
  Independent review of these corrections finds no blocker and reruns **12/12**
  cases successfully in a separate owned runtime.
- Independent local review found no production blocker and reran all eleven
  fault cases. Its nonblocking timeout-cleanup suggestion is incorporated: close
  the result pipe and perform bounded child reaping before failing a timed-out
  probe, rather than risking a blocking read or leaving a zombie.

This is the current Lua helper overlaid into an existing verified native emulator,
not a new native build or a Kindle hardware/durability test. The base input-EOF
work in PR 36 is independent and is not included or approved by this change.
The final KOReader gitlink must reference an actually merged, authorized base
commit; review gates and any do-not-merge hold remain in force. No upstream
submission, release, device installation or paid add-on activation is authorized.
