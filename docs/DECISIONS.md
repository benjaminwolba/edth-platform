# Decisions

Running log of decisions made while building the EDTH App. Newest entries at the bottom.
Each entry: date, decision, reason. Update `PLAN.md` / `DATA_MODEL.md` when an entry affects them.

---

## 2026-11-18 — Repo setup

- **Docs live in `docs/`.** `PLAN.md` and `DATA_MODEL.md` moved from the repo root into `docs/`, matching the
  layout in `CLAUDE.md`. This file was created as the decision log.
- **Git initialized** with `main` as the default branch and a `.gitignore` that excludes `.env*` files,
  build output and Supabase local state.

## 2026-11-18 — Week 1 table list completed

- `app_users`, `record_grants` and `email_sends` added to the Week 1 schema list in `PLAN.md`. The access model
  (`auth_role()`, `can_read()`) needs the first two, and the check-in loop needs `email_sends`. All three were
  already in `DATA_MODEL.md`.

## 2026-11-18 — Prod imports are run by Benjamin

- The Week 2 step "then run on prod" now says Benjamin runs prod imports himself. This keeps the plan consistent
  with hard rule 2 (Claude Code never touches prod).

## 2026-11-18 — Child tables inherit their tier from the parent row

- `person_emails`, `participation_members`, `challenges`, `consents` and `email_sends` get **no `tier` column**.
  RLS on them checks visibility of the parent row instead (see "Child tables" in `DATA_MODEL.md`).
- **Why:** A separate tier could drift from the parent's, e.g. a `confidential` military contact whose email
  address is still `internal` would leak. Inheriting makes that impossible and leaves less to maintain.
- **Tradeoff:** A child row can't be stricter than its parent. If that is ever needed, the table gets its own `tier`.
- Hard rule 3 in `CLAUDE.md` was reworded to match.

## 2026-11-19 — "Continued building" comes only from the team's answer

- Dropped the "at least 3 months after the hackathon" threshold and the "incorporated, raised money" inference.
  A team's status is its latest approved `status` signal: `building` / `incorporated` / `acquired` → building,
  `paused` / `stopped` → not building, no answer → `unknown`.
- **Why:** Simpler and honest: we report what teams told us, not what we infer from timing.
- `paused` counts as not building. Revisit if paused teams should be shown as their own bucket.

## 2026-11-19 — Status links: confirm page, then form; direct approval unless conflicting

- **Status links don't record anything on open.** They open a page with a Confirm button; only the POST from
  that button records the answer. **Why:** corporate email scanners (e.g. Microsoft Defender) open every link
  in incoming emails and would otherwise record random answers.
- **After confirming, the page shows the prefilled form** to collect fundraising, intro needs and a deck. Optional.
- **Confirmed clicks and form submissions create approved signals directly.** **Why:** they are the team's own
  explicit answer, with no AI interpretation; reviewing them would add work without changing anything.
  Hard rule 6 still holds: Claude's extractions are always `proposed`.
- **Conflicting answers go to review.** If a different member of the same team gives a different answer of the
  same kind in the same check-in round, the new answer is `proposed` and shown next to the other one.
  Details in `DATA_MODEL.md` under signals.

## 2026-11-19 — Access foundation (first migration)

- **`app_users` uses the auth user id as its primary key** instead of a separate `id` plus a unique `user_id`.
  **Why:** every user reference (`created_by`, `owner_user_id`, `reviewed_by`, …) is then simply `auth.uid()`,
  with no second id to mix up.
- **`role` has no default.** An admin sets it explicitly; a user with no `app_users` row or `active = false` sees nothing.
- **`can_write` = `team` or above AND `can_read`.** Nobody can write a row they could not read, and `friends`
  can't write at all.
- **Grants only matter for `confidential` rows.** `sensitive` rows are not grantable to `team` users; if that is
  ever needed, revisit.
- **`anon` has no table privileges in `public`**, including for future tables (default privileges revoked).
  Public pages such as the status confirm page go through server-side code instead.
- **A pgTAP guard test fails if any table in `public` lacks RLS**, so a forgotten policy can't ship silently.
- **Tooling:** pnpm workspace, Node 22 (`.nvmrc`).
