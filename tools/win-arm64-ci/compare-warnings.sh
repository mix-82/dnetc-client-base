#!/bin/bash
# Compare the compiler/linker warnings of two build logs (file names only,
# so the source paths do not matter). Prints the lists and the difference.
#   compare-warnings.sh <before build.log> <after build.log>
norm()
{
  tr -d '\r' < "$1" | grep -iE ': warning |warning LNK|: error |error LNK|fatal error' | sed -E 's#^.*[\\/]##' | sort
}
B=$(norm "$1"); A=$(norm "$2")
echo "before: $(printf '%s\n' "$B" | grep -c .) warnings/errors, after: $(printf '%s\n' "$A" | grep -c .)"
if diff <(printf '%s\n' "$B") <(printf '%s\n' "$A")
then
  echo "identical warning/error lists"
else
  echo "WARNING LISTS DIFFER (< before, > after)"
fi
