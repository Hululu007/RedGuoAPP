package core

import (
	"context"
	"errors"
	"fmt"
	"net"
	"time"
)

var dnsServers = map[string]string{
	"tencent": "119.29.29.29:53",
	"ali":     "223.5.5.5:53",
	"google":  "8.8.8.8:53",
}

// dnsDialContext 返回使用指定服务商解析域名后再拨号的 DialContext；
// 「系统」返回 nil，由 Go 运行时按系统配置解析。
func dnsDialContext(provider string) func(context.Context, string, string) (net.Conn, error) {
	server := dnsServers[provider]
	if server == "" {
		return nil
	}
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	resolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return dialer.DialContext(ctx, network, server)
		},
	}
	return func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(address)
		if err != nil {
			return nil, err
		}
		if ip := net.ParseIP(host); ip != nil {
			return dialer.DialContext(ctx, network, address)
		}
		lookupCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		addresses, err := resolver.LookupHost(lookupCtx, host)
		cancel()
		if err != nil {
			return nil, PublicError(fmt.Errorf("DNS 解析失败（%s）：%w", server, err))
		}
		var connection net.Conn
		for _, candidate := range addresses {
			connection, err = dialer.DialContext(ctx, network, net.JoinHostPort(candidate, port))
			if err == nil {
				return connection, nil
			}
		}
		if err == nil {
			err = errors.New("DNS 未解析到可用地址")
		}
		return nil, PublicError(err)
	}
}
