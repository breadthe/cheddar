# Cheddar — Specs

A small native macOS app for managing git worktrees and branches. Runs locally only; no App Store, no notarization, no Apple developer account.

## Goals

- Sidebar with a **+** button to add a local git project.
- Main pane shows all **worktrees** and **branches** for the selected project, and which branch is checked out in which worktree.
- Create, delete and rename worktrees.
- Create, rename and delete branches.
- **Hand off** a worktree to the main checkout.
- Keep Cheddar's own worktrees inside the project at `.cheddar/worktrees/`.
- Discover and show worktrees made by other tools and agents, especially Claude Code (`.claude/worktrees`) and Codex (`.codex`).
- A simple, compact UI in the spirit of Claude Code.

## Decisions

| Topic | Decision |
|---|---|
| Hand off | Remove the worktree and check its branch out in the main repo's working copy. No merge, no rebase, no branch deletion. |
| Cheddar's worktree location | Inside the project: `<repo>/.cheddar/worktrees/<name>` (slashes in branch names become dashes). Cheddar adds `.cheddar/` to `.git/info/exclude` so no tracked file changes. |
| Other tools' worktrees | Cheddar discovers and shows worktrees made by Claude Code (`<repo>/.claude/worktrees/`), Codex (`$CODEX_HOME/worktrees`, default `~/.codex/worktrees`, plus `<repo>/.codex/`) and anything else, labeled by origin. See **Worktree discovery & ownership**. |
| Rename | Renames the branch **and** moves the worktree folder to match (Cheddar-owned worktrees only; see ownership rules). |
| v1 extras | Status at a glance, auto-refresh, "Open in" actions. |
| Out of scope for v1 | Remote branch management (fetch/pull/push, creating worktrees from remote branches). |

## Stack

- **SwiftUI**, macOS 14+ (`NavigationSplitView`, `@Observable`), using **only Apple's standard controls**. No third-party UI libraries and no custom-drawn widgets. Drop down to AppKit (`NSViewRepresentable`) only where SwiftUI has a real gap. See **Look & feel**.
- **Git via the CLI** (`/usr/bin/git`, or the user's configured git) through an async `Process` wrapper. No libgit2: its worktree support is incomplete, and using the CLI means the app respects the user's git config and hooks and does exactly what you'd do by hand.
- **App Sandbox off** (the sandbox blocks running git on arbitrary folders).
- **Signing:** "Sign to Run Locally" (ad-hoc). Gatekeeper doesn't block locally built apps.
- **Project generation:** XcodeGen from `project.yml`, so the project file stays readable and diffable.
- **Tests:** XCTest. Git-layer tests create throwaway repos in a temp dir and run real git commands.

## Architecture

```
Cheddar/
  project.yml
  Cheddar/
    App/        CheddarApp.swift, AppState (project list, selection)
    Git/        GitRunner (async Process), parsers, GitService (high-level ops)
    Models/     Project, Worktree, Branch, BranchStatus
    Watch/      RepoWatcher (FSEvents, debounced)
    Views/      Sidebar, ProjectView, WorktreeRow, BranchRow, sheets
    Launch/     OpenIn (Finder, Terminal, VS Code/Cursor, Claude Code)
  CheddarTests/
```

- **Persistence:** the project list is a JSON file of repo paths in `~/Library/Application Support/Cheddar/projects.json`. Per-project settings (trunk override, worktree root override) live alongside.
- **GitRunner:** runs `git` with an argument array (never a shell string), a working directory, and a clean environment (`GIT_TERMINAL_PROMPT=0`, `LC_ALL=C`). It returns stdout, stderr and the exit code, and supports cancellation.
- **GitService:** the only thing that calls GitRunner. Every operation returns a typed result or a `GitError` that includes git's stderr, so the UI can show why something failed.
- **Command log:** every git command the app runs, with its output, goes into an in-app log panel so nothing is hidden.

## Reading repo state

| Data | Command |
|---|---|
| Worktrees (path, HEAD, branch, detached, locked, prunable) | `git worktree list --porcelain -z` |
| Local branches, upstream, last commit subject/date | `git for-each-ref refs/heads --format=...` |
| Dirty/clean and changed-file count per worktree | `git -C <wt> status --porcelain=v2 --branch` |
| Ahead/behind trunk | `git rev-list --left-right --count <trunk>...<branch>` |
| Ahead/behind upstream | from `status --porcelain=v2 --branch` / `for-each-ref` `%(upstream:track)` |
| Merged into trunk | `git branch --merged <trunk>` |
| Git common dir (to resolve the main repo) | `git rev-parse --git-common-dir` |
| Trunk name | `origin/HEAD` if set, else `main`, else `master`; overridable per project |

The link between worktrees and branches comes from matching each worktree's `branch` field against the branch list. Every branch row shows either "checked out in X" or nothing.

## Worktree discovery & ownership

### Primary source: git
Every worktree created with `git worktree add` is registered in the repo, wherever it lives on disk. That includes worktrees from Claude Code, Codex, other apps and the terminal. So `git worktree list --porcelain` is the source of truth. Cheddar then gives each entry an **origin** based on its path:

| Origin | Rule (first match wins) | Badge |
|---|---|---|
| Main | the main working tree | `main` |
| Cheddar | under `<repo>/.cheddar/worktrees/` | `cheddar` |
| Claude Code | under `<repo>/.claude/worktrees/` | `claude` |
| Codex | under `$CODEX_HOME/worktrees/` (default `~/.codex/worktrees/`) or `<repo>/.codex/` | `codex` |
| External | anything else | `external` |

The origin rules are data in a small table: path prefix plus label. Extra locations can be added in Settings (for example Conductor, or a custom Codex worktree root), without code changes.

Known conventions, to confirm against real worktrees while building milestone 1:
- **Claude Code** worktrees sit in `<repo>/.claude/worktrees/<name>`, usually on a branch named after the worktree.
- **Codex** worktrees sit in `$CODEX_HOME/worktrees/...` and usually have a **detached HEAD**. The Codex app auto-deletes old ones (it keeps the most recent 15 by default) unless they're pinned as permanent.
- `CODEX_HOME` usually isn't set for GUI apps. Cheddar defaults to `~/.codex` and exposes the path in Settings.

### Secondary source: folder scan
Cheddar also scans the known roots (`.cheddar/worktrees`, `.claude/worktrees`, `.codex`, the Codex worktree root) for folders git no longer tracks correctly:
- **Orphaned folders:** a folder whose `.git` *file* points (`gitdir: …`) into this repo's `.git/worktrees/`, but which git doesn't list, or lists with a mismatched path. These are shown with **Repair** (`git worktree repair <path>`) and **Delete folder** (moves it to the Trash).
- **Missing worktrees:** git lists the worktree but its folder is gone. These are shown with **Prune**.
- Folders under the Codex root that belong to *other* repos are ignored. A folder is matched to a repo by its `gitdir` pointer, never by its folder name.

### What Cheddar may do by origin

| Action | Main | Cheddar | Claude / Codex / External |
|---|---|---|---|
| Open in… | ✓ | ✓ | ✓ |
| Rename branch | ✓ | ✓ | ✓ |
| Rename (move) folder | — | ✓ | ✗ (the owning tool tracks the path; moving it breaks the tool's link to it) |
| Delete | — | ✓ | ✓ with a warning that the owning tool may lose track of the chat or session |
| Hand off | — | ✓ | ✓ with the same warning |
| "Adopt" (move into `.cheddar/worktrees`, making it Cheddar-owned) | — | — | ✓ with a warning; via `git worktree move` |

### Detached HEAD worktrees (typical for Codex)
- The row shows the short SHA and the commit subject, and has a **Create branch here** action (`git -C W switch -c <name>`).
- Hand off from a detached worktree first asks for a branch name, creates the branch at that HEAD, then continues as normal. A branch is needed because the main checkout has to switch to something named.

### Nested worktrees & the main repo
`.cheddar/worktrees` and `.claude/worktrees` sit inside the main working tree:
- Cheddar adds `.cheddar/` to `.git/info/exclude` the first time it creates a worktree, so the main checkout doesn't see it as untracked.
- If `.claude/worktrees/` shows up as untracked in the main checkout, Cheddar offers (but never forces) adding it to `.git/info/exclude` as well.
- Dirty-status for the main worktree must not count nested worktree folders.
- FSEvents from the repo root are routed to whichever worktree has the **longest matching path prefix**, so a change in a nested worktree only refreshes that worktree.

**Adding a project:** the **+** button opens a folder picker. The app checks that the folder is a git repo. If the folder is a linked worktree, the app resolves it to the main repo using `--git-common-dir`. Duplicates are ignored.

## UI

```
┌──────────────┬───────────────────────────────────────────────────┐
│ PROJECTS     │ myrepo · trunk: main                      ⟳  ⚙    │
│ ● myrepo     │                                                   │
│   api        │ WORKTREES                  [All ▾]  [+ New]       │
│   site       │ ▣ myrepo       main     main          ✓ clean     │
│              │ ▣ feat-login   cheddar  feat/login    ● 3         │
│              │                ↑4 ↓1 vs main · 2h ago             │
│              │                [Open ▾] [Hand off] [⋯]            │
│              │ ▣ auth-refac   claude   worktree-auth ✓ clean     │
│              │ ▣ 7f3e/myrepo  codex    detached a1b2c3  ● 1      │
│              │ ⚠ old-exp      cheddar  missing   [Prune]         │
│              │                                                   │
│              │ BRANCHES                                          │
│              │   feat/login  → feat-login      ↑4 ↓1             │
│              │   fix/typo      (no worktree)   ↑1 [+ Worktree]   │
│  +           │   old/spike     (no worktree)   merged  [⋯]       │
└──────────────┴───────────────────────────────────────────────────┘
```

- Each worktree row carries an **origin badge** (`main`, `cheddar`, `claude`, `codex`, `external`). The **All ▾** filter narrows the list by origin.
- Worktrees are grouped as: main first, then Cheddar-owned, then the others by origin.
- The layout takes after the Claude Code desktop app (a sidebar, one focused main pane, compact rows). The controls and styling are **plain macOS** (see **Look & feel**): monospace for branch names, SHAs and paths; actions revealed on hover; a context menu on every row.
- The sidebar lists projects. **+** sits at the bottom. Right-click a project to remove it from Cheddar (this never touches disk), or to reveal it in Finder.
- In the main pane, the main worktree is always first and marked as main.
- Worktrees whose folder is missing are shown as "missing", with a Prune action.
- Hovering a branch highlights its worktree, and hovering a worktree highlights its branch.
- A collapsible bottom panel holds the command log.

## Look & feel

### Mac-native
Cheddar should feel like an app Apple could have shipped. Use the standard SwiftUI and AppKit pieces and let the system style them:

| Element | Use |
|---|---|
| Window layout | `NavigationSplitView`. The sidebar uses `List` with `.listStyle(.sidebar)`, so it gets the system's translucent sidebar material. |
| Worktree and branch lists | `List` with `Section` headers. `Table` is an option for the branches if column sorting turns out to be useful. |
| Toolbar | `.toolbar` with standard `ToolbarItem`s (Refresh, New Worktree, filter `Picker`), plus `.searchable` to filter by branch or worktree name. |
| Row actions | `.contextMenu` on every row, plus hover-revealed borderless `Button`s. Destructive items use `role: .destructive`. |
| Create, rename, hand off | `.sheet` containing a `Form` with `.formStyle(.grouped)`. |
| Confirmations | `.confirmationDialog`, or `.alert` for errors. |
| Settings | A `Settings { }` scene: a standard ⌘, window with a `TabView` (General, Appearance, Dependencies, Discovery). |
| Menus | Standard menu bar commands via `.commands` (File → Add Project… ⌘O; View → Refresh ⌘R; Worktree → New ⌘N, Hand Off, Delete ⌘⌫). |
| Icons | SF Symbols only, e.g. `folder`, `arrow.triangle.branch`, `arrow.up`, `arrow.down`, `exclamationmark.triangle`, `checkmark.circle`. |
| Badges (origin, "merged") | Small text with a subtle tinted capsule background, using `.secondary`/`.quaternary` fills. Neutral colors, so they don't clash with the git colors. |
| Text | System font and Dynamic Type styles (`.body`, `.callout`, `.caption`). `.monospaced()` only for branch names, SHAs and paths. |
| Command log panel | A collapsible bottom area using a `VSplitView` or `.inspector`, with a monospaced, selectable `Text` list. |

What this means in practice:
- No hardcoded background or text colors. Use semantic colors (`.primary`, `.secondary`, `Color(nsColor: .windowBackgroundColor)` and so on), so light, dark, the accent color and Increase Contrast all just work.
- Respect the user's system accent color for selection and prominent buttons.
- Everything is reachable by keyboard, and VoiceOver labels are set on icon-only buttons.

### Appearance setting
Settings → Appearance has a segmented `Picker` with **System** (default), **Light** and **Dark**.
- It's stored with `@AppStorage("appearance")` and applied app-wide by setting `NSApp.appearance`: `nil` for System, `NSAppearance(named: .aqua)` for Light, `NSAppearance(named: .darkAqua)` for Dark.
- This is set at launch and whenever the setting changes. Using `NSApp.appearance` instead of SwiftUI's `.preferredColorScheme` makes sure sheets, alerts, menus and the Settings window follow it too.

### Git colors
Status colors follow **git's own default terminal colors** (from `git status`, `git branch` and `git log --decorate`), so the UI means what users already expect:

| UI state | Git's default | Cheddar |
|---|---|---|
| Staged changes count | `color.status.added` = green | green |
| Unstaged changes count | `color.status.changed` = red | red |
| Untracked files count | `color.status.untracked` = red | red |
| Merge conflicts / unmerged | `color.status.unmerged` = red | red, bold, with ⚠ |
| Current branch (checked out in the main worktree) | `color.branch.current` = green | green |
| Branch checked out in another worktree | `color.branch.worktree` = cyan | cyan |
| Other local branches | `color.branch.local` = normal | `.primary` |
| Remote branch names | `color.branch.remote` = red | red |
| Upstream (tracking) name | `color.branch.upstream` = blue | blue |
| HEAD / detached HEAD | `color.decorate.HEAD` = bold cyan | cyan, semibold |
| Commit SHA | `color.diff.commit` = yellow | yellow |
| Tags | `color.decorate.tag` = bold yellow | yellow |
| Stash references | `color.decorate.stash` = bold magenta | magenta (`.purple`/`.pink`) |
| Ahead ↑ / behind ↓ | not colored by git | ↑ green (commits to add), ↓ red (commits missing): Cheddar's convention, following git's add/remove colors |
| Clean | not colored by git | `.secondary` gray with ✓ |

Rules:
- Use the **system** colors (`Color.green`, `.red`, `.yellow`, `.cyan`, `.blue` and so on) rather than hex values. They're tuned per appearance and adjust for Increase Contrast. Yellow needs special care: in light mode, use a darker yellow/orange so it stays readable.
- Colors live in one `GitColors` enum, so they can be changed in one place.
- **Color is never the only signal.** Every colored state also has a symbol or text (↑3, ●2, ⚠, ✓), so the UI still reads for colorblind users.
- Optional, later: read the user's own `color.*` git config and use it instead of the defaults.

## Operations

### Create worktree
The create sheet offers:
- **New branch**, based on trunk (the default), the current branch, or any local branch.
- **Existing branch**, limited to branches not checked out anywhere.
- A worktree name, which defaults to the branch name with `/` changed to `-`. The folder is always `<repo>/.cheddar/worktrees/<name>`. If that folder exists, Cheddar adds a numeric suffix.

Before the first create, Cheddar makes sure `.cheddar/` is listed in `.git/info/exclude`. Then it runs `git worktree add [-b <new>] <path> [<base>|<branch>]`. The same sheet opens from the **+ Worktree** button on a branch row, with that branch preselected.

### Rename worktree (branch + folder)
1. `git branch -m <old> <new>`
2. `git worktree move <old-path> <repo>/.cheddar/worktrees/<new-name>`
3. If step 2 fails, roll back with `git branch -m <new> <old>`.

Folder moves only apply to Cheddar-owned worktrees:
- For the main worktree, and for worktrees from Claude, Codex or elsewhere, rename only changes the branch.
- A detached Cheddar worktree only moves its folder.

### Delete worktree
- `git worktree remove <path>`.
- If the worktree has uncommitted or untracked changes, the confirmation dialog lists them and requires an explicit **Force** (`--force`).
- A checkbox also deletes the branch: `git branch -d`, or `-D` when it's unmerged, which shows an extra warning.
- The main worktree can't be deleted.

### Branches
- **Create:** `git branch <name> <base>`.
- **Rename:** `git branch -m`. If the branch is checked out in a linked worktree, the user gets a choice between also moving the folder (see rename worktree) and renaming the branch only.
- **Delete:** `git branch -d`, or `-D` with a warning when unmerged. Disabled when the branch is checked out in any worktree.
- **Create worktree from branch**, as above.
- Branch names are validated with `git check-ref-format --branch`.

### Hand off
Goal: stop working on branch **B** in worktree **W** and continue on it in the main checkout.

**1. Preflight.** The app checks the following and shows the results in a confirmation sheet:
- The main checkout is clean. If it isn't, the sheet offers **Stash main's changes** (`git stash push -u -m "cheddar: before handoff of B"`), or the user can cancel.
- Whether W has uncommitted or untracked changes. If it does, the sheet offers **Carry changes over** (the default) or cancel.
- Ignored files in W (`node_modules`, `.env`, build output and similar), found with `git -C W status --ignored --porcelain`. These will be **lost**, so the sheet warns and lists the top-level ignored paths.
- Whether W is locked. If so, the app refuses and explains why.
- Whether W has a **detached HEAD** (common for Codex). If so, the sheet asks for a branch name, and Cheddar runs `git -C W switch -c <name>` before step 2. That new branch is **B** for the rest of hand off.
- Whether W isn't Cheddar-owned. If so, the sheet warns that Claude Code or Codex may lose track of that session once the folder is removed.

**2. Steps**, each logged:
1. If carrying changes: `git -C W stash push -u -m "cheddar handoff: B"`. The stash is shared across worktrees, so it survives step 2.
2. `git worktree remove W` (plain, no force, since W is now clean).
3. `git -C <main> switch B`.
4. If changes were carried: `git -C <main> stash pop`.

**3. Failure handling:**
- If step 3 fails, recreate the worktree with `git worktree add W B`, and `stash pop` there if needed. Then report the error.
- If step 4 conflicts, stop and tell the user the stash is still in the stash list, naming it.

The branch itself is never deleted, merged or rebased by hand off.

## Status at a glance
For each worktree and branch:
- dirty badge with changed-file count
- ahead/behind trunk
- ahead/behind upstream (if one is set)
- last commit subject and relative time
- a "merged" tag when the branch is merged into trunk

Status is computed concurrently per worktree, with a small concurrency limit.

## Auto-refresh
- FSEvents watches:
  - the git common dir (`.git/`, including `worktrees/`, `refs/`, `HEAD`, `index`)
  - each worktree root
  - the discovery roots (`.cheddar/worktrees`, `.claude/worktrees`, `.codex`, the Codex worktree root)

  This means worktrees that agents create or delete show up without a manual refresh.
- Events are debounced to about 300 ms. Changes under `.git/objects` and `.git/logs` are ignored.
- The app also refreshes whenever its window becomes active, and through a manual ⟳ button (⌘R).
- A refresh never runs while a mutating operation is in progress.

## Open in
From the Open ▾ menu on each worktree:
- **Finder:** `NSWorkspace.shared.activateFileViewerSelecting`
- **Terminal:** `open -a Terminal <path>`
- **VS Code / Cursor:** `open -a "Visual Studio Code" <path>` / `open -a Cursor <path>`. Apps that aren't installed stay in the menu marked "Not installed" and link to their install help (see **Dependencies & setup checks**).
- **Claude Code here:** AppleScript that opens Terminal and runs `cd <path> && claude`.

The preferred terminal and editor are configurable in Settings.

## Dependencies & setup checks

Cheddar relies on command-line tools it doesn't ship with. When one is missing, Cheddar **never installs anything itself**. Instead it explains what's missing and what that affects, and gives:
- copy/paste install commands, each with a **Copy** button
- a link to the dependency's official install docs

### Registry
The list of dependencies is data (`Dependencies.swift`), so adding a new one is a one-entry change. Each entry has:
- id and display name
- a **required** or **optional** flag, and which features it enables
- how to find it: binary name, known install paths, an app bundle ID for GUI apps
- a version check command and a minimum version (if any)
- install options: a label and a command
- the docs URL

| Dependency | Required? | Enables | Detect | Install commands | Docs |
|---|---|---|---|---|---|
| **git** ≥ 2.36 | Required | everything | `git --version` (see the CLT note below) | `xcode-select --install` · `brew install git` | https://git-scm.com/install/mac |
| **Xcode Command Line Tools** | Required if using Apple's `/usr/bin/git` | git at `/usr/bin/git` | `xcode-select -p` exits 0 | `xcode-select --install` | https://git-scm.com/install/mac |
| **Homebrew** | Optional | only needed for the `brew` install commands | `brew` on PATH, or `/opt/homebrew/bin/brew` or `/usr/local/bin/brew` | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` | https://brew.sh |
| **Claude Code** (`claude`) | Optional | Open in → Claude Code here | `claude --version` | `curl -fsSL https://claude.ai/install.sh \| bash` · `brew install --cask claude-code` | https://code.claude.com/docs/en/setup |
| **VS Code** | Optional | Open in → VS Code | bundle ID `com.microsoft.VSCode` | `brew install --cask visual-studio-code` | https://code.visualstudio.com/docs/setup/mac |
| **Cursor** | Optional | Open in → Cursor | bundle ID `com.todesktop.230313mzl4w4u92` (confirm on install) | `brew install --cask cursor` | https://cursor.com/downloads |

Why git ≥ 2.36: that's the oldest version supporting everything Cheddar uses: `worktree list --porcelain -z` (2.36), `worktree repair` (2.29), `switch` (2.23). Apple's current Command Line Tools ship a newer git.

A `brew …` command only appears if Homebrew is detected. Otherwise the non-brew option comes first, and the brew option shows a note linking to the Homebrew row.

### Detection rules
- **GUI apps get a minimal PATH** (`/usr/bin:/bin:/usr/sbin:/sbin`), so Cheddar can't rely on PATH lookup for brew or user-installed tools. At launch it resolves the user's real PATH once, by running the user's login shell (`$SHELL -lic 'echo $PATH'`) with a 3-second timeout. It also always checks `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin`. The resolved PATH is then used for every tool Cheddar runs.
- **Don't trigger Apple's install popup.** On a Mac without the Command Line Tools, `/usr/bin/git` is a stub that opens the system "install developer tools" dialog. So when the candidate git is `/usr/bin/git`, Cheddar checks `xcode-select -p` *first*, and only runs `git --version` if the tools are present.
- **Git choice order:** the Settings override, then the first `git` on the resolved PATH, then `/usr/bin/git` (when the Command Line Tools are present). Settings shows which git and version is in use.
- **When checks run:** at launch, when the app becomes active (cheap: cached, rechecked at most every 30 seconds), and on **Check again**.

### UI
- **Required dependency missing or too old:** instead of the project view, a full-window **Setup** screen. It shows:
  - what's missing, and the version found if the problem is an old version
  - each install option as a monospaced command with a **Copy** button
  - an **Install docs ↗** link
  - **Check again**, and **Choose git binary…** (a file picker that sets the Settings override)

  When the check passes, the app continues to the normal UI without a restart.
- **Optional dependency missing:** the related menu item stays visible but shows "Not installed". Choosing it opens a popover with the same pieces: what it's for, commands with Copy buttons, the docs link and **Check again**.
- **Settings → Dependencies:** lists every registry entry with status (✓ found at path and version / ✗ missing / ⚠ too old), and each entry expands to its install commands and docs link.
- **Runtime failure:** if a tool disappears mid-session and running it fails because the file isn't found, the error banner links straight to that tool's install help, rather than just showing the raw error.

## Settings
- Global:
  - **appearance:** System / Light / Dark (see **Look & feel**)
  - preferred terminal and editor
  - git binary path
  - Codex home (default `~/.codex`)
  - extra discovery locations: path prefix plus label, relative to the repo or absolute
- Per project: trunk branch override.

## App icon

### Look
A **skeuomorphic block of cheddar with 2–3 slices cut off**. It should read as a real object, in the style of classic pre-Big Sur Mac icons, not a flat glyph.

**The block**
- A rectangular wedge of aged cheddar seen from a three-quarter view, slightly from above, so the top face and two sides are visible.
- Deep orange-yellow paste, roughly `#F2A516` to `#E08A0B`, with warmer and darker tones on the shaded side.
- A thin, slightly darker rind along the outer edges.
- On the cut face: a subtle crumbly texture, a few tiny pale crystal specks, and a soft sheen.

**The slices**
- 2–3 thin slices cut from one end, fanned or leaning against each other beside the block.
- Each slice is slightly translucent at its edges, and the front slice catches the light.
- The cut face of the block is flat and smoother than its rind. That contrast is what reads as "cut".

**Lighting and board**
- Light comes from the top-left.
- A soft contact shadow sits under the block and slices.
- Optionally, a small wooden cheese board or slate under the cheese. If there is one, it stays subtle and the cheese stays the hero.

**Legibility**
- It must still read as "cheese" at 16×16 and 32×32. At those sizes, simplify: fewer slices, no specks, and stronger edges.
- A small hint at the app's purpose is allowed but optional. One idea is the slices fanning like branches, echoing the git branch shape. It must stay subtle.

### macOS shape
- **macOS 26 (Tahoe) and later:** icons are expected to fill the rounded-square shape. Anything that doesn't gets shrunk onto a grey rounded-square plate. So the default design is the cheese on a warm, dark rounded-square background (deep brown to charcoal gradient, like a cheese board or slate), with the cheese allowed to overlap the plate edge slightly for depth.
- **macOS 14–15:** the same artwork works.

We could build a layered Icon Composer (`.icon`) version later. It isn't needed for v1.

### Production
1. **Source art** is one 1024×1024 master: `Design/AppIcon-1024.png`, plus the source file (`.svg`, `.psd` or `.icon`) next to it. The skeuomorphic version will most likely be drawn or generated outside the code. Until it exists, a hand-written SVG placeholder of the same composition, built from gradients, is fine.
2. **Separate small-size art:** `Design/AppIcon-small.png`, the simplified 16/32 version.
3. **A script**, `scripts/make-icons.sh`, uses `sips` to export every size (16, 32, 64, 128, 256, 512 and 1024) into `Cheddar/Assets.xcassets/AppIcon.appiconset/`, and writes its `Contents.json`. The 16 and 32 sizes come from the small-size art.
4. **XcodeGen** points at the asset catalog, so the icon is in place from the first build (milestone 1).

## Milestones
1. **Scaffold and read-only view.**
   - XcodeGen project, GitRunner, and porcelain parsers.
   - The dependency registry, PATH resolution, and the git/Command Line Tools check with the Setup screen. See **Dependencies & setup checks**.
   - App icon pipeline, with the placeholder cheddar SVG until the final art exists. See **App icon**.
   - Origin classification, with unit tests against temp repos. The tests should include worktrees under `.claude/worktrees` and a fake Codex root.
   - A read-only list of worktrees and branches for one hardcoded repo.
2. **Projects.** Sidebar, the **+** folder picker with validation, and persistence.
3. **Mutations.**
   - Create worktrees in `.cheddar/worktrees`, including the `info/exclude` step.
   - Delete and rename for worktrees and branches, with the ownership rules.
   - Error surfacing and the command log.
4. **Hand off.** Preflight sheet (including the detached-HEAD and non-Cheddar cases), the steps, and rollback.
5. **Discovery extras.** Folder scan for orphaned and missing worktrees, Repair, Prune, Adopt, and the origin filter.
6. **Polish.** Status at a glance with git colors, auto-refresh (including discovery roots), Open in, and settings (including appearance).

## Build & run
Build-time dependencies: Xcode, and XcodeGen (`brew install xcodegen`; docs: https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open Cheddar.xcodeproj   # or: xcodebuild -scheme Cheddar -configuration Release build
```
Signing: Team = None, "Sign to Run Locally". Copy the built `Cheddar.app` to `/Applications`.
