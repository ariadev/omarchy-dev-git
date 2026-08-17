#!/usr/bin/env bash
# Host discovery: the YAML scan, normalization, and ordering. Discovery order
# is display order in the panel, so it is asserted rather than assumed.

source "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"

echo "hosts"

load_collector

fixtures=$(mktemp -d)
trap 'rm -rf "$fixtures"' EXIT

# --- the YAML scan ---------------------------------------------------------

# `gh` writes a flat top-level host map.
cat >"$fixtures/hosts.yml" <<'YAML'
github.com:
    user: ariadev
    oauth_token: xxx
    git_protocol: ssh
ghe.example.com:
    user: ariadev
YAML
assert_eq "github.com ghe.example.com" "$(yaml_keys_at "$fixtures/hosts.yml" "" 0 | tr '\n' ' ' | sed 's/ $//')" \
  "top-level host keys are found"

# `glab` nests its hosts under a parent block, at either of two depths.
cat >"$fixtures/glab.yml" <<'YAML'
git_protocol: ssh
hosts:
    gitlab.com:
        token: xxx
        api_host: gitlab.com
    git.example.com:
        token: yyy
editor: vim
YAML
assert_eq "gitlab.com git.example.com" \
  "$(yaml_keys_at "$fixtures/glab.yml" hosts 4 | tr '\n' ' ' | sed 's/ $//')" \
  "nested host keys are found at the given depth"
assert_eq "" "$(yaml_keys_at "$fixtures/glab.yml" hosts 2)" "the wrong depth finds nothing"

# A key after the parent block closes must not be picked up.
assert_eq "0" "$(yaml_keys_at "$fixtures/glab.yml" hosts 4 | grep -c '^editor$')" \
  "keys outside the parent block are ignored"

cat >"$fixtures/comments.yml" <<'YAML'
# a comment
github.com:  # trailing comment
  user: x

ghe.example.com:
YAML
assert_eq "github.com ghe.example.com" \
  "$(yaml_keys_at "$fixtures/comments.yml" "" 0 | tr '\n' ' ' | sed 's/ $//')" \
  "comments and blank lines are skipped"

assert_eq "" "$(yaml_keys_at "$fixtures/does-not-exist.yml" "" 0)" "a missing file yields nothing"

# Tab-indented YAML is invalid; refusing to guess beats inventing a host.
printf 'hosts:\n\tgitlab.com:\n' >"$fixtures/tabs.yml"
assert_eq "" "$(yaml_keys_at "$fixtures/tabs.yml" hosts 4)" "tab-indented input is refused"

# `tea` keeps a list of logins rather than a map, each with its own token.
cat >"$fixtures/tea.yml" <<'YAML'
logins:
    - name: work
      url: https://git.example.com
      token: aaa
      default: false
    - name: home
      url: https://tea.example.org/
      token: bbb
      default: true
preferences:
    editor: false
YAML
mkdir -p "$fixtures/teacfg/tea"
cp "$fixtures/tea.yml" "$fixtures/teacfg/tea/config.yml"
assert_eq "https://git.example.com|aaa|false https://tea.example.org/|bbb|true" \
  "$(XDG_CONFIG_HOME="$fixtures/teacfg" tea_logins | tr '\t' '|' | tr '\n' ' ' | sed 's/ $//')" \
  "every tea login yields its url, token and default flag"

assert_eq "" "$(XDG_CONFIG_HOME="$fixtures/empty-tea" tea_logins)" \
  "a missing tea config yields no logins"

# --- normalization ---------------------------------------------------------

assert_eq "github.com" "$(printf 'GitHub.com\n' | dedupe)" "hosts are lowercased"
assert_eq "gitlab.com" "$(printf 'https://gitlab.com/\n' | dedupe)" "scheme and trailing slash are stripped"
assert_eq "gitlab.com" "$(printf 'http://gitlab.com\n' | dedupe)" "http is stripped too"
assert_eq "a.com b.com" "$(printf 'a.com\nb.com\nA.com\n' | dedupe | tr '\n' ' ' | sed 's/ $//')" \
  "duplicates are dropped, first-seen order kept"
assert_eq "" "$(printf '\n\n' | dedupe)" "blank lines yield nothing"

# --- ordering --------------------------------------------------------------

assert_eq "github.com ghe.example.com" \
  "$(order_default_first github.com ghe.example.com github.com | tr '\n' ' ' | sed 's/ $//')" \
  "the canonical host is ordered first"
assert_eq "a.example b.example" \
  "$(order_default_first github.com a.example b.example | tr '\n' ' ' | sed 's/ $//')" \
  "without the canonical host, order is preserved"

# --- discovery -------------------------------------------------------------

# An explicit host wins outright: it is how a user pins the collector to one
# instance regardless of what the CLI is configured for.
assert_eq "ghe.example.com" "$(GH_HOST=ghe.example.com github_hosts)" "GH_HOST wins outright"
assert_eq "ghe.example.com" "$(GH_HOST="" GITHUB_HOST=ghe.example.com github_hosts)" \
  "GITHUB_HOST is honoured too"
assert_eq "gl.example.com" "$(GITLAB_HOST=gl.example.com gitlab_hosts)" "GITLAB_HOST wins outright"
assert_eq "gitlab.com" "$(GITLAB_HOST=https://GitLab.com/ gitlab_hosts)" \
  "an explicit host is normalized like any other"
assert_eq "tea.example.com" "$(GITEA_HOST=https://Tea.example.com/ gitea_hosts)" \
  "GITEA_HOST wins outright and is normalized"

# With a config present, every host the CLI knows about is collected.
mkdir -p "$fixtures/cfg/gh" "$fixtures/cfg/glab-cli"
cp "$fixtures/hosts.yml" "$fixtures/cfg/gh/hosts.yml"
cp "$fixtures/glab.yml" "$fixtures/cfg/glab-cli/config.yml"
assert_eq "github.com ghe.example.com" \
  "$(GH_HOST="" GITHUB_HOST="" XDG_CONFIG_HOME="$fixtures/cfg" github_hosts | tr '\n' ' ' | sed 's/ $//')" \
  "every configured GitHub host is discovered"
assert_eq "gitlab.com git.example.com" \
  "$(GITLAB_HOST="" XDG_CONFIG_HOME="$fixtures/cfg" gitlab_hosts | tr '\n' ' ' | sed 's/ $//')" \
  "every configured GitLab host is discovered"

# Gitea has no canonical host at all, so the login marked default leads.
assert_eq "tea.example.org git.example.com" \
  "$(GITEA_HOST="" XDG_CONFIG_HOME="$fixtures/teacfg" gitea_hosts | tr '\n' ' ' | sed 's/ $//')" \
  "the default tea login is ordered first"

# The token is looked up per host, so two instances never borrow each other's.
assert_eq "aaa" "$(GITEA_TOKEN="" XDG_CONFIG_HOME="$fixtures/teacfg" gitea_token git.example.com)" \
  "each Gitea host gets its own token"
assert_eq "bbb" "$(GITEA_TOKEN="" XDG_CONFIG_HOME="$fixtures/teacfg" gitea_token tea.example.org)" \
  "a trailing slash in the config does not hide the match"
GITEA_TOKEN="" XDG_CONFIG_HOME="$fixtures/teacfg" gitea_token nope.example.com >/dev/null
assert_eq "1" "$?" "an unknown Gitea host has no token"
assert_eq "envtoken" "$(GITEA_TOKEN=envtoken XDG_CONFIG_HOME="$fixtures/teacfg" gitea_token anything)" \
  "GITEA_TOKEN covers every host when no GITEA_HOST pins it"
assert_eq "aaa" \
  "$(GITEA_TOKEN=envtoken GITEA_HOST=other.example XDG_CONFIG_HOME="$fixtures/teacfg" gitea_token git.example.com)" \
  "a pinned GITEA_TOKEN does not leak onto another host"

# A self-managed instance alone still sorts stably, with no canonical host to
# lead it.
mkdir -p "$fixtures/self/glab-cli"
printf 'hosts:\n    git.example.com:\n        token: x\n' >"$fixtures/self/glab-cli/config.yml"
assert_eq "git.example.com" \
  "$(GITLAB_HOST="" XDG_CONFIG_HOME="$fixtures/self" gitlab_hosts)" \
  "a self-managed instance is discovered on its own"

# With no config at all, discovery falls back to the canonical host only when
# there is something that could plausibly hold a credential.
empty="$fixtures/empty"; mkdir -p "$empty"
if have gh; then
  assert_eq "github.com" "$(GH_HOST="" GITHUB_HOST="" XDG_CONFIG_HOME="$empty" github_hosts)" \
    "an installed gh implies github.com"
fi
assert_eq "github.com" \
  "$(GH_HOST="" GITHUB_HOST="" GITHUB_TOKEN=x XDG_CONFIG_HOME="$empty" github_hosts)" \
  "a bare token implies github.com"

finish
