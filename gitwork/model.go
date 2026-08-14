package main

import (
	"strings"
	"time"
)

// SchemaVersion is bumped whenever the JSON contract below changes shape.
// Main.qml refuses to render anything it does not recognize.
const SchemaVersion = 3

const (
	KindGitHub = "github"
	KindGitLab = "gitlab"
)

// Item is one merge/pull request or issue. Both providers are normalized onto
// this shape so the panel never branches on which host a row came from.
type Item struct {
	Number     int    `json:"number"`
	Title      string `json:"title"`
	Repository string `json:"repository"`
	URL        string `json:"url"`
	UpdatedAt  string `json:"updatedAt"`
	Draft      bool   `json:"draft"`
	// Author is the handle that opened it, empty when it is you. Rows only
	// need it when somebody else's work is sitting in your queue.
	Author string `json:"author"`
	// Review is the aggregate review state of a PR/MR: "approved",
	// "changes_requested", "review_required" or "" when unknown.
	Review   string `json:"review"`
	Comments int    `json:"comments"`
}

// Calendar is a full trailing year of contributions, aligned so that index 0
// is a Sunday and the final index is today. `Counts` therefore always splits
// evenly into `Weeks` columns of seven rows, which is what lets the panel draw
// the grid without doing any date math of its own.
type Calendar struct {
	Supported bool   `json:"supported"`
	Start     string `json:"start"`
	End       string `json:"end"`
	Weeks     int    `json:"weeks"`
	Counts    []int  `json:"counts"`
	// Levels holds a 0-4 intensity per day, quartiled over the non-zero
	// counts, so the panel paints straight from the data.
	Levels  []int `json:"levels"`
	Total   int   `json:"total"`
	Current int   `json:"current"`
	Longest int   `json:"longest"`
	Today   int   `json:"today"`
	Max     int   `json:"max"`
	// MonthStarts marks, per week column, the month number (1-12) whose
	// first day falls in that column, or 0. Panel labels the axis from it.
	MonthStarts []int `json:"monthStarts"`
}

// Provider is one authenticated (or attempted) host. GitHub Enterprise and
// self-managed GitLab instances each get their own entry, keyed by host, and
// the panel groups them by Kind into one tab per provider.
type Provider struct {
	Key         string `json:"key"`
	Kind        string `json:"kind"`
	Name        string `json:"name"`
	Host        string `json:"host"`
	HostLabel   string `json:"hostLabel"`
	DefaultHost bool   `json:"defaultHost"`
	Ready       bool   `json:"ready"`
	// Stale marks a record carried over from the previous run because this
	// one could not reach the host. The data is real, just not current.
	Stale       bool   `json:"stale"`
	StaleAt     string `json:"staleAt"`
	Username    string `json:"username"`
	DisplayName string `json:"displayName"`
	WebURL      string `json:"webUrl"`
	UserURL     string `json:"userUrl"`
	AuthHelp    string `json:"authHelpText"`
	Error       string `json:"error"`
	UpdatedAt   string `json:"updatedAt"`
	ElapsedMs   int64  `json:"elapsedMs"`
	MrTerm      string `json:"mrTerm"`
	MrTermShort string `json:"mrTermShort"`

	Calendar Calendar `json:"calendar"`

	ReviewRequests []Item `json:"reviewRequests"`
	AssignedPrs    []Item `json:"assignedPrs"`
	AuthoredPrs    []Item `json:"authoredPrs"`
	AssignedIssues []Item `json:"assignedIssues"`
	AuthoredIssues []Item `json:"authoredIssues"`

	// Totals carry the server-side count, which can exceed the number of
	// rows fetched; the panel shows the true number and marks the list as
	// truncated rather than lying about it.
	Totals map[string]int `json:"totals"`
}

// Overview is the whole document written to disk.
type Overview struct {
	SchemaVersion int         `json:"schemaVersion"`
	UpdatedAt     string      `json:"updatedAt"`
	ElapsedMs     int64       `json:"elapsedMs"`
	Providers     []*Provider `json:"providers"`
}

func newProvider(kind, host string, isDefault bool) *Provider {
	p := &Provider{
		Key:            kind + "@" + host,
		Kind:           kind,
		Host:           host,
		HostLabel:      host,
		DefaultHost:    isDefault,
		UpdatedAt:      nowISO(),
		ReviewRequests: []Item{},
		AssignedPrs:    []Item{},
		AuthoredPrs:    []Item{},
		AssignedIssues: []Item{},
		AuthoredIssues: []Item{},
		Totals:         map[string]int{},
		Calendar:       emptyCalendar(),
	}
	if kind == KindGitHub {
		p.Name = "GitHub"
		p.MrTerm = "Pull requests"
		p.MrTermShort = "PRs"
		p.WebURL = "https://" + host
		if host == "github.com" {
			p.HostLabel = "github.com"
		}
	} else {
		p.Name = "GitLab"
		p.MrTerm = "Merge requests"
		p.MrTermShort = "MRs"
		p.WebURL = "https://" + host
	}
	return p
}

// count fills Totals from a server-reported count, falling back to the number
// of rows actually returned when the API gives us nothing better.
func (p *Provider) count(name string, reported int, rows []Item) {
	if reported < len(rows) {
		reported = len(rows)
	}
	p.Totals[name] = reported
}

func nowISO() string {
	return time.Now().UTC().Format(time.RFC3339)
}

// otherAuthor blanks the author when it is the viewer: a row in your own
// queue does not need to tell you who opened it.
func otherAuthor(author, viewer string) string {
	if author == "" || strings.EqualFold(author, viewer) {
		return ""
	}
	return author
}
