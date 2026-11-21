# EDTH App

This repo is the unified data backend and internal web app of the European Defense Tech Hub (EDTH).
It replaces Attio as EDTH's system of record for organizations, people and relationships, and it
starts with one concrete use case: **tracking EDTH hackathon alumni through monthly check-in emails**.

Read these before doing anything substantial:

- `docs/PLAN.md` — goals, phase 1 scope, the 4-week plan, the module roadmap, open decisions
- `docs/DATA_MODEL.md` — every table, why it exists, and the access model
- `docs/DECISIONS.md` — running log of decisions made while building (create it if missing, append to it)

The repo is built and maintained by one person (Benjamin) working with Claude Code. Optimize for
**simplicity, explicitness and things that are hard to break**, not for cleverness or scale.

---

## Stack

| Layer | Choice |
|---|---|
| Database, auth, storage, edge functions | Supabase (Postgres), EU region Frankfurt |
| Web app | Next.js (App Router, TypeScript), shadcn/ui, TanStack Table |
| Hosting | Vercel, functions pinned to an EU region; domain `app.eurodefense.tech` |
| Login | Supabase Auth with Google, restricted to `@eurodefense.tech` accounts |
| Email out / in | Resend (sending from a subdomain such as `updates.eurodefense.tech`, plus inbound webhook) |
| AI extraction | Claude API, called server-side only |
| Natural-language querying | MCP server in `services/mcp/`, read-only, runs as the calling user |
| Excel export | SheetJS, from any filtered table view |

Events themselves stay on **commonspace** (events.eurodefense.tech). This app imports from commonspace;
it does not replace it.

## Repo layout

```
supabase/migrations/   all schema changes, one file per change, never edited after merge
supabase/seed.sql      FAKE data for local development only
supabase/tests/        pgTAP tests, especially for RLS policies
apps/web/              Next.js app
packages/db/           generated database types + zod schemas for jsonb payloads
services/mcp/          MCP server
scripts/import/        importers (commonspace, attio, csv) — all go through staging, see below
docs/                  PLAN.md, DATA_MODEL.md, DECISIONS.md
```

## Environments

- **local**: `supabase start` (Docker). All development and all Claude Code work happens here.
- **staging**: hosted Supabase project for testing migrations and imports on realistic data.
- **prod**: hosted Supabase project. Changed only by applying migrations from `main`.

Common commands:

```
supabase start                       # local stack
supabase db reset                    # rebuild local db from migrations + seed
supabase migration new <name>        # new migration file
supabase test db                     # run pgTAP tests
supabase gen types typescript --local > packages/db/src/types.ts
```

---

## Hard rules

1. **Schema changes only via migrations.** Never change a hosted database by hand, never edit a merged migration. After every migration: regenerate types, run `supabase db reset` and `supabase test db`.
2. **Never touch prod from Claude Code.** No prod connection strings or service-role keys in this environment. If a task seems to need prod access, stop and ask.
3. **Every table that holds data about organizations, people or interactions has RLS enabled with explicit policies, and gets its visibility from a `tier`.** Main tables have their own `tier` column; child tables (e.g. `person_emails`, `consents`) have none and inherit visibility from their parent row. See "Child tables" in `docs/DATA_MODEL.md`. No table ships without a pgTAP test proving each role sees exactly what it should. See "Access model" in `docs/DATA_MODEL.md`.
4. **`interactions` is append-only.** No UPDATE or DELETE for app roles. Corrections are new rows. The only exception is the GDPR erasure function, which redacts.
5. **Imports always go through staging.** Raw source data → `staging.raw_records` → matching → review → canonical tables + `external_ids`. Importers must be idempotent: running one twice changes nothing.
6. **AI never writes directly to canonical data.** Claude extractions land as `review_state = 'proposed'` and only become effective after a human approves them.
7. **No real personal data in the repo.** Seed data, fixtures, tests, logs and example payloads use invented people and companies only. Never log email bodies or personal data in plain text.
8. **Secrets** live in `.env.local` (git-ignored) and in Vercel/Supabase settings. The service-role key is used only in server-side code (edge functions, server actions, importers), never shipped to the browser.
9. **Background-check data** (later module) lives in its own `screening` schema with stricter policies and a retention period. Never join it into general views, never expose it via the MCP server.
10. **Ask before** adding a new external service, a paid dependency, or anything that sends email to real recipients.

## Conventions

- Postgres: `snake_case`, `uuid` primary keys (`gen_random_uuid()`), `timestamptz` everywhere, `created_at`/`updated_at` on every table, emails as `citext`, domains stored lowercase without `www.`.
- Countries as ISO 3166-1 alpha-2 codes (`UA`, `DE`, `SI`, …). Money as `numeric` plus a currency code, with an EUR-normalized column for filtering.
- Enums as Postgres enums only when the set is truly stable; otherwise lookup tables.
- jsonb payloads have a matching zod schema in `packages/db` and are validated before insert.
- TypeScript strict mode. Server actions or route handlers for writes; no direct table writes from client components.
- Prefer boring, readable SQL views over complex app-side logic for "current state" questions.

## Writing and email copy

- All UI text, docs and email copy use **American English** (e.g. "organize", "defense"; dates like "August 20–23").
- Written materials use the full name **"Benjamin Wolba"**. Emails sign off with just **"Benjamin"**.
- Check-in emails are short, near-plain text, sent from a person, with a working `List-Unsubscribe` header and a one-click opt-out.
- Links in emails are clean, direct URLs.

## How to work in this repo

- For anything bigger than a small fix: propose a plan first, then implement in small steps that each leave `supabase db reset`, tests and the build green.
- When a decision is made (a new table, a changed definition, a tradeoff), append a dated entry to `docs/DECISIONS.md` and update `docs/DATA_MODEL.md` or `docs/PLAN.md` if they are affected. The docs are the project's memory between sessions.
- When something in these docs is ambiguous or contradicts the code, ask rather than guess.
