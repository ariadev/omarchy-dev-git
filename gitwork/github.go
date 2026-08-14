package main

import (
	"context"
	"os"
	"strings"
	"time"
)

// One query covers the whole provider: identity, the trailing-year
// contribution calendar, and all five open-work queues. GitHub bills this as a
// single point of rate limit and answers in one round trip, replacing the six
// separate `gh` invocations the previous collector paid for.
const githubQuery = `
query {
  viewer {
    login
    name
    url
    contributionsCollection {
      contributionCalendar {
        totalContributions
        weeks { contributionDays { date contributionCount } }
      }
    }
  }
  reviewRequests: search(query: "is:open is:pr review-requested:@me archived:false", type: ISSUE, first: 50) {
    issueCount
    nodes { ...pr }
  }
  assignedPrs: search(query: "is:open is:pr assignee:@me archived:false", type: ISSUE, first: 50) {
    issueCount
    nodes { ...pr }
  }
  authoredPrs: search(query: "is:open is:pr author:@me archived:false", type: ISSUE, first: 50) {
    issueCount
    nodes { ...pr }
  }
  assignedIssues: search(query: "is:open is:issue assignee:@me archived:false", type: ISSUE, first: 50) {
    issueCount
    nodes { ...issue }
  }
  authoredIssues: search(query: "is:open is:issue author:@me archived:false", type: ISSUE, first: 50) {
    issueCount
    nodes { ...issue }
  }
}
fragment pr on PullRequest {
  number title url updatedAt isDraft reviewDecision
  comments { totalCount }
  repository { nameWithOwner }
}
fragment issue on Issue {
  number title url updatedAt
  comments { totalCount }
  repository { nameWithOwner }
}
`

type ghNode struct {
	Number         int    `json:"number"`
	Title          string `json:"title"`
	URL            string `json:"url"`
	UpdatedAt      string `json:"updatedAt"`
	IsDraft        bool   `json:"isDraft"`
	ReviewDecision string `json:"reviewDecision"`
	Comments       struct {
		TotalCount int `json:"totalCount"`
	} `json:"comments"`
	Repository struct {
		NameWithOwner string `json:"nameWithOwner"`
	} `json:"repository"`
}

type ghSearch struct {
	IssueCount int      `json:"issueCount"`
	Nodes      []ghNode `json:"nodes"`
}

type ghResponse struct {
	Viewer struct {
		Login                   string `json:"login"`
		Name                    string `json:"name"`
		URL                     string `json:"url"`
		ContributionsCollection struct {
			ContributionCalendar struct {
				TotalContributions int `json:"totalContributions"`
				Weeks              []struct {
					ContributionDays []struct {
						Date              string `json:"date"`
						ContributionCount int    `json:"contributionCount"`
					} `json:"contributionDays"`
				} `json:"weeks"`
			} `json:"contributionCalendar"`
		} `json:"contributionsCollection"`
	} `json:"viewer"`
	ReviewRequests ghSearch `json:"reviewRequests"`
	AssignedPrs    ghSearch `json:"assignedPrs"`
	AuthoredPrs    ghSearch `json:"authoredPrs"`
	AssignedIssues ghSearch `json:"assignedIssues"`
	AuthoredIssues ghSearch `json:"authoredIssues"`
}

func githubGraphQLEndpoint(host string) string {
	if host == "github.com" || host == "api.github.com" {
		return "https://api.github.com/graphql"
	}
	return "https://" + host + "/api/graphql"
}

// githubToken prefers the environment (so a headless run works with no CLI at
// all) and otherwise asks `gh`, which transparently handles keyring storage.
func githubToken(ctx context.Context, host string) (string, error) {
	if host == "github.com" {
		for _, key := range []string{"GH_TOKEN", "GITHUB_TOKEN"} {
			if v := strings.TrimSpace(os.Getenv(key)); v != "" {
				return v, nil
			}
		}
	}
	if !haveBinary("gh") {
		return "", errNoCLI
	}
	return runCLI(ctx, "gh", "auth", "token", "--hostname", host)
}

func collectGitHub(ctx context.Context, host string, isDefault bool) *Provider {
	started := time.Now()
	p := newProvider(KindGitHub, host, isDefault)
	defer func() {
		p.UpdatedAt = nowISO()
		p.ElapsedMs = time.Since(started).Milliseconds()
	}()

	token, err := githubToken(ctx, host)
	if err != nil || token == "" {
		p.AuthHelp = "Not signed in to " + host + ". Run: gh auth login --hostname " + host
		if err == errNoCLI {
			p.AuthHelp = "GitHub CLI not found. Install `gh`, then run: gh auth login"
		}
		return p
	}

	headers := map[string]string{"Authorization": "bearer " + token}
	var data ghResponse
	if err := graphQL(ctx, githubGraphQLEndpoint(host), headers, githubQuery, nil, &data); err != nil {
		if isAuthError(err) {
			p.AuthHelp = "Token rejected by " + host + ". Run: gh auth login --hostname " + host
		} else {
			p.Error = err.Error()
			p.AuthHelp = "Could not reach " + host + "."
		}
		return p
	}

	p.Username = data.Viewer.Login
	p.DisplayName = data.Viewer.Name
	p.UserURL = data.Viewer.URL
	if p.UserURL != "" {
		p.WebURL = strings.TrimSuffix(p.UserURL, "/"+p.Username)
	}

	p.ReviewRequests = ghItems(data.ReviewRequests.Nodes)
	p.AssignedPrs = ghItems(data.AssignedPrs.Nodes)
	p.AuthoredPrs = ghItems(data.AuthoredPrs.Nodes)
	p.AssignedIssues = ghItems(data.AssignedIssues.Nodes)
	p.AuthoredIssues = ghItems(data.AuthoredIssues.Nodes)

	p.count("reviewRequests", data.ReviewRequests.IssueCount, p.ReviewRequests)
	p.count("assignedPrs", data.AssignedPrs.IssueCount, p.AssignedPrs)
	p.count("authoredPrs", data.AuthoredPrs.IssueCount, p.AuthoredPrs)
	p.count("assignedIssues", data.AssignedIssues.IssueCount, p.AssignedIssues)
	p.count("authoredIssues", data.AuthoredIssues.IssueCount, p.AuthoredIssues)

	counts := map[string]int{}
	for _, week := range data.Viewer.ContributionsCollection.ContributionCalendar.Weeks {
		for _, day := range week.ContributionDays {
			counts[day.Date] = day.ContributionCount
		}
	}
	p.Calendar = buildCalendar(counts, time.Now(),
		data.Viewer.ContributionsCollection.ContributionCalendar.TotalContributions)

	p.Ready = true
	return p
}

func ghItems(nodes []ghNode) []Item {
	items := make([]Item, 0, len(nodes))
	for _, n := range nodes {
		if n.URL == "" {
			continue
		}
		items = append(items, Item{
			Number:     n.Number,
			Title:      n.Title,
			Repository: n.Repository.NameWithOwner,
			URL:        n.URL,
			UpdatedAt:  n.UpdatedAt,
			Draft:      n.IsDraft,
			Review:     strings.ToLower(n.ReviewDecision),
			Comments:   n.Comments.TotalCount,
		})
	}
	return items
}
