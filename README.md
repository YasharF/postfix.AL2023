# Postfix for Amazon Linux 2023 (AL2023)

AL2023 ships Postfix 3.7.2 and hasn't moved it since. AWS patches security issues in it, but bug fixes from newer Postfix releases don't get backported, and nobody publishes newer Postfix RPMs for AL2023.

This project builds them, for `x86_64` and `aarch64`, and publishes them as a `dnf` repository.

## Install

Add the repository for the Postfix release series you want, then upgrade:

```sh
curl -fsSLo /etc/yum.repos.d/postfix-al2023-3.11.repo https://yasharf.github.io/postfix.AL2023/postfix-al2023-3.11.repo
dnf upgrade postfix
```

This replaces AL2023's Postfix in place. There's nothing to uninstall first. If Postfix isn't installed yet, use `dnf install postfix`.

The first `dnf` command asks you to accept the signing key. Its fingerprint is:

```
777625EB8DD729DED69AFAE51AC59EAA21B89A3C
```

## Verifying packages

The packages and the repository metadata are both signed with an RSA-4096 key, published at [`RPM-GPG-KEY-yasharf-al2023`](https://yasharf.github.io/postfix.AL2023/RPM-GPG-KEY-yasharf-al2023). `dnf` checks both on every install, because the `.repo` file sets `gpgcheck=1` and `repo_gpgcheck=1`.

To check a downloaded RPM by hand:

```sh
rpm --import https://yasharf.github.io/postfix.AL2023/RPM-GPG-KEY-yasharf-al2023
rpm -K postfix-*.rpm
```

`digests signatures OK` is the answer you want. [postfix.AL2023.md](postfix.AL2023.md) covers why the key is RSA rather than something newer.

## Optional packages

Postfix's lookup-table backends ship as separate packages. All of them are built here:

| Package | For |
| --- | --- |
| `postfix-ldap` | LDAP lookup tables |
| `postfix-mysql` | MySQL / MariaDB lookup tables |
| `postfix-pgsql` | PostgreSQL lookup tables |
| `postfix-sqlite` | SQLite lookup tables |
| `postfix-lmdb` | LMDB lookup tables |
| `postfix-cdb` | CDB lookup tables |
| `postfix-pcre` | PCRE lookup tables |
| `postfix-perl-scripts` | The `pflogsumm` and `qshape` tools |

Install the ones you need, such as `dnf install postfix-mysql`. If you already have some installed, `dnf upgrade` updates them along with the rest.

## Choosing a version

There's one repository per Postfix release series — 3.11, 3.12, 4.0 — which is what Postfix itself calls a major release. The 3.11 repository serves every 3.11 release, so `dnf upgrade` takes you from 3.11.6 to 3.11.7, and never to 3.12.

Moving to a new series is something you do deliberately, by swapping the `.repo` file:

```sh
rm /etc/yum.repos.d/postfix-al2023-3.11.repo
curl -fsSLo /etc/yum.repos.d/postfix-al2023-3.12.repo https://yasharf.github.io/postfix.AL2023/postfix-al2023-3.12.repo
dnf upgrade postfix
```

Read the [release notes](https://www.postfix.org/announcements.html) for the new series first: a new series can change defaults in ways a patch release doesn't. If you leave both `.repo` files in place, `dnf` serves the newest package either one offers, which puts you on the newer series.

To stay on one exact build:

```sh
dnf install python3-dnf-plugin-versionlock
dnf versionlock add --raw 'postfix-3.11.6-*'
```

`--raw` takes a glob, so this holds you on 3.11.6 whichever RPM release number it carries. Without it, `dnf` locks the exact package you have installed now.

To see what's available and install a specific build:

```sh
dnf list --showduplicates postfix
dnf install postfix-3.11.6-1.amzn2023
```

Old builds stay available, so you can go back to one.

## Upgrading from AL2023's 3.7.2

That jumps across several Postfix releases at once. Read the [release notes](https://www.postfix.org/announcements.html) for what changed, and run `postfix check` afterwards.

## How it works

Every Postfix release from 3.11.6 onwards is built, usually within a day of release. 3.11.6 is just where this project started; earlier releases aren't built.

Source tarballs come from a Postfix release mirror and are checked against the Postfix release signing key ([`build/postfix-release-key.asc`](build/postfix-release-key.asc)) before each build. The RPM spec comes from Fedora, which keeps the packaging patches current.

The RPMs are signed, and so is the repository metadata, so the generated `.repo` file sets `gpgcheck=1` and `repo_gpgcheck=1`. It also sets `priority=5`, because AL2023's own repository is priority 10 and `dnf` compares priority before version. Without it, `dnf` keeps installing 3.7.2.

Four GitHub Actions workflows run the whole thing:

- `watch.yml` looks daily for a release that hasn't been published here.
- `build.yml` builds it for both architectures.
- `verify.yml` installs the RPMs in an AL2023 container and runs mail through them: SMTP, STARTTLS, the `sendmail` command, every lookup backend, and an in-place upgrade from AL2023's 3.7.2.
- `publish.yml` signs the RPMs, adds them to the repository, and installs from it twice: once from the assembled copy before uploading anything, and once from the published site afterwards. If the second one fails, the release is rolled back off the site and the next `watch.yml` run rebuilds it.

Both installs use `verify/repo-install.sh`, which does what you would do: add the repository, install Postfix, and check the version that arrived is the one the repository offered and carries a signature from the published key. It also checks the signature actually means something, by confirming the package fails verification on a machine that has not imported the key.

To build locally:

```sh
docker run --rm -v "$PWD:/w" -w /w public.ecr.aws/amazonlinux/amazonlinux:2023 \
  ./build/build.sh 3.11.6 1 rawhide
```

The arguments are the Postfix version, the RPM release number, and the Fedora branch to take the spec from. RPMs land in `out/RPMS`.

## License

[LICENSE](LICENSE) covers this repository's own content, under the MIT license. It doesn't cover Postfix. No Postfix source is included here, and the RPMs are Postfix's own unmodified software, each carrying its own `LICENSE` and `TLS_LICENSE`.
