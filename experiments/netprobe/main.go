package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

type loggingDialer struct {
	dialer net.Dialer
}

func (d *loggingDialer) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	start := time.Now()
	conn, err := d.dialer.DialContext(ctx, network, address)
	if err != nil {
		fmt.Printf("dial=%s address=%s error=%v elapsed=%s\n", network, address, err, time.Since(start).Round(time.Millisecond))
		return nil, err
	}
	fmt.Printf("dial=%s address=%s local=%s remote=%s elapsed=%s\n", network, address, conn.LocalAddr(), conn.RemoteAddr(), time.Since(start).Round(time.Millisecond))
	return conn, nil
}

func main() {
	target := flag.String("url", "https://chatgpt.com/", "URL to fetch")
	timeout := flag.Duration("timeout", 10*time.Second, "request timeout")
	flag.Parse()

	u, err := url.Parse(*target)
	if err != nil {
		fmt.Printf("url_error=%v\n", err)
		os.Exit(2)
	}

	host := u.Hostname()
	fmt.Printf("pid=%d exe=%s\n", os.Getpid(), os.Args[0])
	fmt.Printf("url=%s host=%s\n", *target, host)
	fmt.Printf("env_proxy ALL_PROXY=%q HTTPS_PROXY=%q HTTP_PROXY=%q NO_PROXY=%q\n",
		os.Getenv("ALL_PROXY"), os.Getenv("HTTPS_PROXY"), os.Getenv("HTTP_PROXY"), os.Getenv("NO_PROXY"))

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	addrs, err := net.DefaultResolver.LookupHost(ctx, host)
	if err != nil {
		fmt.Printf("resolve_error=%v\n", err)
	} else {
		fmt.Printf("resolve=%s\n", strings.Join(addrs, ","))
	}

	dialer := &loggingDialer{dialer: net.Dialer{Timeout: *timeout}}
	transport := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		DialContext:           dialer.DialContext,
		TLSHandshakeTimeout:   *timeout,
		ResponseHeaderTimeout: *timeout,
		TLSClientConfig:       &tls.Config{MinVersion: tls.VersionTLS12},
	}
	client := &http.Client{Transport: transport, Timeout: *timeout}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, *target, nil)
	if err != nil {
		fmt.Printf("request_error=%v\n", err)
		os.Exit(2)
	}
	req.Header.Set("User-Agent", "funnel-netprobe/0.1")

	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		fmt.Printf("fetch_error=%v elapsed=%s\n", err, time.Since(start).Round(time.Millisecond))
		os.Exit(1)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	fmt.Printf("status=%s elapsed=%s\n", resp.Status, time.Since(start).Round(time.Millisecond))
	fmt.Printf("server=%q content_type=%q\n", resp.Header.Get("Server"), resp.Header.Get("Content-Type"))
	fmt.Printf("body_prefix=%q\n", string(body))
}
