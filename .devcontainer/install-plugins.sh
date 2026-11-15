#!/usr/bin/env bash
# install-plugins.sh — chained into the agent sandbox's postStartCommand after init-firewall.sh, run as node.
#
# Registers the toolbox tree baked to /opt/agents-toolbox as a Claude Code folder marketplace and installs
# every plugin in its marketplace.json that is not defaultEnabled:false. Folder marketplaces load in place,
# so the ~/.claude volume only stores the registration and the skills run from the root-owned copy.
# Idempotent: a registered marketplace and an installed plugin are skipped, one line per action.
# Never touches the project tree; everything lands under CLAUDE_CONFIG_DIR (the ~/.claude volume).
set -euo pipefail

root=/opt/agents-toolbox
manifest="$root/.claude-plugin/marketplace.json"

if [ ! -f "$manifest" ]; then
  echo "install-plugins: no $manifest; image built without toolbox/, nothing to install"
  exit 0
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "install-plugins: claude not on PATH; skipping plugin install"
  exit 0
fi

# Stay out of the workspace: plugin commands write to the config dir, never to the cwd, but a cwd that
# is a project tree is one surprise too many.
cd "${HOME:-/}"

name="$(jq -r .name "$manifest")"
if [ -z "$name" ] || [ "$name" = null ]; then
  echo "install-plugins: $manifest has no .name" >&2
  exit 1
fi

plugins="$(jq -r '.plugins[] | select(.defaultEnabled != false) | .name' "$manifest")"
registered="$(claude plugin marketplace list 2>/dev/null || true)"
if grep -qF "Folder ($root)" <<<"$registered"; then
  echo "install-plugins: marketplace $name already registered from $root"
else
  # A marketplace of the same name that points elsewhere (a stale path from an older container, or the
  # project's git entry) blocks `add`; its plugins must go first, then the entry, then the fresh registration.
  if grep -qE "[[:space:]]$name[[:space:]]*\$" <<<"$registered"; then
    echo "install-plugins: marketplace $name points elsewhere; re-registering from $root"
    for plugin in $plugins; do claude plugin uninstall "$plugin@$name" >/dev/null 2>&1 || true; done
    claude plugin marketplace remove "$name" >/dev/null 2>&1 || true
  fi
  claude plugin marketplace add "$root"
  echo "install-plugins: registered marketplace $name from $root"
fi

installed="$(claude plugin list 2>/dev/null || true)"
for plugin in $plugins; do
  if grep -qF "$plugin@$name" <<<"$installed"; then
    echo "install-plugins: $plugin@$name already installed"
  else
    claude plugin install "$plugin@$name"
    echo "install-plugins: installed $plugin@$name"
  fi
done
