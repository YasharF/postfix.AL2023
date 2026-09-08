#!/bin/bash
# Install the built Postfix RPMs on a clean AL2023 host and start Postfix, for
# verify.yml to test against. Takes the directory holding the RPMs.
#
#   verify/run.sh /w/rpms
#
# Runs as root in an AL2023 container. There is no systemd there, so Postfix
# starts through its own postfix-script rather than the unit. postfix start
# daemonises, so this returns once Postfix is up.

set -eux -o pipefail

RPMS=${1:?usage: run.sh <directory of RPMs>}
HERE=$(cd "$(dirname "$0")" && pwd)

# shadow-utils: %pre falls back to useradd/groupadd with no systemd-sysusers.
# openssl: %post generates the self-signed cert Postfix serves for STARTTLS.
# systemd: for systemd-tmpfiles only, nothing is run under it.
# The rest are postfix-script's dependencies and what the checks below use.
dnf -y install shadow-utils openssl hostname findutils diffutils procps-ng \
    python3 iproute systemd

# Every subpackage, so the map plugins are all present for the map checks: a
# dynamic map that failed to build or link shows up there as a missing type.
# Debug packages are filtered by filename, because dnf --exclude matches
# package names, not a list of local files.
mapfile -t pkgs < <(find "$RPMS" -name 'postfix-*.rpm' \
    ! -name '*-debuginfo-*' ! -name '*-debugsource-*' | sort)
[ "${#pkgs[@]}" -gt 0 ] || { echo "no RPMs found under $RPMS"; exit 1; }
printf '%s\n' "${pkgs[@]}"
dnf -y install "${pkgs[@]}"

# The sendmail-compatible entry points are alternatives symlinks from %post,
# not files in the package. rpm only warns when %post fails, so a broken
# alternatives call shows up nowhere else.
alternatives --display mta
command -v sendmail mailq newaliases rmail

# The identities %pre creates through sysusers. If that silently did nothing,
# everything below fails in a much less obvious way.
getent passwd postfix
getent group postdrop

# Postfix looks the host's name up, so it has to resolve. Setting the name
# needs privileges the container lacks; the /etc/hosts entry is what matters.
hostname postfix-verify.example.com 2>/dev/null || :
grep -q postfix-verify /etc/hosts || echo "127.0.0.1 postfix-verify.example.com postfix-verify" >> /etc/hosts

# postconf -e rather than appending to main.cf: several of these already have
# values there, and a second entry wins but warns on every postfix command.
mapfile -t settings < <(grep -vE '^[[:space:]]*(#|$)' "$HERE/main.cf.settings")
postconf -e "${settings[@]}"

# The chroot the default master.cf puts smtpd in has no /etc/hosts or resolver
# config in a bare container.
sed -i -E 's/^([a-z]+ +(inet|unix|fifo|pass) +[ny-]+ +[ny-]+ +)y( +)/\1n\3/' /etc/postfix/master.cf

# The queue tree is not in the package. It comes from tmpfiles.d, which a
# real host runs through systemd at install time and at boot. Nothing runs it
# in a bare container, and postfix will not start without the tree.
[ -d /var/spool/postfix ] \
    && echo "queue tree already present" \
    || echo "queue tree absent; creating it from the tmpfiles config"
systemd-tmpfiles --create /usr/lib/tmpfiles.d/postfix.conf
ls -la /var/spool/postfix

postconf -n

# /etc/aliases comes from the setup package, not from postfix: the spec
# removes its own copy. postalias fails outright without it.
[ -e /etc/aliases ] || printf 'postmaster: root\n' > /etc/aliases

# postalias rather than newaliases: newaliases only reaches the same place by
# a longer route through the alternatives symlinks. Timed, because a hang here
# looks like nothing more than a slow start.
timeout 120 postalias /etc/aliases

postfix set-permissions
postfix check
postfix start
# Informational. postfix start returns as soon as master is spawned, so this
# can lose the race with master writing its pid file. The workflow's check for
# a listener on port 25 is the authoritative one.
postfix status || true
