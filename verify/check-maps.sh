#!/bin/bash
# Check that every map type the build claims to support actually loads.
#
# postconf -m lists what dynamicmaps.cf declares, which says nothing about
# whether the plugin behind it links and dlopens. Asking postmap to query each
# type against a path that does not exist separates the two: a type whose .so
# is missing or unloadable fails with "unsupported dictionary type", while one
# that loads gets far enough to complain about the file or its configuration
# instead.

set -u

# The map types this spec's subpackages provide, plus the ones built into the
# core package. sqlite/mysql/pgsql/ldap need a server or a config file to do
# anything useful, so they are checked for loading only.
EXPECTED="btree cdb hash ldap lmdb mysql pcre pgsql regexp sqlite texthash static inline"

echo "=== postconf -m ==="
postconf -m

fail=0
for t in $EXPECTED; do
    if ! postconf -m | grep -qx "$t"; then
        echo "MISSING from postconf -m: $t"
        fail=1
        continue
    fi
    err=$(postmap -q nosuchkey "$t:/nonexistent/postfix-verify" 2>&1)
    case "$err" in
        *"unsupported dictionary type"*)
            echo "WILL NOT LOAD: $t -- $err"
            fail=1
            ;;
        *)
            echo "loads: $t"
            ;;
    esac
done

# The map types that can actually be created and read back on a bare host get
# a real round trip, so this is not only a dlopen check.
for t in hash btree lmdb cdb; do
    d=$(mktemp -d)
    printf 'alice@example.com\tbob@example.com\n' > "$d/table"
    if ! postmap "$t:$d/table" 2>&1; then
        echo "postmap could not build a $t map"
        fail=1
        rm -rf "$d"
        continue
    fi
    got=$(postmap -q alice@example.com "$t:$d/table" 2>&1)
    if [ "$got" = "bob@example.com" ]; then
        echo "round trip: $t"
    else
        echo "round trip FAILED for $t: got '$got'"
        fail=1
    fi
    rm -rf "$d"
done

exit $fail
