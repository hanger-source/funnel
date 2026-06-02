package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

const sockPath = "/var/run/funnel.sock"
const resolverDir = "/etc/resolver"
const funnelResolverPrefix = "# Managed by Funnel. Do not edit.\n"
const localDNSPort = 53535

type Request struct {
	Action        string   `json:"action"` // start, stop, status
	ConfigPath    string   `json:"config_path,omitempty"`
	BinaryPath    string   `json:"binary_path,omitempty"`
	LogPath       string   `json:"log_path,omitempty"`
	TargetDomains []string `json:"target_domains,omitempty"`
}

type Response struct {
	OK      bool   `json:"ok"`
	Message string `json:"message,omitempty"`
}

var (
	singboxMu   sync.Mutex
	singboxCmd  *exec.Cmd
	singboxDone chan error
)

func main() {
	// Raise fd limit for sing-box TUN
	var rLimit syscall.Rlimit
	rLimit.Cur = 10240
	rLimit.Max = 10240
	syscall.Setrlimit(syscall.RLIMIT_NOFILE, &rLimit)

	os.Remove(sockPath)

	listener, err := net.Listen("unix", sockPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to listen: %v\n", err)
		os.Exit(1)
	}
	defer listener.Close()

	os.Chmod(sockPath, 0660)
	exec.Command("chgrp", "staff", sockPath).Run()

	fmt.Println("funnel-helper started, listening on", sockPath)

	// Handle shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-sigCh
		stopSingBox()
		os.Remove(sockPath)
		os.Exit(0)
	}()

	for {
		conn, err := listener.Accept()
		if err != nil {
			continue
		}
		go handleConn(conn)
	}
}

func handleConn(conn net.Conn) {
	defer conn.Close()

	var req Request
	if err := json.NewDecoder(conn).Decode(&req); err != nil {
		sendResponse(conn, false, "invalid request")
		return
	}

	switch req.Action {
	case "start":
		if req.BinaryPath == "" || req.ConfigPath == "" {
			sendResponse(conn, false, "missing binary_path or config_path")
			return
		}
		if !isAllowedBinary(req.BinaryPath) {
			sendResponse(conn, false, "binary path not allowed: "+req.BinaryPath)
			return
		}
		stopSingBox()
		err := startSingBox(req.BinaryPath, req.ConfigPath, req.LogPath)
		if err != nil {
			sendResponse(conn, false, err.Error())
		} else if err := installResolverFiles(req.TargetDomains); err != nil {
			stopSingBox()
			sendResponse(conn, false, err.Error())
		} else {
			sendResponse(conn, true, "started")
		}

	case "stop":
		stopSingBox()
		sendResponse(conn, true, "stopped")

	case "status":
		singboxMu.Lock()
		running := singboxCmd != nil && singboxCmd.Process != nil
		if running {
			if err := singboxCmd.Process.Signal(syscall.Signal(0)); err != nil {
				running = false
			}
		}
		singboxMu.Unlock()
		if running {
			sendResponse(conn, true, "running")
		} else {
			sendResponse(conn, true, "stopped")
		}

	default:
		sendResponse(conn, false, "unknown action: "+req.Action)
	}
}

func startSingBox(binary, config, logPath string) error {
	singboxMu.Lock()
	defer singboxMu.Unlock()

	stopSingBoxLocked()

	singboxCmd = exec.Command(binary, "run", "-c", config)
	singboxDone = make(chan error, 1)

	if logPath != "" {
		f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
		if err == nil {
			singboxCmd.Stdout = f
			singboxCmd.Stderr = f
			os.Chmod(logPath, 0666)
		}
	}

	if err := singboxCmd.Start(); err != nil {
		singboxCmd = nil
		singboxDone = nil
		return fmt.Errorf("start failed: %v", err)
	}

	cmd := singboxCmd
	done := singboxDone
	go func() {
		done <- cmd.Wait()
	}()

	return nil
}

func stopSingBox() {
	singboxMu.Lock()
	defer singboxMu.Unlock()
	stopSingBoxLocked()
}

func stopSingBoxLocked() {
	removeResolverFiles()
	if singboxCmd != nil && singboxCmd.Process != nil {
		singboxCmd.Process.Signal(syscall.SIGTERM)
		select {
		case <-singboxDone:
		case <-time.After(3 * time.Second):
			singboxCmd.Process.Kill()
			<-singboxDone
		}
		singboxCmd = nil
		singboxDone = nil
	}
	// Clean up any old child left by a previous helper instance.
	exec.Command("pkill", "-f", "sing-box.*funnel").Run()
}

var resolverDomainPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9.-]*[a-z0-9]$`)

func installResolverFiles(domains []string) error {
	if len(domains) == 0 {
		return nil
	}
	if err := os.MkdirAll(resolverDir, 0755); err != nil {
		return fmt.Errorf("create resolver dir failed: %v", err)
	}
	seen := map[string]bool{}
	for _, raw := range domains {
		domain := normalizeResolverDomain(raw)
		if domain == "" || seen[domain] {
			continue
		}
		seen[domain] = true
		content := fmt.Sprintf("%snameserver 127.0.0.1\nport %d\ndomain %s\noptions timeout:1 attempts:1\n", funnelResolverPrefix, localDNSPort, domain)
		path := filepath.Join(resolverDir, domain)
		if err := os.WriteFile(path, []byte(content), 0644); err != nil {
			return fmt.Errorf("write resolver %s failed: %v", domain, err)
		}
	}
	return nil
}

func removeResolverFiles() {
	entries, err := os.ReadDir(resolverDir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		path := filepath.Join(resolverDir, entry.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		if strings.HasPrefix(string(data), funnelResolverPrefix) {
			os.Remove(path)
		}
	}
}

func normalizeResolverDomain(raw string) string {
	domain := strings.Trim(strings.ToLower(raw), ". ")
	if domain == "" || strings.Contains(domain, "/") || strings.Contains(domain, "\\") {
		return ""
	}
	if !resolverDomainPattern.MatchString(domain) {
		return ""
	}
	return domain
}

func sendResponse(conn net.Conn, ok bool, msg string) {
	json.NewEncoder(conn).Encode(Response{OK: ok, Message: msg})
}

func isAllowedBinary(path string) bool {
	allowed := []string{
		"/.funnel/sing-box",
		"/.tun-proxy/sing-box",
		"/usr/local/bin/sing-box",
	}
	for _, suffix := range allowed {
		if strings.HasSuffix(path, suffix) {
			return true
		}
	}
	return false
}
