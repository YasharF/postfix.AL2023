#!/bin/bash
# Install the built Postfix RPMs on a clean AL2023 host and start Postfix, for
# verify.yml to test against. Takes the directory holding the RPMs.
#
#   verify/run.sh /w/rpms
#
# Runs as root in an AL2023 container, in the foreground, so every step's
# output lands in the workflow log as it happens and a failure is attributed
# to the command that caused it. There is no systemd in that container, so
# Postfix is started through its own postfix-script rather than the unit --
# the same binaries and the same master.cf either way. postfix start
# daemonises, so this returns once Postfix is up.

set -eux -o pipefail

RPMS=${1:?usage: run.sh <directory of RPMs>}
HERE=$(cd "$(dirname "$0")" && pwd)

# shadow-utils: %pre creates the postfix user through
# %sysusers_create_compat, which falls back to useradd/groupadd where
# systemd-sysusers isn't running, as here.
# openssl: %post generates the self-signed cert Postfix serves for STARTTLS.
# hostname, findutils, diffutils, procps-ng: postfix-script's own dependencies
# plus what the checks below use.
# systemd is here for systemd-tmpfiles, not to run anything: see the queue
# directory note below.
dnf -y install shadow-utils openssl hostname findutils diffutils procps-ng \
    python3 iproute systemd

# Every subpackage, so the map plugins are all present for the postconf -m
# check below: a dynamic map that failed to build or link shows up there as a
# missing type rather than as a build error. The debug packages are filtered
# by filename rather than with dnf --exclude, which matches package names and
# is not dependable against a list of local files.
mapfile -t pkgs < <(find "$RPMS" -name 'postfix-*.rpm' \
    ! -name '*-debuginfo-*' ! -name '*-debugsource-*' | sort)
[ "${#pkgs[@]}" -gt 0 ] || { echo "no RPMs found under $RPMS"; exit 1; }
printf '%s\n' "${pkgs[@]}"
dnf -y install "${pkgs[@]}"

# The sendmail-compatible entry points are alternatives symlinks that %post
# creates; they are not files in the package. A failing %post is only a
# warning to rpm, so if the alternatives call does not work the package still
# installs "successfully" and this is the only place it shows.
alternatives --display mta
command -v sendmail mailq newaliases rmail

# The identities %pre is supposed to have created through sysusers. Worth
# asserting rather than assuming: if the sysusers path silently did nothing,
# everything below fails in a much less obvious way.
getent passwd postfix
getent group postdrop

# A resolvable hostname. Changing it needs privileges the container does not
# have, and does not matter anyway -- myhostname and mydomain are set
# explicitly below -- but the name has to resolve, because Postfix looks it up.
hostname postfix-verify.example.com 2>/dev/null || :
grep -q postfix-verify /etc/hosts || echo "127.0.0.1 postfix-verify.example.com postfix-verify" >> /etc/hosts

# postconf -e rather than appending to main.cf: several of these parameters
# already have values in the shipped file, and a second entry lower down wins
# but makes postfix warn about the override on every single command, which
# buries everything else in the log.
mapfile -t settings < <(grep -vE '^[[:space:]]*(#|$)' "$HERE/main.cf.settings")
postconf -e "${settings[@]}"

# The chroot the default master.cf would put smtpd in has no /etc/hosts or
# resolver config in a bare container. Fedora's config patch already sets
# chroot to n; this makes that explicit and independent of it.
sed -i -E 's/^([a-z]+ +(inet|unix|fifo|pass) +[ny-]+ +[ny-]+ +)y( +)/\1n\3/' /etc/postfix/master.cf

# /var/spool/postfix and its queue subdirectories are not in the package. They
# come from /usr/lib/tmpfiles.d/postfix.conf, which systemd-tmpfiles creates:
# on a real host through systemd's RPM file trigger at install time, and again
# through systemd-tmpfiles-setup.service at boot. Neither runs in a bare
# container, so postfix finds no queue directory and dies with
# "chdir(/var/spool/postfix): No such file or directory". This does explicitly
# what systemd would have done, rather than working around it by hand.
[ -d /var/spool/postfix ] \
    && echo "queue tree already present" \
    || echo "queue tree absent; creating it from the tmpfiles config"
systemd-tmpfiles --create /usr/lib/tmpfiles.d/postfix.conf
ls -la /var/spool/postfix

postconf -n

# /etc/aliases comes from the `setup` package on RHEL-family distributions,
# not from postfix -- the spec explicitly removes its own copy. newaliases
# fails outright without it, so this does not assume it is there.
[ -e /etc/aliases ] || printf 'postmaster: root\n' > /etc/aliases

# postalias rather than newaliases: newaliases is postfix's sendmail(1) in
# another guise, and reaches the same postalias by a longer route through the
# alternatives symlinks. Timed, because a hang here is otherwise invisible --
# it just looks like a slow start.
timeout 120 postalias /etc/aliases

postfix set-permissions
postfix check
postfix start
# Informational: postfix start returns as soon as master is spawned, so a
# status check immediately after can lose the race with master writing its pid
# file. The workflow's own check that something is listening on port 25 is the
# authoritative one.
postfix status || true
