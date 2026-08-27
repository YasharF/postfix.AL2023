#!/bin/bash
# Install Postfix from a dnf repository the way a consumer does, and check that
# what arrived is what the repository offered and is properly signed.
#
#   verify/repo-install.sh <series> [expected-version-release]
#
# Give the expected version when checking a repository that has just been
# published. Without it this only checks the repository is self consistent,
# which stale metadata satisfies just as well as fresh metadata.
#
# Expects /etc/yum.repos.d/postfix-al2023-<series>.repo to already be in place,
# so the caller decides whether it points at a local copy of the repository or
# at the published site. Run on AL2023 as root.

set -eux -o pipefail

SERIES=${1:?usage: repo-install.sh <series> [expected-version-release]}
EXPECTED=${2:-}
ID=postfix-al2023-$SERIES
REPO=/etc/yum.repos.d/$ID.repo
[ -s "$REPO" ] || { echo "$REPO is not in place"; exit 1; }

dnf -y install --allowerasing shadow-utils systemd gnupg2

export GNUPGHOME=/tmp/gnupg
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

dnf -q repolist
dnf list --showduplicates postfix

# The newest postfix this repository offers. Anything else means dnf preferred
# AL2023's own package, which is what priority= exists to prevent.
want=$(dnf -q repoquery --repo="$ID" --qf '%{version}-%{release}' postfix | sort -V | tail -1)
[ -n "$want" ] || { echo "the repository offers no postfix at all"; exit 1; }

dnf -y install postfix postfix-pcre postfix-lmdb
got=$(rpm -q --qf '%{version}-%{release}' postfix)
echo "repository offers $want, dnf installed $got"
[ "$want" = "$got" ]

if [ -n "$EXPECTED" ] && [ "$got" != "$EXPECTED" ]; then
    echo "expected $EXPECTED to be the newest, but the repository served $got"
    exit 1
fi

# A host pointed at one series' repository stays on that series.
case "$got" in
    "$SERIES".*) echo "on series $SERIES, as asked for" ;;
    *) echo "asked for series $SERIES but got $got"; exit 1 ;;
esac

arch=$(rpm -E '%{_arch}')
baseurl=$(sed -n 's/^baseurl=//p' "$REPO" | head -1)
baseurl=${baseurl//\$basearch/$arch}
baseurl=${baseurl%/}
keyurl=$(sed -n 's/^gpgkey=//p' "$REPO" | head -1)
curl -fsSLo /tmp/key.asc "$keyurl"
keyid=$(gpg --show-keys --with-colons /tmp/key.asc | awk -F: '/^fpr/{print $10; exit}' \
          | tail -c 17 | tr 'A-Z' 'a-z')
[ -n "$keyid" ] || { echo "$keyurl holds no key"; exit 1; }
echo "expecting signatures from key $keyid"

# The signature is in the RSAHEADER tag, not SIGPGP, so read the rendered
# line rather than naming a tag that a header-only signature leaves empty.
for p in postfix postfix-pcre postfix-lmdb; do
    sig=$(rpm -qi "$p" | sed -n 's/^Signature *: *//p')
    case "$sig" in
        *"Key ID $keyid"*) echo "$p: $sig" ;;
        *) echo "$p is not signed by $keyid (got: ${sig:-none})"; exit 1 ;;
    esac
done

# Against an rpmdb holding no keys first. If that verified, the check below
# would prove nothing: it would pass for an unsigned package too.
url=$(dnf -q repoquery --repo="$ID" --location "postfix-$got" | tail -1)
curl -fsSLo /tmp/pkg.rpm "$url"
mkdir -p /tmp/db
rpm --dbpath /tmp/db --initdb
if rpm --dbpath /tmp/db -K /tmp/pkg.rpm; then
    echo "the package verified with no key imported"
    exit 1
fi
rpm --dbpath /tmp/db --import /tmp/key.asc
rpm --dbpath /tmp/db -K /tmp/pkg.rpm | grep -q "digests signatures OK"

# The metadata signature, against the key the repository publishes rather than
# the copy dnf has already imported.
gpg --batch --quiet --import /tmp/key.asc
curl -fsSLo /tmp/repomd.xml "$baseurl/repodata/repomd.xml"
curl -fsSLo /tmp/repomd.xml.asc "$baseurl/repodata/repomd.xml.asc"
gpg --batch --verify /tmp/repomd.xml.asc /tmp/repomd.xml

# sendmail symlinks come from %post, not from the package, so a broken
# scriptlet shows up only here.
command -v sendmail mailq newaliases rmail

# The queue tree comes from tmpfiles, which no container runs.
systemd-tmpfiles --create /usr/lib/tmpfiles.d/postfix.conf
postfix check
echo "installed $got from $ID"
