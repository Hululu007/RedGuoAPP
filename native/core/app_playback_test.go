package core

import (
	"context"
	"strings"
	"testing"
)

// 取地址必须只 beginPlayback 一次：分发层 begin 之后，nativeResolve 直接使用
// 同一个播放上下文。曾经 nativeResolve 内部又 begin 了一次，同一个序列号
// 第二次过闸会被判过期，所有手动取地址永远失败，用户看到
// 「暂时无法播放，context canceled（播放序列号过期：请求=X 当前=X）」。
func TestResolveUsesBegunPlaybackContext(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir(), t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	input := nativeInput{
		Action:   "resolve",
		Sequence: 42,
		Drama:    LibraryDrama{ID: "nosuchsource#1"},
		Index:    1,
	}
	playback, finish, err := engine.nativeBeginPlayback(context.Background(), input.Sequence)
	if err != nil {
		t.Fatalf("分发层 beginPlayback 失败：%v", err)
	}
	defer finish()
	if _, err := engine.nativeResolve(playback, input); err == nil {
		t.Fatal("无效站源应当报错")
	} else if strings.Contains(err.Error(), "序列号过期") {
		t.Fatalf("nativeResolve 不得再次 beginPlayback：%v", err)
	}
}

// 重复使用已消费的序列号会被拒绝，这是取消通道的过期判断，必须保留。
func TestStalePlaybackSequenceRejected(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir(), t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := engine.nativeBeginPlayback(context.Background(), 42); err != nil {
		t.Fatalf("首次 beginPlayback 失败：%v", err)
	}
	if _, _, err := engine.nativeBeginPlayback(context.Background(), 42); err == nil ||
		!strings.Contains(err.Error(), "序列号过期") {
		t.Fatalf("同序列号重复 begin 应被判过期，得到：%v", err)
	}
}
