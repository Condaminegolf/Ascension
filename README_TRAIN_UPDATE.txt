YOUR PATH — Train Tab Correction (changed files only)

Update from your most recent YOUR PATH GitHub Pages release.
Upload only these files into the ROOT of your existing /Ascension/ repository, replacing the matching filenames:
  1. index.html
  2. sw.js
  3. release-notes.json

Keep all other existing files, including cloud-config.js, icons and manifest, unchanged.
All avatar, clothing and equipment artwork remains EMBEDDED inside index.html.

Changes:
 - Dates → Scheduled Session → Add Other Session → Workout Log.
 - A single Edit Session control opens the selected workout editor.
 - Removed separate per-set "Use AI" buttons. Faint suggested kg/reps placeholders remain; the user manually logs actual sets.
 - Set row columns now remain on one line at mobile widths.
 - Extra strength sessions stay collapsed under Add Other Session; empty accidental extra strength sessions have a Remove control.
 - More room for the floating menu by moving its default position further down the viewport; prior drag preference remains untouched.
 - New service-worker cache version and a polite update-ready prompt for existing users; no automatic reload in the middle of a workout.

If your iPhone still displays a separate Cardio row, "Manage this session" or per-set "Use AI" buttons, it is still running the OLD cached frontend.
  - Ensure all three files actually replaced the previous versions in GitHub (not added inside a nested folder).
  - With an internet connection, open the website URL in Safari and refresh it. If offered "Update now", tap it when you are not actively logging a workout.
  - Close and reopen the iPhone Home Screen app after the new site has loaded.
  - Do not clear website data or sign out to force the update; this could remove unsynced local workout entries.

Only download/upload changed files; not a full app package. The live GitHub website is not deployed automatically.
