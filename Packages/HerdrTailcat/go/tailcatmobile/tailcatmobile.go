// Package tailcatmobile is the gomobile-bound face of the tailcat bridge.
// gomobile compiles it into Tailcat.xcframework and generates the Swift API,
// so every exported symbol must use bindable types only: string and error.
// The work all lives in the sibling bridge package; these are thin wrappers
// keyed by the local listen path, letting the app host one bridge per device.
package tailcatmobile

import (
	"github.com/missuo/herdrm/tailcat/bridge"
)

// StartBridge holds one tailcat session for token and serves the herdr API
// socket on listenPath (plus the derived "-client" socket for attach). It
// returns once the listeners are bound; the bridge runs until StopBridge.
// Calling it again for the same listenPath is a no-op. The token passes as a
// plain argument here — unlike a CLI it never enters a process list.
func StartBridge(token, listenPath string) error {
	_, err := bridge.Start(token, listenPath)
	return err
}

// StopBridge tears down the bridge serving listenPath, if any.
func StopBridge(listenPath string) {
	bridge.Stop(listenPath)
}

// BridgeError reports the most recent asynchronous error (failed warm-up,
// refused tunnel dial) for the bridge on listenPath, or "".
func BridgeError(listenPath string) string {
	return bridge.LastError(listenPath)
}
