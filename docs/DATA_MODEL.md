# EDTH App — Data Model

This is the target schema for phase 1, designed so later modules (sales, network intros, field testing,
background checks, EDTH Intelligence) fit without restructuring. Column lists are the intended shape;
refine types and constraints in migrations and record changes in `docs/DECISIONS.md`.

## Core principles

1. **One graph.** Every company, team, investor, prime, NGO, military unit, university or agency is an
   `organization`. Being an alumnus, sponsor, investor or prospect is a **role** (`org_roles`), not a separate table.
2. **Raw events vs. current state.** `interactions` stores everything that happened (append-only).
   `signals` stores facts derived from interactions, each with a date and a source. "Current state" is a
   **view** over the latest approved, non-superseded signals. Never overwrite history.
3. **Provenance everywhere.** Derived data points back to the interaction it came from.
4. **Tiered access in the database.** Every data row has a `tier`; RLS enforces who sees it.
5. **Idempotent imports.** `external_ids` maps source records to canonical entities.

All tables: `id uuid primary key default gen_random_uuid()`, `created_at timestamptz default now()`,
`updated_at timestamptz` (trigger-maintained), and `created_by uuid` (references `app_users`) where a human creates rows.

---

## Access model

### Tiers (`tier` enum)

Mirrors EDTH's information-handling policy:

| Tier | Meaning | Visible to |
|---|---|---|
| `open` | Shareable with collaborators | `friends`, `team`, `core`, `admin` |
| `internal` | EDTH team only | `team`, `core`, `admin` |
| `sensitive` | Core team only | `core`, `admin` |
| `confidential` | Need-to-know | `admin` + users with an explicit grant in `record_grants` |

Default tier for new rows: `internal`. Military contacts and anything about them default to `confidential`.

### Roles (`app_role` enum), stored in `app_users`

- `admin` — EDTH founders; see everything.
- `core` — payroll staff whose main project is EDTH.
- `team` — everyone on payroll, including freelancers and working students.
- `friends` — collaborators with limited access (not used in phase 1).
- `external` — reserved for EDTH Intelligence users (later; separate policies, consent-gated views only).

### Tables

- **app_users**: `user_id` (primary key, → `auth.users`, i.e. `auth.uid()`), `email citext`, `display_name`, `role app_role` (no default; set explicitly by an admin), `active bool`.
  No row or `active = false` means no access. Every user reference in the schema (`created_by`, `owner_user_id`, …) points to `app_users.user_id`.
- **record_grants**: `entity_type`, `entity_id`, `user_id`, `granted_by`, `reason` — need-to-know access to `confidential` rows.

### Helpers

- `auth_role()` → the current user's `app_role` (security definer, stable).
- `can_read(tier, entity_type, entity_id)` → bool, implementing the table above. `external` users always get false.
- `can_write(tier, entity_type, entity_id)` → bool: `team`, `core` or `admin`, and only rows the user can also read
  (so confidential rows need admin or a grant).
- Every RLS select policy is `using (can_read(tier, '<entity_type>', id))`; write policies use `can_write(...)`.
- `anon` (not logged in) has no privileges on any table in `public`.
- pgTAP tests create one user per role and assert visibility for one row per tier, for every table.

### Child tables

Some tables only hold details of a parent row. They have **no `tier` column** and inherit visibility
from their parent: a user can read (and, under the same rules, write) a child row exactly when they can read its parent.
A parent's tier change therefore applies to its children automatically, and the two can never drift apart.

| Child table | Inherits from |
|---|---|
| `person_emails` | `people` (via `person_id`) |
| `participation_members` | `participations` (via `participation_id`) |
| `challenges` | `events` (via `event_id`) |
| `consents` | `people` if `person_id` is set, otherwise `organizations` |
| `email_sends` | `people` (via `person_id`) |

Policies on child tables are `using (exists (select 1 from <parent> p where p.id = <fk>))`. That subquery
runs under the parent's RLS, so it only finds parents the user may see. pgTAP tests assert that a child row is visible to a role exactly
when its parent is, for a parent in each tier. A new table either gets its own `tier` or is added to this list.

---

## Entities

### organizations
| column | notes |
|---|---|
| `name` | display name |
| `legal_name` | nullable |
| `domain` | lowercase, no `www.`; unique when not null; main dedupe key |
| `kind` | `team`, `startup`, `investor`, `prime`, `sme`, `ngo`, `government`, `military`, `university`, `research`, `accelerator`, `media`, `other` |
| `country` | ISO alpha-2 |
| `city`, `website`, `linkedin_url`, `description` | |
| `merged_into` | uuid → organizations; set when a duplicate is merged (row kept, hidden from views) |
| `tier` | |

Status is **not** a column here. It comes from `signals` (see `org_current_state`).
A team that incorporates is updated from `kind = 'team'` to `kind = 'startup'` (log it as an interaction).

### people
`full_name`, `first_name`, `last_name`, `linkedin_url`, `country`, `merged_into`, `tier`.

### person_emails
`person_id`, `email citext unique`, `is_primary bool`, `bounced_at`. Matching and inbound email routing use this table.

### affiliations
Person ↔ organization over time.
`person_id`, `org_id`, `title`, `relation` (`founder`, `team_member`, `employee`, `advisor`, `investor_partner`, `contact`),
`is_primary_contact bool`, `start_date`, `end_date`, `tier`.

### org_roles
`org_id`, `role` (`alumni`, `sponsor`, `partner`, `investor`, `prospect`, `customer`, `field_test_site`, `vendor`, `mentor_org`),
`since`, `until`, `notes`, `tier`. Unique on (`org_id`, `role`, `since`).
The `alumni` role is created automatically when a participation is added.

### events
`name`, `slug unique`, `kind` (`hackathon`, `online_hackathon`, `festival`, `field_testing`, `conference`, `meetup`, `workshop`),
`start_date`, `end_date`, `city`, `country`, `commonspace_audience_id`, `tier`.

### challenges
`event_id`, `name`, `description`, `sponsor_org_id` (nullable → organizations).

### participations
A team (organization) at an event.
`org_id`, `event_id`, `challenge_id` (nullable), `project_name`, `project_url`, `placement` (text, e.g. "1st", "finalist"), `notes`, `tier`.
Unique on (`org_id`, `event_id`).

### participation_members
`participation_id`, `person_id`, `role_in_team` (nullable).

---

## The check-in data

### interactions — append-only
Everything that happened.

| column | notes |
|---|---|
| `occurred_at` | |
| `channel` | `email_in`, `email_out`, `form`, `status_click`, `call`, `meeting`, `note`, `import`, `system` |
| `org_id`, `person_id` | nullable, at least one set |
| `subject`, `body_text` | |
| `raw` | jsonb (full webhook / form / import payload) |
| `source`, `source_ref` | e.g. `resend` + message id, `commonspace` + id |
| `email_send_id` | nullable → email_sends (which check-in this answers) |
| `tier` | |

No UPDATE/DELETE grants for app roles. GDPR erasure goes through a security-definer function
`erase_person(person_id)` that redacts personal fields and raw payloads and logs the erasure.

### signals
Point-in-time facts about an organization.

| column | notes |
|---|---|
| `org_id` | |
| `kind` | phase 1: `status`, `fundraising` |
| `data` | jsonb, validated by zod per kind (see below) |
| `observed_at` | when the fact was true / reported |
| `source_interaction_id` | → interactions |
| `review_state` | `proposed`, `approved`, `rejected` |
| `confidence` | numeric 0–1, for AI proposals |
| `superseded_by` | nullable → signals |
| `reviewed_by`, `reviewed_at` | |
| `tier` | |

Payloads:
- `status`: `{ "status": "building" | "incorporated" | "paused" | "stopped" | "acquired", "acquired_by_org_id"?: uuid, "note"?: string }`
- `fundraising`: `{ "state": "not_raising" | "planning" | "raising" | "closed", "stage"?: "pre_seed" | "seed" | "series_a" | "series_b_plus" | "grant" | "other", "target_amount"?: number, "currency"?: string, "target_amount_eur"?: number, "expected_close"?: date, "deck_file_id"?: uuid }`

Manual edits in the UI also create a `note` interaction plus an approved signal, so every value has a source.

Which `review_state` a new signal gets:

| Source | `review_state` |
|---|---|
| Claude extraction from a free-text reply | always `proposed` |
| Confirmed status click or form submission by a team member | `approved`, unless it conflicts |
| Manual edit in the UI by an EDTH user | `approved` |

**Conflict:** a signal of the same `kind` for the same `org_id`, from a different person, in the same check-in round
(same `email_sends.campaign`), with a different value (for `status`: a different `status`; for `fundraising`: a
different `state`). The new signal is created as `proposed` and the review queue shows it alongside the existing one.
The reviewer approves one; the other is rejected or superseded.

### intro_requests
Workflow objects, so they live in their own table (they have a lifecycle).

| column | notes |
|---|---|
| `requester_org_id`, `requester_person_id` | |
| `target_type` | `military`, `investor`, `customer`, `prime`, `government`, `field_test_site`, `research`, `other` |
| `target_country` | ISO alpha-2, nullable |
| `target_org_id` | nullable → organizations (when a specific org is known) |
| `target_detail` | free text, e.g. branch or unit |
| `context` | what they want and why |
| `status` | `proposed`, `open`, `in_progress`, `done`, `declined` |
| `owner_user_id` | |
| `source_interaction_id` | |
| `closed_at` | |
| `tier` | defaults to `confidential` when `target_type = 'military'` |

Designed to serve the network-intros and field-testing modules later without changes.

### files
`org_id`, `kind` (`deck`, `one_pager`, `other`), `storage_path` (Supabase Storage, private bucket), `filename`,
`mime_type`, `size_bytes`, `version int`, `source_interaction_id`, `tier`. Accessed only via signed, expiring URLs.

### consents
Latest row per (subject, purpose) wins.
`person_id` or `org_id`, `purpose` (`checkin_emails`, `share_with_investors`, `public_alumni_listing`, `marketing`),
`state` (`granted`, `denied`, `ask_each_time`), `recorded_at`, `source_interaction_id`.
Sending logic must check `checkin_emails`; EDTH Intelligence must check `share_with_investors`.

### email_sends
`campaign` (e.g. `baseline-2026-12`, `monthly-2027-01`), `person_id`, `org_id`, `resend_message_id`,
`token_hash` (magic link / one-click links; store the hash only), `token_expires_at`, `sent_at`, `status` (`queued`, `sent`, `bounced`, `complained`, `failed`).

### tasks
`title`, `org_id`, `person_id`, `intro_request_id`, `assignee_user_id`, `due_date`, `status` (`open`, `done`), `tier`.

### tags / entity_tags
`tags`: `name unique`, `category`. `entity_tags`: `tag_id`, `entity_type`, `entity_id`.
For free-form labels only. Anything you will filter on regularly (status, amounts, intro targets) is a structured field.

---

## Imports

### external_ids
`entity_type`, `entity_id`, `source` (`commonspace`, `attio`, `csv:<name>`, `luma`), `source_id`, `last_synced_at`.
Unique on (`source`, `entity_type`, `source_id`).

### staging schema
- `staging.import_batches`: `source`, `started_at`, `finished_at`, `stats jsonb`, `run_by`.
- `staging.raw_records`: `batch_id`, `source`, `source_type` (e.g. `team`, `person`, `company`), `source_id`, `payload jsonb`, `processed_at`.
- `staging.match_candidates`: `raw_record_id`, `entity_type`, `candidate_id`, `method` (`domain`, `email`, `trigram`, `ai`), `score`, `decision` (`pending`, `accept`, `reject`, `create_new`), `decided_by`, `decided_at`.

Flow: load raw → exact matches auto-accepted → everything else `pending` in the review queue → commit
creates or updates canonical rows and writes `external_ids`.

---

## Views (phase 1)

- **org_current_state**: per organization — latest approved `status` signal (or `unknown`), latest approved
  `fundraising` signal with its EUR amount and a **bucket** (`<1M`, `1–10M`, `10–100M`, `≥100M`),
  count of open intro requests, `last_checkin_at`, number of EDTH events attended, first and latest event date.
- **alumni_overview**: `org_current_state` limited to organizations with the `alumni` role, excluding merged rows.
  Backs the alumni table and the Excel export.
- **alumni_metrics**: total alumni teams, alumni companies, counts and shares for building / stopped / unknown,
  using the "continued building" definition in `docs/PLAN.md`.
- **open_intro_requests**: joined with requester and target, filterable by `target_type` and `target_country`.
- **review_queue**: union of proposed signals, proposed intro requests and pending match candidates.

Views are created `with (security_invoker = true)` so RLS from the underlying tables applies.

---

## Later modules (not built in phase 1, schema must not block them)

- **deals** (sales): `org_id`, `title`, `stage`, `value`, `currency`, `owner_user_id`, `expected_close`, `lost_reason`, plus `deal_events` for stage history.
- **Gmail / Calendar sync**: writes `email_in` / `email_out` / `meeting` rows into `interactions`, matched via `person_emails`.
- **screening** schema (background checks): separate tables, separate policies (admin and a dedicated screener role only), retention and deletion jobs, never exposed in general views or the MCP server.
- **EDTH Intelligence**: `external` role with dedicated views that only return organizations with `share_with_investors = granted` and only `open`-tier fields.
