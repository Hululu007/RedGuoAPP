package core

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"
)

// 预占名额必须跟随调用方生命周期：ctx 取消时立即释放。
//
// 曾经名额只靠 60 秒超时回收——被取消的预加载/取地址如果刚好卡在
// 「reserve → fetch(ticket)」之间，名额就成孤儿。全局限流名额一共没几个，
// 连续快速切集（每次都取消上一集的预热）会把名额逐个占光，之后所有
// 取地址排队到超时，用户看到的是「第 N 集必然卡住，重试也一直转圈」。
func TestReserveReleasesSlotOnCancel(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir(), t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	d := engine.downloader
	ctx, cancel := context.WithCancel(context.Background())
	ticket, err := d.Reserve(ctx, "https://example.com/a", "")
	if err != nil {
		t.Fatalf("预占名额失败：%v", err)
	}
	// 名额已占住：模拟同配置的其它请求排队（用短超时确认它能占到名额之外的空位即可，
	// 这里直接验证取消释放）。
	cancel()
	deadline := time.Now().Add(2 * time.Second)
	for {
		d.reserveMu.Lock()
		_, alive := d.reservations[ticket]
		d.reserveMu.Unlock()
		if !alive {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("ctx 取消后预占名额没有被立即释放（孤儿名额会饿死后续取地址）")
		}
		time.Sleep(10 * time.Millisecond)
	}
	// 名额已回收：新的预占应该立即可用。
	if _, err := d.Reserve(context.Background(), "https://example.com/b", ""); err != nil {
		t.Fatalf("名额释放后再次预占失败：%v", err)
	}
}

// 前台请求排队等待超过上限时必须尽快失败并说明原因，
// 而不是让调用方一直挂到外层超时。
func TestForegroundAcquireWaitLimit(t *testing.T) {
	limiter := newRequestLimiter(1, 0)
	request, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, "https://a.example/x", nil)
	release, err := limiter.acquire(request.Context(), request)
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	other, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, "https://b.example/y", nil)
	started := time.Now()
	_, err = limiter.acquire(other.Context(), other)
	if err == nil || !strings.Contains(err.Error(), "排队超时") {
		t.Fatalf("前台排队应在上限内失败，得到：%v", err)
	}
	if elapsed := time.Since(started); elapsed > foregroundWaitLimit+2*time.Second {
		t.Fatalf("前台排队失败太慢：%v", elapsed)
	}
}
