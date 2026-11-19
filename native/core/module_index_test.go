package core

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"testing/fstest"
	"time"
)

func TestModuleIndexInstallFallsBackAndVerifies(t *testing.T) {
	example := filepath.Join("..", "module_example", "jsexample")
	files := map[string][]byte{}
	sums := map[string]string{}
	for _, name := range []string{moduleManifest, moduleEntry} {
		data, err := os.ReadFile(filepath.Join(example, name))
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(data)
		files[name], sums[name] = data, hex.EncodeToString(sum[:])
	}
	entry := func(id, repo string, api int, hashes map[string]string) moduleIndexEntry {
		return moduleIndexEntry{ID: id, Name: id, Version: "1.0.0", API: api, Repo: repo, Tag: "v1.0.0", SHA256: hashes}
	}
	located := func(id, repo, path string, api int, hashes map[string]string) moduleIndexEntry {
		return moduleIndexEntry{ID: id, Name: id, Version: "1.0.0", API: api, Repo: repo, Tag: "v1.0.0", Path: path, SHA256: hashes}
	}
	wrong := map[string]string{moduleManifest: strings.Repeat("0", 64), moduleEntry: strings.Repeat("0", 64)}
	index, err := json.Marshal(map[string]any{"format": moduleIndexFormat, "modules": []moduleIndexEntry{
		located("jsexample", "owner/jsexample", "modules/jsexample", moduleAPIVersion, sums),
		entry("future", "owner/jsexample", moduleAPIVersion+1, sums),
		located("renamed", "owner/jsexample", "modules/renamed", moduleAPIVersion, sums),
		entry("tampered", "owner/jsexample", moduleAPIVersion, wrong),
		entry("bad-repo", "../jsexample", moduleAPIVersion, sums),
		located("bad-path", "owner/jsexample", "../escape", moduleAPIVersion, sums),
	}})
	if err != nil {
		t.Fatal(err)
	}
	var staleHits atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch {
		case request.URL.Path == "/broken/index.json":
			http.Error(writer, "down", http.StatusBadGateway)
		case request.URL.Path == "/index.json":
			_, _ = writer.Write(index)
		case strings.HasPrefix(request.URL.Path, "/stale/"):
			staleHits.Add(1)
			_, _ = writer.Write([]byte("stale"))
		case strings.HasPrefix(request.URL.Path, "/files/owner/jsexample/modules/"):
			_, _ = writer.Write(files[filepath.Base(request.URL.Path)])
		default:
			http.NotFound(writer, request)
		}
	}))
	t.Cleanup(server.Close)
	addresses, patterns := moduleIndexAddresses, moduleFileAddresses
	moduleIndexAddresses = []string{server.URL + "/broken/index.json", server.URL + "/index.json"}
	moduleFileAddresses = []string{server.URL + "/stale/%s/%s", server.URL + "/files/%s/%s"}
	t.Cleanup(func() { moduleIndexAddresses, moduleFileAddresses = addresses, patterns })

	engine := &nativeEngine{downloader: &Downloader{cfg: Config{dataDir: t.TempDir()}, client: server.Client()}, cacheDirectory: t.TempDir()}
	ctx := context.Background()
	entries, mirror, err := engine.moduleIndex(ctx)
	if err != nil || mirror != 1 || len(entries) != 3 || entries[0].ID != "jsexample" || entries[1].ID != "renamed" || entries[2].ID != "tampered" {
		t.Fatalf("index = %+v, %v", entries, err)
	}
	info, err := engine.prepareModule(ctx, "", "", "jsexample", false, false)
	if err != nil || info.ID != "jsexample" || info.Token == "" || staleHits.Load() != 0 {
		t.Fatalf("prepare = %+v, %v, stale hits %d", info, err, staleHits.Load())
	}
	moduleFileAddresses = []string{server.URL + "/files/%s/%s", server.URL + "/stale/%s/%s"}
	if info, err := engine.prepareModule(ctx, "", "", "jsexample", false, false); err != nil || info.ID != "jsexample" || staleHits.Load() != 2 {
		t.Fatalf("fallback prepare = %+v, %v, stale hits %d", info, err, staleHits.Load())
	}
	if _, err := engine.prepareModule(ctx, "", "", "renamed", false, false); err == nil || !strings.Contains(err.Error(), "实际是模块 jsexample") {
		t.Fatalf("renamed error = %v", err)
	}
	if _, err := engine.prepareModule(ctx, "", "", "tampered", false, false); err == nil || !strings.Contains(err.Error(), "校验不符") {
		t.Fatalf("tampered error = %v", err)
	}
	if _, err := engine.prepareModule(ctx, "", "", "future", false, false); err == nil || !strings.Contains(err.Error(), "没有 future") {
		t.Fatalf("future error = %v", err)
	}

	previous := bundledModules
	bundledModules = fstest.MapFS{
		"jsexample/" + moduleManifest: {Data: []byte(strings.Replace(string(files[moduleManifest]), `"version": "1.0.0"`, `"version": "0.9.0"`, 1))},
		"jsexample/" + moduleEntry:    {Data: files[moduleEntry]},
	}
	t.Cleanup(func() { bundledModules = previous })
	store, err := engine.moduleStore(ctx, false)
	items, _ := store["items"].([]moduleIndexEntry)
	if err != nil || len(items) != 3 || items[0].ID != "jsexample" || items[0].Bundled || items[0].Version != "1.0.0" {
		t.Fatalf("store with bundled and indexed copies = %+v, %v", items, err)
	}
	if info, err := engine.prepareModule(ctx, "", "", "jsexample", true, false); err != nil || info.Version != "0.9.0" {
		t.Fatalf("bundled prepare = %+v, %v", info, err)
	}
	if info, err := engine.prepareModule(ctx, "", "", "jsexample", false, false); err != nil || info.Version != "1.0.0" {
		t.Fatalf("indexed prepare beside bundled = %+v, %v", info, err)
	}
	if _, err := engine.prepareModule(ctx, "", "", "renamed", true, false); err == nil || !strings.Contains(err.Error(), "没有内置 renamed") {
		t.Fatalf("missing bundled error = %v", err)
	}
	if _, err := parseModuleIndex([]byte(`{"format": 2, "modules": []}`)); err == nil || !strings.Contains(err.Error(), "更新应用") {
		t.Fatalf("format error = %v", err)
	}
}

// 解锁全量站源后，安装路径必须和商店列表读同一份索引，否则全量包独有的
// 模块会提示「模块索引里没有」。
func TestModuleAllIndexInstall(t *testing.T) {
	example := filepath.Join("..", "module_example", "jsexample")
	manifestData, err := os.ReadFile(filepath.Join(example, moduleManifest))
	if err != nil {
		t.Fatal(err)
	}
	codeData, err := os.ReadFile(filepath.Join(example, moduleEntry))
	if err != nil {
		t.Fatal(err)
	}
	extraManifest := []byte(strings.Replace(strings.Replace(string(manifestData),
		`"id": "jsexample"`, `"id": "extra"`, 1), `"JS 示例"`, `"附加示例"`, 1))
	sum := func(data []byte) string {
		digest := sha256.Sum256(data)
		return hex.EncodeToString(digest[:])
	}
	shared := map[string]string{moduleManifest: sum(manifestData), moduleEntry: sum(codeData)}
	extraSums := map[string]string{moduleManifest: sum(extraManifest), moduleEntry: sum(codeData)}
	simple, err := json.Marshal(map[string]any{"format": moduleIndexFormat, "modules": []moduleIndexEntry{
		{ID: "jsexample", Name: "jsexample", Version: "1.0.0", API: moduleAPIVersion, Repo: "owner/repo", Tag: "v1.0.0", SHA256: shared},
	}})
	if err != nil {
		t.Fatal(err)
	}
	full, err := json.Marshal(map[string]any{"format": moduleIndexFormat, "modules": []moduleIndexEntry{
		{ID: "jsexample", Name: "jsexample", Version: "1.0.0", API: moduleAPIVersion, Repo: "owner/repo", Tag: "v1.0.0", SHA256: shared},
		{ID: "extra", Name: "extra", Version: "1.0.0", API: moduleAPIVersion, Repo: "owner/repo", Tag: "v1.0.0", Path: "modules/extra", SHA256: extraSums},
	}})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/index.json":
			_, _ = writer.Write(simple)
			return
		case "/allindex.json":
			_, _ = writer.Write(full)
			return
		}
		switch filepath.Base(request.URL.Path) {
		case moduleManifest:
			if strings.Contains(request.URL.Path, "extra") {
				_, _ = writer.Write(extraManifest)
				return
			}
			_, _ = writer.Write(manifestData)
		case moduleEntry:
			_, _ = writer.Write(codeData)
		default:
			http.NotFound(writer, request)
		}
	}))
	t.Cleanup(server.Close)
	indexes, alls, patterns := moduleIndexAddresses, moduleAllIndexAddresses, moduleFileAddresses
	moduleIndexAddresses = []string{server.URL + "/index.json"}
	moduleAllIndexAddresses = []string{server.URL + "/allindex.json"}
	moduleFileAddresses = []string{server.URL + "/files/%s/%s"}
	t.Cleanup(func() {
		moduleIndexAddresses, moduleAllIndexAddresses, moduleFileAddresses = indexes, alls, patterns
	})

	engine := &nativeEngine{downloader: &Downloader{cfg: Config{dataDir: t.TempDir()}, client: server.Client()}, cacheDirectory: t.TempDir()}
	ctx := context.Background()
	if _, err := engine.prepareModule(ctx, "", "", "extra", false, false); err == nil || !strings.Contains(err.Error(), "没有 extra") {
		t.Fatalf("locked prepare should miss full-only module: %v", err)
	}
	info, err := engine.prepareModule(ctx, "", "", "extra", false, true)
	if err != nil || info.ID != "extra" {
		t.Fatalf("unlocked prepare = %+v, %v", info, err)
	}
	store, err := engine.moduleStore(ctx, true)
	items, _ := store["items"].([]moduleIndexEntry)
	counts := map[string]int{}
	for _, item := range items {
		counts[item.ID]++
	}
	if err != nil || counts["jsexample"] != 1 || counts["extra"] != 1 {
		t.Fatalf("unlocked store = %+v, %v", items, err)
	}

	locked, err := engine.moduleStore(ctx, false)
	lockedItems, _ := locked["items"].([]moduleIndexEntry)
	for _, item := range lockedItems {
		if item.ID == "extra" {
			t.Fatalf("locked store leaked full-only module: %+v", lockedItems)
		}
	}

	previous := bundledModules
	bundledModules = fstest.MapFS{
		"jsexample/" + moduleManifest: {Data: manifestData},
		"jsexample/" + moduleEntry:    {Data: codeData},
	}
	t.Cleanup(func() { bundledModules = previous })
	store, err = engine.moduleStore(ctx, true)
	items, _ = store["items"].([]moduleIndexEntry)
	sample := moduleIndexEntry{}
	for _, item := range items {
		if item.ID == "jsexample" {
			sample = item
		}
	}
	if err != nil || !sample.Bundled || sample.ID != "jsexample" {
		t.Fatalf("store should prefer bundled on same version = %+v, %v", items, err)
	}
}

// 索引镜像必须并行请求：raw 卡住时不能拖慢可用的 jsDelivr。
func TestModuleIndexUsesFastestMirror(t *testing.T) {
	index, err := json.Marshal(map[string]any{"format": moduleIndexFormat, "modules": []moduleIndexEntry{
		{ID: "jsexample", Name: "jsexample", Version: "1.0.0", API: moduleAPIVersion, Repo: "owner/repo", Tag: "v1.0.0",
			SHA256: map[string]string{moduleManifest: strings.Repeat("0", 64), moduleEntry: strings.Repeat("0", 64)}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/slow/index.json":
			select {
			case <-request.Context().Done():
				return
			case <-time.After(5 * time.Second):
			}
			_, _ = writer.Write(index)
		case "/fast/index.json":
			_, _ = writer.Write(index)
		default:
			http.NotFound(writer, request)
		}
	}))
	t.Cleanup(server.Close)
	addresses := moduleIndexAddresses
	moduleIndexAddresses = []string{server.URL + "/slow/index.json", server.URL + "/fast/index.json"}
	t.Cleanup(func() { moduleIndexAddresses = addresses })

	engine := &nativeEngine{downloader: &Downloader{cfg: Config{dataDir: t.TempDir()}, client: server.Client()}, cacheDirectory: t.TempDir()}
	started := time.Now()
	entries, mirror, err := engine.moduleIndex(context.Background())
	if err != nil || mirror != 1 || len(entries) != 1 || entries[0].ID != "jsexample" {
		t.Fatalf("index = %+v mirror=%d, %v", entries, mirror, err)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("index fetch took %s, mirrors are not racing", elapsed)
	}
}

// 精简索引只给 repo/path/version，不带 tag 与 sha256；条目不能因此被丢掉，
// 下载后用 manifest 的 id/version 兜底校验。
func TestModuleIndexAcceptsCompactEntries(t *testing.T) {
	example := filepath.Join("..", "module_example", "jsexample")
	files := map[string][]byte{}
	for _, name := range []string{moduleManifest, moduleEntry} {
		data, err := os.ReadFile(filepath.Join(example, name))
		if err != nil {
			t.Fatal(err)
		}
		files[name] = data
	}
	compact := func(version string) []byte {
		raw, err := json.Marshal(map[string]any{"format": moduleIndexFormat, "modules": []moduleIndexEntry{{
			ID: "jsexample", Name: "JS 示例", Version: version, API: moduleAPIVersion,
			Repo: "owner/jsexample", Path: "modules/jsexample",
		}}})
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch {
		case request.URL.Path == "/compact.json":
			_, _ = writer.Write(compact("1.0.0"))
		case request.URL.Path == "/mismatch.json":
			_, _ = writer.Write(compact("2.0.0"))
		case strings.HasPrefix(request.URL.Path, "/files/owner/jsexample/modules/jsexample/"):
			_, _ = writer.Write(files[filepath.Base(request.URL.Path)])
		default:
			http.NotFound(writer, request)
		}
	}))
	t.Cleanup(server.Close)
	addresses, patterns := moduleIndexAddresses, moduleFileAddresses
	moduleFileAddresses = []string{server.URL + "/files/%s/%s"}
	t.Cleanup(func() { moduleIndexAddresses, moduleFileAddresses = addresses, patterns })

	engine := &nativeEngine{downloader: &Downloader{cfg: Config{dataDir: t.TempDir()}, client: server.Client()}, cacheDirectory: t.TempDir()}
	ctx := context.Background()

	moduleIndexAddresses = []string{server.URL + "/compact.json"}
	entries, _, err := engine.moduleIndex(ctx)
	if err != nil || len(entries) != 1 || entries[0].ID != "jsexample" {
		t.Fatalf("compact index = %+v, %v", entries, err)
	}
	payload, err := engine.indexedModulePackage(ctx, "jsexample", false, false)
	if err != nil || len(payload) == 0 {
		t.Fatalf("compact package = %d bytes, %v", len(payload), err)
	}

	moduleIndexAddresses = []string{server.URL + "/mismatch.json"}
	if _, err := engine.indexedModulePackage(ctx, "jsexample", false, false); err == nil || !strings.Contains(err.Error(), "版本不符") {
		t.Fatalf("mismatch error = %v", err)
	}
}
