# Google Sheet side of Crew Clock

- `Code.gs` — paste into the sheet's **Extensions → Apps Script**. Set `SYNC_KEY` to your own key
  (the same key that ends the tablet link, `...?key=YOUR_KEY`). The real key is not stored here
  because this repository is public.
- After any change: **Save**, then **Deploy → Manage deployments → ✏️ → Version: New version → Deploy**.
  Who has access must be **Anyone**.
- Run `setup` once in a new sheet (creates the tabs and the keep-awake timer).
- `crew-clock-station.html` — computer version of the clock-in screen with a Manager section.
  Open it in Chrome and paste the tablet link.
- The phone scan page is `docs/index.html`, served by GitHub Pages.
