package core

import (
	"context"
	"fmt"
)

func (engine *nativeEngine) nativeBeginPlayback(ctx context.Context, sequence int64) (context.Context, func(), error) {
	engine.playbackMu.Lock()
	defer engine.playbackMu.Unlock()
	if sequence <= engine.playbackSequence {
		// 诊断：区分「序列号过期」与「执行中被取消」，两者都会以
		// context canceled 的形态透传到 Dart。保留前缀让取消分类继续生效。
		return nil, nil, fmt.Errorf(
			"context canceled（播放序列号过期：请求=%d 当前=%d）",
			sequence, engine.playbackSequence,
		)
	}
	if engine.playbackCancel != nil {
		engine.playbackCancel()
	}
	engine.playbackSequence = sequence
	playback, cancel := context.WithCancel(ctx)
	engine.playbackCancel = cancel
	finish := func() {
		cancel()
		engine.playbackMu.Lock()
		if engine.playbackSequence == sequence {
			engine.playbackCancel = nil
		}
		engine.playbackMu.Unlock()
	}
	return playback, finish, nil
}

func (engine *nativeEngine) nativeCancelPlayback(sequence int64) {
	engine.playbackMu.Lock()
	defer engine.playbackMu.Unlock()
	if sequence <= engine.playbackSequence {
		return
	}
	engine.playbackSequence = sequence
	if engine.playbackCancel != nil {
		engine.playbackCancel()
		engine.playbackCancel = nil
	}
}
