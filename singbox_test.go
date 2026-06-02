package main

import "testing"

func TestGenerateSingboxConfigUsesFakeIPDNSHijack(t *testing.T) {
	cfg := &Config{
		Upstream: &UpstreamProxy{
			Type: "socks5",
			Host: "127.0.0.1",
			Port: 13658,
		},
		TargetProcesses: []string{"Codex", "codex"},
		TargetDomains:   []string{"chatgpt.com", "openai.com"},
		DirectDNS:       DefaultDirectDNS,
		FakeIPRange:     DefaultFakeIPRange,
		LogLevel:        "error",
	}

	generated := GenerateSingboxConfig(cfg)
	if generated == nil {
		t.Fatal("expected config")
	}

	dns := generated["dns"].(map[string]interface{})
	fakeip := dns["fakeip"].(map[string]interface{})
	if fakeip["inet4_range"] != DefaultFakeIPRange {
		t.Fatalf("fake IP range = %v, want %s", fakeip["inet4_range"], DefaultFakeIPRange)
	}
	if dns["reverse_mapping"] != true {
		t.Fatal("reverse_mapping must be enabled for fake IP routing")
	}
	dnsServers := dns["servers"].([]map[string]interface{})
	if !hasDNSServer(dnsServers, "dns-empty", "rcode://success") {
		t.Fatalf("dns servers = %#v, want dns-empty rcode success server for target AAAA", dnsServers)
	}
	dnsRules := dns["rules"].([]map[string]interface{})
	if !hasDNSRule(dnsRules, "domain_suffix", "AAAA", "dns-empty") {
		t.Fatalf("dns rules = %#v, want target domain AAAA -> dns-empty", dnsRules)
	}
	if !hasDNSRule(dnsRules, "domain_suffix", "A", "dns-fake") {
		t.Fatalf("dns rules = %#v, want target domain A -> dns-fake", dnsRules)
	}
	if hasDNSRule(dnsRules, "domain_suffix", "AAAA", "dns-fake") {
		t.Fatalf("dns rules must not send AAAA to dns-fake without inet6_range: %#v", dnsRules)
	}

	route := generated["route"].(map[string]interface{})
	routeRules := route["rules"].([]map[string]interface{})
	if !containsString(routeRules[0]["inbound"].([]string), "dns-in") || routeRules[0]["action"] != "hijack-dns" {
		t.Fatalf("first route rule = %#v, want local DNS inbound hijack", routeRules[0])
	}
	if routeRules[1]["protocol"] != "dns" || routeRules[1]["action"] != "hijack-dns" {
		t.Fatalf("second route rule = %#v, want TUN DNS hijack fallback", routeRules[1])
	}
	for _, rule := range routeRules {
		if rule["action"] == "reject" {
			t.Fatalf("route rules must not reject captured traffic before target process/domain matching: %#v", rule)
		}
	}

	inbounds := generated["inbounds"].([]map[string]interface{})
	tun := inbounds[0]
	dnsIn := inbounds[1]
	if dnsIn["tag"] != "dns-in" || dnsIn["listen"] != "127.0.0.1" || dnsIn["listen_port"] != LocalDNSPort {
		t.Fatalf("dns inbound = %#v, want local DNS inbound on 127.0.0.1:%d", dnsIn, LocalDNSPort)
	}
	routeExcludeAddresses := tun["route_exclude_address"].([]string)
	// sing-box's own direct DNS server must stay outside the TUN.
	if !containsString(routeExcludeAddresses, DefaultDirectDNS+"/32") {
		t.Fatalf("route_exclude_address = %v, want direct DNS excluded", routeExcludeAddresses)
	}
	routeAddresses := tun["route_address"].([]string)
	if !containsString(routeAddresses, DefaultFakeIPRange) {
		t.Fatalf("route_address = %v, want fake IP range", routeAddresses)
	}
	// On many home or office networks the system DNS IP is also the default
	// gateway. Routing that /32 into the TUN breaks ordinary direct traffic
	// because en0 traffic still uses the captured gateway as its next hop.
	if containsString(routeAddresses, "192.168.31.1/32") {
		t.Fatalf("route_address must not capture system DNS/default gateway: %v", routeAddresses)
	}
	if containsString(routeAddresses, "59.82.0.0/16") {
		t.Fatalf("route_address must not include broad controlled ranges: %v", routeAddresses)
	}
}

func containsString(items []string, needle string) bool {
	for _, item := range items {
		if item == needle {
			return true
		}
	}
	return false
}

func hasDNSServer(servers []map[string]interface{}, tag, address string) bool {
	for _, server := range servers {
		if server["tag"] == tag && server["address"] == address {
			return true
		}
	}
	return false
}

func hasDNSRule(rules []map[string]interface{}, matchKey, queryType, server string) bool {
	for _, rule := range rules {
		if _, ok := rule[matchKey]; !ok {
			continue
		}
		if rule["server"] != server {
			continue
		}
		queryTypes, ok := rule["query_type"].([]string)
		if !ok {
			continue
		}
		if containsString(queryTypes, queryType) {
			return true
		}
	}
	return false
}
