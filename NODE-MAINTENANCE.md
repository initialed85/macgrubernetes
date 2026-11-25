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
