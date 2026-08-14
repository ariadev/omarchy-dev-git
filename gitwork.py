#!/usr/bin/env python3
"""Collect GitHub and GitLab open work into one JSON overview.

Reads nothing but the local `gh` and `glab` CLIs (their authenticated
sessions) and writes a single JSON record consumed by the dev.git
bar plugin. GitHub and GitLab are collected independently, so one being
unauthenticated or unreachable never hides the other.

Output shape:

  {
    "schemaVersion": 1,
    "updatedAt": "...",
    "providers": {
      "github": {
        "id": "github", "name": "GitHub", "ready": true, "username": "ariadev",
        "authHelpText": "", "updatedAt": "...", "webUrl": "...",
        "mrTerm": "Pull requests",
        "streak": { "days": [{"date","count"}], "current", "longest", "total", "today" },
        "reviewRequests":  [ {number,title,repository,url,updatedAt} ],
        "assignedPrs":     [ ... ],
        "authoredPrs":     [ ... ],
        "assignedIssues":  [ ... ],
        "authoredIssues":  [ ... ]
      },
      "gitlab": { ... same shape, "mrTerm": "Merge requests" },
      "gitlab.<host>": { ... extra GitLab instances, one entry per host ... }
    }
  }
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys

SCHEMA_VERSION = 1


def run(argv, timeout=60):
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return proc.returncode, proc.stdout, proc.stderr
    except FileNotFoundError:
        return 127, "", "not found: %s" % (argv[0] if argv else "?")
    except subprocess.TimeoutExpired:
        return 124, "", "timed out: %s" % (argv[0] if argv else "?")
    except Exception as exc:  # noqa: BLE001
        return 1, "", str(exc)


def parse_json(text):
    if not text:
        return None
    try:
        return json.loads(text)
    except Exception:
        return None


def iso_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def date_shift(days):
    return (datetime.date.today() - datetime.timedelta(days=days)).isoformat()


# Shared streak computation. `counts` maps "YYYY-MM-DD" -> contribution count.
def streak_from_counts(counts):
    today = datetime.date.today()
    days = []
    for i in range(6, -1, -1):
        day = (today - datetime.timedelta(days=i)).isoformat()
        days.append({"date": day, "count": int(counts.get(day, 0) or 0)})

    cursor = today
    current = 0
    while int(counts.get(cursor.isoformat(), 0) or 0) > 0:
        current += 1
        cursor = cursor - datetime.timedelta(days=1)

    longest = 0
    run = 0
    for date in sorted(counts):
        if int(counts[date] or 0) > 0:
            run += 1
            longest = max(longest, run)
        else:
            run = 0

    return {
        "days": days,
        "current": current,
        "longest": longest,
        "total": sum(int(counts[d] or 0) for d in counts),
        "today": int(counts.get(today.isoformat(), 0) or 0),
    }


def empty_streak():
    return {"days": [], "current": 0, "longest": 0, "total": 0, "today": 0}


# ---------------------------------------------------------------- GitHub


def gh_collect():
    provider = {
        "id": "github",
        "name": "GitHub",
        "ready": False,
        "username": "",
        "authHelpText": "",
        "webUrl": "https://github.com",
        "mrTerm": "Pull requests",
        "updatedAt": iso_now(),
        "streak": empty_streak(),
        "reviewRequests": [],
        "assignedPrs": [],
        "authoredPrs": [],
        "assignedIssues": [],
        "authoredIssues": [],
    }

    rc, _, _ = run(["gh", "auth", "status"])
    if rc != 0:
        provider["authHelpText"] = "Not signed in. Run `gh auth login`."
        return provider

    rc, out, _ = run(["gh", "api", "user", "--jq", ".login"])
    if rc != 0:
        provider["authHelpText"] = "GitHub API unreachable. Check `gh auth status`."
        return provider
    provider["username"] = out.strip()

    query = (
        "query { viewer { login contributionsCollection { contributionCalendar { "
        "weeks { contributionDays { date contributionCount } } } } } }"
    )
    rc, out, _ = run(["gh", "api", "graphql", "-f", "query=" + query])
    if rc == 0:
        provider["streak"] = gh_streak(parse_json(out))
    else:
        provider["authHelpText"] = "GitHub GraphQL failed."

    provider["reviewRequests"] = gh_search("prs", ["--review-requested", "@me"])
    provider["assignedPrs"] = gh_search("prs", ["--assignee", "@me"])
    provider["authoredPrs"] = gh_search("prs", ["--author", "@me"])
    provider["assignedIssues"] = gh_search("issues", ["--assignee", "@me"])
    provider["authoredIssues"] = gh_search("issues", ["--author", "@me"])
    provider["ready"] = True
    return provider


def gh_search(kind, qual):
    argv = [
        "gh", "search", kind, "--state", "open",
        "--json", "number,title,repository,url,updatedAt", "--limit", "100",
    ] + qual
    rc, out, _ = run(argv)
    if rc != 0:
        return []
    rows = parse_json(out) or []
    result = []
    for row in rows:
        repo = row.get("repository") or {}
        result.append({
            "number": row.get("number"),
            "title": str(row.get("title", "")),
            "repository": str(repo.get("nameWithOwner", "")),
            "url": str(row.get("url", "")),
            "updatedAt": str(row.get("updatedAt", "")),
        })
    return result


def gh_streak(raw):
    counts = {}
    try:
        weeks = raw["data"]["viewer"]["contributionsCollection"]["contributionCalendar"]["weeks"]
        for week in weeks:
            for day in week["contributionDays"]:
                counts[day["date"]] = int(day.get("contributionCount", 0) or 0)
    except Exception:
        return empty_streak()
    return streak_from_counts(counts)


# ---------------------------------------------------------------- GitLab


def glab_hosts():
    """Configured GitLab hosts, in the order glab lists them in config.yml."""
    env_host = os.environ.get("GITLAB_HOST", "").strip()
    if env_host:
        return [env_host]

    path = os.path.expanduser("~/.config/glab-cli/config.yml")
    hosts = []
    default_host = "gitlab.com"
    in_hosts = False
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                if line[0].isspace():
                    if in_hosts and line[:4].isspace() and not line[4:5].isspace():
                        match = re.match(r"^([A-Za-z0-9_.-]+):\s*$", stripped)
                        if match:
                            hosts.append(match.group(1))
                    continue
                if stripped == "hosts:":
                    in_hosts = True
                    continue
                if in_hosts:
                    break
                if stripped.startswith("host:"):
                    value = stripped.split(":", 1)[1].strip()
                    if value:
                        default_host = value
    except (FileNotFoundError, OSError):
        pass

    if not hosts:
        hosts = [default_host]
    return hosts


def glab_collect(host):
    provider = {
        "id": "gitlab",
        "name": "GitLab" if host == "gitlab.com" else host,
        "host": host,
        "ready": False,
        "username": "",
        "authHelpText": "",
        "webUrl": "https://" + host,
        "mrTerm": "Merge requests",
        "updatedAt": iso_now(),
        "streak": empty_streak(),
        "reviewRequests": [],
        "assignedPrs": [],
        "authoredPrs": [],
        "assignedIssues": [],
        "authoredIssues": [],
    }

    rc, out, _ = run(["glab", "api", "--hostname", host, "user"])
    if rc != 0:
        provider["authHelpText"] = (
            "Not signed in to %s. Run `glab auth login --hostname %s`." % (host, host)
        )
        return provider
    me = parse_json(out) or {}
    username = str(me.get("username", "")).strip()
    user_id = me.get("id")
    web_url = str(me.get("web_url", "")).strip()
    if not username or user_id is None:
        provider["authHelpText"] = "Could not read user for %s." % host
        return provider
    provider["username"] = username
    if web_url:
        provider["webUrl"] = web_url

    provider["streak"] = glab_streak(username, host)

    # Cross-project queues live behind GraphQL; fall back to the REST
    # collection when the endpoint is not available on the host.
    gql = (
        "query { currentUser { username "
        "reviewRequestedMergeRequests(state: opened, first: 100) { nodes { iid title webUrl updatedAt project { fullPath } } } "
        "assignedMergeRequests(state: opened, first: 100) { nodes { iid title webUrl updatedAt project { fullPath } } } "
        "authoredMergeRequests(state: opened, first: 100) { nodes { iid title webUrl updatedAt project { fullPath } } } "
        "} }"
    )
    rc, out, _ = run(["glab", "api", "--hostname", host, "graphql", "-f", "query=" + gql])
    if rc == 0:
        data = parse_json(out)
        current = (data or {}).get("data", {}).get("currentUser", {}) if data else {}
        provider["reviewRequests"] = glab_nodes(current.get("reviewRequestedMergeRequests"))
        provider["assignedPrs"] = glab_nodes(current.get("assignedMergeRequests"))
        provider["authoredPrs"] = glab_nodes(current.get("authoredMergeRequests"))
    else:
        provider["reviewRequests"] = glab_rest("merge_requests", {"reviewer_id": user_id}, host)
        provider["assignedPrs"] = glab_rest("merge_requests", {"assignee_id": user_id}, host)
        provider["authoredPrs"] = glab_rest("merge_requests", {"author_id": user_id}, host)

    provider["assignedIssues"] = glab_rest("issues", {"assignee_id": user_id}, host)
    provider["authoredIssues"] = glab_rest("issues", {"author_id": user_id}, host)
    provider["ready"] = True
    return provider


def glab_nodes(bucket):
    nodes = (bucket or {}).get("nodes") or []
    result = []
    for node in nodes:
        project = node.get("project") or {}
        result.append({
            "number": node.get("iid"),
            "title": str(node.get("title", "")),
            "repository": str(project.get("fullPath", "")),
            "url": str(node.get("webUrl", "")),
            "updatedAt": str(node.get("updatedAt", "")),
        })
    return result


def glab_rest(collection, filters, host):
    params = {"state": "opened", "scope": "all", "per_page": "100"}
    params.update({k: v for k, v in filters.items() if v is not None})
    query = "&".join("%s=%s" % (k, v) for k, v in params.items())
    rc, out, _ = run(["glab", "api", "--hostname", host, "%s?%s" % (collection, query)])
    if rc != 0:
        return []
    rows = parse_json(out) or []
    result = []
    for row in rows:
        ref = row.get("references") or {}
        repo = glab_repo(ref)
        result.append({
            "number": row.get("iid"),
            "title": str(row.get("title", "")),
            "repository": repo,
            "url": str(row.get("web_url", "")),
            "updatedAt": str(row.get("updated_at", "")),
        })
    return result


def glab_repo(ref):
    if not ref:
        return ""
    full = str(ref.get("full", ""))
    for sep in ("!", "#"):
        if sep in full:
            return full.split(sep, 1)[0]
    return full


def glab_streak(username, host):
    counts = {}
    page = 1
    after = date_shift(30)
    while page <= 5:
        rc, out, _ = run([
            "glab", "api", "--hostname", host,
            "users/%s/events?after=%s&per_page=100&sort=asc&page=%d" % (username, after, page),
        ])
        if rc != 0:
            break
        rows = parse_json(out) or []
        if not isinstance(rows, list) or not rows:
            break
        for event in rows:
            date = str(event.get("created_at", ""))[:10]
            if date:
                counts[date] = counts.get(date, 0) + 1
        if len(rows) < 100:
            break
        page += 1
    return streak_from_counts(counts)


# ------------------------------------------------------------------ main


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="", help="Path to write the overview JSON.")
    args = parser.parse_args(argv)

    providers = {"github": gh_collect()}
    for host in glab_hosts():
        key = "gitlab" if host == "gitlab.com" else "gitlab." + host
        providers[key] = glab_collect(host)

    # Only keep providers whose CLI binary exists at all; a provider that is
    # present but unauthenticated stays in the record with ready: false so the
    # panel can offer the auth hint.
    for pid in list(providers):
        binary = "gh" if pid == "github" else "glab"
        rc, _, _ = run([binary, "--version"])
        if rc != 0:
            providers.pop(pid)

    overview = {
        "schemaVersion": SCHEMA_VERSION,
        "updatedAt": iso_now(),
        "providers": providers,
    }
    text = json.dumps(overview, indent=2, ensure_ascii=False) + "\n"
    output = args.output
    if output:
        import os

        directory = os.path.dirname(output)
        if directory:
            os.makedirs(directory, exist_ok=True)
        tmp = output + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp, output)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
