# Node maintenance: swapping a binary on a darwin node

Measured on icarus-2, 2026-11-25, by maclet, after a ~10 minute crash loop:

* `~/.macgrubernetes/bin` is a **symlink into `releases/<tag>/bin`** (install.sh's
  `replace_link`). A `cp newbinary ~/.macgrubernetes/bin/maclet` therefore writes **in
  place into the released bundle directory**, replacing that release's bytes while
  launchd keeps the job alive.
* Truncating-and-rewriting the inode of a live linker-signed Mach-O leaves pages that
  no longer match the code signature, and macOS kills every exec of it. The crash
  reports name the cause plainly: `~/Library/Logs/DiagnosticReports/maclet-*.ips` with
  `termination: namespace CODESIGNING, code 2, indicator "Invalid Page"` /
  `EXC_BAD_ACCESS, SIGKILL (Code Signature Invalid)`.
* The node going `NotReady,SchedulingDisabled` during such a loop is maclet cordoning
  *itself* on graceful shutdown (`shutdownCordonAnnotation`) and uncordoning at startup
  only when it installed the marker. It is self-cleanup, not a bug.

## The rule

Never `cp` (or `>` or any in-place write) over a live binary path on a darwin node.
The safe swap is copy → sign → atomic rename:

```bash
scp new-maclet mac-node:/tmp/
ssh mac-node '
  cd ~/.macgrubernetes/bin            # follows the symlink into releases/<tag>/bin
  cp /tmp/new-maclet maclet.new
  codesign -f -s - maclet.new && codesign -v maclet.new
  mv maclet.new maclet                # replaces the directory entry; old inode survives
  launchctl kickstart -k system/cc.initialed85.maclet
'                                     # ThrottleInterval is 30, so give it ~45s before checking
```

`scripts/hot-swap.sh` on the node performs exactly this for any bundled binary
(`maclet`, `macker`, ...) and refuses obvious mistakes. Prefer, though, the ordinary
path: install a **new release** with `install.sh --release <tag>` (it moves whole
release directories and swaps links atomically; old releases stay intact) and let
`update.sh` keep the pin honest. A hot-swap is an emergency tool; it edits a released
build's bytes and makes that release no longer match its published checksum.

## Checksums and restores

Every bundle release publishes `macgrubernetes-build-<n>-darwin-arm64.tar.gz` plus a
`.sha256` asset on GitHub. After any swap, verify against the release checksum:

```bash
sha256sum ~/.macgrubernetes/releases/<tag>/bin/maclet   # compare with the release asset
```

If a hot-swap clobbered a release's bytes (build-61's `bin/maclet` was clobbered this
way on 2026-11-25 and never restored from the node), the release archive is the source
of truth: download `macgrubernetes-build-<n>-darwin-arm64.tar.gz`, check it against the
`.sha256` asset, and copy `bin/maclet` back with the copy → sign → atomic rename rule.

## Provenance pairing (rule adopted from macker, 2026-11-25)

A binary sha256 on its own certifies nothing. `codesign -f -s -` rewrites the Mach-O's
signature, so the installed hash differs from the CI artifact hash, and neither one is a
source commit. Concrete failure seen tonight: a lifecycle stage was graded green against
a macker stamped `7a3b42ae…`, which is not a commit in macker's history at all — it was
the *installed binary hash* of build-33 (source commit `dee408c`), with no pairing recorded.

So every swap records a triple — **commit + build tag + hashes** — in
`~/.macgrubernetes/provenance.log`:

```bash
MACGRUB_PROVENANCE_REF='macker build-38 866c98fd4b24173135fd3e0d76ccec5195e01fab' \
    ~/.macgrubernetes/bin/hot-swap.sh macker /tmp/macker-866c98f
```

`hot-swap.sh` appends timestamp, component, staged source hash, installed hash (post-
codesign) and the ref automatically; it warns on the console when the ref is missing.
When building from a checkout instead of a CI artifact, the commit is
`git rev-parse HEAD` **of the tree the binary was compiled from**, taken before shipping
it. A green lifecycle stage may only be cited against a binary whose ref is in that log.

## Acceptance markers after installing macker build-38 (866c98f) or later

`macker volumes --format json` on the node must show:

- `probe_status: "not_attempted_os"` (a decision, not an unknown), and
- `guidance` containing `errno 19 is ENODEV on both Darwin and Linux` - proves the false
  "ENOTSUP"/"kernel does not register nullfs" text is gone (builds before it printed that
  false sentence into Pod status at admission time), and
- `guidance` containing `EPROGMISMATCH (75, which Linux numbers as EOVERFLOW) for nfs` -
  distinguishes 866c98f from its immediate predecessor ff7b159.

If the installed binary's output lacks these, the wrong build landed; treat it as a failed
install, not a cosmetic mismatch.

## Reading a node that has NOT been rolled yet

A node still running an old macker build (build-33 `dee408c`, or the do-not-select builds
35/36) prints a false kernel claim into every refused read-only hostPath Pod's status. The
correction exists on such a node in exactly one place: maclet's own log line naming the
falsified claim and the real mechanism (the type name `nullfs` is registered; `mount(2)` as
root draws `EPERM` because its entry point is gated on `com.apple.private.nullfs_allow`
with no superuser fallback). Grep the maclet log for either measured prefix:

- `macker read-only volume capability for this node:`
- `macker read-only volume guidance for this node:`

The lifecycle stage (`test-native-workload-lifecycle.sh` in the maclet checkout) now rejects
falsified claims in `.status.message` instead of accepting any mechanism text. Run against
an unrolled node it must FAIL, naming the fix range - that red run is the live defect being
instrumented, not a flake and not a reason to postpone the roll. Do not loosen the stage to
make a pre-roll run green. Because that check lives in the script, always run it from a
current maclet checkout (`git pull` first): the installed binary does not carry it.
