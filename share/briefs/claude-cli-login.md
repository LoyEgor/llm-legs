# Claude Code CLI sign-in — stock brief

Run by `bin/claude-relogin`, which fills the five values, waits for the run and checks `claude auth status` itself.

```
COMPUTER: yes
EFFORT: low
ACCOUNT-TO-SIGN-IN: <account>
EMAIL: <email>
CHROME-PROFILE: <profile dir>

Authorize Claude Code for <email> in Google Chrome profile <profile dir>; `claude auth login` waits on localhost:<port>.
1. That profile's window is up (`worker-run browse --window <account>`; rerun it if gone); work only there.
2. Read the authorize URL from <url file> and open it in a new tab of that window.
3. claude.ai login page only: click "Continue with Google". Google chooser: click <email>, then "Continue".
4. The page must show "Logged in as <email>": click "Authorize". Another email: stop.
5. It reads "You're all set up for Claude Code". Close your tabs; leave the example.com marker tab.

Stop and end `OUTCOME: COMPUTER_UNAVAILABLE reason=<which>` on a password field, 2FA/emailed code, captcha, passkey,
magic-link request or any account other than <email>. Never type a credential.
Done: `OUTCOME: COMPUTER_OK authorized=<email>`.
```
