package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

const helperSockPath = "/var/run/funnel.sock"

type HelperRequest struct {
	Action        string   `json:"action"`
	ConfigPath    string   `json:"config_path,omitempty"`
	BinaryPath    string   `json:"binary_path,omitempty"`
	LogPath       string   `json:"log_path,omitempty"`
	TargetDomains []string `json:"target_domains,omitempty"`
}

type HelperResponse struct {
	OK      bool   `json:"ok"`
	Message string `json:"message,omitempty"`
}

type App struct {
	Cfg       *Config
	Connected bool
}

func NewApp() *App {
	cfg, err := LoadConfig()
	if err != nil {
		logError("config load error: %v", err)
		cfg = &Config{LogLevel: "info"}
	}
	logInfo("config loaded: %d nodes, selected=%d", len(cfg.Nodes), cfg.SelectedNode)
	if len(cfg.Nodes) > 0 && cfg.SelectedNode < len(cfg.Nodes) {
		n := cfg.Nodes[cfg.SelectedNode]
		logInfo("active node: %s (%s:%d)", n.Name, n.Server, n.Port)
	}
	for _, p := range cfg.GetTargetProcesses() {
		logInfo("  target: %s", p)
	}
	return &App{Cfg: cfg}
}

func (a *App) Connect() error {
	if a.Connected {
		a.Disconnect()
	}

	logInfo("=== CONNECT START ===")

	if !a.Cfg.HasUpstream() && len(a.Cfg.Nodes) == 0 {
		return fmt.Errorf("无代理配置，请先配置 %s", ConfigPath())
	}

	// Ensure helper is installed
	if err := installHelperIfNeeded(); err != nil {
		logError("helper install failed: %v", err)
		return fmt.Errorf("helper 安装失败: %v", err)
	}

	// Generate sing-box config
	sbConfig := GenerateSingboxConfig(a.Cfg)
	if sbConfig == nil {
		return fmt.Errorf("配置生成失败")
	}
	configPath := filepath.Join(ConfigDir(), "singbox.json")
	data, err := json.MarshalIndent(sbConfig, "", "  ")
	if err != nil {
		return fmt.Errorf("config marshal failed: %v", err)
	}
	if err := os.WriteFile(configPath, data, 0644); err != nil {
		return fmt.Errorf("config write failed: %v", err)
	}
	logInfo("sing-box config written to %s (%d bytes)", configPath, len(data))

	// Ensure sing-box binary
	binary := a.findSingBox()
	if binary == "" {
		logInfo("sing-box not found, downloading...")
		var dlErr error
		binary, dlErr = downloadSingBox(ConfigDir())
		if dlErr != nil {
			return fmt.Errorf("sing-box 下载失败: %v", dlErr)
		}
	}
	logInfo("using sing-box binary: %s", binary)

	// Log path
	logPath := filepath.Join(ConfigDir(), "singbox.log")

	// Send start command to helper
	resp, err := sendHelperCommand(HelperRequest{
		Action:        "start",
		BinaryPath:    binary,
		ConfigPath:    configPath,
		LogPath:       logPath,
		TargetDomains: a.Cfg.GetTargetDomains(),
	})
	if err != nil {
		logError("helper communication failed: %v", err)
		return fmt.Errorf("helper 通信失败: %v", err)
	}
	if !resp.OK {
		logError("helper start failed: %s", resp.Message)
		return fmt.Errorf("启动失败: %s", resp.Message)
	}
	logInfo("helper responded: ok=%v msg=%s", resp.OK, resp.Message)

	// Wait for TUN to be ready
	time.Sleep(1500 * time.Millisecond)

	// Verify connectivity through proxy
	if err := a.verifyConnectivity(); err != nil {
		logWarn("connectivity check failed: %v", err)
	} else {
		logInfo("connectivity check passed")
	}

	a.Connected = true
	logInfo("=== CONNECT SUCCESS ===")
	return nil
}

func (a *App) Disconnect() {
	logInfo("=== DISCONNECT ===")
	resp, err := sendHelperCommand(HelperRequest{Action: "stop"})
	if err != nil {
		logError("helper stop failed: %v", err)
	} else {
		logInfo("helper stop: ok=%v msg=%s", resp.OK, resp.Message)
	}
	a.Connected = false
}

func (a *App) OpenLog() {
	logPath := filepath.Join(ConfigDir(), "funnel.log")
	if err := exec.Command("open", "-a", "Console", logPath).Run(); err != nil {
		exec.Command("open", logPath).Run()
	}
}

func (a *App) connectionLabel() string {
	if a.Cfg.HasUpstream() {
		return fmt.Sprintf("%s://%s:%d", a.Cfg.Upstream.Type, a.Cfg.Upstream.Host, a.Cfg.Upstream.Port)
	}
	if len(a.Cfg.Nodes) > 0 && a.Cfg.SelectedNode < len(a.Cfg.Nodes) {
		return a.Cfg.Nodes[a.Cfg.SelectedNode].Name
	}
	return "unknown"
}

func (a *App) findSingBox() string {
	candidates := []string{
		filepath.Join(ConfigDir(), "sing-box"),
		// Also check tun-proxy's copy
		func() string { h, _ := os.UserHomeDir(); return filepath.Join(h, ".tun-proxy", "sing-box") }(),
		"/usr/local/bin/sing-box",
	}
	for _, p := range candidates {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

func (a *App) verifyConnectivity() error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	d := net.Dialer{Timeout: 3 * time.Second}
	conn, err := d.DialContext(ctx, "tcp", "1.1.1.1:443")
	if err != nil {
		return err
	}
	conn.Close()
	return nil
}

func sendHelperCommand(req HelperRequest) (*HelperResponse, error) {
	logInfo("sending helper command: action=%s", req.Action)
	var lastErr error
	deadline := time.Now().Add(2 * time.Second)
	for {
		resp, err := sendHelperCommandOnce(req)
		if err == nil {
			return resp, nil
		}
		lastErr = err
		if time.Now().After(deadline) {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	return nil, lastErr
}

func sendHelperCommandOnce(req HelperRequest) (*HelperResponse, error) {
	conn, err := net.DialTimeout("unix", helperSockPath, 3*time.Second)
	if err != nil {
		return nil, fmt.Errorf("cannot connect to helper: %w", err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(10 * time.Second))

	if err := json.NewEncoder(conn).Encode(req); err != nil {
		return nil, fmt.Errorf("send failed: %w", err)
	}
	var resp HelperResponse
	if err := json.NewDecoder(conn).Decode(&resp); err != nil {
		return nil, fmt.Errorf("recv failed: %w", err)
	}
	return &resp, nil
}
