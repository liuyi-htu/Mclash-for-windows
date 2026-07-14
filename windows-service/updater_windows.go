package main

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const mihomoReleaseAPI = "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"

type coreUpdateInfo struct {
	CurrentVersion  string `json:"currentVersion"`
	LatestVersion   string `json:"latestVersion"`
	UpdateAvailable bool   `json:"updateAvailable"`
}

type githubRelease struct {
	TagName string `json:"tag_name"`
	Assets  []struct {
		Name               string `json:"name"`
		BrowserDownloadURL string `json:"browser_download_url"`
		Digest             string `json:"digest"`
	} `json:"assets"`
}

var versionPattern = regexp.MustCompile(`(?i)\bv?(\d+)\.(\d+)\.(\d+)\b`)

var updateHTTPClient = func() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	dialer := &net.Dialer{Timeout: 30 * time.Second, KeepAlive: 30 * time.Second}
	transport.DialContext = func(ctx context.Context, _, address string) (net.Conn, error) {
		return dialer.DialContext(ctx, "tcp4", address)
	}
	transport.TLSHandshakeTimeout = 60 * time.Second
	transport.ResponseHeaderTimeout = 60 * time.Second
	return &http.Client{Transport: transport}
}()

func checkCoreUpdate(paths appPaths) (coreUpdateInfo, githubRelease, error) {
	current, err := readMihomoVersion(paths.MihomoExe)
	if err != nil {
		return coreUpdateInfo{}, githubRelease{}, err
	}
	release, err := fetchLatestMihomoRelease()
	if err != nil {
		return coreUpdateInfo{}, githubRelease{}, err
	}
	latest, err := normalizeVersion(release.TagName)
	if err != nil {
		return coreUpdateInfo{}, githubRelease{}, fmt.Errorf("invalid official release version: %w", err)
	}
	comparison, err := compareVersions(current, latest)
	if err != nil {
		return coreUpdateInfo{}, githubRelease{}, err
	}
	return coreUpdateInfo{
		CurrentVersion:  current,
		LatestVersion:   latest,
		UpdateAvailable: comparison < 0,
	}, release, nil
}

func updateCore(paths appPaths) error {
	status := queryStatus(paths)
	if status.State == "running" || status.State == "start_pending" || status.State == "stop_pending" {
		return fmt.Errorf("stop the Mclash service before updating Mihomo")
	}
	info, release, err := checkCoreUpdate(paths)
	if err != nil {
		return err
	}
	if !info.UpdateAvailable {
		return nil
	}
	wantedName := "mihomo-windows-amd64-compatible-v" + info.LatestVersion + ".zip"
	var downloadURL, digest string
	for _, asset := range release.Assets {
		if strings.EqualFold(asset.Name, wantedName) {
			downloadURL = asset.BrowserDownloadURL
			digest = asset.Digest
			break
		}
	}
	if downloadURL == "" {
		return fmt.Errorf("official release does not contain %s", wantedName)
	}
	if !strings.HasPrefix(strings.ToLower(digest), "sha256:") {
		return fmt.Errorf("official release asset has no SHA-256 digest")
	}
	archive, err := downloadCoreArchive(downloadURL)
	if err != nil {
		return err
	}
	expected, err := hex.DecodeString(strings.TrimPrefix(strings.ToLower(digest), "sha256:"))
	if err != nil {
		return fmt.Errorf("decode official SHA-256 digest: %w", err)
	}
	actual := sha256.Sum256(archive)
	if !bytes.Equal(actual[:], expected) {
		return fmt.Errorf("downloaded Mihomo SHA-256 does not match the official digest")
	}
	binary, err := extractMihomoExecutable(archive)
	if err != nil {
		return err
	}
	temporary := paths.MihomoExe + ".update"
	backup := paths.MihomoExe + ".backup"
	_ = os.Remove(temporary)
	_ = os.Remove(backup)
	if err := os.WriteFile(temporary, binary, 0o755); err != nil {
		return fmt.Errorf("write updated Mihomo: %w", err)
	}
	defer os.Remove(temporary)
	if err := os.Rename(paths.MihomoExe, backup); err != nil {
		return fmt.Errorf("back up current Mihomo: %w", err)
	}
	restore := true
	defer func() {
		if restore {
			_ = os.Remove(paths.MihomoExe)
			_ = os.Rename(backup, paths.MihomoExe)
		}
	}()
	if err := os.Rename(temporary, paths.MihomoExe); err != nil {
		return fmt.Errorf("activate updated Mihomo: %w", err)
	}
	installed, err := readMihomoVersion(paths.MihomoExe)
	if err != nil || installed != info.LatestVersion {
		return fmt.Errorf("updated Mihomo failed version verification: got %q: %v", installed, err)
	}
	restore = false
	_ = os.Remove(backup)
	return nil
}

func fetchLatestMihomoRelease() (githubRelease, error) {
	var lastErr error
	for attempt := 1; attempt <= 3; attempt++ {
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, mihomoReleaseAPI, nil)
		if err != nil {
			cancel()
			return githubRelease{}, err
		}
		req.Header.Set("Accept", "application/vnd.github+json")
		req.Header.Set("User-Agent", "Mclash-Windows")
		response, err := updateHTTPClient.Do(req)
		if err == nil && response.StatusCode == http.StatusOK {
			var release githubRelease
			decodeErr := json.NewDecoder(io.LimitReader(response.Body, 4<<20)).Decode(&release)
			response.Body.Close()
			cancel()
			if decodeErr != nil {
				return githubRelease{}, fmt.Errorf("decode official Mihomo release: %w", decodeErr)
			}
			return release, nil
		}
		if response != nil {
			lastErr = fmt.Errorf("HTTP %d", response.StatusCode)
			response.Body.Close()
		} else {
			lastErr = err
		}
		cancel()
		if attempt < 3 {
			time.Sleep(time.Duration(attempt) * time.Second)
		}
	}
	return githubRelease{}, fmt.Errorf("query official Mihomo release: %w", lastErr)
}

func downloadCoreArchive(url string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mclash-Windows")
	response, err := updateHTTPClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("download Mihomo update: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("download Mihomo update: HTTP %d", response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 200<<20))
	if err != nil {
		return nil, fmt.Errorf("read Mihomo update: %w", err)
	}
	return data, nil
}

func extractMihomoExecutable(archive []byte) ([]byte, error) {
	reader, err := zip.NewReader(bytes.NewReader(archive), int64(len(archive)))
	if err != nil {
		return nil, fmt.Errorf("open Mihomo update archive: %w", err)
	}
	for _, file := range reader.File {
		if !strings.HasSuffix(strings.ToLower(filepath.Base(file.Name)), ".exe") {
			continue
		}
		stream, err := file.Open()
		if err != nil {
			return nil, err
		}
		data, readErr := io.ReadAll(io.LimitReader(stream, 150<<20))
		stream.Close()
		if readErr != nil {
			return nil, readErr
		}
		if len(data) == 0 {
			return nil, fmt.Errorf("Mihomo executable in update archive is empty")
		}
		return data, nil
	}
	return nil, fmt.Errorf("Mihomo update archive contains no executable")
}

func readMihomoVersion(path string) (string, error) {
	if err := validateRegularNonEmpty(path, ".exe"); err != nil {
		return "", err
	}
	cmd := exec.Command(path, "-v")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("read Mihomo version: %w", err)
	}
	return normalizeVersion(string(output))
}

func normalizeVersion(value string) (string, error) {
	match := versionPattern.FindStringSubmatch(value)
	if match == nil {
		return "", fmt.Errorf("version not found in %q", strings.TrimSpace(value))
	}
	return strings.Join(match[1:4], "."), nil
}

func compareVersions(left, right string) (int, error) {
	parse := func(value string) ([3]int, error) {
		var result [3]int
		parts := strings.Split(value, ".")
		if len(parts) != 3 {
			return result, fmt.Errorf("invalid semantic version %q", value)
		}
		for i, part := range parts {
			number, err := strconv.Atoi(part)
			if err != nil {
				return result, fmt.Errorf("invalid semantic version %q", value)
			}
			result[i] = number
		}
		return result, nil
	}
	l, err := parse(left)
	if err != nil {
		return 0, err
	}
	r, err := parse(right)
	if err != nil {
		return 0, err
	}
	for i := range l {
		if l[i] < r[i] {
			return -1, nil
		}
		if l[i] > r[i] {
			return 1, nil
		}
	}
	return 0, nil
}
