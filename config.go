package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// UpstreamProxy defines a local proxy to forward traffic to (e.g. V2RayX, Clash)
type UpstreamProxy struct {
	Type string `json:"type"` // "socks5" or "http"
	Host string `json:"host"` // e.g. "127.0.0.1"
	Port int    `json:"port"` // e.g. 13658
}

// NodeConfig defines a direct proxy node (vmess/shadowsocks)
type NodeConfig struct {
	Name     string `json:"name"`
	Type     string `json:"type"`   // "vmess" or "shadowsocks"
	Server   string `json:"server"` // server address
	Port     int    `json:"port"`   // server port
	UUID     string `json:"uuid,omitempty"`
	Security string `json:"security,omitempty"`
	Method   string `json:"method,omitempty"`
	Password string `json:"password,omitempty"`
}

// Config is the main configuration
type Config struct {
	// Upstream local proxy (preferred over Nodes if set)
	Upstream *UpstreamProxy `json:"upstream,omitempty"`

	// Direct nodes (fallback if upstream is not set)
	Nodes        []NodeConfig `json:"nodes,omitempty"`
	SelectedNode int          `json:"selected_node,omitempty"`

	// TargetProcesses lists process names to proxy.
	TargetProcesses []string `json:"target_processes,omitempty"`

	// TargetDomains lists domain suffixes to proxy (in addition to process matching).
	// Traffic to these domains will be proxied regardless of which process sends it.
	TargetDomains []string `json:"target_domains,omitempty"`

	// RouteAddresses lists optional IP ranges that should be forced into the TUN.
	// These are appended to the DNS and FakeIP routes managed by Funnel.
	RouteAddresses []string `json:"route_addresses,omitempty"`

	// DirectDNS is used by sing-box for non-target DNS after DNS hijack.
	DirectDNS string `json:"direct_dns,omitempty"`

	// FakeIPRange is returned for target A queries. Target AAAA queries get
	// an empty success response because the current TUN setup is IPv4 FakeIP only.
	FakeIPRange string `json:"fake_ip_range,omitempty"`

	// LogLevel for sing-box: trace/debug/info/warn/error
	LogLevel string `json:"log_level,omitempty"`
}

// DefaultTargetProcesses — Antigravity + Codex
var DefaultTargetProcesses = []string{
	// Antigravity
	"Antigravity",
	"Antigravity Helper",
	"Antigravity Helper (Renderer)",
	"Antigravity Helper (GPU)",
	"language_server",
	"Electron",
	"Antigravity IDE Helper",
	"Antigravity IDE Helper (Plugin)",
	"Antigravity IDE Helper (Renderer)",
	"Antigravity IDE Helper (GPU)",
	"language_server_macos_arm",
	// Codex
	"Codex",
	"Codex Helper",
	"Codex Helper (Renderer)",
	"Codex Helper (GPU)",
	"Codex Helper (Plugin)",
}

// DefaultTargetDomains — OpenAI auth & API + Google/Antigravity IDE domains
var DefaultTargetDomains = []string{
	"openai.com",
	"auth.openai.com",
	"api.openai.com",
	"chatgpt.com",
	"oaistatic.com",
	"oaiusercontent.com",
	// Google / Antigravity IDE
	"google.com",
	"googleapis.com",
	"googlevideo.com",
	"goog",
	"gstatic.com",
	"run.app",
}

var DefaultRouteAddresses []string

const (
	DefaultDirectDNS   = "223.5.5.5"
	DefaultFakeIPRange = "198.18.0.0/15"
	LocalDNSPort       = 53535
)

func ConfigDir() string {
	home, _ := os.UserHomeDir()
	dir := filepath.Join(home, ".funnel")
	os.MkdirAll(dir, 0755)
	return dir
}

func ConfigPath() string {
	return filepath.Join(ConfigDir(), "config.json")
}

func LoadConfig() (*Config, error) {
	c := &Config{
		LogLevel: "info",
	}
	data, err := os.ReadFile(ConfigPath())
	if err != nil {
		// No config yet, generate default
		c.Upstream = &UpstreamProxy{
			Type: "socks5",
			Host: "127.0.0.1",
			Port: 13658,
		}
		c.TargetProcesses = DefaultTargetProcesses
		c.TargetDomains = DefaultTargetDomains
		c.RouteAddresses = DefaultRouteAddresses
		c.DirectDNS = DefaultDirectDNS
		c.FakeIPRange = DefaultFakeIPRange
		c.Save()
		return c, nil
	}
	if err := json.Unmarshal(data, c); err != nil {
		return nil, err
	}
	if c.LogLevel == "" {
		c.LogLevel = "info"
	}
	if c.DirectDNS == "" {
		c.DirectDNS = DefaultDirectDNS
	}
	if c.FakeIPRange == "" {
		c.FakeIPRange = DefaultFakeIPRange
	}
	return c, nil
}

func (c *Config) Save() error {
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(ConfigPath(), data, 0644)
}

func (c *Config) GetTargetProcesses() []string {
	if len(c.TargetProcesses) > 0 {
		return c.TargetProcesses
	}
	return DefaultTargetProcesses
}

func (c *Config) GetTargetDomains() []string {
	if len(c.TargetDomains) > 0 {
		return c.TargetDomains
	}
	return DefaultTargetDomains
}

func (c *Config) GetRouteAddresses() []string {
	if len(c.RouteAddresses) > 0 {
		return c.RouteAddresses
	}
	return DefaultRouteAddresses
}

func (c *Config) HasUpstream() bool {
	return c.Upstream != nil && c.Upstream.Host != "" && c.Upstream.Port > 0
}
