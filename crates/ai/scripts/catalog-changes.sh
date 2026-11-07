#!/usr/bin/env bash
# Print the model changes between two generated catalogs as Markdown.
set -euo pipefail

if (( $# != 2 )); then
    printf 'usage: %s old.rs new.rs\n' "$0" >&2
    exit 2
fi

# The generator fixes the layout: a provider id has 8 spaces, a model has 12, and a model field has 16.
awk '
    FNR == 1 { side++ }
    /^        id: Cow::Borrowed\("/ { split($0, part, "\""); provider = part[2] }
    /^            Model \{$/ { in_model = 1; next }
    in_model && /^            \},?$/ { flush(); in_model = 0; next }
    in_model && /^                id: Cow::Borrowed\("/ { split($0, part, "\""); key = provider "/" part[2] }
    in_model && /^                [a-z_]+:/ { flush(); field = $1; sub(":", "", field) }
    in_model { text = text $0 }

    function flush() {
        if (field == "") return
        models[side, key] = 1
        keys[key] = 1
        if (!((key, field) in seen)) {
            seen[key, field] = 1
            order[key] = order[key] " " field
        }
        value[side, key, field] = text
        field = ""
        text = ""
    }

    END {
        for (key in keys) {
            if (!((1, key) in models)) print "added\t" key
            else if (!((2, key) in models)) print "removed\t" key
            else {
                count = split(order[key], fields, " ")
                changed = ""
                for (i = 1; i <= count; i++) {
                    if (value[1, key, fields[i]] != value[2, key, fields[i]]) {
                        changed = changed (changed == "" ? "" : ", ") fields[i]
                    }
                }
                if (changed != "") print "changed\t" key "\t" changed
            }
        }
    }
' "$1" "$2" | LC_ALL=C sort | awk -F '\t' '
    { rows[$1] = rows[$1] "- `" $2 "`" ($3 == "" ? "" : ": " $3) "\n"; counts[$1]++ }

    END {
        print "Generated from https://catalog.yuke.sh/v1/catalog?executable=true."
        if (NR == 0) print "\nNo model changed."
        if (counts["added"]) printf "\n**Added (%d)**\n\n%s", counts["added"], rows["added"]
        if (counts["removed"]) printf "\n**Removed (%d)**\n\n%s", counts["removed"], rows["removed"]
        if (counts["changed"]) {
            printf "\n<details><summary>Changed (%d)</summary>\n\n%s\n</details>\n", counts["changed"], rows["changed"]
        }
    }
'
