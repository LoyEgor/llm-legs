SCOPE: {{target}}
VERIFY: bash {{target}}

Write {{target}}, modelled on the existing {{sibling}}.

Copy that sibling's shape: shebang, harness helpers, fixture style, temp-directory discipline and
the shape of its final PASS line. Copy its structure, never its assertions — assert only what this
suite's own subject does, and where the expected value would be a guess, leave a `# TODO(owner):`
line instead of an assertion. Point nothing at a real store or a real account.
