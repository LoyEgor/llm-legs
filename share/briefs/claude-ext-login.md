# Claude in Chrome sign-in — stock brief

Dispatched by the orchestrator when `worker-run browse --enroll` prints `needs-login`; the supervisor never
signs anything in itself. Fill the three values from that REASON line, launch it as a codex Computer Use
run (`COMPUTER: yes`), then re-run `worker-run browse --enroll <account>`.

```
COMPUTER: yes
ACCOUNT-TO-SIGN-IN: <account>
EMAIL: <email>
CHROME-PROFILE: <profile dir>

Sign the Claude in Chrome extension in Google Chrome profile <profile dir> in as <email>.
1. Run `worker-run browse --window <account>` to bring that profile's window up; work only in that window.
2. Confirm it is the right profile: the avatar menu (top right) shows <email>. Another email: stop.
3. Open https://claude.ai in a new tab of that window. It must show a signed-in workspace whose account
   menu shows <email>; a sign-in page or another email: stop.
4. Open the Claude extension (puzzle icon → Claude). If it offers "Sign in" / "Connect", accept it; the
   extension takes the claude.ai session of step 3. Approve only an authorization page that names <email>.
5. The extension panel shows it is signed in as <email>. Close the tabs you opened.

Stop at once and end `OUTCOME: COMPUTER_UNAVAILABLE reason=<which>` on: a password field, a 2FA or
emailed code, a captcha, a passkey or device prompt, or any account other than <email>. Never type a
credential. Done: `OUTCOME: COMPUTER_OK signed-in=<email> profile=<profile dir>`.
```
