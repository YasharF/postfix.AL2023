#!/bin/bash
# Sign published artifacts with this repository's package signing key.
#
#   build/sign.sh rpms <dir>        sign every *.rpm under <dir>, in place
#   build/sign.sh repomd <file>...  write a detached <file>.asc beside each
#
# Run on AL2023 as root (a container is fine), so signatures are produced by
# the same rpm and gnupg that consumers verify with.
#
# The key comes from the environment, never the command line:
#   RPM_GPG_PRIVATE_KEY  ASCII-armored secret key
#   RPM_GPG_PASSPHRASE   its passphrase
#
# The public half is committed. The secret key must match it, so a swapped or
# stale secret is caught here instead of at the consumer.

# No -x. It would print the passphrase.
set -eu -o pipefail

usage='usage: sign.sh rpms <dir> | sign.sh repomd <file>...'
MODE=${1:?$usage}
shift
[ $# -gt 0 ] || { echo "$usage"; exit 1; }

PUBKEY=$(dirname "$0")/../RPM-GPG-KEY-yasharf-al2023

: "${RPM_GPG_PRIVATE_KEY:?the signing key is not in the environment}"
: "${RPM_GPG_PASSPHRASE:?the signing key passphrase is not in the environment}"
[ -s "$PUBKEY" ] || { echo "$PUBKEY is missing; the signing key has not been set up"; exit 1; }

# The image ships gnupg2-minimal, which conflicts with gnupg2 and has no
# gpg-agent for gpg --import.
dnf -y install --allowerasing gnupg2 findutils
if [ "$MODE" = rpms ]; then
    dnf -y install rpm-sign
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
umask 077

export GNUPGHOME=$WORK/gnupg
mkdir -p "$GNUPGHOME"

# The fingerprint to require comes from the committed public key, so there is
# one source of truth for which key this repository signs with.
gpg --batch --quiet --import "$PUBKEY"
FPR=$(gpg --batch --list-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')
[ -n "$FPR" ] || { echo "$PUBKEY holds no key"; exit 1; }

printf '%s\n' "$RPM_GPG_PRIVATE_KEY" | gpg --batch --quiet --import
gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10}' \
    | grep -qx "$FPR" || {
    echo "the secret key in the environment is not $FPR, which is the key $PUBKEY holds"
    exit 1
}

# gpg runs unattended here, so the passphrase comes from a file rather than a
# pinentry prompt.
PASS=$WORK/passphrase
printf '%s' "$RPM_GPG_PASSPHRASE" > "$PASS"

case $MODE in
rpms)
    mapfile -t files < <(find "$1" -name '*.rpm' | sort)
    [ ${#files[@]} -gt 0 ] || { echo "no RPMs under $1"; exit 1; }

    # The whole command is defined because rpm 4.16's default leaves no hook
    # for the loopback arguments. Signing only rewrites the header, so the
    # payload stays the one Verify passed. Architecture does not matter: the
    # package is never executed, only hashed.
    rpmsign \
        --define "_gpg_name $FPR" \
        --define "__gpg_sign_cmd %{__gpg} gpg --batch --no-verbose --no-armor --pinentry-mode loopback --passphrase-file $PASS --no-secmem-warning -u \"%{_gpg_name}\" -sbo %{__signature_filename} --digest-algo sha256 %{__plaintext_filename}" \
        --addsign "${files[@]}"

    # Checked against an rpmdb holding only this key, so this tests the
    # signature rather than whatever the build host already trusts.
    db=$WORK/rpmdb
    mkdir -p "$db"
    gpg --batch --export --armor "$FPR" > "$WORK/pubkey.asc"
    rpm --dbpath "$db" --initdb
    rpm --dbpath "$db" --import "$WORK/pubkey.asc"
    for f in "${files[@]}"; do
        if ! out=$(rpm --dbpath "$db" -K "$f" 2>&1); then
            echo "$out"
            echo "signature check failed for $f"
            exit 1
        fi
        case $out in
            *"digests signatures OK"*) ;;
            *) echo "$out"; echo "$f is not signed by $FPR"; exit 1 ;;
        esac
    done
    echo "signed and verified ${#files[@]} package(s) with $FPR"
    ;;
repomd)
    for f in "$@"; do
        gpg --batch --yes --pinentry-mode loopback --passphrase-file "$PASS" \
            --local-user "$FPR" --digest-algo sha256 \
            --detach-sign --armor --output "$f.asc" "$f"
        gpg --batch --verify "$f.asc" "$f"
        echo "signed $f"
    done
    ;;
*)
    echo "$usage"
    exit 1
    ;;
esac
