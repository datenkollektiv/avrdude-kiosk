#!/usr/bin/env bash
# init-firewall.sh — default-deny egress for the agent sandbox.
# Adapted from anthropics/claude-code/.devcontainer/init-firewall.sh (blob 361d2aa, 2026-11-10).
# Deviations from upstream are marked "toolbox:"; the rest follows upstream so a diff stays readable.
#
# Usage: sudo /usr/local/bin/init-firewall.sh         apply (root, via the sudoers entry)
#        init-firewall.sh --check [ALLOWLIST_DIR]      print the assembled domain list, change nothing, no root
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

die() { echo "ERROR: $*" >&2; exit 1; }

# toolbox: paths. Root always uses the image-baked locations; the FIREWALL_* overrides exist for
# scripts/test-init-firewall.sh, which runs as a normal user. sudo's env_reset strips them anyway.
ALLOWLIST_DIR=/etc/devcontainer-firewall/allowlist.d
GH_META_SNAPSHOT=/etc/devcontainer-firewall/github-meta.json
RUN_DIR=/run/agent-sandbox
RESOLV_CONF=/etc/resolv.conf
CHECK=0
if [ "${1:-}" = "--check" ]; then
    # toolbox: --check reads whatever directory the caller names and echoes offending lines, so it must
    # never run with privileges. sudoers pins the root invocation to no arguments; this is the second layer.
    [ "$(id -u)" -ne 0 ] || die "--check must not run as root; run it without sudo"
    CHECK=1
    ALLOWLIST_DIR="${2:-$ALLOWLIST_DIR}"
elif [ "$(id -u)" -ne 0 ]; then
    ALLOWLIST_DIR="${FIREWALL_ALLOWLIST_DIR:-$ALLOWLIST_DIR}"
    GH_META_SNAPSHOT="${FIREWALL_GH_META_SNAPSHOT:-$GH_META_SNAPSHOT}"
    RUN_DIR="${FIREWALL_RUN_DIR:-$RUN_DIR}"
    RESOLV_CONF="${FIREWALL_RESOLV_CONF:-$RESOLV_CONF}"
fi
SET=allowed-domains

# toolbox: temporary rules for the recovery resolve phase. Inserted at the top of the chain so they
# precede a leftover final REJECT; remembered so the trap and the apply phase can remove them by spec.
TEMP_RULES=()
temp_allow() {   # temp_allow <chain> <match...> -j ACCEPT
    local IFS=' '
    iptables -I "$@"
    TEMP_RULES+=("$*")
}
temp_clear() {
    local IFS=' ' rule
    for rule in ${TEMP_RULES[@]+"${TEMP_RULES[@]}"}; do
        # shellcheck disable=SC2086  # word-split on purpose: the rule was stored as one string
        iptables -D $rule 2>/dev/null || true
    done
    TEMP_RULES=()
}

# toolbox: fail closed. Upstream set its DROP policies ~60 lines in, so any earlier failure left
# everything ACCEPT (claude-code#106426). Here any non-zero exit ends with DROP policies and no marker.
# The failed flag makes the next run keep DROP and open only DNS and api.github.com:443 while it resolves;
# policies are never set to ACCEPT, so a run the agent forces to fail cannot open the network.
fail_closed() {
    local rc=$?
    if [ "$rc" -eq 0 ] || [ "$CHECK" -eq 1 ]; then
        return 0
    fi
    rm -f "$RUN_DIR/firewall-ok" 2>/dev/null || true
    { mkdir -p "$RUN_DIR" && : > "$RUN_DIR/firewall-failed"; } 2>/dev/null || true
    temp_clear
    iptables -P INPUT DROP 2>/dev/null || true
    iptables -P FORWARD DROP 2>/dev/null || true
    iptables -P OUTPUT DROP 2>/dev/null || true
    # toolbox: the success path drops IPv6 only after the apply phase, so the trap mirrors it; a kernel without
    # ip6tables fails silently here and the success-path warning covers that case.
    ip6tables -P INPUT DROP 2>/dev/null || true
    ip6tables -P FORWARD DROP 2>/dev/null || true
    ip6tables -P OUTPUT DROP 2>/dev/null || true
    echo "ERROR: firewall init failed (rc=$rc); all traffic dropped until 'sudo /usr/local/bin/init-firewall.sh' succeeds" >&2
}
# toolbox: a fatal signal runs the EXIT trap with $?=0, which fail_closed reads as success and skips. Ctrl-C or a
# closed terminal during resolution would leave the network open, so the signals exit non-zero on purpose.
trap 'exit 130' INT
trap 'exit 143' TERM HUP
trap fail_closed EXIT

# --- toolbox: 1. assemble the domain list from fragments ---------------------------------------------
[ -d "$ALLOWLIST_DIR" ] || die "allowlist dir $ALLOWLIST_DIR missing"
DOMAINS=()
for f in "$ALLOWLIST_DIR"/*.txt; do
    [ -e "$f" ] || continue
    n=0
    while IFS= read -r raw || [ -n "$raw" ]; do
        n=$((n + 1))
        line="${raw%%#*}"
        line="$(printf '%s' "$line" | tr -d ' \t\r' | tr 'A-Z' 'a-z')"
        if [ -z "$line" ]; then
            continue
        fi
        if printf '%s' "$line" | grep -Eq '^[0-9.]+$'; then
            die "$f:$n: IP literals are not allowed: '$line'"
        fi
        if ! printf '%s' "$line" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; then
            die "$f:$n: invalid domain: '$line'"
        fi
        case "$line" in
            localhost|*.localhost|*.internal|*.local) die "$f:$n: refused internal name: '$line'" ;;
        esac
        DOMAINS+=("$line")
    done < "$f"
done
DOMAIN_LIST="$(printf '%s\n' ${DOMAINS[@]+"${DOMAINS[@]}"} | grep -v '^$' | sort -u || true)"
[ -n "$DOMAIN_LIST" ] || die "no domains found in $ALLOWLIST_DIR"
DOMAIN_COUNT=$(printf '%s\n' "$DOMAIN_LIST" | wc -l | tr -d ' ')

if [ "$CHECK" -eq 1 ]; then
    printf '%s\n' "$DOMAIN_LIST"
    echo "check only: $DOMAIN_COUNT domains from $ALLOWLIST_DIR, plus GitHub ranges from api.github.com/meta at apply time" >&2
    exit 0
fi

# --- toolbox: 2. resolve everything while the network is still open ----------------------------------
rm -f "$RUN_DIR/firewall-ok" 2>/dev/null || true
RECOVERY=0
if [ -e "$RUN_DIR/firewall-failed" ]; then
    RECOVERY=1
    rm -f "$RUN_DIR/firewall-failed"
fi

# toolbox: DNS is allowed only to the resolvers this container started with (upstream: udp/53 to any host).
RESOLVERS=""
while IFS=$' \t' read -r kw addr _; do
    [ "$kw" = "nameserver" ] || continue
    case "$addr" in
        *:*) echo "Skipping IPv6 resolver $addr (IPv6 is dropped)" ;;
        *)   RESOLVERS="$RESOLVERS$addr"$'\n' ;;
    esac
done < "$RESOLV_CONF"
RESOLVERS="$(printf '%s' "$RESOLVERS" | grep -v '^$' || true)"
[ -n "$RESOLVERS" ] || die "no IPv4 nameserver in $RESOLV_CONF"

# toolbox: after a failed run the policies are DROP. Open only what resolution needs (lo, replies, DNS to
# the pinned resolvers, tcp/443 to api.github.com) instead of ACCEPT-all; temp_clear removes it again.
GH_RESOLVE=()
if [ "$RECOVERY" -eq 1 ]; then
    echo "Previous run failed closed; policies stay DROP, opening DNS and api.github.com:443 for this run's resolution..."
    temp_allow INPUT -i lo -j ACCEPT
    temp_allow OUTPUT -o lo -j ACCEPT
    temp_allow INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    temp_allow OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    for ns in $RESOLVERS; do
        temp_allow OUTPUT -d "$ns" -p udp --dport 53 -j ACCEPT
        temp_allow OUTPUT -d "$ns" -p tcp --dport 53 -j ACCEPT
    done
    gh_ips=$(dig +noall +answer +time=3 +tries=2 A api.github.com | awk '$4 == "A" {print $5}' || true)
    gh_hosts=""
    for ip in $gh_ips; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            die "Invalid IP from DNS for api.github.com: $ip"
        fi
        temp_allow OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT
        gh_hosts="$gh_hosts${gh_hosts:+,}$ip"
    done
    if [ -n "$gh_hosts" ]; then
        GH_RESOLVE=(--resolve "api.github.com:443:$gh_hosts")   # curl connects to the IPs just allowed
    else
        echo "WARNING: api.github.com did not resolve; the live /meta fetch will fail and the snapshot is used"
    fi
fi

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Fetch GitHub meta information and aggregate their IP ranges (upstream, moved before the flush)
# toolbox: -f turns a 403 rate-limit body into an empty result, --max-time bounds a stalled fetch, and a
# build-time snapshot of /meta keeps the firewall recoverable when the live fetch is unusable.
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -fsS --max-time 20 --proto '=https' ${GH_RESOLVE[@]+"${GH_RESOLVE[@]}"} https://api.github.com/meta || true)
gh_live_error=""
if [ -z "$gh_ranges" ]; then
    gh_live_error="Failed to fetch GitHub IP ranges"
elif ! printf '%s' "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
    gh_live_error="GitHub API response missing required fields"
fi
if [ -n "$gh_live_error" ]; then
    [ -s "$GH_META_SNAPSHOT" ] || die "$gh_live_error (no snapshot at $GH_META_SNAPSHOT)"
    echo "WARNING: $gh_live_error; using build-time snapshot $GH_META_SNAPSHOT"
    gh_ranges=$(cat "$GH_META_SNAPSHOT")
    printf '%s' "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1 || die "GitHub meta snapshot $GH_META_SNAPSHOT missing required fields"
fi
GH_CIDRS=""
while read -r cidr; do
    [ -n "$cidr" ] || continue
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        die "Invalid CIDR range from GitHub meta: $cidr"
    fi
    GH_CIDRS="$GH_CIDRS$cidr"$'\n'
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

# Resolve allowed domains (upstream loop over a fragment-built list)
RESOLVED=""
for domain in $DOMAIN_LIST; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer +time=3 +tries=2 A "$domain" | awk '$4 == "A" {print $5}')
    [ -n "$ips" ] || die "Failed to resolve $domain"
    for ip in $ips; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            die "Invalid IP from DNS for $domain: $ip"
        fi
        RESOLVED="$RESOLVED$ip $domain"$'\n'
    done
done

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
[ -n "$HOST_IP" ] || die "Failed to detect host IP"
HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# --- toolbox: 3. build the new ipset and swap it in atomically ---------------------------------------
ipset create "$SET-new" hash:net -exist
ipset flush "$SET-new"
for cidr in $GH_CIDRS; do
    echo "Adding GitHub range $cidr"
    ipset add "$SET-new" "$cidr" -exist   # toolbox: -exist, duplicates aborted upstream (claude-code#15611)
done
while IFS=' ' read -r ip domain; do
    [ -n "$ip" ] || continue
    echo "Adding $ip for $domain"
    ipset add "$SET-new" "$ip" -exist
done <<< "$RESOLVED"
if ipset list "$SET" >/dev/null 2>&1; then
    ipset swap "$SET-new" "$SET"
    ipset destroy "$SET-new"
else
    ipset rename "$SET-new" "$SET"
fi

# --- 4. apply: toolbox sets DROP policies first, then flushes, then adds the allows --------------------
temp_clear   # toolbox: the recovery rules are gone before the final set is built
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# Allow localhost (Docker's embedded DNS at 127.0.0.11 rides on lo)
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
# Allow established connections for already approved traffic (covers DNS and SSH replies)
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# toolbox: outbound DNS only to the pinned resolvers
for ns in $RESOLVERS; do
    iptables -A OUTPUT -d "$ns" -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -d "$ns" -p tcp --dport 53 -j ACCEPT
done
# toolbox: cloud metadata and link-local are never reachable
iptables -A OUTPUT -d 169.254.0.0/16 -j REJECT --reject-with icmp-admin-prohibited
iptables -A OUTPUT -d 100.100.100.200/32 -j REJECT --reject-with icmp-admin-prohibited
# Allow outbound SSH (git over ssh to any host; see README "Limits")
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
# Host network (keeps IDE backends and forwarded ports working)
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT
# Then allow only specific outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set "$SET" dst -j ACCEPT
# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# toolbox: the allowlist holds IPv4 A records only, so IPv6 would bypass it; drop it where ip6tables works.
if command -v ip6tables >/dev/null 2>&1 && ip6tables -L -n >/dev/null 2>&1; then
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
    ip6tables -F
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
else
    echo "WARNING: ip6tables unavailable; IPv6 is not filtered (disable IPv6 on the Docker network)"
fi

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    die "Firewall verification failed - was able to reach https://example.com"
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# Verify GitHub API access
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    die "Firewall verification failed - unable to reach https://api.github.com"
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi

# toolbox: success marker; yolo.just refuses bypass mode without it. Root-owned, so node cannot forge it.
mkdir -p "$RUN_DIR"
chmod 0755 "$RUN_DIR"
date -u +%Y-%m-%dT%H:%M:%SZ > "$RUN_DIR/firewall-ok"
chmod 0644 "$RUN_DIR/firewall-ok"
echo "Firewall active: $DOMAIN_COUNT domains from $ALLOWLIST_DIR plus GitHub ranges; marker $RUN_DIR/firewall-ok"
