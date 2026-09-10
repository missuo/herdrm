# HerdrTailcat

`HerdrTailcat` is the repository-local Swift package that embeds the
[tailcat](https://github.com/tailscale/tailcat) (WireGuard/DERP) client so the
app reaches a remote herdr through the `herdr.tailcat` plugin — in-process,
with no helper binary and nothing to install on `PATH`.

The checked-in `Artifacts/Tailcat.xcframework` is the normal build input.
Rebuilding it is a dependency-maintenance operation, not part of ordinary app
or CI builds.

## Layout

- `go/bridge` — the shared transport core: one tailcat session per device,
  re-served on a local Unix socket (API on the listen path, client-protocol on
  the derived `-client` sibling). Consumed by both the gomobile face and the
  standalone CLI (`Tools/herdr-tailcat-bridge`).
- `go/tailcatmobile` — the gomobile-bound package. Exports only bindable types
  (`StartBridge(token, listenPath) error`, `StopBridge`, `BridgeError`), which
  gomobile turns into the `Tailcatmobile*` Swift symbols.
- `Sources/HerdrTailcat` — the `TailcatBridge` actor over those symbols.
- `Artifacts/Tailcat.xcframework` — gomobile output: `ios-arm64`,
  `ios-arm64_x86_64-simulator`, `macos-arm64_x86_64`. gomobile emits a **static**
  archive per framework, so Xcode links the Go code into the app binary; the
  copied `Tailcat.framework` in the bundle is a codeless stub and is not a
  runtime dependency.

## Rebuild

Requires `go`, plus `gomobile`/`gobind` on PATH:

```sh
go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init
sh Scripts/build-xcframework.sh
```

The script runs `gomobile bind -target=ios,iossimulator,macos -trimpath
-ldflags="-s -w"` from `go/`, which roughly halves the framework size by
stripping Go's symbol and debug tables. The exported `Tailcatmobile*` symbols
survive stripping (they are cgo exports, kept for linking).
