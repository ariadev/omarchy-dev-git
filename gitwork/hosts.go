package main

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var hostKeyRe = regexp.MustCompile(`^([A-Za-z0-9_.:-]+):\s*(?:#.*)?$`)

func configHome() string {
	if dir := strings.TrimSpace(os.Getenv("XDG_CONFIG_HOME")); dir != "" {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config")
}

// yamlKeysAt scans a YAML file for mapping keys at one indentation depth,
// optionally only inside a named parent block. Both CLIs write flat host maps,
// so this is enough to enumerate hosts without pulling in a YAML dependency —
// and it keeps the collector a zero-dependency build.
func yamlKeysAt(path, parent string, indent int) []string {
	file, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer file.Close()

	var keys []string
	inParent := parent == ""
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for scanner.Scan() {
		line := strings.TrimRight(scanner.Text(), " \t\r")
		if line == "" || strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		depth := len(line) - len(strings.TrimLeft(line, " "))
		if strings.Contains(line, "\t") {
			continue
		}
		if parent != "" {
			if depth == 0 {
				// A new top-level key ends the parent block we were in.
				inParent = strings.TrimSpace(line) == parent+":"
				continue
			}
			if !inParent {
				continue
			}
		}
		if depth != indent {
			continue
		}
		if m := hostKeyRe.FindStringSubmatch(strings.TrimSpace(line)); m != nil {
			keys = append(keys, m[1])
		}
	}
	return keys
}

func dedupe(values []string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(values))
	for _, v := range values {
		v = strings.TrimSpace(strings.ToLower(v))
		v = strings.TrimPrefix(strings.TrimPrefix(v, "https://"), "http://")
		v = strings.TrimSuffix(v, "/")
		if v == "" || seen[v] {
			continue
		}
		seen[v] = true
		out = append(out, v)
	}
	return out
}

// githubHosts lists every GitHub (or GitHub Enterprise) host worth asking.
// An explicit GH_HOST wins outright; otherwise every host `gh` knows about is
// collected, with github.com first so it lands as the default tab.
func githubHosts() []string {
	for _, key := range []string{"GH_HOST", "GITHUB_HOST"} {
		if v := strings.TrimSpace(os.Getenv(key)); v != "" {
			return dedupe([]string{v})
		}
	}
	hosts := yamlKeysAt(filepath.Join(configHome(), "gh", "hosts.yml"), "", 0)
	if len(hosts) == 0 {
		if os.Getenv("GITHUB_TOKEN") != "" || haveBinary("gh") {
			hosts = []string{"github.com"}
		}
	}
	return orderDefaultFirst(dedupe(hosts), "github.com")
}

// gitlabHosts lists every GitLab instance `glab` is configured for, including
// self-managed ones, with gitlab.com first when present.
func gitlabHosts() []string {
	if v := strings.TrimSpace(os.Getenv("GITLAB_HOST")); v != "" {
		return dedupe([]string{v})
	}
	path := filepath.Join(configHome(), "glab-cli", "config.yml")
	hosts := yamlKeysAt(path, "hosts", 4)
	if len(hosts) == 0 {
		hosts = yamlKeysAt(path, "hosts", 2)
	}
	if len(hosts) == 0 && haveBinary("glab") {
		hosts = []string{"gitlab.com"}
	}
	return orderDefaultFirst(dedupe(hosts), "gitlab.com")
}

func orderDefaultFirst(hosts []string, primary string) []string {
	out := make([]string, 0, len(hosts))
	for _, h := range hosts {
		if h == primary {
			out = append(out, h)
		}
	}
	for _, h := range hosts {
		if h != primary {
			out = append(out, h)
		}
	}
	return out
}
