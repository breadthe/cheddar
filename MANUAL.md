# Cheddar user manual

Cheddar is a native macOS app for managing git worktrees and branches. This manual covers everything you can do in the app. For build/install instructions, see the [README](README.md).

## Contents

- [Projects](#projects)
- [The main window](#the-main-window)
- [Worktrees](#worktrees)
- [Branches](#branches)
- [Remote branches](#remote-branches)
- [Tags](#tags)
- [Opening a worktree](#opening-a-worktree)
- [Running a worktree](#running-a-worktree)
- [Hand off](#hand-off)
- [Adopting foreign worktrees](#adopting-foreign-worktrees)
- [Orphaned and missing worktrees](#orphaned-and-missing-worktrees)
- [Cleaning up](#cleaning-up)
- [Fetching and comparing with remotes](#fetching-and-comparing-with-remotes)
- [Filtering and search](#filtering-and-search)
- [Command Log](#command-log)
- [Settings](#settings)
- [Setup screen](#setup-screen)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Where data lives](#where-data-lives)

## Projects

The sidebar lists the git repositories you've added. Cheddar itself makes no changes to a repo until you tell it to (other than adding `.cheddar/` to `.git/info/exclude` the first time you create a worktree there).

- **Add a project**: click **+ Add Project** at the bottom of the sidebar, or **File → Add Project…** (⌘O), and choose a repo's folder.
- **Switch projects**: click a project in the sidebar.
- **Reveal in Finder** or **Remove from Cheddar**: right-click a project. Removing only forgets it in Cheddar — nothing on disk is touched.

## The main window

Selecting a project shows its worktrees, branches, remote branches and tags in one list, with a toolbar above it:

- **trunk: `<branch>` ▾** — the branch used for "ahead/behind" and "merged" comparisons. **Automatic** picks `origin/HEAD`, then `main`, then `master`; you can override it per project.
- **Origin filter** — show only worktrees from one origin (see [Worktrees](#worktrees)) or **All**.
- **+ New Worktree** (⌘N) — opens the New Worktree sheet.
- **Fetch** — fetches every remote (see [Fetching](#fetching-and-comparing-with-remotes)).
- **Refresh** (⌘R) — reloads everything from git. Cheddar also auto-refreshes when files change under the repo (see below) and when the app becomes active.
- **Command Log** (⇧⌘L) — toggles the bottom panel described in [Command Log](#command-log).
- The searchable field filters worktrees, branches, remote branches and tags by name as you type.

Cheddar watches the repo's git directory, every worktree folder, and any discovery roots (see [Settings → Discovery](#settings)) for file-system changes, and refreshes automatically — you rarely need to click Refresh yourself.

## Worktrees

Each worktree row shows its folder name, an **origin badge**, its branch (or `detached` and a short SHA), lock status, and uncommitted-change counts (staged, modified, untracked, conflicts — or a "clean" checkmark). Below that: ahead/behind vs. trunk, the last commit's subject, and its date.

**Origin badges** tell you which tool made a worktree, based on its folder location:
- **main** — the repository's original checkout.
- **cheddar** — made by Cheddar, in `<repo>/.cheddar/worktrees/`.
- **claude** — made by Claude Code, in `<repo>/.claude/worktrees/`.
- **codex** — made by Codex, in `<Codex home>/worktrees/` or `<repo>/.codex/`.
- **external** — anywhere else.
- A custom label — from an extra discovery location you added in Settings → Discovery.

**Creating a worktree** (**+ New Worktree**, ⌘N, or **+ Worktree** next to a branch without one):
- Choose **New branch** (name it, pick a base branch) or **Existing branch** (any local branch not already checked out somewhere).
- Pick a folder name; Cheddar suggests one from the branch name and shows where it will live (under `<repo>/.cheddar/worktrees/`).
- Cheddar adds `.cheddar/` to `.git/info/exclude` so the worktree folder never shows as untracked in your main checkout.

**Other worktree actions** (hover a row for quick buttons, or use its **⋯** menu):
- **Open In** — see [Opening a worktree](#opening-a-worktree).
- **Rename…** — for a Cheddar-made worktree, renames its branch *and* moves its folder to match. For other worktrees, only the branch is renamed (the folder stays where the owning tool expects it).
- **Rename Folder…** — for a Cheddar worktree whose folder has no branch (detached HEAD).
- **Hand Off…** — see [Hand off](#hand-off).
- **Adopt into Cheddar…** — for worktrees made by another tool; see [Adopting foreign worktrees](#adopting-foreign-worktrees).
- **Delete…** — removes the worktree (`git worktree remove`), with the option to also delete its branch. If there are uncommitted changes, you must confirm **Force** to discard them. Locked worktrees can't be deleted until unlocked.
- **Prune** — for a worktree git still lists but whose folder is gone; removes git's stale entry.

## Branches

The **Branches** section lists every local branch, with:
- The **trunk** badge on your trunk branch.
- `→ <worktree>` if it's checked out somewhere.
- Its upstream (if any), with "gone" if the upstream was deleted remotely, or ahead/behind counts against it.
- Ahead/behind vs. trunk, and a **merged** badge if trunk contains it.
- The last commit's subject and date.

Actions (hover or **⋯** menu):
- **+ New Branch** (header button) or **New Branch from Here…** (on a specific branch) — creates a branch from a chosen base.
- **+ Worktree** — creates a worktree for a branch that doesn't have one yet.
- **Rename…** — renames the branch; if it's checked out in a Cheddar-made worktree, you're asked whether to also move that worktree's folder.
- **Delete…** — deletes the branch (only when it isn't checked out anywhere). If it has commits not reachable from HEAD or its upstream, Cheddar asks again before force-deleting (`-D`); those commits stay recoverable from the reflog for a while.

### Deleting several branches

Each branch row has a checkbox (disabled for branches checked out in a worktree, which git won't delete). While any are checked, the **Branches** header shows the count, **Clear**, and **Delete Selected…**. The confirmation lists each branch with whether it's merged into trunk and whether it tracks an upstream or is local only. Cheddar then runs `git branch -d` on each, one at a time: branches that aren't fully merged are **skipped**, never force-deleted. The summary lists what was deleted and what was skipped (with git's reason); a skipped unmerged branch can still be removed with **Force Delete (-D)…**, which asks again first.

## Remote branches

Branches on a remote that aren't tracked by any local branch appear under **Remote Branches**, next to the last time you fetched. A local branch's own upstream is instead shown as an indented row directly under that branch.

- **+ Branch** — creates a local branch tracking a remote branch (nothing is checked out; add a worktree separately with **+ Worktree**).
- **Delete on `<remote>`…** — deletes the branch on the remote. This closes any open pull request from it on GitHub. Cheddar only deletes it if it still points at the commit you last fetched, so someone else's newer push isn't silently discarded.

## Tags

The **Tags** section is collapsed by default (repos can have hundreds); click the header to expand it, or just search — matches show regardless. Once you've fetched, each tag shows how it compares with your remotes:
- **only on `<remote>`** — not fetched locally yet; click **Fetch** to bring it down.
- **local only** — never pushed; click **Push** to send it (only offered when exactly one remote is missing it).
- **not on `<remote>`** — pushed to some remotes but not others.
- **differs on `<remote>`** — the remote has a different object at that tag name; Cheddar won't push or fetch over a mismatch like this.

Other actions: **Rename…** (annotated tags keep their message but get a new tagger and date; a GPG signature isn't kept — this only renames your local tag, a remote copy needs a manual push + delete) and **Delete…** (local tags only; a copy on a remote survives and can come back on your next fetch unless you also delete it there).

## Opening a worktree

Every non-missing worktree has an **Open** menu (hover a row, or double-click/Return to open directly in your preferred editor):

- **Finder** — reveals the folder.
- Your preferred **terminal** (Settings → General; defaults to Terminal).
- Every installed **editor**, plus VS Code and Cursor even if not installed (clicking shows install instructions).
- **Claude Code Here** — opens a new Terminal window/tab and runs `claude` in it. The first time, macOS asks whether Cheddar may control Terminal (you can change this later in **System Settings → Privacy & Security → Automation**).

The **Worktree** menu bar menu mirrors these for the selected worktree: **New Worktree…** (⌘N), **Open in `<editor>`** (⇧⌘E), **Hand Off…**, and **Delete…** (⌫). It also has **Clean Up…** and **Calculate Disk Usage** for the project (see [Cleaning up](#cleaning-up)).

## Running a worktree

**Run** lets you try what an agent built in its worktree the way you'd try main: same `.env`, same dependencies, same database, and a URL of its own. Your main checkout isn't touched, and the agent can keep working. Hover a worktree (not main) and click **Run**, or right-click → **Run**.

### What Run does

1. **Brings over what git doesn't.** A new worktree has only the files git tracks, so it has no `.env`, `vendor/` or `node_modules/`. Run copies whichever of those main has and the worktree lacks, as long as git ignores them there, so they never show up as changes. The copies are APFS clones: instant, and they take no extra disk space until one side changes. They live in the worktree folder and are deleted with it.
   **SQLite databases** that git ignores in main (`*.sqlite`, `*.sqlite3`, `*.db`, `*.db3`, anywhere in the project) aren't copied but **linked** at the same path, e.g. `database/database.sqlite` → main's. However the app finds its database (a relative `DB_DATABASE`, Laravel's default, Django's `db.sqlite3`, Rails' `storage/development.sqlite3`), it gets main's. SQLite follows the link, so its `-wal`/`-shm` files stay next to main's file and both sides see the same data.
   **Uploaded files** are linked the same way, so the worktree sees (and adds to) main's uploads: in a Laravel app, everything git ignores under `storage/app/` (e.g. `storage/app/private/files/`) plus the `public/storage` link; in Rails, `storage/`; in Django, `media/`. Laravel's logs and caches (`storage/logs`, `storage/framework`) stay separate. Deleting the worktree removes only the links, never main's files.
2. **Installs dependencies if the branch changed them.** If the worktree's lockfile differs from main's (or its dependencies folder is missing), Run reinstalls from the lockfile first without changing it: `composer install`, `npm ci`, `pnpm install --frozen-lockfile`, `yarn install --frozen-lockfile` or `bun install --frozen-lockfile`.
3. **Gives it a URL.** If main is a [Laravel Herd](https://herd.laravel.com) site, the worktree gets its own site next to it (details below). Otherwise the URL is whatever the dev server prints when it starts.
4. **Starts the dev command** in the worktree folder: `composer run dev` if `composer.json` has a `dev` script, else `npm run dev` (or `pnpm`, `yarn`, `bun`, going by the lockfile) if `package.json` has one. If neither exists, Run asks for the command once per project. To change it later, right-click a worktree → **Dev Command…** (leave it empty to go back to automatic).
5. **Opens the browser** once the server is up.

While it runs, the row shows **● running**, a Safari button that reopens the URL, and **Stop**. Click the status to see the dev command's output: it's a tab in the bottom panel next to the Command Log. **Stop** ends the dev command and everything it started (Vite, queue workers, and so on) and removes the worktree's Herd site. Quitting Cheddar stops every run. If a worktree is deleted, handed off or moved while it's running, the run stops on its own.

If the dev command exits by itself, the row shows **✗ exited** with its status; the output tab keeps what it printed until you **Close** it or run again.

### What's shared with main, and what isn't

- **The database and uploads are shared.** The copied `.env` points at main's database server, and SQLite files and upload folders are linked to main's (see above). A file the worktree uploads lands in main's folder. The exception: a brand-new folder the branch creates under `storage/app/` (one main doesn't have yet) stays in the worktree. Run never migrates anything; if the branch adds migrations, run them yourself, and remember main's database is the one that changes.
- **Queue workers:** Laravel's `composer run dev` also starts a queue worker. With a shared database, the worktree's worker will pick up jobs queued by main too, while it runs.
- **Your `.env` edits stick.** Run only copies `.env` when the worktree doesn't have one yet, so changes you make in the worktree's copy are kept for the next run.
- **Hand off** lists the copied `.env`, `vendor/` and `node_modules/` among the ignored files that will be deleted with the worktree. That's expected: they're copies, and main still has its own.

### By stack

**Laravel with Herd** (main served at `https://<project>.test`)
- Run links the worktree as `<project>-<worktree>` (e.g. `https://myapp-feat-login.test`), with main's HTTPS and PHP version, and points `APP_URL` in the worktree's `.env` at it. The browser opens once Vite (or `artisan serve`) is ready, or after 15 seconds if the dev command never announces a server.
- The name is `<project>-<worktree>` rather than `<worktree>.<project>`: Herd sends every `*.<project>.test` address to main.
- `composer run dev` also starts `php artisan serve`; it's harmless (it just takes the next free port) and Herd's URL is the one opened. Older projects without a `dev` composer script use `npm run dev` for Vite, and Herd serves the PHP.
- **Stop** runs `herd unlink`, which removes the site, its certificate and its PHP version pin. If Cheddar is killed or crashes mid-run, the site is removed the next time Cheddar starts.
- Uploads under `storage/app/` and the `public/storage` link (from `php artisan storage:link`) are shared with main, so public files show up too.

**Laravel without Herd**
- `composer run dev` starts `php artisan serve`, which takes the next free port when 8000 is busy (8001, 8002, …). Run opens the URL from its "Server running on […]" line and ignores Vite's, which only serves assets.
- `APP_URL` in the copied `.env` still says main's URL. Most pages don't care (Laravel builds links from the request), but mail links and anything built from `APP_URL` will point at main.

**Node (Vite, Next.js, Nuxt, SvelteKit, Astro, Remix…)**
- `npm run dev` (or the package manager your lockfile says) runs as usual. Dev servers move to the next free port when main's is taken, and Run opens whatever `http://localhost:…` they print first.
- `.env`, `.env.local` and the like are copied if they're ignored in the worktree.
- In a monorepo, only the top-level `node_modules/` is copied; nested ones are rebuilt by the install step only when the lockfile differs. If a package inside is missing its dependencies, run the install once in the worktree.

**Anything else** (Rails, Django, Go, Python…)
- Set the command with **Dev Command…**, e.g. `bin/dev`, `bin/rails server -p 3001`, `python manage.py runserver 8001` or `go run .`. The browser opens at the first `http://localhost…`/`127.0.0.1…` address it prints.
- Pick a different port from main's if the server doesn't move on its own.
- Virtual environments (`.venv`) and `bundle` paths aren't copied: they contain absolute paths to main. Use main's by its full path in the command (e.g. `~/code/myapp/.venv/bin/python manage.py runserver 8001`), or create one in the worktree.

## Hand off

"Hand off" continues a branch from a linked worktree in your **main checkout**, then removes that worktree — handy when you want to keep working on a branch a tool like Claude Code or Codex started, without a second folder around.

- If the worktree's branch is detached (no name), you're asked to name a branch first.
- If your main checkout has uncommitted changes, you can stash them first (they're recoverable from the stash list).
- Uncommitted changes in the worktree are carried over: stashed there, then popped in the main checkout (if they don't apply cleanly, they stay in the stash list rather than being lost).
- **Ignored files** (dependencies, build output, `.env`, etc.) are **not** carried over — they're deleted with the worktree folder.
- The branch itself is never merged, rebased or deleted by a hand-off.
- A locked worktree must be unlocked first (`git worktree unlock`).

## Adopting foreign worktrees

A worktree made by another tool (Claude Code, Codex, or anything else Cheddar didn't create) can be **adopted**: **Adopt into Cheddar…** moves it (via `git worktree move`) into `<repo>/.cheddar/worktrees/`, after which Cheddar can rename and move it like one of its own. The originating tool will lose track of that worktree's path once it's moved.

## Orphaned and missing worktrees

- **Orphaned** — a folder whose `.git` file points into this repo, but which git no longer lists at that path (usually because it was moved). If it's **repairable**, click **Repair** (`git worktree repair`) to relink it; otherwise your only option is **Move to Trash…** (never a permanent delete — recoverable from Finder's Trash).
- **Missing** — a worktree git still has an entry for, but whose folder is gone. Click **Prune** to remove the stale entry.

When a discovery root (like `.cheddar/worktrees` or `.claude/worktrees`) isn't yet excluded from git status, Cheddar offers to add it to `.git/info/exclude` so it stops appearing as untracked in your main checkout — no tracked files are changed.

## Cleaning up

### Merged branches and missing worktrees

**Worktree → Clean Up…** (or the ✨ button in the Branches header) collects, in one sheet:

- **Missing worktrees** — git still lists them but their folders are gone. They're pruned (git forgets them).
- **Branches merged into trunk** that nothing has checked out. A branch whose only checkout is one of those missing worktrees is included too: it's pruned first, then the branch is deleted.

Everything starts checked; uncheck what you want to keep, then **Clean Up**. Branches are deleted with `git branch -d`, so git still refuses one that isn't fully merged (for example, merged into trunk but your main checkout is on another branch). Those are listed as skipped, each with **Force Delete (-D)…**, as in [Deleting several branches](#deleting-several-branches). If there's nothing to clean, Cheddar says so.

### Disk usage and build artifacts

**Worktree → Calculate Disk Usage** (or the drive button in the Worktrees header) measures every worktree and shows its size on the row's second line. It's measured on request only, since walking `node_modules` takes a moment. Main's size leaves out the worktrees nested inside it, and links (like [Run](#running-a-worktree)'s links to main's database and uploads) don't count. Folders Run cloned from main (`vendor/`, `node_modules/`) share their disk space with main, but macOS reports them at full size, so treat the numbers as "up to".

Right-click a worktree (not main) → **Clean Build Artifacts…** lists its dependency and build folders, with sizes: `node_modules`, `vendor`, `dist`, `build`, `out`, `target`, `coverage`, `.next`, `.nuxt`, `.svelte-kit`, `.astro`, `.turbo`, `.parcel-cache`, `.cache` and `public/build`. Only folders git ignores in that worktree are listed, and never `.env`, databases, uploads or Run's links. Uncheck what you want to keep, then **Move to Trash**. Empty the Trash to free the space; reinstall (or Run again, which clones from main) to get them back. A running worktree must be stopped first.

## Fetching and comparing with remotes

**Fetch** (toolbar button, or **View → Fetch All Remotes**) fetches every remote and updates:
- Remote-branch ahead/behind counts and "gone" upstream detection.
- Tag comparisons against each remote (see [Tags](#tags)).
- The "fetched `<when>`" timestamp shown next to Remote Branches.

## Filtering and search

- The **Origin** picker in the toolbar shows only worktrees (and orphans) from one origin.
- The search field filters worktrees (by name or branch), branches (by name or upstream), remote branches, and tags, all by substring, case-insensitive.

## Command Log

**View → Show Command Log** (⇧⌘L) opens a bottom panel listing every git command Cheddar has run in the current session, with its working directory, exit code, and output. Each command is colored by role: `git` and the subcommand in your accent color, flags (`-b`, `--force`) in gray, and paths, refs and values in the normal text color. It's useful for seeing exactly what Cheddar is doing, or diagnosing a failure. **Clear** empties it. Cheddar's `herd` commands (from [Run](#running-a-worktree)) show up here too. While worktrees are running, the panel gets a tab for each one's output.

## Settings

Open with **Cheddar → Settings…** (⌘,).

- **General**
  - **Open In**: preferred **Terminal** and **Editor** apps (only installed terminals are offered; VS Code and Cursor are always listed). The preferred editor is used on double-click and ⇧⌘E; Claude Code always opens in Terminal.
  - **Git**: shows the git binary currently in use and its version. **Automatic** uses the first `git` on your login shell's `PATH`, falling back to `/usr/bin/git`. Use **Choose…** to pin a specific binary, or **Automatic** to clear the override.
- **Appearance** — System, Light, or Dark.
- **Dependencies** — status of git, Xcode Command Line Tools, Homebrew, Claude Code, VS Code and Cursor, with install instructions (a copyable command per option) for anything missing or outdated. **Check Again** re-scans.
- **Discovery**
  - **Codex home** — where Codex keeps its worktrees (`<Codex home>/worktrees`). Set this if you've moved `$CODEX_HOME`, since GUI apps don't see that environment variable.
  - **Extra locations** — add other tools' worktree folders (absolute path, or relative to the repo) with a custom label; worktrees found there get that badge and are treated like any other tool's worktrees.

## Setup screen

If a required dependency (git, at a new-enough version) isn't found, Cheddar shows a Setup screen instead of the project view, explaining what's missing, what it's needed for, and copyable install commands (via Xcode Command Line Tools or Homebrew). **Check Again** re-scans once you've installed something; **Choose git Binary…** lets you point at a specific binary directly. Cheddar never installs anything on its own.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘O | Add Project… |
| ⌘R | Refresh |
| ⌘N | New Worktree… |
| ⇧⌘E | Open in preferred editor |
| ⌫ | Delete selection |
| ⇧⌘L | Show/Hide Command Log |
| ⌘, | Settings… |

## Where data lives

- The project list: `~/Library/Application Support/Cheddar/projects.json`, with each project's trunk override and Run dev command.
- Settings: stored under the app ID `com.breadthe.Cheddar` (macOS preferences).
- Cheddar's own worktrees: `<repo>/.cheddar/worktrees/`.
