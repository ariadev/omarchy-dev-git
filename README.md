# dev.git — Git dashboard bar widget for Omarchy

A native [Omarchy](https://opencode.ai) shell bar widget that watches GitHub and
GitLab for open work: activity streaks, review queues, and your own pull and
merge requests, all in one panel.

## Features

- Per-provider activity streak: last 7 days, current run, longest run, total contributions
- A grid of open-work counts: awaiting review, assigned PRs/MRs, assigned issues, authored issues
- Click a count to open the pre-filtered queue page in your browser
- "Awaiting review" list and "My open PRs/MRs" list, each row clickable
- Multiple GitLab instances supported side by side (one entry per configured host)
- Keyboard navigation: `j`/`k` rows, `h`/`l` provider, `Enter` open, `r` refresh, `Tab` switch panel
- Left click toggles the panel, middle click cycles providers, right click refreshes

## Requirements

- [gh](https://cli.github.com/) authenticated with `gh auth login`
- [glab](https://gitlab.com/gitlab-org/cli) authenticated with `glab auth login`

Both are optional: GitHub and each GitLab host are collected independently, so
a missing or unauthenticated provider never hides the others.

## Install

```bash
omarchy plugin add https://github.com/ariadev/omarchy-dev-git.git --enable --yes
```

Or clone into your config by hand and enable it:

```bash
omarchy plugin enable dev.git
omarchy bar put dev.git --after omarchy.agents
```

## How it works

The widget runs `gitwork.py` on a timer (default every 300 s) and reads the
JSON it writes to `~/.local/state/omarchy/git/overview.json`. Data is collected
via the `gh` and `glab` CLIs:

- GitHub: search API for review-requested/assigned/authored PRs and issues,
  GraphQL contribution calendar for the streak
- GitLab: GraphQL `currentUser` MR queues with a REST fallback, REST for
  issues, user events for the streak

No tokens or secrets are stored by the plugin; it only uses the CLIs you have
already authenticated.

## Settings

| Key                | Type    | Default | Description                       |
|--------------------|---------|---------|-----------------------------------|
| `refreshIntervalSec` | integer | 300     | Collector run interval in seconds |
| `providers.github.enabled`  | boolean | true | Show the GitHub provider |
| `providers.gitlab.enabled`  | boolean | true | Show GitLab providers |

## License

MIT