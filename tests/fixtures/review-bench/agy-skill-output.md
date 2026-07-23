# Change summary: Tightens request validation and cache refresh behavior.

## File: src/auth.py
### L41: [HIGH] Empty bearer tokens reach the verifier.

The new branch accepts an empty string and sends it to the verifier, which treats it as an anonymous request.

Suggested change:
```python
if not token:
    raise InvalidToken()
```

## File: src/cache.py
### L18: [LOW] Passive reads overwrite the observation timestamp.

This makes old quota data appear fresh even though no upstream refresh occurred.
