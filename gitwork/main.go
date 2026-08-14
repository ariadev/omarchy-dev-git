// Command gitwork collects GitHub and GitLab open work into one JSON overview
// for the dev.git Omarchy bar plugin.
//
// It reads nothing but the tokens the `gh` and `glab` CLIs already hold, then
// talks to each API directly over a shared HTTP transport. Every host is
// collected concurrently and independently, so one unreachable or
// unauthenticated instance never hides the others — it just carries its own
// sign-in hint into the panel.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

func main() {
	output := flag.String("output", "", "Path to write the overview JSON (default: stdout).")
	timeout := flag.Duration("timeout", 60*time.Second, "Overall deadline for the collection run.")
	pretty := flag.Bool("pretty", true, "Indent the JSON output.")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	started := time.Now()
	overview := Overview{
		SchemaVersion: SchemaVersion,
		Providers:     collect(ctx),
	}
	carryForward(overview.Providers, *output)
	overview.UpdatedAt = nowISO()
	overview.ElapsedMs = time.Since(started).Milliseconds()

	if err := write(overview, *output, *pretty); err != nil {
		fmt.Fprintln(os.Stderr, "gitwork:", err)
		os.Exit(1)
	}
}

// collect fans out over every configured host at once. A slow self-managed
// GitLab no longer delays GitHub — the run costs the slowest single host
// rather than the sum of all of them.
func collect(ctx context.Context) []*Provider {
	type job struct {
		order int
		build func() *Provider
	}

	var jobs []job
	for i, host := range githubHosts() {
		host, isDefault := host, i == 0
		jobs = append(jobs, job{
			order: len(jobs),
			build: func() *Provider { return collectGitHub(ctx, host, isDefault) },
		})
	}
	for i, host := range gitlabHosts() {
		host, isDefault := host, i == 0
		jobs = append(jobs, job{
			order: len(jobs),
			build: func() *Provider { return collectGitLab(ctx, host, isDefault) },
		})
	}

	results := make([]*Provider, len(jobs))
	var wg sync.WaitGroup
	for _, j := range jobs {
		wg.Add(1)
		go func(j job) {
			defer wg.Done()
			results[j.order] = j.build()
		}(j)
	}
	wg.Wait()

	// Discovery order is the display order: GitHub first, then GitLab, each
	// with its canonical host ahead of any self-managed instance. Which host
	// the panel *opens* on is a presentation choice and stays in the panel.
	providers := make([]*Provider, 0, len(results))
	for _, p := range results {
		if p != nil {
			providers = append(providers, p)
		}
	}
	return providers
}

// write lands the document atomically: the panel watches this file, and a
// half-written overview would flash an empty dashboard on every refresh.
func write(overview Overview, path string, pretty bool) error {
	var (
		data []byte
		err  error
	)
	if pretty {
		data, err = json.MarshalIndent(overview, "", "  ")
	} else {
		data, err = json.Marshal(overview)
	}
	if err != nil {
		return err
	}
	data = append(data, '\n')

	if path == "" {
		_, err = os.Stdout.Write(data)
		return err
	}
	if dir := filepath.Dir(path); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// staleWindow bounds how long a carried-over record stays useful. Past this,
// showing yesterday's queue is worse than showing the error.
const staleWindow = 6 * time.Hour

// carryForward keeps the last good record for any host this run could not
// reach. A dropped VPN or a flaky network should not blank a working dashboard
// — but an *authentication* failure genuinely means the data is gone, so those
// records (which carry no Error) are left as the collector found them.
func carryForward(providers []*Provider, path string) {
	if path == "" {
		return
	}
	previous := readOverview(path)
	if previous == nil {
		return
	}
	byKey := make(map[string]*Provider, len(previous.Providers))
	for _, p := range previous.Providers {
		byKey[p.Key] = p
	}

	for i, current := range providers {
		if current.Ready || current.Error == "" {
			continue
		}
		old := byKey[current.Key]
		if old == nil || !old.Ready {
			continue
		}
		asOf := old.UpdatedAt
		if old.Stale && old.StaleAt != "" {
			asOf = old.StaleAt
		}
		when, err := time.Parse(time.RFC3339, asOf)
		if err != nil || time.Since(when) > staleWindow {
			continue
		}

		carried := *old
		carried.Stale = true
		carried.StaleAt = asOf
		carried.UpdatedAt = current.UpdatedAt
		carried.ElapsedMs = current.ElapsedMs
		carried.Error = current.Error
		carried.AuthHelp = current.AuthHelp
		providers[i] = &carried
	}
}

func readOverview(path string) *Overview {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var previous Overview
	if err := json.Unmarshal(data, &previous); err != nil {
		return nil
	}
	if previous.SchemaVersion != SchemaVersion {
		return nil
	}
	return &previous
}
