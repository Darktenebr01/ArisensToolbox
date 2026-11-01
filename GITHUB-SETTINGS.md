# GitHub and search setup for Arisen's Toolbox

The SEO files are committed on branch `seo/github-pages`. Push it first:

```bat
cd C:\Users\oltim\Downloads\Arisen Toolbox\ArisensToolbox-seo
git push -u origin seo/github-pages
```

Open the PR link GitHub prints, merge it into `master`, then enable Pages below.

These are the manual settings that live outside the repository files. Do them once, then
re-check after a release.

## 1. Repository description and website

GitHub → the repository → **About** (gear icon) → edit:

**Description** (paste exactly):

```
Free Dragon's Dogma 2 trainer, item editor and Cheat Engine table for PC/Steam. Item giver, gear and skill editing, pawn tools, boss summons, fast travel, save backups. REFramework-based, single-player.
```

**Website**:

```
https://darktenebr01.github.io/ArisensToolbox/
```

**Topics** (20; GitHub lowercases them):

```
dragons-dogma-2
dragonsdogma
dd2
trainer
save-editor
item-editor
cheat-engine
cheat-table
reframework
customtkinter
python
windows
single-player
rpg
capcom
re-engine
game-tools
pawn
summon
mod
```

Do not use unrelated topics. GitHub search and Google both use the repo name, description,
topics and README; the first 160 characters matter most.

## 2. Social preview

Settings → **General** → **Social preview** → upload:

```
docs/assets/social-preview.png
```

This is the 1280×640 card shown when the repo is shared on Discord, Reddit, X and Slack.
The page itself uses the same image through Open Graph tags.

## 3. Enable GitHub Pages

Settings → **Pages**:

- Source: **Deploy from a branch**
- Branch: **master**
- Folder: **/docs**
- Save

After the first deployment, open:

```
https://darktenebr01.github.io/ArisensToolbox/
```

The site is plain static HTML with `docs/.nojekyll`, so no build step is needed. A push to
`master` updates it.

Check these URLs after enabling Pages:

- `/`
- `/item-editor.html`
- `/skills.html`
- `/summons.html`
- `/cheat-table.html`
- `/install.html`
- `/faq.html`
- `/sitemap.xml`
- `/robots.txt`

**Robots caveat for a project site:** GitHub serves the project at
`https://darktenebr01.github.io/ArisensToolbox/`, but `robots.txt` is only authoritative at
the domain root, `https://darktenebr01.github.io/robots.txt`. The `docs/robots.txt` file is
still useful documentation, but Google will not treat it as the site-wide robots file.
Submitting the sitemap in Search Console is the reliable route. A custom domain or a
`darktenebr01.github.io` user site would give you root-level `robots.txt` and a cleaner SEO
footprint.

## 4. Google Search Console

1. Open <https://search.google.com/search-console>.
2. Add a property of type **URL prefix**:
   `https://darktenebr01.github.io/ArisensToolbox/`
3. Verify with the **HTML file** method:
   - Download the verification file Google gives you.
   - Put it in `docs/` (for example `docs/google1234567890abcdef.html`).
   - Commit and push, wait for Pages to deploy, then press Verify.
4. Open **Sitemaps** and submit:
   `https://darktenebr01.github.io/ArisensToolbox/sitemap.xml`
5. Open **URL Inspection** and request indexing for:
   - the home page
   - `/item-editor.html`
   - `/skills.html`
   - `/cheat-table.html`
   - `/install.html`

Indexing is not instant. Expect days to weeks, and check **Pages → Indexing → Pages** for
crawl or duplicate-canonical reports.

## 5. Bing Webmaster Tools

1. Open <https://www.bing.com/webmasters>.
2. Add `https://darktenebr01.github.io/ArisensToolbox/`.
3. Import from Google Search Console if available, or verify with the same HTML file.
4. Submit the sitemap.

Bing also feeds some AI search surfaces; the `docs/llms.txt` file gives assistants a clean
summary and canonical links.

## 6. Off-site links that actually help

Search engines need links from pages they already trust. Use real, relevant places, not
link farms:

- **Nexus Mods description**: link to the GitHub repo and the Pages site in the first
  screen of the description. The Nexus page already ranks for Dragon's Dogma 2 mod
  searches.
- **FearlessRevolution thread**: put the GitHub and Pages links in the first post.
- **Reddit**: answer questions in r/DragonsDogma and r/DragonsDogma2 with a link only when
  it is directly useful. Read each subreddit's self-promotion rules first.
- **YouTube**: a short install and feature video with the repo and Pages links in the
  description.
- **Mod lists and Discord servers**: ask the owner to list the tool; do not spam invites.

## 7. Release hygiene

For each release:

- Use a descriptive title: `Arisen's Toolbox v0.189 — monster summon, probes, fixes`.
- Paste the change list into the release notes; link the install guide and the CT.
- Update `softwareVersion` in `docs/index.html` (and the CT version text on the cheat
  table page if it changed).
- Keep the README's first paragraph accurate.

## 8. What not to do

- Do not add hidden keyword blocks or unrelated game names.
- Do not buy backlinks or mass-post the link.
- Do not claim the project is open source; the license is all-rights-reserved.
- Do not promise that save editing is risk-free.
- Do not use the same title and description on every page; each guide already has a
  unique H1, title and description.
