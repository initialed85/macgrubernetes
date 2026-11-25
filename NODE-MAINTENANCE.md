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
