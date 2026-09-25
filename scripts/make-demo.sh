#!/bin/bash
# Creates demo repos in ./demo (gitignored) with worktrees and branches in every state Cheddar shows,
# for screenshots. Re-running it deletes and rebuilds ./demo. Add the repos in Cheddar with + Add Project.
#
#   storefront    Cheddar, Claude Code and Codex worktrees; dirty changes; ahead/behind trunk and upstream;
#                 a merged branch; a missing worktree (Prune); teammates' remote-only branches and a
#                 same-name branch pushed without an upstream (Remote Branches); tags in every state
#                 (click Fetch in Cheddar to compare them with origin)
#   payments-api  a merge conflict; an upstream that's gone; a moved Claude worktree (orphaned, Repair);
#                 the ".claude/worktrees/ shows as untracked" offer
#   mobile-app    trunk "develop" (from origin/HEAD); two Codex worktrees; an external worktree;
#                 a locked worktree
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO="$ROOT/demo"
MARKER=".cheddar-demo"

if [ -e "$DEMO" ] && [ ! -e "$DEMO/$MARKER" ]; then
  echo "$DEMO exists but wasn't made by this script; not touching it." >&2
  exit 1
fi
rm -rf "${DEMO:?}"
mkdir -p "$DEMO"
touch "$DEMO/$MARKER"

# Reproducible: ignore the user's git config, fixed identity, no signing.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Demo Dev" GIT_AUTHOR_EMAIL="dev@example.invalid"
export GIT_COMMITTER_NAME="Demo Dev" GIT_COMMITTER_EMAIL="dev@example.invalid"
NOW=$(date +%s)

# commit <hours ago> <message>: commits everything staged (or an empty commit) at a past time.
commit() {
  local when="@$((NOW - $1 * 3600)) +0000"
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git commit -q --allow-empty -m "$2"
}

# remote_only <branch> <hours ago> <message> <file> <line>: a branch that exists only on origin, like a
# teammate's (committed on top of main, pushed, then the local branch deleted).
remote_only() {
  git checkout -q -b "$1" main
  change "$2" "$3" "$4" "$5"
  git push -q origin "$1"
  git checkout -q main
  git branch -q -D "$1"
}

# edit <file> <line>: appends a line, creating the file and its folders.
edit() {
  mkdir -p "$(dirname "$1")"
  echo "$2" >> "$1"
}

# change <hours ago> <message> <file> <line>: edit, stage and commit.
change() {
  edit "$3" "$4"
  git add "$3"
  commit "$1" "$2"
}

# new_repo <name>: a repo with a bare "origin" next to it, cd'd into.
new_repo() {
  git init -q --bare "$DEMO/.remotes/$1.git"
  git init -q -b main "$DEMO/$1"
  cd "$DEMO/$1"
  git remote add origin "$DEMO/.remotes/$1.git"
}

exclude() {
  printf '%s\n' "$@" >> .git/info/exclude
}

# ---------------------------------------------------------------- storefront
new_repo storefront
printf 'vendor/\nnode_modules/\n.env\n' > .gitignore
edit README.md "# Storefront"
git add .
commit 480 "Initial commit"
change 460 "Add product catalog" app/Http/Controllers/ProductController.php "<?php // catalog"
change 400 "Add shopping cart" app/Http/Controllers/CartController.php "<?php // cart"
change 300 "Cart totals in minor units" app/Models/Cart.php "<?php // totals"
git branch spike/graphql
change 250 "Checkout page" resources/js/Checkout.vue "<template>checkout</template>"
git branch release/2.4
change 180 "Order confirmation emails" app/Mail/OrderPlaced.php "<?php // mail"
change 120 "Faster product search" app/Search/ProductSearch.php "<?php // search"
git push -q -u origin main
git remote set-head origin main

# Cheddar worktree: ahead 4 / behind 1 vs main, 1 unpushed commit, staged + modified + untracked, ignored deps.
git worktree add -q -b feat/checkout-redesign .cheddar/worktrees/feat-checkout-redesign
(
  cd .cheddar/worktrees/feat-checkout-redesign
  change 96 "Two-column checkout layout" resources/js/Checkout.vue "<aside>summary</aside>"
  change 70 "Address autocomplete" resources/js/Address.vue "<template>address</template>"
  change 30 "Validate postcode" app/Rules/Postcode.php "<?php // postcode"
  git push -q -u origin feat/checkout-redesign
  change 5 "Remember saved cards" app/Payments/SavedCards.php "<?php // cards"
  edit resources/js/Checkout.vue "<button>Pay now</button>"
  edit app/Http/Controllers/CartController.php "// apply coupon"
  git add resources/js/Checkout.vue app/Http/Controllers/CartController.php
  edit app/Models/Cart.php "// shipping estimate"
  edit README.md "Checkout redesign notes"
  edit routes/web.php "Route::get('/checkout', CheckoutController::class);"
  edit resources/js/Payment.vue "<template>payment</template>"
  edit node_modules/vue/index.js "// dependency"
)
git -C "$DEMO/storefront" checkout -q main
change 20 "Bump PHP to 8.4" composer.json '{"require": {"php": "^8.4"}}'
git push -q origin main

# Cheddar worktree: 1 commit ahead, clean.
git worktree add -q -b fix/cart-rounding .cheddar/worktrees/fix-cart-rounding
( cd .cheddar/worktrees/fix-cart-rounding && change 3 "Round cart totals half-even" app/Models/Cart.php "// half-even" )

# Claude Code worktree: 2 commits, 1 modified file.
git worktree add -q -b claude/search-filters .claude/worktrees/search-filters
(
  cd .claude/worktrees/search-filters
  change 9 "Filter search by price range" app/Search/ProductSearch.php "// price range"
  change 2 "Filter search by brand" app/Search/ProductSearch.php "// brand"
  edit app/Search/Facets.php "<?php // facets"
  git add app/Search/Facets.php
)

# Codex worktree: detached HEAD with its own commit.
git worktree add -q --detach .codex/7f3e
( cd .codex/7f3e && change 1 "Codex: fix typo in order email subject" app/Mail/OrderPlaced.php "// subject typo" )

# Branches without worktrees: merged (release/2.4), 1 ahead (chore/bump-deps), old spike ahead 3 / behind 6.
git branch chore/bump-deps
git checkout -q chore/bump-deps && change 48 "Bump laravel/framework" composer.json '{"laravel/framework": "^12.0"}' && git checkout -q main
git checkout -q spike/graphql
change 330 "GraphQL schema" graphql/schema.graphql "type Product { id: ID! }"
change 320 "GraphQL resolvers" graphql/Resolvers.php "<?php // resolvers"
change 310 "GraphQL playground" graphql/playground.html "<html></html>"
git checkout -q main

# Remote branches: teammates' branches with no local branch, and spike/graphql pushed without -u
# (same name as the local branch, but not linked to it).
remote_only feat/gift-cards 28 "Gift card balance endpoint" app/GiftCards/Balance.php "<?php // balance"
remote_only dependabot/composer/stripe-php-16 50 "Bump stripe/stripe-php to 16.2" composer.lock "stripe 16.2"
git push -q origin spike/graphql
git fetch -q origin

# Tags: releases on origin (annotated and lightweight), an unpushed release candidate, "nightly" pointing
# somewhere else on origin, and a teammate's tag that's only on origin (on a commit no branch reaches, so
# fetch doesn't bring it along).
git tag v2.3.0 release/2.4~1
GIT_COMMITTER_DATE="@$((NOW - 200 * 3600)) +0000" git tag -a v2.4.0 -m "Release 2.4.0" release/2.4
git push -q origin v2.3.0 v2.4.0
git push -q origin main~1:refs/tags/nightly
git tag nightly main
GIT_COMMITTER_DATE="@$((NOW - 6 * 3600)) +0000" git tag -a v2.5.0-rc1 -m "Release candidate 1" main
git clone -q -b main "$DEMO/.remotes/storefront.git" "$DEMO/.teammate"
(
  cd "$DEMO/.teammate"
  git checkout -q --detach
  change 16 "Try a new price formatter" app/Support/Money.php "<?php // formatter"
  git tag experiment/price-format
  git push -q origin refs/tags/experiment/price-format
)
rm -rf "$DEMO/.teammate"

# Missing worktree: git lists it, its folder is gone (shows Prune).
git worktree add -q -b feat/wishlist .cheddar/worktrees/feat-wishlist
rm -rf .cheddar/worktrees/feat-wishlist

exclude .cheddar/ .claude/ .codex/

# ---------------------------------------------------------------- payments-api
new_repo payments-api
printf 'bin/\n*.log\n' > .gitignore
edit go.mod "module example.com/payments"
git add .
commit 700 "Initial commit"
change 650 "Charge endpoint" internal/charge/charge.go "package charge"
change 500 "Webhook signatures" internal/webhook/verify.go "package webhook"
change 200 "Idempotency keys" internal/charge/idempotency.go "package charge"
git push -q -u origin main
git remote set-head origin main

# Merged into main, no worktree.
git checkout -q -b hotfix/webhook-retry
change 150 "Retry failed webhooks" internal/webhook/retry.go "package webhook // retry"
git checkout -q main && git merge -q --no-edit hotfix/webhook-retry

# Cheddar worktree with a merge conflict in progress; its upstream was deleted on the remote ("gone").
git worktree add -q -b feat/refunds .cheddar/worktrees/feat-refunds
(
  cd .cheddar/worktrees/feat-refunds
  change 60 "Partial refunds" internal/charge/charge.go "func Refund(amount int) {}"
  git push -q -u origin feat/refunds
  git push -q origin --delete feat/refunds
  git fetch -q --prune
)
change 40 "Charge in minor units" internal/charge/charge.go "func Charge(minor int64) {}"
( cd .cheddar/worktrees/feat-refunds && git merge -q main >/dev/null 2>&1 || true )

# A Claude Code worktree whose folder was moved by hand: orphaned (Repair) plus git's stale entry (missing).
git worktree add -q -b claude/ledger-export .claude/worktrees/ledger-export
( cd .claude/worktrees/ledger-export && change 12 "Export ledger as CSV" internal/ledger/export.go "package ledger" )
mv .claude/worktrees/ledger-export .claude/worktrees/ledger-export-moved

# .claude/worktrees/ is left out of info/exclude, so Cheddar offers to add it.
exclude .cheddar/

# ---------------------------------------------------------------- mobile-app
new_repo mobile-app
printf 'build/\nDerivedData/\n' > .gitignore
edit App/App.swift "@main struct App {}"
git add .
commit 900 "Initial commit"
change 600 "Onboarding flow" App/Onboarding.swift "struct Onboarding {}"
git push -q -u origin main
git checkout -q -b develop
change 300 "Offline mode" App/Offline.swift "struct Offline {}"
change 100 "Dark mode polish" App/Theme.swift "struct Theme {}"
git push -q -u origin develop
# Trunk comes from origin/HEAD, which points at develop.
git remote set-head origin develop

# Locked Cheddar worktree.
git worktree add -q -b feat/widgets .cheddar/worktrees/feat-widgets
( cd .cheddar/worktrees/feat-widgets && change 26 "Home screen widget" App/Widget.swift "struct Widget {}" )
git worktree lock --reason "on an external drive" .cheddar/worktrees/feat-widgets

# Two Codex worktrees, detached; one with uncommitted changes.
git worktree add -q --detach .codex/a91c
( cd .codex/a91c && change 7 "Codex: add accessibility labels" App/Onboarding.swift "// a11y" )
git worktree add -q --detach .codex/c20d
( cd .codex/c20d && edit App/Offline.swift "// retry sync" && edit App/Sync.swift "struct Sync {}" )

# External worktree, made by hand outside the repo.
git worktree add -q -b hotfix/crash-on-launch "$DEMO/external/mobile-app-hotfix" main
( cd "$DEMO/external/mobile-app-hotfix" && change 4 "Fix crash on launch" App/App.swift "// guard nil config" )

exclude .cheddar/ .claude/ .codex/

echo "Demo repos are in $DEMO:"
ls -1 "$DEMO" | grep -v '^external$'
