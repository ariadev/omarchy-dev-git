# dev.git — Git dashboard bar widget for Omarchy

A native [Omarchy](https://omarchy.org) shell bar widget that watches GitHub,
GitLab and Gitea for open work: a full-year contribution graph, review queues,
your own pull and merge requests, and recent Gitea organization activity, all
in one panel.

![The dev.git panel showing the GitHub and GitLab tabs side by side](preview.png)

## Features

- **Full-year activity graph** — trailing 53 weeks, quartile-shaded, with
  per-day tooltips, streaks and today's count
- **Multiple hosts per provider** — GitHub Enterprise and self-managed GitLab
  and Gitea are discovered from `gh`/`glab`/`tea` config, each with its own
  identity, graph and queues, behind a host switch inside the tab
- **Gitea organization activity** — every visible organization member is
  listed and ranked by push events in the recent organization feed, with the
  latest repository and activity age; quiet members remain visible. Counts
  cover the first feed page (up to 100 events), not a fixed time period or
  lifetime total
- **Open-work grid** — awaiting review, assigned PRs/MRs, assigned and authored
  issues; each click opens the pre-filtered queue page
- **Queue rows** carrying draft tag, approval check, comment count, repository,
  number and age
- A dot on the bar icon when something is waiting on your review
- Keyboard driven throughout

## Install

```bash
omarchy plugin add https://github.com/ariadev/omarchy-dev-git.git --enable --yes
```

Needs `curl` and `jq`, plus any of [gh](https://cli.github.com/),
[glab](https://gitlab.com/gitlab-org/cli) and [tea](https://gitea.com/gitea/tea)
signed in — the collector reads the credentials those CLIs already hold and
never stores a token of its own. All three are optional: each provider is
collected independently, so a missing or unauthenticated one never hides the
others.

Self-hosted instances may use plain HTTP for local development. Configure the
CLI with an `http://` URL (for example, `tea login add --url
http://localhost:3000` or `glab auth login --hostname localhost:3000
--api-protocol http`) and the collector will preserve that scheme. HTTPS
remains the default for hosts that do not explicitly select HTTP.
Gitea URLs can also include a reverse-proxy subpath, such as
`https://git.example.com/Code`.

Nothing is compiled or installed. Clone it and it runs.

## Keyboard

| Key       | Action                        |
|-----------|-------------------------------|
| `j` / `k` | Move down / up the queue rows |
| `h` / `l` | Previous / next provider tab  |
| `[` / `]` | Previous / next host          |
| `g` / `G` | First / last row              |
| `Enter`   | Open the selected row         |
| `p`       | Pin the provider tab first    |
| `r`       | Refresh now                   |
| `Tab`     | Neighbouring panel            |
| `Esc`     | Close                         |

Left click toggles the panel, middle click cycles providers, right click
refreshes.

### Open it from a keybinding

The panel exposes an IPC target, so it can be bound to a key. Add to
`~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + G", "Git dashboard", "omarchy-shell dev.git toggle")
```

`toggle`, `open`, `close`, `refresh` and `next` (cycle provider) are all
available — `omarchy-shell dev.git refresh` refreshes without opening.

## How it works

`bin/gitwork` runs on a timer (default 300 s) and writes one JSON overview to
`~/.local/state/omarchy/git/overview.json`, which the panel watches. It is a
bash script with its JSON transforms in `bin/gitwork.jq`.

GitHub needs one GraphQL request per host for identity, calendar and all five
queues. GitLab takes one GraphQL request for identity and merge requests, REST
for issues, and the events feed for the calendar — it has no calendar API — with
page one reporting the page count so the rest are fetched together. Gitea has no
GraphQL at all, but its issue search takes each queue as query parameters and
answers pulls and issues from one row shape, so identity comes first and then
the five queues, heatmap, visible organization rosters and recent organization
feeds fly together. Gitea browser links use the base URL configured in `tea`,
including its scheme, port and subpath.

Organization and member lists are paginated, with a 40-page safety limit per
list and at most eight organization requests in flight per host. Visibility
follows the signed-in account's permissions. A missing or restricted organization
API leaves the personal queues working; unavailable feeds and incomplete member
lists are labeled in the panel instead of being presented as quiet activity.

Every host is collected in its own subshell, so a run costs the slowest single
host rather than the sum of them. A host that cannot be reached carries its last
good record forward for up to six hours, marked stale, so a dropped VPN does not
blank a working dashboard. An authentication failure is not carried: that data
is genuinely gone.

## Settings

| Key                        | Type    | Default | Description                |
|----------------------------|---------|---------|----------------------------|
| `refreshIntervalSec`       | integer | 300     | Collector run interval (s) |
| `providers.github.enabled` | boolean | true    | Show the GitHub tab        |
| `providers.gitlab.enabled` | boolean | true    | Show the GitLab tab        |
| `providers.gitea.enabled`  | boolean | true    | Show the Gitea tab         |

## Tests

```bash
./tests/run.sh
```

No network or credentials required — requests use stub responses or
deliberately unreachable hosts.

## License

MIT
