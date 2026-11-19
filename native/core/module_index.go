package core

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
)

const (
	moduleIndexFormat  = 1
	moduleIndexBytes   = 1 << 20
	moduleFetchTimeout = 20 * time.Second
)

var (
	moduleIndexAddresses = []string{
		"https://raw.githubusercontent.com/xycvip/RedGuoAPI/refs/heads/main/index.json",
		"https://cdn.jsdelivr.net/gh/xycvip/RedGuoAPI@main/index.json",
	}
	moduleAllIndexAddresses = []string{
		"https://raw.githubusercontent.com/xycvip/RedGuoAPI/refs/heads/main/allindex.json",
		"https://cdn.jsdelivr.net/gh/xycvip/RedGuoAPI@main/allindex.json",
	}
	moduleFileAddresses = []string{
		"https://raw.githubusercontent.com/%s/refs/heads/main/%s",
		"https://cdn.jsdelivr.net/gh/%s@main/%s",
	}
	moduleIndexRepo = regexp.MustCompile(`^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$`)
	moduleIndexTag  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)
	moduleIndexPath = regexp.MustCompile(`^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$`)
	moduleIndexHash = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

type moduleIndexEntry struct {
	ID          string            `json:"id"`
	Name        string            `json:"name"`
	Version     string            `json:"version"`
	Description string            `json:"description"`
	API         int               `json:"api"`
	Adult       bool              `json:"adult"`
	Repo        string            `json:"repo"`
	Tag         string            `json:"tag"`
	Path        string            `json:"path,omitempty"`
	SHA256      map[string]string `json:"sha256"`
	Bundled     bool              `json:"bundled,omitempty"`
}

func validModuleIndexPath(path string) bool {
	if path == "" {
		return true
	}
	if !moduleIndexPath.MatchString(path) {
		return false
	}
	for _, segment := range strings.Split(path, "/") {
		if segment == "." || segment == ".." {
			return false
		}
	}
	return true
}

func (entry moduleIndexEntry) usable() bool {
	return entry.API == moduleAPIVersion && moduleIDPattern.MatchString(entry.ID) && strings.TrimSpace(entry.Name) != "" &&
		moduleIndexRepo.MatchString(entry.Repo) && moduleIndexTag.MatchString(entry.Tag) &&
		validModuleIndexPath(entry.Path) &&
		moduleIndexHash.MatchString(entry.SHA256[moduleManifest]) && moduleIndexHash.MatchString(entry.SHA256[moduleEntry])
}

func parseModuleIndex(raw []byte) ([]moduleIndexEntry, error) {
	var index struct {
		Format  int                `json:"format"`
		Modules []moduleIndexEntry `json:"modules"`
	}
	if err := json.Unmarshal(raw, &index); err != nil {
		return nil, errors.New("索引格式无效")
	}
	if index.Format != moduleIndexFormat {
		return nil, fmt.Errorf("索引格式为第 %d 版，请更新应用", index.Format)
	}
	entries := []moduleIndexEntry{}
	for _, entry := range index.Modules {
		if entry.usable() {
			entries = append(entries, entry)
		}
	}
	return entries, nil
}

func (engine *nativeEngine) moduleIndex(ctx context.Context) ([]moduleIndexEntry, int, error) {
	return engine.fetchModuleIndex(ctx, moduleIndexAddresses)
}

// moduleEntries 返回模块商店的条目；all 时只使用全量索引。
func (engine *nativeEngine) moduleEntries(ctx context.Context, all bool) ([]moduleIndexEntry, int, error) {
	if all {
		return engine.fetchModuleIndex(ctx, moduleAllIndexAddresses)
	}
	return engine.moduleIndex(ctx)
}

// moduleIndexOutcome 保存单个镜像地址的取索引结果。
type moduleIndexOutcome struct {
	entries []moduleIndexEntry
	mirror  int
	err     error
}

// fetchModuleIndex 并行请求全部镜像地址，采用最先成功的一份。
// raw.githubusercontent.com 在国内经常不可达，串行等待会白等一个超时周期。
func (engine *nativeEngine) fetchModuleIndex(ctx context.Context, addresses []string) ([]moduleIndexEntry, int, error) {
	if len(addresses) == 0 {
		return nil, 0, errors.New("读取模块索引失败：未配置索引地址")
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	outcomes := make(chan moduleIndexOutcome, len(addresses))
	for mirror, address := range addresses {
		go func(mirror int, address string) {
			raw, err := engine.fetchModuleResource(ctx, address, moduleIndexBytes)
			if err == nil {
				var entries []moduleIndexEntry
				if entries, err = parseModuleIndex(raw); err == nil {
					outcomes <- moduleIndexOutcome{entries: entries, mirror: mirror}
					return
				}
			}
			outcomes <- moduleIndexOutcome{mirror: mirror, err: err}
		}(mirror, address)
	}
	failures := make([]string, len(addresses))
	for range addresses {
		outcome := <-outcomes
		if outcome.err == nil {
			cancel()
			return outcome.entries, outcome.mirror, nil
		}
		failures[outcome.mirror] = outcome.err.Error()
	}
	return nil, 0, fmt.Errorf("读取模块索引失败：%s", strings.Join(failures, "；"))
}

func (engine *nativeEngine) moduleStore(ctx context.Context, all bool) (map[string]any, error) {
	entries, _, err := engine.moduleEntries(ctx, all)
	bundled := bundledIndexEntries()
	if err != nil && len(bundled) == 0 {
		return nil, err
	}
	items := mergeModuleEntries(entries, bundled)
	result := map[string]any{"items": items}
	if err != nil {
		result["warning"] = err.Error()
	}
	return result, nil
}

// mergeModuleEntries 合并索引条目与内置模块，同一个 id 只保留一条：
// 版本一致时沿用内置条目（可离线安装），版本不同时采用索引条目（便于升级）。
func mergeModuleEntries(entries, bundled []moduleIndexEntry) []moduleIndexEntry {
	position := make(map[string]int, len(bundled))
	for index, entry := range bundled {
		position[entry.ID] = index
	}
	used := make([]bool, len(bundled))
	items := make([]moduleIndexEntry, 0, len(bundled)+len(entries))
	for _, entry := range entries {
		index, ok := position[entry.ID]
		if ok {
			used[index] = true
			if bundled[index].Version == entry.Version {
				entry = bundled[index]
			}
		}
		items = append(items, entry)
	}
	for index, entry := range bundled {
		if !used[index] {
			items = append(items, entry)
		}
	}
	return items
}

func (engine *nativeEngine) indexedModulePackage(ctx context.Context, id string, bundled, all bool) ([]byte, error) {
	if bundled {
		modules, _ := readBundledModules()
		if modules[id].raw == nil {
			return nil, fmt.Errorf("安装包没有内置 %s", id)
		}
		return zipModuleFiles(modules[id].raw, modules[id].code)
	}
	entries, mirror, err := engine.moduleEntries(ctx, all)
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		if entry.ID != id {
			continue
		}
		manifest, err := engine.fetchIndexedFile(ctx, entry, mirror, moduleManifest, moduleManifestBytes)
		if err != nil {
			return nil, err
		}
		code, err := engine.fetchIndexedFile(ctx, entry, mirror, moduleEntry, moduleEntryBytes)
		if err != nil {
			return nil, err
		}
		return zipModuleFiles(manifest, code)
	}
	return nil, fmt.Errorf("模块索引里没有 %s", id)
}

func (engine *nativeEngine) fetchIndexedFile(ctx context.Context, entry moduleIndexEntry, mirror int, name string, limit int) ([]byte, error) {
	var failures []string
	relative := ""
	if entry.Path != "" {
		relative = entry.Path + "/"
	}
	for offset := range moduleFileAddresses {
		pattern := moduleFileAddresses[(mirror+offset)%len(moduleFileAddresses)]
		data, err := engine.fetchModuleResource(ctx, fmt.Sprintf(pattern, entry.Repo, relative+name), limit)
		if err == nil {
			sum := sha256.Sum256(data)
			if hex.EncodeToString(sum[:]) == entry.SHA256[name] {
				return data, nil
			}
			err = errors.New("文件校验不符")
		}
		failures = append(failures, err.Error())
	}
	return nil, fmt.Errorf("下载 %s 的 %s 失败：%s", entry.Name, name, strings.Join(failures, "；"))
}

func (engine *nativeEngine) fetchModuleResource(ctx context.Context, address string, limit int) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, moduleFetchTimeout)
	defer cancel()
	return engine.fetchLimited(ctx, address, limit)
}

func zipModuleFiles(manifest, code []byte) ([]byte, error) {
	var buffer bytes.Buffer
	archive := zip.NewWriter(&buffer)
	for _, file := range []struct {
		name string
		data []byte
	}{{moduleManifest, manifest}, {moduleEntry, code}} {
		writer, err := archive.Create(file.name)
		if err != nil {
			return nil, err
		}
		if _, err := writer.Write(file.data); err != nil {
			return nil, err
		}
	}
	if err := archive.Close(); err != nil {
		return nil, err
	}
	return buffer.Bytes(), nil
}
