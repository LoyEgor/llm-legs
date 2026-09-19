SCOPE: {{paths}}
VERIFY: ! grep -rlF '{{from}}' {{paths}}

Rename `{{from}}` to `{{to}}` in {{paths}} and nowhere else.

Replace whole occurrences of that name only: a longer identifier that merely contains it keeps its
own spelling. Change no other character of the lines you touch — no reflow, no reformatting, no
neighbouring fix. Report the file count and the occurrence count, nothing else.
