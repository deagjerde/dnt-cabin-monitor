# DNT Cabin Availability Monitor

Monitors **Fuglemyrhytta** (DNT cabin 101209) for newly available nights and sends you an email the moment a cancellation opens up a date.

## How it works

Every 15 minutes, a GitHub Actions workflow runs `monitor.R`, which:

1. Queries the DNT booking API for each night from today through Dec 31, 2026.
2. Compares against the previous run's state (`state.json`).
3. If a date that was booked is now available, sends you an email.
4. Saves the updated state back to the repo.

You only get emailed when **new** dates open up — no spam.

## Setup guide

### Step 1 — Create a GitHub repository

1. Go to [github.com/new](https://github.com/new).
2. Name it whatever you like (e.g. `dnt-cabin-monitor`).
3. **Important**: Set it to **Public**. GitHub Actions has unlimited free minutes for public repos. A private repo would exceed the 2,000 min/month free tier (~4,300 min/month estimated usage). The repo contains no sensitive data — your email credentials are stored as GitHub Secrets, never in the code.
4. Click **Create repository**.

### Step 2 — Add the files

Upload these three files to the root of your new repository:

```
monitor.R                          ← the monitoring script
README.md                          ← this file (optional)
.github/workflows/monitor.yml      ← the GitHub Actions workflow
```

You can do this via the GitHub web interface (click "Add file" → "Upload files") or by cloning and pushing:

```bash
git clone https://github.com/YOUR_USERNAME/dnt-cabin-monitor.git
cd dnt-cabin-monitor
# Copy the files into this directory
mkdir -p .github/workflows
# ... place monitor.R, README.md, .github/workflows/monitor.yml ...
git add .
git commit -m "Add DNT cabin monitor"
git push
```

### Step 3 — Add your email secrets

Go to your repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**. Add these 6 secrets:

| Secret name | Value | Example |
|---|---|---|
| `SMTP_HOST` | Your email provider's SMTP server | `smtp.yourprovider.com` |
| `SMTP_PORT` | Port number (587 for STARTTLS, 465 for SSL) | `587` |
| `SMTP_USER` | Your email address or SMTP username | `you@example.com` |
| `SMTP_PASS` | Your email password or app password | `your-app-password` |
| `EMAIL_FROM` | Sender address (usually same as SMTP_USER) | `you@example.com` |
| `EMAIL_TO` | Where notifications are sent | `you@example.com` |

**Finding your SMTP details for common providers:**

| Provider | SMTP host | Port | Notes |
|---|---|---|---|
| Gmail | `smtp.gmail.com` | 587 | Needs an [app password](https://myaccount.google.com/apppasswords) (2FA must be on) |
| Outlook / Microsoft 365 | `smtp.office365.com` | 587 | App password if 2FA is enabled |
| Yahoo | `smtp.mail.yahoo.com` | 587 | Needs an app password |
| ProtonMail | `smtp.protonmail.com` | 587 | Requires paid plan + app password |
| Your web host | Check your hosting docs | 587 or 465 | Varies by provider |

### Step 4 — Test it manually

1. Go to your repo → **Actions** tab.
2. Click **DNT Cabin Monitor** in the left sidebar.
3. Click **Run workflow** → **Run workflow**.
4. Watch the run complete (should take 1–2 minutes).
5. If any dates are currently available, you'll get an email. If not, you'll see "No new openings" in the logs.
6. Check that `state.json` was committed to the repo (look at the commit history).

### Step 5 — Let it run

After the manual test, the workflow runs automatically every 15 minutes. You'll get an email whenever a new date opens up.

## Customizing

Edit `monitor.R` to change:

| Setting | Variable | Default |
|---|---|---|
| Cabin | `CABIN_ID` | `101209` (Fuglemyrhytta) |
| End date | `END_DATE` | `2026-12-31` |
| Number of guests | `GUESTS` | `1` |
| Delay between API calls | `POLL_DELAY` | `0.2` seconds |

To monitor a **different cabin**, find its ID in the URL: `hyttebestilling.dnt.no/hytte/XXXXXX` → the number is the `CABIN_ID`.

## Troubleshooting

**No email received?**
- Check the Actions log for `[ERROR] Failed to send email`.
- Verify your SMTP secrets are correct (especially app passwords vs. regular passwords).
- Check your spam folder.

**Workflow not running on schedule?**
- GitHub Actions cron can be delayed 5–15 min during peak times. This is normal.
- Make sure the workflow file is on your default branch.
- Public repos get priority scheduling.

**`state.json` not being committed?**
- Check that `permissions: contents: write` is in the workflow file (it is).
- Look for "No changes to state.json" in the logs — this just means availability didn't change.

**API stopped working?**
- The DNT API is an internal endpoint that could change. Run the workflow manually to test.
- Check the logs for `[WARN] Failed to check` messages.

## Files

| File | Purpose |
|---|---|
| `monitor.R` | Main script — polls API, diffs state, sends email |
| `.github/workflows/monitor.yml` | GitHub Actions workflow — schedule, R setup, state commit |
| `state.json` | Auto-generated — stores last known availability between runs |
