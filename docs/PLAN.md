# EDTH App — Plan

## Why this exists

EDTH runs ~40 events a year (hackathons, festivals, field-testing days) and has built a large network of
alumni teams, investors, primes, government and military contacts, NGOs and partners. Today that knowledge
is spread across commonspace, Attio, spreadsheets and people's heads.

The EDTH App becomes **one data backend for all of it**, with an internal web app on top. It will
eventually replace Attio completely and power these modules:

1. **Alumni tracking** (phase 1, this plan): monthly check-ins with hackathon alumni.
2. **Network intros**: intros within the EDTH network (investors, military, primes, customers).
3. **Sales**: EDTH's own pipeline (sponsors, partners) — the Attio replacement.
4. **Field-testing intros**: matching teams with test sites and ranges.
5. **Background checks**: applicant screening for hackathons (isolated schema, strict access).
6. **EDTH Intelligence**: an external, consent-gated frontend for investors and companies ("Deal Room for Defense").

Events keep running on commonspace (events.eurodefense.tech). The app imports from it.

## Phase 1 goal: alumni tracking

Be able to answer, at any time and with up-to-date data:

- How many EDTH alumni companies do we have?
- How many continued building after their hackathon, and what share of the total is that?
- Who is fundraising right now, for how much, and where is their deck?
- Who needs intros to the military — filtered by country (e.g. Ukrainian, German, Slovenian)?
- Filter alumni by request type and size, e.g. "raising <€1M / €1–10M / €10–100M / ≥€100M".
- See how all of this changes over time.

### Definitions (keep in sync with DATA_MODEL.md)

- **Alumni team**: any team that took part in an EDTH hackathon. Each team is an organization with `kind = 'team'`.
- **Alumni company**: an alumni team that became a company (`kind = 'startup'`), or an existing startup that took part.
- **Continued building**: based only on the team's own latest answer (its latest approved `status` signal). `building`, `incorporated` or `acquired` count as building; `paused` or `stopped` count as not building. No time threshold since the hackathon.
- **Unknown is its own bucket.** A team that has never answered is `unknown`. Silence is not "stopped". Every share is reported as building / not building / unknown out of the total.

### Phase 1 non-goals

Sales pipeline, Gmail/calendar sync, the Attio cutover, background checks, any external-facing UI.
The schema must not block these, but none of them get built yet.

---

## Architecture (phase 1)

```
commonspace ──┐                                  ┌── Web app (app.eurodefense.tech)
Attio export ─┼─▶ staging ─▶ match ─▶ review ─▶  │   alumni table, company page,
CSV / sheets ─┘                          │       │   review queue, import, Excel export
                                         ▼       │
                                  Supabase Postgres ── MCP server (Claude queries)
                                         ▲
Resend outbound (monthly check-in) ──────┤
Resend inbound (replies) ─▶ Claude extraction ─▶ proposed signals ─▶ review queue
Magic-link form / one-click status links ┘
```

## The check-in loop

1. **Send.** A monthly email via Resend, from a person, near-plain text. It contains:
   - three status links: "Still building" / "Paused" / "Stopped",
   - a link to the magic-link form prefilled with what we already know (status, fundraising, intro needs, deck upload),
   - "Or just reply to this email",
   - a one-click opt-out and a `List-Unsubscribe` header.
2. **Receive.**
   - **Status links never record anything on open.** Corporate email scanners (e.g. Microsoft Defender) open every
     link in an email automatically. So a status link only opens a page showing the chosen answer with a
     **Confirm** button. Only pressing Confirm (a POST) records the answer.
   - **After confirming**, the same page shows the prefilled form to collect more (fundraising, intro needs, deck).
     The form is optional; the confirmed status counts on its own.
   - Confirmed clicks and form submissions write `interactions` and, being the team's own structured answers,
     create **approved** signals directly, unless they conflict (see Review).
   - Email replies arrive via the Resend inbound webhook and are stored as `interactions` (raw).
3. **Extract.** Claude turns free-text replies into proposed `signals`, `intro_requests`, `consents` and file links (`review_state = 'proposed'`).
4. **Review.** A human approves, edits or rejects proposals in the review queue. Only then do they affect current state.
   Two things go to review: everything Claude extracts from free-text replies, and **conflicting answers** — when
   members of the same team give different answers of the same kind (e.g. one says "Still building", another
   "Stopped") in the same check-in round. The conflicting answer lands as `proposed` and the queue shows it next
   to the other member's answer.
5. **Acknowledge.** An automatic short reply confirms receipt; intro requests create a task for whoever owns intros.

**Cadence.** The first email is a one-time **baseline** (slightly longer: current status, fundraising, needs,
consent questions). After that: monthly for the first 6 months after a hackathon and for anyone with an open
request or active raise; quarterly for everyone else.

**Consent questions in the baseline email** (so EDTH Intelligence later needs no re-consent campaign):

- Keep receiving check-ins? (yes / no)
- May we share your deck and fundraising status with vetted investors on an EDTH platform? (yes / no / ask me each time)
- May we list you publicly as an EDTH alumni company? (yes / no)

**Deliverability.** Send from a dedicated subdomain with SPF, DKIM and DMARC configured; warm up gradually;
monitor bounces and complaints.

---

## Import plan

Every source follows the same pipeline: **stage raw → match → review → commit + `external_ids`**.
Importers are idempotent and re-runnable.

Order:

1. **Canonical event list.** Every EDTH hackathon since the first one (Munich, June 2024): name, dates, city, country, challenges. Compiled manually as a CSV — this is the backbone everything hangs off.
2. **commonspace** (events since May 2026): teams, members, challenges, placements. Confirm API/token access with commonspace.
3. **"60 EDTH Alumni to Watch" list**: the best-curated set of known startups; seeds `kind = 'startup'` orgs.
4. **Attio full export via API**: companies, people, notes, lists, tags — alumni, investors, NGOs, sponsors, primes. This is also the first step of the Attio migration. Attio stays in use in parallel until the sales module exists.
5. **Older events** (before May 2026): spreadsheets and Luma exports, plus the EDTH Commons past-projects list.

Matching rules: exact domain match → exact email match → fuzzy name match (`pg_trgm`) with Claude-proposed
merges. Anything not exact goes to the review queue. New teams default to `status = unknown`.

---

## 4-week plan

### Week 1 — Foundation
- Repo, Supabase projects (local / staging / prod, Frankfurt), Vercel project, `app.eurodefense.tech`.
- Google SSO restricted to `@eurodefense.tech`; `app_users` with roles.
- Core schema per DATA_MODEL.md: app_users, record_grants, organizations, people, person_emails, affiliations, org_roles, events, challenges, participations, participation_members, interactions, signals, intro_requests, files, consents, email_sends, tags, tasks, external_ids, staging schema.
- RLS policies for all tiers + pgTAP tests. Fake seed data.
- **Done when:** `supabase db reset` + `supabase test db` pass; a test user of each role sees exactly the right rows.

### Week 2 — Imports
- Staging tables, matching (domain, email, trigram), review decisions.
- Importers: event-list CSV, commonspace, 60-alumni list, Attio export, generic CSV.
- Run all imports against **staging**, review matches. Benjamin then runs them on prod himself (Claude Code never touches prod).
- **Done when:** every known alumni team exists once, linked to its event(s); re-running any importer creates no duplicates.

### Week 3 — Web app + MCP
- Alumni table: filters (event, status, fundraising bucket, intro type, intro country, tags), saved views, Excel/CSV export of the filtered view.
- Company page: people, participations, timeline of interactions and signals, current fundraising, deck versions, open intro requests.
- Review queue: proposed signals and merge candidates.
- Import page: upload CSV, trigger commonspace sync, see what changed.
- MCP server (read-only, runs with the user's permissions) with tools for the phase 1 questions.
- **Done when:** every phase 1 question above is answerable in the UI or via MCP.

### Week 4 — Check-in loop
- Resend domain setup, email templates, send log, magic-link tokens, one-click status links, opt-out.
- Inbound webhook → interactions → Claude extraction → proposed signals → review queue.
- Auto-acknowledgment; tasks for intro requests.
- Test end-to-end with internal addresses, then a small pilot batch, then the **baseline email** to all alumni.
- **Done when:** the baseline is sent and replies flow into the review queue.

### Success metrics
- Share of alumni teams with a known status (target: >70% after baseline + one follow-up).
- Check-in response rate (target: 30–40%).
- Time from reply to approved data (target: < 1 week).

---

## After phase 1 (module roadmap)

1. **Network intros**: generalize `intro_requests` to any requester, add matching against the network graph.
2. **Sales / Attio cutover**: `deals` with stages, Gmail and Calendar sync via Google Workspace APIs, Attio import of notes and pipelines, one month of parallel running, then switch.
3. **Field-testing intros**: test sites as organizations with `org_roles = field_test_site`, requests via `intro_requests`.
4. **Background checks**: `screening` schema, own policies, retention and deletion, legal review first.
5. **EDTH Intelligence**: external users (investors, companies), consent-gated views enforced by RLS, deck sharing via signed URLs.

## Open decisions

- Who the check-in emails come from (Benjamin, or a community role address with a named person).
- Final wording of consent questions and the privacy notice (check what event registration terms already cover).
- Exact sending subdomain.
- Who reviews the queue weekly.
- How long to run Attio in parallel before cutover.
- Where to store deck files long-term (Supabase Storage by default).## Risks

- **Maintenance load**: one person maintains this. Keep scope tight; prefer views and generated code over custom UI.
- **Data leaks**: mitigated by tier-based RLS, tests, and never using the service-role key client-side.
- **Low response rates**: keep emails short, make one-click answers possible, send from a person.
- **Duplicate records**: mitigated by staging, `external_ids` and the review queue.
