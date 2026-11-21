package core

import (
	"context"
	"strconv"
	"time"
)

// 站源取地址结果的短时缓存。同一集重复打开（退出重进、失败重试、换清晰度）
// 不再重复走网络；预热下一集与手动取地址共用这份缓存，谁先解析谁受益。
//
// 缓存的是 ProviderMedia（含各清晰度候选与 m3u8 播放列表文本），播放会话
// 仍按次新建，互不干扰。

const (
	nativeResolveTTL      = 8 * time.Minute
	nativeResolveCacheMax = 32
)

type nativeResolveEntry struct {
	media   ProviderMedia
	expires time.Time
}

func resolveCacheKey(dramaID string, index int) string {
	return dramaID + "#" + strconv.Itoa(index)
}

func (engine *nativeEngine) resolveProviderMediaCached(
	ctx context.Context, task Task, force bool,
) (ProviderMedia, error) {
	key := resolveCacheKey(task.DramaID, task.Index)
	if !force {
		engine.resolveMu.Lock()
		entry, ok := engine.resolveCache[key]
		engine.resolveMu.Unlock()
		if ok && time.Now().Before(entry.expires) {
			return entry.media, nil
		}
	}
	media, err := engine.downloader.resolveProviderMedia(ctx, task)
	if err != nil {
		return media, err
	}
	engine.rememberResolvedMedia(key, media)
	return media, nil
}

func (engine *nativeEngine) rememberResolvedMedia(key string, media ProviderMedia) {
	engine.resolveMu.Lock()
	defer engine.resolveMu.Unlock()
	if engine.resolveCache == nil {
		engine.resolveCache = make(map[string]nativeResolveEntry)
	}
	if len(engine.resolveCache) >= nativeResolveCacheMax {
		now := time.Now()
		for k, v := range engine.resolveCache {
			if now.After(v.expires) {
				delete(engine.resolveCache, k)
			}
		}
		if len(engine.resolveCache) >= nativeResolveCacheMax {
			var oldestKey string
			var oldest time.Time
			first := true
			for k, v := range engine.resolveCache {
				if first || v.expires.Before(oldest) {
					oldestKey, oldest, first = k, v.expires, false
				}
			}
			delete(engine.resolveCache, oldestKey)
		}
	}
	engine.resolveCache[key] = nativeResolveEntry{
		media:   media,
		expires: time.Now().Add(nativeResolveTTL),
	}
}
