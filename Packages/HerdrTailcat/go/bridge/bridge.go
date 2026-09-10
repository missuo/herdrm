// Package bridge is the shared core of herdr's tailcat client transport. It
// holds one tailcat (WireGuard/DERP) session to a host exposing its herdr
// socket through the herdr.tailcat plugin, and serves that socket on local
// Unix sockets so herdr clients reach the remote herdr exactly as if it were
// local.
//
// Two local sockets are served, mirroring the two a herdr server listens on:
// the API socket (at listenPath, forwarded to the plugin's API port) and the
// client-protocol socket (listenPath with "-client" inserted before ".sock",
// forwarded to the plugin's client port). Terminal attach (`herdr agent
// attach`) derives the client socket from HERDR_SOCKET_PATH, so without the
// second listener every attach dies with ENOENT.
//
// The package is consumed two ways: the `herdr-tailcat-bridge` CLI wraps it in
// a flag foreground process, and the gomobile `tailcatmobile` package exposes
// it to Swift as an embedded xcframework. The registry is keyed by the listen
// path, so a process can host several bridges (one per tailcat device).
package bridge

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/types/logger"
)

// Default tunnel ports the herdr.tailcat plugin serves on. Control carries the
// NDJSON API socket; Client carries the client-protocol socket attach speaks.
const (
	DefaultControlPort = 6464
	DefaultClientPort  = 6465
)

// Bridge is one running tailcat session plus its local listeners.
type Bridge struct {
	client     *tailcat.Client
	listen     string
	clientSock string
	listeners  []net.Listener

	mu       sync.Mutex
	lastErr  string
	stopOnce sync.Once
	done     chan struct{}
}

var (
	registry sync.Map // listenPath -> *Bridge
)

// Start launches a bridge for one host and returns once its listeners are
// bound. token is the tailcat connection token; listenPath is the local Unix
// socket to serve the API on (the "-client" sibling is derived). A bridge
// already serving listenPath is returned as-is, so Start is idempotent.
func Start(token, listenPath string) (*Bridge, error) {
	if token == "" {
		return nil, fmt.Errorf("tailcat token is empty")
	}
	if listenPath == "" {
		return nil, fmt.Errorf("listen path is empty")
	}
	if existing, ok := registry.Load(listenPath); ok {
		return existing.(*Bridge), nil
	}

	client := tailcat.NewClient(tailcat.ConnBlob(token))
	// The bridge runs inside the host app now; the netstack's per-packet debug
	// log (Client.Logf defaults to log.Printf) would flood its stderr. Silence
	// it — actionable failures are captured by setErr and surfaced via
	// LastError instead.
	client.Logf = logger.Discard

	b := &Bridge{
		client:     client,
		listen:     listenPath,
		clientSock: DeriveClientSocket(listenPath),
		done:       make(chan struct{}),
	}

	controlLn, err := listenUnix(b.listen)
	if err != nil {
		b.client.Close()
		return nil, err
	}
	clientLn, err := listenUnix(b.clientSock)
	if err != nil {
		controlLn.Close()
		os.Remove(b.listen)
		b.client.Close()
		return nil, err
	}
	b.listeners = []net.Listener{controlLn, clientLn}

	if _, loaded := registry.LoadOrStore(listenPath, b); loaded {
		// Lost a concurrent Start race; serve nothing and hand back the winner.
		b.Close()
		existing, _ := registry.Load(listenPath)
		return existing.(*Bridge), nil
	}

	go b.acceptLoop(clientLn, DefaultClientPort)
	go b.acceptLoop(controlLn, DefaultControlPort)
	go b.warmup()
	return b, nil
}

// Stop tears down the bridge serving listenPath, if any.
func Stop(listenPath string) {
	if v, ok := registry.LoadAndDelete(listenPath); ok {
		v.(*Bridge).Close()
	}
}

// LastError reports the most recent asynchronous error (a failed warm-up
// handshake, a refused tunnel dial) for the bridge on listenPath, or "".
func LastError(listenPath string) string {
	if v, ok := registry.Load(listenPath); ok {
		return v.(*Bridge).LastError()
	}
	return ""
}

// LastError reports the bridge's most recent asynchronous error, or "".
func (b *Bridge) LastError() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.lastErr
}

func (b *Bridge) setErr(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	b.mu.Lock()
	b.lastErr = msg
	b.mu.Unlock()
	log.Printf("%s", msg)
}

// Close shuts the bridge down: closes the listeners, removes the socket
// files, and drops the tailcat session. Safe to call more than once.
func (b *Bridge) Close() {
	b.stopOnce.Do(func() {
		close(b.done)
		for _, ln := range b.listeners {
			ln.Close()
		}
		os.Remove(b.listen)
		os.Remove(b.clientSock)
		b.client.Close()
	})
}

// DeriveClientSocket mirrors herdr's derive_client_socket_from_api_socket:
// insert "-client" before the ".sock" extension (herdr.sock -> herdr-client.sock).
func DeriveClientSocket(apiSocket string) string {
	dir := filepath.Dir(apiSocket)
	base := filepath.Base(apiSocket)
	stem := strings.TrimSuffix(base, filepath.Ext(base))
	return filepath.Join(dir, stem+"-client.sock")
}

// warmup drives the first handshake in the background: the initial
// DialTCPPort triggers WireGuard key exchange and DERP relay selection, which
// can take seconds. Recording the outcome here surfaces a bad token or an
// unreachable server instead of a silent empty-reply RPC; failure does not
// stop the accept loops, since a slow server may still serve later dials.
func (b *Bridge) warmup() {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := b.client.Ping(ctx); err != nil {
		b.setErr("warmup ping failed (token invalid or server unreachable): %v", err)
		return
	}
	log.Printf("tunnel up; api %s -> %d, client %s -> %d", b.listen, DefaultControlPort, b.clientSock, DefaultClientPort)
}

// acceptLoop proxies each accepted Unix connection to one tunnel connection.
func (b *Bridge) acceptLoop(ln net.Listener, port uint16) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			return // listener closed (shutdown)
		}
		go b.serve(conn, port)
	}
}

// serve proxies one local Unix connection to one tunnel connection.
func (b *Bridge) serve(local net.Conn, port uint16) {
	defer local.Close()
	// Generous dial window: a cold session may still be handshaking.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	remote, err := b.client.DialTCPPort(ctx, port)
	if err != nil {
		b.setErr("dial tunnel port %d: %v", port, err)
		return
	}
	tailcat.ProxyConns(local, remote)
}

// listenUnix binds a Unix socket with owner-only permissions, clearing any
// stale socket file left by a previous run.
func listenUnix(path string) (net.Listener, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("listen dir: %w", err)
	}
	os.Remove(path) // clear a stale socket from a previous run
	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, fmt.Errorf("listen %s: %w", path, err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		ln.Close()
		os.Remove(path)
		return nil, fmt.Errorf("chmod %s: %w", path, err)
	}
	return ln, nil
}
