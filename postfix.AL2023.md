# Postfix for Amazon Linux 2023 — task tracker

Working document for building this repo out. Records the objective, the decisions made and why, and where the work stands. Delete or fold into the README once the pipeline is settled.

## Objective

AL2023 ships Postfix 3.7.2 and has picked up little beyond security patches since. Postfix 3.7 is at end of life upstream (3.7.22 released around mid-August 2026 as a final-stretch release), while upstream's current stable line is 3.11.x. This repo builds current Postfix as RPMs for AL2023 — `x86_64` and `aarch64` — and publishes them as a `dnf` repository, so an AL2023 host can track upstream Postfix instead of sitting on 3.7.2.

**Scope: every Postfix release from 3.11.6 onward.** Not a selection, and not whatever a distribution happened to package — every release the Postfix team publishes, across major and minor lines alike. 3.11.6 is a floor chosen so the pipeline does not rebuild the 394 releases on the mirror; everything at or above it gets built, with no version to bump here when Postfix moves on.

It started out pinned to 3.11.x to get the build/verify/publish pipeline settled first, and was widened once it was. What that took, since the pin turned out to be spread wider than one variable: `watch.yml` traded its 3.11 ceiling for a `MIN_VERSION` floor (which exists only to refuse a *downgrade* if rawhide were reverted or pointed at an older branch); `verify.yml` dropped its hardcoded `3.11.6` for two invariants that hold at any version — the running binary reports the version its own RPM claims, and an in-place upgrade from AL2023's Postfix lands on a strictly newer one; and the repository itself was renamed from `postfix-3.11-al2023` to `postfix-al2023` (nothing had been advertised or installed anywhere under the old name, so it was dropped outright rather than kept as an alias).

## Reference pattern

Follows [dovecot.2.4.ALinux2023](https://github.com/YasharF/dovecot.2.4.ALinux2023) and [spamassassin.Alinux2023](https://github.com/YasharF/spamassassin.Alinux2023): `build/build.sh` runs in an `amazonlinux:2023` container and drops RPMs in `out/RPMS`; `verify/run.sh` installs them on a clean AL2023 host and exercises the running service; four chained GitHub Actions workflows (Watch → Build → Verify → Publish) carry an upstream release to the published `dnf` repo without anyone touching it; gh-pages holds the repo and nothing is ever unpublished.

## Source material — decision

**Rebase Fedora rawhide's `postfix` spec.** Findings that led here:

- Postfix upstream publishes source tarballs only, no RPMs. Unlike Dovecot, there is no vendor RHEL 9 repo to rebuild from, so the dovecot repo's "rebuild the vendor SRPM" path is unavailable.
- There is **no `epel9` branch** of `postfix` in Fedora dist-git, and EPEL 9 carries no `postfix` — RHEL 9 ships it in base, so EPEL has no reason to.
- AL2023's own postfix spec is pinned to 3.7.2 with 3.7-era patches that will not apply to anything current.
- Fedora dist-git branch versions, checked directly: `rawhide` 3.11.6-1, `f45` 3.11.6-1, `f44` 3.10.13-1, `f43` 3.10.13-1, `f42` 3.9.11-1. Each branch tracks a line and Fedora rebases the patch set per line, so the spec for any given line is available from the branch carrying it. The branches move in sweeps: on 17 Aug 2026 the maintainer put 3.11.6 on `rawhide` and `f45` while moving `f44` and `f43` from 3.10.10 to 3.10.13.
- **Fedora is a spec source, not a version source.** It skips releases outright — it never packaged 3.10.6, 3.10.9, 3.10.11 or 3.10.12. Following Fedora's package list would have silently never built those. See "Version and tarball source" below.
- The spec carries `%if 0%{?rhel}` conditionals, so `--define "rhel 9"` builds a RHEL9-flavoured package — the same trick the spamassassin repo uses, and genuinely what AL2023 is closest to.

Same shape as spamassassin's build, then: pull the spec, patches and aux sources from dist-git, and build them on AL2023.

### Version and tarball source — decision

**A Postfix release mirror, signature-verified.** The lookaside cache was the original choice and had to be abandoned: it only holds what Fedora packaged, and the requirement is every release Postfix publishes.

The mirror sweep is grim. `ftp.porcupine.org` (the spec's own `Source0` host) does not connect at all. `de.postfix.org` does not resolve. `cdn.postfix.johnriley.me`, listed as a CDN mirror, redirects to a LinkedIn profile. Several answer `200` with an HTML landing page in place of the file — `ftp.heikorichter.name` serves a 6 KB HTML page for a `.tar.gz` request, which looks like success to anything checking only the status code. Of twelve probed, `ftp.netclusive.de` was the one serving real tarballs, with all 394 releases and a scrapable nginx index.

Trust is not placed in the mirror. Every release carries `.sig`/`.gpg1`/`.gpg2` signatures from Wietse Venema; the key is committed at `build/postfix-release-key.asc` and its fingerprint `622C7C012254C186677469C50C0B590E80CA15A7` pinned in `build/build.sh`. Verified working on `postfix-3.10.9.tar.gz` — a release Fedora never packaged — with a good signature.

The pin is anchored outside the mirror system, so the key is not taken from the same place as the tarball on faith: that key signs `postfix-3.11.6.tar.gz`, and those bytes are byte-identical to Fedora's independently recorded lookaside copy (confirmed by `cmp`). Where Fedora did package the version being built, the `sources` SHA-512 is checked as a second anchor. `pflogsumm-1.1.6.tar.gz` (the spec's `Source53`) still comes from the lookaside, where it is version-independent of Postfix.

### Building a release Fedora skipped — risk and evidence

The spec's `Version` is rewritten to the release being built, so Fedora's patches meet a tarball Fedora never tried them against. Tested directly: of f44's 3.10.13 spec against `postfix-3.10.9`, all eight postfix-tree patches apply cleanly, including `postfix-3.10.13-linux-7-fix.patch` and `postfix-3.10.10-large-fs.patch`. (A ninth, `pflogsumm-1.1.6-syslog-name-underscore-fix.patch`, is applied inside `pushd pflogsumm-*` and is not a postfix-tree patch at all.)

So the line-stable patch assumption holds in the case that was checkable. Where it does not, `rpmbuild` fails and the release does not publish — a build needing a human, rather than a silently wrong package. A line with no Fedora branch behind it is reported and skipped rather than guessed at. That is the standing cost of building everything, accepted deliberately.

## Architecture

Both `x86_64` and `aarch64` — the ARM build is the point, for Graviton hosts.

## Package identity

Fedora's postfix carries `Epoch: 2`, so the built package is `postfix-3.11.6-1.amzn2023` at epoch 2. AL2023's own postfix is epoch 2 as well (confirmed: `2:postfix-3.7.2-4.amzn2023.0.6`), so 3.11.6 > 3.7.2 and the upgrade is a plain in-place one, no `dnf swap` and no obsoletes needed.

**But version is not what decides it.** AL2023 sets `priority=10` on its own `amazonlinux` repository, and dnf settles repository priority *before* it compares versions. A repo left at the default priority of 99 loses outright: with this repo enabled and `dnf list --showduplicates postfix` showing `2:3.11.6-1.amzn2023` as the newest, `dnf install postfix` still installed `2:3.7.2-4.amzn2023.0.6`. Found by the end-to-end smoke test, and it would have shipped as a silently useless repository otherwise. The generated `.repo` files now set `priority=5`. The repo carries nothing but Postfix packages, so nothing else on the system is affected.

Worth checking whether [dovecot.2.4.ALinux2023](https://github.com/YasharF/dovecot.2.4.ALinux2023) and [spamassassin.Alinux2023](https://github.com/YasharF/spamassassin.Alinux2023) have the same gap. Neither `.repo` file sets a priority. It only bites where AL2023 ships a package of the same name, which is dovecot's situation exactly (AL2023 has dovecot 2.3.20); spamassassin is not in AL2023 at all, so priority never comes into it there.

## Status

- [x] Decide source material (Fedora per-line spec + mirror tarballs, signature-verified)
- [x] `build/build.sh` builds cleanly on AL2023, both arches
- [x] Document each AL2023-specific fixup and why it was needed
- [x] `verify/run.sh` + Verify workflow exercise a running Postfix
- [x] Watch/Build/Verify/Publish chain wired and green
- [x] gh-pages `dnf` repo live and installable
- [x] Smoke test installing from the published repo, wired after Publish
- [x] README
- [x] Build every release Postfix publishes, not the subset Fedora packaged
- [x] One `dnf` repository per Postfix release series (3.11, 3.12, 4.0), so 3.11 never auto-upgrades to 3.12
- [x] Generate the signing key, commit its public half, set the CI secrets
- [x] Pre-upload gate, post-upload check and rollback, all inside Publish (see *Publish safety*)

## Package signing

Signed with an RSA-4096 key, at publish time rather than build time. `build.sh` runs `rpmbuild` over a spec fetched from Fedora dist-git, which means executing third-party `%build` scriptlets on a matrix of runners before anything has been verified. That is the last job that should hold a signing key. Publish is already the only job with write access to `gh-pages`, so the key goes there and touches one runner.

The cost is that Verify tests the packages before they are signed. Signing rewrites only the RPM header and leaves the rest of the package alone, so what Verify approved is what ships. Nothing checks the packages again once they are published; see *Publish safety* below.

**RSA, because AL2023 cannot verify anything better.** It ships rpm 4.16.1.3 and stays there. Post-quantum OpenPGP became a standard in June 2026 (RFC 9980) but rpm only supports it from 6.0; even Ed25519 fails on rpm 4.17, which is newer than AL2023's. Nor would post-quantum help: harvest-now-decrypt-later is an encryption problem, and this key only has to resist forgery until AL2023 goes out of support in June 2029.

**The committed public key is the pin.** `build/sign.sh` reads the fingerprint out of `RPM-GPG-KEY-yasharf-al2023` and refuses to run if the secret key in the environment does not match, the same shape as the `KEY_FPR` pin that guards the incoming Postfix tarball. One source of truth, and a swapped secret fails in CI rather than at a consumer.

**The metadata is signed too.** Package signatures alone still let a tampered `repomd.xml` hide a package or serve an old one, so `repo_gpgcheck=1` and Publish detach-signs `repomd.xml` for each tree `createrepo_c` rewrites.

**Checking that the check works.** A signature test is only meaningful if it can fail. So the test runs twice on a throwaway machine: once before the signing key is trusted there, where it must be rejected, and again after importing the key, where it must be accepted. If it passed both times the test would be proving nothing, because an unsigned package would pass it too. This is about the test machine's own keyring and has nothing to do with what the repository contains.

All 36 published packages were checked by hand instead. Every one carries a good RSA signature from the right key, made with SHA-256. Each signed header also records a checksum of the package contents, and in every case that checksum matches what the package actually contains, so the signature covers the whole file rather than just its header. Both metadata signatures check out as well. The signing works. What is missing is anything that checks it automatically.

## Publish safety

### The Smoke workflow has never run

Not once, since the project started.

GitHub lets one workflow start another only three times in a row. Watch starts Build, Build starts Verify, Verify starts Publish — that is the three. Publish would start Smoke, one step too far, so GitHub never starts it. Nothing is broken and no setting is wrong; the chain is simply one link too long.

The result is that nothing tests the repository after it goes live.

### Why that is worse than it sounds

The obvious reading is that a bad publish is survivable, because anyone who already has Postfix installed keeps the copy they have. That reading is wrong in two ways.

**New machines fail to build.** An autoscaling group that installs Postfix when an instance boots has no older copy to fall back on. Neither does a Packer image build, a container build, or a CI job. If the repository is bad, the machine fails to come up — automatically, during a scale-out, with nobody watching.

**Existing machines can break too.** Every publish rewrites the file that lists what the repository contains. If that file is damaged, or its signature does not check out, dnf refuses to use the repository at all and gives up on whatever it was doing. A host that only wanted an unrelated security update gets nothing.

Individual package files are safe, because publishing only ever adds new ones and never touches what is already there. The list of contents is the part that gets rewritten every time, and it is the part every host has to read.

### What "fall back to the last good version" requires

The intuition is that if a new release turns out to be broken, users should simply keep getting the previous one, which is still sitting in the repository. That is the right goal, but it does not happen on its own.

dnf always picks the newest version the repository offers. If that version is broken, dnf reports the failure and stops. It does not quietly try the one before it. And if the damage is to the list of repository contents rather than to a package, dnf refuses to use the repository at all, which puts the older packages out of reach as well.

So users only fall back to the last good version if the broken one never appears in the repository in the first place. Once it has been published, the fallback is gone, whether or not a test later notices the problem. This is the whole argument for testing before the upload rather than after it: the test itself is the same either way, but only one order of operations preserves the fallback.

### The decision: test before the upload, and again after it

Both. They catch different things.

**Before the upload.** Publish assembles the whole repository as a directory on the runner before it sends anything anywhere. That directory is exactly what users will download, so it can be tested there: install Postfix from it the way a user would, signature checks included. If that fails, skip the upload. Nothing was published, so there is nothing to undo, and users carry on installing the previous release exactly as before. This is the check that does most of the work, because it catches every problem with the packages or the metadata.

**After the upload.** The same install, run against the real public address, the way a consumer actually reaches it. This catches what the first test cannot: that GitHub Pages accepted the upload and is serving it. If this fails, undo the publish by resetting `gh-pages` back to the commit before it, which removes the new packages and restores the previous list of contents.

Running the second test inside the Publish workflow, rather than as a separate one, is also what gets around the chaining limit.

**On removing published files.** The rule that nothing is ever removed is about superseded releases: an old version stays available so people can go back to it. Withdrawing a package that was published minutes ago and is broken is a different act, and it does not weaken that guarantee. Nobody is depending on the broken one yet.

### What the rollback actually costs

Worth being honest about, since the second test is the one with teeth.

**The bad window is minutes, not seconds.** Publishing has to deploy, the test has to notice and run, then the revert has to deploy in turn. Realistically five to ten minutes where the repository is serving something broken. A machine provisioning in that window fails, the same as it would during a GitHub outage, and the same way it would recover on retry.

**A failed test has to be believed before acting on it.** GitHub Pages is eventually consistent, so a slow deploy or a momentary error looks identical to a genuinely broken package. The test must retry before concluding anything, or a transient blip will revert a perfectly good release.

**Clients that already fetched the bad state keep it for a while.** The repository sets `metadata_expire=6h`, so a machine that cached the new package list just before the rollback will keep asking for a package that no longer exists, and get an error, until its cache expires or someone runs `dnf clean metadata`. The rollback fixes the repository immediately; it does not reach back into clients that already read it.

None of these change the decision. They are the price of catching a problem after publication rather than before it, which is why the pre-upload test carries the real load and this one is the backstop.

### A rollback makes the next Watch retry the release

Watch decides what still needs building by reading the package filenames straight off `gh-pages`. Roll a release back and its files are gone, so the next daily run sees it as unpublished and builds it again from scratch.

That is the behaviour to want. The pre-upload test catches anything wrong with the packages themselves, so a rollback only ever happens because of a delivery problem, and those are usually temporary. Retrying tomorrow fixes it with nobody involved.

It does mean a release that fails the same way every day will rebuild and roll back every day. That is noisy but bounded, and each failure is a red build, which is the signal to go and look.

**Roll back by resetting and force-pushing, not by reverting.** A revert leaves the withdrawn packages in the branch history even though they disappear from the tree. A release stuck in a daily retry loop would then add its packages to that history every day, tens of megabytes at a time, which is the same storage problem that ruled out staging. Resetting the branch and force-pushing removes the commit outright, so nothing accumulates. This is safe here: `gh-pages` is generated rather than authored, nothing branches from it, and the `concurrency: publish` group means no other run can be writing it at the same time.

### On `metadata_expire=6h`

Left as it is.

The setting controls how long a machine trusts its cached copy of the package list before fetching a new one. It has no effect on the case that matters most here: a new instance, an image build or a container has no cache at all, so it always reads the current list.

It only affects machines that have used the repository before, where the cost of a stale cache is not noticing a new Postfix release for up to six hours. Postfix publishes a few releases a year. dnf's own default is 48 hours and Fedora's update repository uses six, so six is already at the brisk end of normal.

Lowering it would shorten the window in which a rolled-back release lingers in a client's cache, but only for a machine that happened to run dnf during the few minutes the repository was bad. That is a rare case inside a rare case, and not worth trading away a sensible default for.

### Alternatives considered

**Do nothing.** Nothing checks the published repository at all. This is where the project is today, by accident rather than choice.

**Stage, test, then promote.** Upload to a separate location, test it at its real address, and only then move it into place. The only approach where a broken repository is never publicly reachable at all. Rejected on storage: this project keeps every build it has ever made, so the staged copy duplicates the entire repository on every publish, and the `gh-pages` branch keeps both copies in its history forever. That cost is permanent and grows with every release, to remove a failure window of a few minutes.

### Two things worth telling users

**Keeping every old build is what makes version pinning work.** Someone who installs an exact version, such as `postfix-3.11.6-1.amzn2023`, is unaffected by a bad publish later on, because that exact file is still sitting there. That is worth saying out loud in the README, because it is the one thing a cautious user can do to protect themselves.

**Do not set `skip_if_unavailable=1`.** It looks like it would help: when the repository cannot be read, dnf carries on instead of failing. But dnf then installs AL2023's own Postfix 3.7.2 instead. Every new machine would quietly come up with the old version this project exists to replace. A visible failure is better than a silent downgrade.

## AL2023 fixups found

**One, in the install-time scriptlet rather than the build.** Fedora rawhide's `postfix.spec` *compiles* on AL2023 unmodified given `--define "rhel 9"`, producing the full package set on both architectures: `postfix`, `postfix-cdb`, `postfix-ldap`, `postfix-lmdb`, `postfix-mysql`, `postfix-pcre`, `postfix-perl-scripts`, `postfix-pgsql`, `postfix-sqlite`, plus the matching debuginfo/debugsource packages. `postfix-sysvinit` is correctly skipped, the spec gating it on `%if 0%{?fedora} < 23 && 0%{?rhel} < 9`.

Every optional backend the spec can enable has a `-devel` package on AL2023 under exactly the name the spec asks for, so nothing had to be stubbed the way dovecot's build needed a `mariadb-devel` stub. Checked directly in an AL2023 container: `libdb-devel` 5.3.28, `openldap-devel` 2.4.57, `lmdb-devel` 0.9.29, `cyrus-sasl-devel` 2.1.27, `pcre2-devel` 10.40, `mariadb-connector-c-devel` 3.1.13, `libpq-devel` 15.0, `sqlite-devel` 3.40.0, `tinycdb-devel` 0.78, `openssl-devel` 3.0.5, `libicu-devel` 67.1, `perl-generators` 1.13, `systemd-rpm-macros` 252.16.

`pkgconfig` and `systemd-units` have no package of those names on AL2023, but both are capabilities other packages provide (`pkgconf-pkg-config` and `systemd`), and `dnf builddep` resolves them that way. Not a problem, just something a name-only availability check misreports.

`--define "rhel 9"` is what makes this work, the same as mock's `epel9` config would pass. The spec branches on it in the places that matter: it drops the `libnsl2-devel` BuildRequires (AL2023 genuinely has no such package), builds with `-DNO_NIS` and without `-lnsl`, and applies `postfix-3.10.7-rhel-remove-version-mismatch-warning.patch`.

The one change that was needed is in this repo's own build script, not the spec: **the build container must not be asked to install `curl`.** AL2023's base image ships `curl-minimal`, which provides the `curl` command, and the two packages conflict, so naming `curl` in the BuildRequires install makes `dnf` refuse the whole transaction.

**`alternatives --follower` is not understood by AL2023.** AL2023 ships chkconfig 1.15, whose `alternatives` supports `--slave`, `--initscript` and `--family` but not `--follower` — the option Fedora's `%post` uses eleven times. The call prints its usage and exits, and since a failing `%post` is only a warning to `rpm`, the package installs "successfully" with its entire sendmail-compatible interface missing: no `/usr/sbin/sendmail`, no `/usr/bin/mailq`, no `/usr/bin/newaliases`, no `/usr/bin/rmail`. Postfix runs, but anything that submits mail by calling `sendmail(1)` — cron, logwatch, most scripts — has nothing to call, and nothing anywhere says so.

Fixed with `sed -i 's/--follower /--slave /g'` on the spec, conditional on the build host's `alternatives` not already understanding `--follower`, so it self-heals if AWS ships a newer chkconfig. `--slave` is the name `--follower` was renamed from and newer chkconfig still accepts it, so this is a rename, not a behaviour change.

**The queue tree comes from tmpfiles.** `/var/spool/postfix` and its subdirectories are not in the package; they come from `/usr/lib/tmpfiles.d/postfix.conf`, created by `systemd-tmpfiles` through systemd's RPM file trigger at install time and again by `systemd-tmpfiles-setup.service` at boot. In a container neither runs, and Postfix dies with `chdir(/var/spool/postfix): No such file or directory`. The harness runs `systemd-tmpfiles --create` explicitly — doing what systemd would have done, rather than papering over it. Container-only as far as anything shows so far; the harness prints whether the tree was already there, which is the evidence either way.

## Verify findings

- The `newaliases` "hang" was not a hang. `newaliases` did not exist (see the `--follower` finding), the shell exited 127, `set -e` killed the container, and the port-25 wait loop ran its full 180s and reported "postfix never listened". Two lessons, both applied: the setup runs in the foreground through `docker exec` into a long-lived container, so a failure lands on the command that caused it; and `run.sh` now asserts the alternatives symlinks exist right after install, where the real cause is unmissable.
- Delivery, STARTTLS, and every map plugin passed on both architectures before the sendmail step was reached, so the build itself was sound throughout.
- Verify installs RPM files off a Build run, which cannot see anything about the published repository. The `priority` bug proved that gap is real and silent: correct packages, correct publish, useless repository. `smoke.yml` closes it by installing from the real URL after every Publish and asserting that what landed is what the repository offers.

## Where it ended up

- Repository: https://github.com/YasharF/postfix.AL2023
- `dnf` repo: https://yasharf.github.io/postfix.AL2023/ (Pages, `gh-pages` branch)
- Published: `postfix` 3.11.6-1.amzn2023 and all eight subpackages, `x86_64` and `aarch64`, under `al2023/3.11/`, with later releases picked up automatically
- Repository layout: one per release series, `postfix-al2023-<series>.repo`, generated at publish time from `postfix-al2023.repo.in`
- Full chain exercised end to end: Watch (correctly finds 3.11.6-1 already published and stops), Build, Verify, Publish, Smoke.
