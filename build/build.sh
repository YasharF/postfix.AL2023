#!/bin/bash
# Build Postfix RPMs for Amazon Linux 2023, using Fedora's spec.
#
#   build/build.sh 3.11.6 1 [rawhide]
#
# Run on AL2023 as root (a container is fine). RPMs land in ./out/RPMS.

set -eux -o pipefail

usage='usage: build.sh <postfix-version> <fedora-spec-release> [fedora-branch]'
V=${1:?$usage}
R=${2:?$usage}

# Fedora branch to take the spec from. Its patches are rebased per version
# series, so the branch must carry the same series as $V. There is no epel9
# branch and EPEL 9 has no postfix package, so Fedora is the only source.
#
# Fedora does not package every release, so its spec version is often not the
# one being built. The Version field is rewritten below.
BRANCH=${3:-${POSTFIX_SPEC_BRANCH:-rawhide}}
DISTGIT=https://src.fedoraproject.org/rpms/postfix/raw/$BRANCH/f

# Mirrors to fetch the tarball from, tried in order. Fedora's lookaside cache
# is not usable here: it only holds versions Fedora packaged. Most mirrors
# postfix.org lists are dead or serve an HTML page in place of the file.
MIRRORS=${POSTFIX_MIRRORS:-"http://ftp.netclusive.de/pub/postfix/postfix-release"}

# Postfix release signing key, pinned so an unauthenticated mirror cannot
# serve a doctored tarball. Where Fedora packaged the same version, its
# recorded SHA-512 is checked too.
KEYFILE=$(dirname "$0")/postfix-release-key.asc
KEY_FPR=622C7C012254C186677469C50C0B590E80CA15A7

LOOKASIDE=https://src.fedoraproject.org/repo/pkgs/rpms/postfix
DEST=$PWD/out/RPMS
WORK=${POSTFIX_BUILD_WORK:-/var/tmp/postfix-build}
TOP=$WORK/rpmbuild

get() { curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors "$@"; }

# Not curl: the base image ships curl-minimal, and the two conflict.
dnf -y install rpm-build 'dnf-command(builddep)' \
    findutils tar gzip gcc make patch sed m4 util-linux diffutils chkconfig

# The image ships gnupg2-minimal, which conflicts with gnupg2 and has no
# gpg-agent for gpg --import.
dnf -y install --allowerasing gnupg2

# dnf needs root; rpmbuild must not have it.
id builder >/dev/null 2>&1 || useradd -m builder
build() { runuser -u builder -- "$@"; }

rm -rf "$WORK"
mkdir -p "$TOP"/SOURCES "$TOP"/SPECS "$TOP"/BUILD "$TOP"/RPMS "$TOP"/SRPMS "$TOP"/BUILDROOT

get -o "$TOP/SPECS/postfix.spec" "$DISTGIT/postfix.spec"
get -o "$WORK/sources" "$DISTGIT/sources"

SPEC=$TOP/SPECS/postfix.spec

specver=$(sed -n 's/^Version:[[:space:]]*//p' "$SPEC" | head -1)

# The spec's series must match: a 3.11 spec builds 3.11.x, not 3.12.x.
series() { printf '%s\n' "$1" | cut -d. -f1,2; }
if [ "$(series "$specver")" != "$(series "$V")" ]; then
    echo "$BRANCH's spec is $specver; $V needs a branch on $(series "$V")"
    exit 1
fi

# Source0 uses %{version}, so the tarball name follows this rewrite.
if [ "$specver" != "$V" ]; then
    echo "spec is $specver; building $V from it"
    sed -i "s/^Version:[[:space:]]*.*/Version:        $V/" "$SPEC"
fi
sed -i "s/^Release:[[:space:]]*[0-9]\{1,\}/Release:        $R/" "$SPEC"

# Fetch and verify the tarball before using it.
export GNUPGHOME=$WORK/gnupg
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
gpg --batch --quiet --import "$KEYFILE"
gpg --batch --list-keys --with-colons | awk -F: '/^fpr/{print $10}' | grep -qx "$KEY_FPR" || {
    echo "$KEYFILE does not contain the pinned key $KEY_FPR"
    exit 1
}

tarball=postfix-$V.tar.gz
for m in $MIRRORS; do
    echo "fetching $tarball from $m"
    if get -o "$TOP/SOURCES/$tarball" "$m/official/$tarball" &&
       get -o "$WORK/$tarball.gpg2" "$m/official/$tarball.gpg2"; then
        # Some mirrors answer 200 with an HTML page instead of the file.
        if gzip -t "$TOP/SOURCES/$tarball" 2>/dev/null; then
            break
        fi
        echo "$m served something that is not a gzip file; trying the next mirror"
    fi
    rm -f "$TOP/SOURCES/$tarball" "$WORK/$tarball.gpg2"
done
[ -s "$TOP/SOURCES/$tarball" ] || { echo "no mirror served $tarball"; exit 1; }

gpg --batch --status-fd 3 --verify "$WORK/$tarball.gpg2" "$TOP/SOURCES/$tarball" 3>"$WORK/gpg.status"
grep -q "^\[GNUPG:\] VALIDSIG $KEY_FPR" "$WORK/gpg.status" || {
    echo "$tarball is not signed by the pinned Postfix release key"
    cat "$WORK/gpg.status"
    exit 1
}
echo "$tarball carries a good signature from $KEY_FPR"

# Remaining sources from Fedora's lookaside cache. Lines look like:
#   SHA512 (postfix-3.11.6.tar.gz) = <hash>
while read -r alg name _ hash; do
    [ -n "${hash:-}" ] || continue
    name=${name#(}; name=${name%)}
    [ "$alg" = SHA512 ] || { echo "unexpected checksum algorithm $alg for $name"; exit 1; }
    if [ "$name" = "$tarball" ]; then
        echo "Fedora also packaged $V; checking the mirror's bytes against its hash"
        echo "$hash  $TOP/SOURCES/$name" | sha512sum -c -
        continue
    fi
    # A tarball for a version this is not building.
    case "$name" in
        postfix-*.tar.gz) echo "skipping $name; building $V"; continue ;;
    esac
    get -o "$TOP/SOURCES/$name" "$LOOKASIDE/$name/sha512/$hash/$name"
    echo "$hash  $TOP/SOURCES/$name" | sha512sum -c -
done < "$WORK/sources"

# Patches, unit files and config snippets live in dist-git beside the spec.
# Read from the spec, so a newly added source is picked up.
pflogsumm_ver=$(sed -n 's/^%define pflogsumm_ver[[:space:]]*//p' "$SPEC" | head -1)
while read -r ref; do
    f=${ref##*/}
    f=${f//%\{name\}/postfix}
    f=${f//%\{version\}/$V}
    f=${f//%\{pflogsumm_ver\}/$pflogsumm_ver}
    case "$f" in
        *%*) echo "unexpanded macro in source name: $f"; exit 1 ;;
    esac
    # Already fetched above.
    if [ ! -e "$TOP/SOURCES/$f" ]; then
        get -o "$TOP/SOURCES/$f" "$DISTGIT/$f"
    fi
done < <(sed -nE 's/^(Source|Patch)[0-9]*:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\2/p' "$SPEC")

# AL2023's alternatives (chkconfig 1.15) knows --slave, not the newer
# --follower that Fedora's %post uses. Left alone it exits with a usage error,
# and since rpm only warns on a failed %post, the package installs without
# sendmail, mailq, newaliases or rmail.
#
# --slave is the older name for the same option. Conditional, so it stops
# applying if AL2023 ships a newer chkconfig.
if alternatives --help 2>&1 | grep -q -- --follower; then
    echo "this alternatives understands --follower; leaving the scriptlets alone"
else
    echo "rewriting --follower to --slave for AL2023's alternatives"
    sed -i 's/--follower /--slave /g' "$SPEC"
fi

chown -R builder "$WORK"

# Build as RHEL 9, which AL2023 is closest to. The spec then drops the
# libnsl2-devel BuildRequires (no such package on AL2023), builds with -DNO_NIS
# and without -lnsl, and applies the version-mismatch-warning patch.
RHEL=(--define "rhel 9")

dnf -y builddep "$SPEC" "${RHEL[@]}"

build rpmbuild -ba --define "_topdir $TOP" "${RHEL[@]}" "$SPEC"

mkdir -p "$DEST"
find "$TOP/RPMS" -name '*.rpm' -exec mv -t "$DEST" {} +
ls -1 "$DEST"
