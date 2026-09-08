#!/bin/bash
# Check that every map type the build claims to support actually loads.
#
# postconf -m only lists what dynamicmaps.cf declares, not whether the plugin
# behind it loads. Querying each type against a path that does not exist tells
# them apart: one that cannot load says "unsupported dictionary type", one that
# loads complains about the file instead.

set -u

# The types the subpackages provide, plus the ones in the core package.
# sqlite, mysql, pgsql and ldap need a server, so they are only checked for
# loading.
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

# The types that can be built and read back on a bare host get a real round
# trip, so this is more than a load check.
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
