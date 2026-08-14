package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

var errNoCLI = errors.New("cli not installed")

// Identity plus all three merge-request queues in one request. Issues come
// over REST because the root `issues` GraphQL field needs a username we do not
// have yet, while REST's `scope=` filters work off the token alone — so both
// can fly concurrently instead of one waiting on the other.
const gitlabQuery = `
query {
  currentUser {
    username
    name
    webUrl
    reviewRequestedMergeRequests(state: opened, first: 50, sort: UPDATED_DESC) { count nodes { ...mr } }
    assignedMergeRequests(state: opened, first: 50, sort: UPDATED_DESC) { count nodes { ...mr } }
    authoredMergeRequests(state: opened, first: 50, sort: UPDATED_DESC) { count nodes { ...mr } }
  }
}
fragment mr on MergeRequest {
  iid title webUrl updatedAt draft approved userNotesCount
  project { fullPath }
}
`

type glMR struct {
	IID            string `json:"iid"`
	Title          string `json:"title"`
	WebURL         string `json:"webUrl"`
	UpdatedAt      string `json:"updatedAt"`
	Draft          bool   `json:"draft"`
	Approved       bool   `json:"approved"`
	UserNotesCount int    `json:"userNotesCount"`
	Project        struct {
		FullPath string `json:"fullPath"`
	} `json:"project"`
}

type glConnection struct {
	Count int    `json:"count"`
	Nodes []glMR `json:"nodes"`
}

type glResponse struct {
	CurrentUser *struct {
		Username string `json:"username"`
		Name     string `json:"name"`
		WebURL   string `json:"webUrl"`

		ReviewRequestedMergeRequests glConnection `json:"reviewRequestedMergeRequests"`
		AssignedMergeRequests        glConnection `json:"assignedMergeRequests"`
		AuthoredMergeRequests        glConnection `json:"authoredMergeRequests"`
	} `json:"currentUser"`
}

type glIssue struct {
	IID            int    `json:"iid"`
	Title          string `json:"title"`
	WebURL         string `json:"web_url"`
	UpdatedAt      string `json:"updated_at"`
	UserNotesCount int    `json:"user_notes_count"`
	References     struct {
		Full string `json:"full"`
	} `json:"references"`
}

type glEvent struct {
	CreatedAt string `json:"created_at"`
}

// gitlabToken asks `glab` for the token it already stores for this host,
// which covers both the plain-config and keyring cases.
func gitlabToken(ctx context.Context, host string) (string, error) {
	if v := strings.TrimSpace(os.Getenv("GITLAB_TOKEN")); v != "" && host == strings.TrimSpace(os.Getenv("GITLAB_HOST")) {
		return v, nil
	}
	if !haveBinary("glab") {
		return "", errNoCLI
	}
	return runCLI(ctx, "glab", "config", "get", "token", "--host", host)
}

func collectGitLab(ctx context.Context, host string, isDefault bool) *Provider {
	started := time.Now()
	p := newProvider(KindGitLab, host, isDefault)
	defer func() {
		p.UpdatedAt = nowISO()
		p.ElapsedMs = time.Since(started).Milliseconds()
	}()

	token, err := gitlabToken(ctx, host)
	if err != nil || token == "" {
		p.AuthHelp = "Not signed in to " + host + ". Run: glab auth login --hostname " + host
		if err == errNoCLI {
			p.AuthHelp = "GitLab CLI not found. Install `glab`, then run: glab auth login"
		}
		return p
	}

	base := "https://" + host
	headers := map[string]string{"PRIVATE-TOKEN": token}

	var (
		wg                                 sync.WaitGroup
		graph                              glResponse
		graphErr, assignedErr, authoredErr error
		assigned, authored                 []glIssue
		assignedTotal, authoredTotal       int
		calendar                           Calendar
	)

	wg.Add(4)
	go func() {
		defer wg.Done()
		graphErr = graphQL(ctx, base+"/api/graphql", headers, gitlabQuery, nil, &graph)
	}()
	go func() {
		defer wg.Done()
		assigned, assignedTotal, assignedErr = gitlabIssues(ctx, base, headers, "assigned_to_me")
	}()
	go func() {
		defer wg.Done()
		authored, authoredTotal, authoredErr = gitlabIssues(ctx, base, headers, "created_by_me")
	}()
	go func() {
		defer wg.Done()
		calendar = gitlabCalendar(ctx, base, headers)
	}()
	wg.Wait()

	if graphErr != nil {
		if isAuthError(graphErr) {
			p.AuthHelp = "Token rejected by " + host + ". Run: glab auth login --hostname " + host
		} else {
			p.Error = graphErr.Error()
			p.AuthHelp = "Could not reach " + host + "."
		}
		return p
	}
	if graph.CurrentUser == nil || graph.CurrentUser.Username == "" {
		p.AuthHelp = "Token for " + host + " has no user. Run: glab auth login --hostname " + host
		return p
	}

	user := graph.CurrentUser
	p.Username = user.Username
	p.DisplayName = user.Name
	p.UserURL = user.WebURL
	p.Calendar = calendar

	p.ReviewRequests = glMRItems(user.ReviewRequestedMergeRequests.Nodes)
	p.AssignedPrs = glMRItems(user.AssignedMergeRequests.Nodes)
	p.AuthoredPrs = glMRItems(user.AuthoredMergeRequests.Nodes)
	p.AssignedIssues = glIssueItems(assigned)
	p.AuthoredIssues = glIssueItems(authored)

	p.count("reviewRequests", user.ReviewRequestedMergeRequests.Count, p.ReviewRequests)
	p.count("assignedPrs", user.AssignedMergeRequests.Count, p.AssignedPrs)
	p.count("authoredPrs", user.AuthoredMergeRequests.Count, p.AuthoredPrs)
	p.count("assignedIssues", assignedTotal, p.AssignedIssues)
	p.count("authoredIssues", authoredTotal, p.AuthoredIssues)

	// Issue failures are not fatal: MRs and the calendar still carry the
	// panel, and the row simply reads zero.
	if assignedErr != nil && authoredErr != nil {
		p.Error = assignedErr.Error()
	}

	p.Ready = true
	return p
}

func gitlabIssues(ctx context.Context, base string, headers map[string]string, scope string) ([]glIssue, int, error) {
	url := base + "/api/v4/issues?state=opened&scope=" + scope +
		"&order_by=updated_at&sort=desc&per_page=50&with_labels_details=false"
	var rows []glIssue
	head, err := request(ctx, http.MethodGet, url, headers, nil, &rows)
	if err != nil {
		return nil, 0, err
	}
	total, _ := strconv.Atoi(head.Get("X-Total"))
	return rows, total, nil
}

// gitlabPageCap bounds the event walk. A year of heavy activity can run to
// thousands of events; past this the calendar is already representative and
// the extra requests only cost the user latency.
const gitlabPageCap = 40

// gitlabCalendar reconstructs a contribution year from the events feed.
// GitLab has no contribution-calendar API, and its `/users/x/calendar.json`
// web endpoint is not reliably available on self-managed instances. Page one
// reports the total page count, so every remaining page is fetched at once
// rather than walked serially.
func gitlabCalendar(ctx context.Context, base string, headers map[string]string) Calendar {
	today := time.Now()
	start, _ := calendarWindow(today)
	after := start.AddDate(0, 0, -1).Format(dayFormat)

	page := func(n int) ([]glEvent, http.Header, error) {
		url := base + "/api/v4/events?after=" + after +
			"&per_page=100&sort=asc&page=" + strconv.Itoa(n)
		var rows []glEvent
		head, err := request(ctx, http.MethodGet, url, headers, nil, &rows)
		return rows, head, err
	}

	first, head, err := page(1)
	if err != nil {
		return emptyCalendar()
	}

	pages := 1
	if n, convErr := strconv.Atoi(head.Get("X-Total-Pages")); convErr == nil && n > pages {
		pages = n
	}
	if pages > gitlabPageCap {
		pages = gitlabPageCap
	}

	rest := make([][]glEvent, pages+1)
	if pages > 1 {
		var wg sync.WaitGroup
		for n := 2; n <= pages; n++ {
			wg.Add(1)
			go func(n int) {
				defer wg.Done()
				rows, _, pageErr := page(n)
				if pageErr == nil {
					rest[n] = rows
				}
			}(n)
		}
		wg.Wait()
	}

	counts := map[string]int{}
	tally := func(rows []glEvent) {
		for _, e := range rows {
			if len(e.CreatedAt) >= 10 {
				counts[e.CreatedAt[:10]]++
			}
		}
	}
	tally(first)
	for _, rows := range rest {
		tally(rows)
	}
	return buildCalendar(counts, today, 0)
}

func glMRItems(nodes []glMR) []Item {
	items := make([]Item, 0, len(nodes))
	for _, n := range nodes {
		if n.WebURL == "" {
			continue
		}
		iid, _ := strconv.Atoi(n.IID)
		review := ""
		if n.Approved {
			review = "approved"
		}
		items = append(items, Item{
			Number:     iid,
			Title:      n.Title,
			Repository: n.Project.FullPath,
			URL:        n.WebURL,
			UpdatedAt:  n.UpdatedAt,
			Draft:      n.Draft,
			Review:     review,
			Comments:   n.UserNotesCount,
		})
	}
	return items
}

func glIssueItems(rows []glIssue) []Item {
	items := make([]Item, 0, len(rows))
	for _, r := range rows {
		if r.WebURL == "" {
			continue
		}
		items = append(items, Item{
			Number:     r.IID,
			Title:      r.Title,
			Repository: projectFromReference(r.References.Full),
			URL:        r.WebURL,
			UpdatedAt:  r.UpdatedAt,
			Comments:   r.UserNotesCount,
		})
	}
	return items
}

// projectFromReference turns "group/project#12" into "group/project".
func projectFromReference(ref string) string {
	if i := strings.IndexAny(ref, "#!"); i >= 0 {
		return ref[:i]
	}
	return ref
}
