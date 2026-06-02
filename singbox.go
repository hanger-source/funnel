package main

import (
	"bufio"
	"net"
	"os"
	"strings"
)

// GenerateSingboxConfig creates a sing-box configuration that proxies
// specified processes and/or domains. All other traffic goes direct.
func GenerateSingboxConfig(cfg *Config) map[string]interface{} {
	logInfo("generating sing-box config...")

	// Build outbound based on config mode
	var proxyOutbound map[string]interface{}
	var excludeIPs []string

	if cfg.HasUpstream() {
		// Upstream proxy mode (e.g. local V2RayX/Clash)
		logInfo("mode: upstream proxy (%s %s:%d)", cfg.Upstream.Type, cfg.Upstream.Host, cfg.Upstream.Port)
		proxyOutbound = map[string]interface{}{
			"type":        "socks",
			"tag":         "proxy",
			"server":      cfg.Upstream.Host,
			"server_port": cfg.Upstream.Port,
		}
		if cfg.Upstream.Type == "http" {
			proxyOutbound["type"] = "http"
		}
		// Exclude upstream proxy from TUN to prevent loop
		if cfg.Upstream.Host != "127.0.0.1" && cfg.Upstream.Host != "localhost" {
			excludeIPs = append(excludeIPs, cfg.Upstream.Host+"/32")
		}
	} else if len(cfg.Nodes) > 0 {
		// Direct node mode
		node := cfg.Nodes[cfg.SelectedNode]
		logInfo("mode: direct node (%s %s:%d, type=%s)", node.Name, node.Server, node.Port, node.Type)

		// Resolve server IP to exclude from TUN
		server := node.Server
		if net.ParseIP(server) == nil {
			if addrs, err := net.LookupHost(server); err == nil && len(addrs) > 0 {
				logInfo("resolved %s -> %v", server, addrs)
				for _, addr := range addrs {
					excludeIPs = append(excludeIPs, addr+"/32")
				}
				server = addrs[0]
			} else {
				logError("failed to resolve %s: %v", server, err)
			}
		} else {
			excludeIPs = append(excludeIPs, server+"/32")
		}

		proxyOutbound = map[string]interface{}{
			"type":        node.Type,
			"tag":         "proxy",
			"server":      server,
			"server_port": node.Port,
		}
		if node.Type == "vmess" {
			proxyOutbound["uuid"] = node.UUID
			proxyOutbound["security"] = "auto"
			proxyOutbound["authenticated_length"] = true
			proxyOutbound["packet_encoding"] = "xudp"
		} else if node.Type == "shadowsocks" {
			proxyOutbound["method"] = node.Method
			proxyOutbound["password"] = node.Password
		}
	} else {
		logError("no upstream proxy or nodes configured!")
		return nil
	}

	// Target processes
	targetProcesses := cfg.GetTargetProcesses()
	logInfo("target processes (%d):", len(targetProcesses))
	for _, p := range targetProcesses {
		logInfo("  - %s", p)
	}

	// Target domains
	targetDomains := cfg.GetTargetDomains()
	logInfo("target domains (%d):", len(targetDomains))
	for _, d := range targetDomains {
		logInfo("  - %s", d)
	}

	// Route rules:
	// 1. DNS packets -> internal DNS
	// 2. Target domains -> proxy (regardless of process)
	// 3. Target processes -> proxy
	// 4. Private IPs -> direct
	// 5. Everything else -> direct
	routeRules := []map[string]interface{}{
		{"protocol": "dns", "action": "hijack-dns"},
	}

	if len(targetDomains) > 0 {
		routeRules = append(routeRules, map[string]interface{}{
			"domain_suffix": targetDomains,
			"outbound":      "proxy",
		})
	}

	if len(targetProcesses) > 0 {
		routeRules = append(routeRules, map[string]interface{}{
			"process_name": targetProcesses,
			"outbound":     "proxy",
		})
	}

	routeRules = append(routeRules, map[string]interface{}{
		"ip_is_private": true,
		"outbound":      "direct",
	})

	systemDNSList := detectSystemDNSList()
	logInfo("system DNS: %v", systemDNSList)
	logInfo("direct DNS: %s", cfg.DirectDNS)
	logInfo("fake IP range: %s", cfg.FakeIPRange)
	logInfo("local target DNS: 127.0.0.1:%d", LocalDNSPort)

	dnsRules := []map[string]interface{}{}
	// sing-box 1.11 legacy fakeip needs an IPv6 range for AAAA fake responses.
	// Funnel only routes IPv4 FakeIP today, so target AAAA returns NOERROR/NODATA
	// and target A carries the stable FakeIP path.
	if len(targetDomains) > 0 {
		dnsRules = append(dnsRules, map[string]interface{}{
			"domain_suffix": targetDomains,
			"query_type":    []string{"AAAA"},
			"server":        "dns-empty",
		})
		dnsRules = append(dnsRules, map[string]interface{}{
			"domain_suffix": targetDomains,
			"query_type":    []string{"A"},
			"server":        "dns-fake",
		})
		dnsRules = append(dnsRules, map[string]interface{}{
			"domain_suffix": targetDomains,
			"server":        "dns-remote",
		})
	}
	if len(targetProcesses) > 0 {
		dnsRules = append(dnsRules, map[string]interface{}{
			"process_name": targetProcesses,
			"query_type":   []string{"AAAA"},
			"server":       "dns-empty",
		})
		dnsRules = append(dnsRules, map[string]interface{}{
			"process_name": targetProcesses,
			"query_type":   []string{"A"},
			"server":       "dns-fake",
		})
		dnsRules = append(dnsRules, map[string]interface{}{
			"process_name": targetProcesses,
			"server":       "dns-remote",
		})
	}

	// Outbounds
	outbounds := []map[string]interface{}{
		proxyOutbound,
		{"type": "direct", "tag": "direct"},
	}

	// TUN inbound
	var excludeAddrs []string
	excludeAddrs = append(excludeAddrs, excludeIPs...)
	excludeAddrs = append(excludeAddrs, cidrHostAddrs([]string{cfg.DirectDNS})...)
	logInfo("route_exclude_address: %v", excludeAddrs)

	routeAddrs := mergeRouteAddresses(cfg.GetRouteAddresses(), []string{cfg.FakeIPRange})
	logInfo("route_address: %v", routeAddrs)

	tunInbound := map[string]interface{}{
		"type":                       "tun",
		"tag":                        "tun-in",
		"address":                    []string{"172.19.0.1/28"},
		"auto_route":                 true,
		"strict_route":               true,
		"stack":                      "gvisor",
		"sniff":                      true,
		"sniff_override_destination": true,
		"route_exclude_address":      excludeAddrs,
	}
	if len(routeAddrs) > 0 {
		tunInbound["route_address"] = routeAddrs
	}

	dnsInbound := map[string]interface{}{
		"type":             "direct",
		"tag":              "dns-in",
		"listen":           "127.0.0.1",
		"listen_port":      LocalDNSPort,
		"network":          "udp",
		"override_address": "8.8.8.8",
		"override_port":    53,
	}

	routeRules = append([]map[string]interface{}{
		{"inbound": []string{"dns-in"}, "action": "hijack-dns"},
	}, routeRules...)

	// Log level
	logLevel := cfg.LogLevel
	if logLevel == "" {
		logLevel = "info"
	}

	result := map[string]interface{}{
		"log": map[string]interface{}{
			"level":     logLevel,
			"timestamp": true,
		},
		"dns": map[string]interface{}{
			"servers": []map[string]interface{}{
				{"tag": "dns-remote", "address": "tcp://1.1.1.1", "detour": "proxy"},
				{"tag": "dns-direct", "address": cfg.DirectDNS, "detour": "direct"},
				{"tag": "dns-fake", "address": "fakeip"},
				{"tag": "dns-empty", "address": "rcode://success"},
			},
			"rules":             dnsRules,
			"final":             "dns-direct",
			"strategy":          "prefer_ipv4",
			"independent_cache": true,
			"reverse_mapping":   true,
			"fakeip": map[string]interface{}{
				"enabled":     true,
				"inet4_range": cfg.FakeIPRange,
			},
		},
		"inbounds":  []map[string]interface{}{tunInbound, dnsInbound},
		"outbounds": outbounds,
		"route": map[string]interface{}{
			"auto_detect_interface": true,
			"rules":                 routeRules,
			"final":                 "direct",
		},
	}

	mode := "upstream"
	if !cfg.HasUpstream() {
		mode = "direct-node"
	}
	logInfo("sing-box config generated: mode=%s, route.final=direct, %d route rules, %d domain rules",
		mode, len(routeRules), len(targetDomains))
	return result
}

func detectSystemDNSList() []string {
	f, err := os.Open("/etc/resolv.conf")
	if err != nil {
		return nil
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	seen := map[string]bool{}
	var result []string
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if strings.HasPrefix(line, "nameserver") {
			fields := strings.Fields(line)
			if len(fields) >= 2 && net.ParseIP(fields[1]) != nil && !strings.Contains(fields[1], ":") {
				if !seen[fields[1]] {
					seen[fields[1]] = true
					result = append(result, fields[1])
				}
			}
		}
	}
	return result
}

func cidrHostAddrs(addrs []string) []string {
	var result []string
	for _, addr := range addrs {
		ip := net.ParseIP(addr)
		if ip == nil || ip.To4() == nil || addr == "127.0.0.1" {
			continue
		}
		result = append(result, ip.String()+"/32")
	}
	return result
}

func mergeRouteAddresses(groups ...[]string) []string {
	seen := map[string]bool{}
	var result []string
	for _, group := range groups {
		for _, addr := range group {
			if addr == "" || seen[addr] {
				continue
			}
			seen[addr] = true
			result = append(result, addr)
		}
	}
	return result
}
