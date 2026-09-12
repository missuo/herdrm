# HerdrSSH

`HerdrSSH` is Heeler's repository-local Swift package for the native SSH
implementation accepted in ADR 0011. The package owns libssh2 and OpenSSL so
the app target consumes only the `HerdrSSH` product and never imports native
modules or owns native pointers directly.

The checked-in XCFrameworks are the normal build input. Rebuilding them is a
dependency-maintenance operation, not part of ordinary app or CI builds.

## Audit and rebuild

`Sources.lock` records the exact upstream release archives, tags, commits, and
SHA-256 hashes. `Scripts/build-native.sh` verifies both archives before
extracting or compiling them. A mismatch is fatal.

Run the complete rebuild from the repository root:

```sh
HEELER_SSH_XCFRAMEWORK_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" \
    make ssh-artifacts
```

The command builds Release arm64 slices for iPhoneOS and iPhone Simulator,
creates both XCFrameworks, refreshes licenses and provenance, writes file-level
SHA-256 checksums, signs the OpenSSL XCFramework, and verifies the result. Use
an Apple Development or Apple Distribution identity belonging to team
`9VM4RM39R3`. Exact byte-for-byte output requires the Xcode, SDK, compiler, and
configuration recorded in `Artifacts/PROVENANCE.md`; the signature and its
checksum also change when the signing timestamp changes.

To verify the committed artifacts without downloading or compiling sources:

```sh
make verify-ssh-artifacts
```

OpenSSL is built without its legacy provider and without the legacy algorithms
listed in the provenance record. libssh2 is compiled with its obsolete cipher
and signature switches disabled; the small reviewed patch in `Patches/`
removes SHA-1 key exchange and MAC methods that libssh2 1.11.1 otherwise has no
build switch for.

## Tests

Swift Testing under `Tests/HerdrSSHTests`. From the repo root:

```sh
make ssh-test
```

That runs `xcodebuild test -scheme HerdrSSH` against an iOS Simulator. Unit
tests always run. Session-driver e2e tests enable only when a disposable sshd
fixture exports `HEELER_SSH_E2E_*` into the Simulator (`simctl … launchctl
setenv`); without that fixture they skip. herdrm does not currently ship the
OpenSSH fixture runner — keep unit coverage green via `make ssh-test` /
`make mobile-build`.

## Jump Host

`SSHConnection.connectThrough(to:timeout:)` opens a `direct-tcpip` channel on
an authenticated Jump Host and runs a second, independent SSH session over its
byte stream. The target performs its own Host Key verification and
authentication. Closing the target connection tears down the target session,
forwarding channel, and Jump Host session in that order.
