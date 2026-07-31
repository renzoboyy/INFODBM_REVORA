# Revora

Integrated relational database platform for verified material exchange —
registration, government-ID/TIN verification, admin approval workflow, and
branch closure, built on SQL Server + a thin Node/Express API + static
HTML/JS front ends.

This README takes you from a fresh clone on a machine with **no existing
`INFODBM_REVORA` database** to a fully running app. The scripts in `db/`
build the database from scratch, including the full security layer (roles,
permission grants, dynamic data masking) and the login/password the app
itself connects with.

## 1. Prerequisites

- Node.js 18+ and npm
- A SQL Server instance you can connect to as a sysadmin (SSMS or `sqlcmd`)
- **Mixed Mode authentication** enabled on the instance (SQL Server logins,
  not just Windows auth) — the app connects via a SQL login, not Windows
  Integrated Auth
- **TCP/IP enabled** on the SQL Server instance. Named instances (e.g.
  `localhost\INFODBMSERVER`) usually have TCP/IP **disabled by default**,
  which breaks Node's driver even though SSMS still connects fine over
  Named Pipes/Shared Memory. To enable it:
  1. Open **SQL Server Configuration Manager** → **SQL Server Network
     Configuration** → **Protocols for `<your instance>`**.
  2. Right-click **TCP/IP** → **Enable**.
  3. Double-click **TCP/IP** → **IP Addresses** tab → scroll to **IPAll** →
     clear **TCP Dynamic Ports**, set **TCP Port** to a free port (e.g.
     `1435`).
  4. Restart the SQL Server service for that instance.

## 2. Clone and install

```powershell
git clone <this-repo-url>
cd INFODBM_REVORA
npm install
```

## 3. Build the database from scratch

Run the scripts in `db/` **in this exact order**, against your instance.
Each one is layered on top of the previous, and `05`/`06` explicitly depend
on the ones before them.

```powershell
sqlcmd -S "<your-server>\<your-instance>" -E -C -i "db\01_schema_v3.sql"
sqlcmd -S "<your-server>\<your-instance>" -E -C -i "db\02_lookups_v3.sql"
sqlcmd -S "<your-server>\<your-instance>" -E -C -i "db\03_additional_objects_v3.sql"
sqlcmd -S "<your-server>\<your-instance>" -E -C -i "db\04_indexes_and_views_v3.sql"
sqlcmd -S "<your-server>\<your-instance>" -E -C -i "db\05_security_v3.sql"
sqlcmd -S "<your-server>\<your-instance>" -E -C -i "db\06_profile_edit_workflow_v3.sql"
```

**Run all six with `-E` (Windows auth), every time — not just for `01`.**
`05_security_v3.sql` runs `CREATE LOGIN` at the *server* level, which
requires sysadmin. If you re-run `05` later under a login that only has
`db_owner` inside `INFODBM_REVORA` (e.g. `revora_admin`), `CREATE LOGIN`
fails with "User does not have permission to perform this action" for any
login that doesn't already exist yet — and does so *silently* per-batch
under `sqlcmd`, so it's easy to not notice. `db_owner` is sufficient for
`CREATE USER`/grants inside the database, just not for the server-level
login itself. Substitute `-U -P` for SQL auth (with a sysadmin login) if
you're not using Windows auth.

- **`02_lookups_v3.sql` is required, not optional** — unlike `02_seed_v2.sql`
  (sample business records, safe to skip), this one loads static reference
  data (`Roles`, `Categories`, `AccountStatus`, `Sectors`) that
  `GET /api/lookups` and `sp_RegisterUser`'s foreign keys need to function
  at all. Skipping it leaves those four tables empty and registration will
  fail outright.
- **`01_schema_v3.sql` DROPS and RECREATES `INFODBM_REVORA`** if it already
  exists on that instance. Don't point this at a database you care about.
  Re-running it also wipes the lookup data from `02_lookups_v3.sql`, so
  re-run `02` again afterward.
- All scripts are idempotent (each object is dropped/recreated or
  existence-checked, and `02`'s inserts are guarded by `IF NOT EXISTS`), so
  re-running any of them after a pull is safe.

### v3: Address+Branches merged, geography hierarchy added

`01_schema_v3.sql` replaces the old flat `Address`/`Branches` tables with one
merged `Address` table plus a normalized geography hierarchy
(`Region → Province → CityMunicipality → Barangay`, with `Barangay` carrying
`PostalCode`). `Branch` is now a thin record (`BranchID` + `AddressID`);
**`BranchCode` is removed** — `BranchID` was already the unique, system-issued
identifier for a branch, so `BranchCode` was a redundant second one.
`UK_Password` and the old `UK_Address` constraint are also dropped (password
uniqueness was an information leak; addresses are now legitimately shared
across records).

The registration/profile-edit UI still only collects
`DetailedAddress`/`City`/`Province`/`PostalCode` (no Barangay/Region field
exists yet), so `sp_RegisterUser` resolves Barangay/Region to a placeholder
`'Unspecified'` row internally via a new `sp_ResolveAddress` helper — no
front-end changes were needed to adopt the new schema. Add real Barangay/
Region inputs to `registrant.html` whenever that data actually needs to be
captured; the schema doesn't need to change again for that, only the values
passed in.

### What `05_security_v3.sql` creates

This is the security layer from the lab exercise, adapted to Revora's
actual access model. It creates three SQL Server logins + matching DB
users, each scoped to a different consumer:

| Login           | Password              | Role                                             |
|-----------------|------------------------|---------------------------------------------------|
| `revora_admin`  | `R3v0ra@Admin#2025!`  | `db_owner` + `UNMASK` — full control              |
| `revora_staff`  | `R3v0ra@Staff#2025!`  | read + approval/rejection SPs only               |
| `revora_api`    | `R3v0ra@Api#2025!`    | read + write via SPs only, no DELETE, no DDL      |

It also applies Dynamic Data Masking to `Users.Email`, `Users.PhoneNumber`,
and `GID.GovtNo` — `revora_staff`/`revora_api` see masked values, only
`revora_admin` sees real ones.

`revora_staff` and `revora_api` are intentionally narrow and don't overlap
(e.g. only `revora_api` can execute `sp_RegisterUser`/`sp_RequestProfileEdit`,
only `revora_staff` can execute `ApproveUserAccount`/`sp_RejectRegistrant`/
`sp_ApproveProfileEdit`/`sp_RejectProfileEdit`). The Node
app in this repo is a single process sharing one connection pool across
*all* of those routes, so **it must connect as `revora_admin`** — no single
scoped login covers everything the app calls end to end.

## 4. Configure environment variables

```powershell
Copy-Item .env.example .env
```

```
DB_SERVER=localhost
DB_PORT=1435
DB_DATABASE=INFODBM_REVORA
DB_USER=revora_admin
DB_PASS=R3v0ra@Admin#2025!
PORT=3000
```

- `DB_SERVER` / `DB_PORT`: for a **named instance**, do *not* use the
  `server\instance` syntax here — set `DB_SERVER` to the host only and
  `DB_PORT` to the static TCP port you configured in step 1. For a
  **default instance** (`MSSQLSERVER`), `DB_PORT` is normally `1433`.
- `.env` is gitignored — it's still worth changing `revora_admin`'s
  password on any instance that isn't purely local/disposable, since the
  value above is the literal one baked into `05_security_v3.sql`.

## 5. Run it

```powershell
npm start
```

You should see:

```
REVORA server running at http://localhost:3000
Connected to INFODBM_REVORA
```

Open:
- `http://localhost:3000/registrant.html` — registration portal (individual
  or entity, mobile-first form)
- `http://localhost:3000/login.html` — account login
- `http://localhost:3000/dashboard.html` — logged-in user dashboard /
  self-service profile edit requests
- `http://localhost:3000/admin.html` — admin dashboard: onboarding
  analytics, pending queue with SLA flags, per-applicant review modal
  (approve/reject with notes), applicant directory search, and branch
  closure

## Project layout

```
db/
  01_schema_v3.sql              full schema (merged Address/Branch + geography hierarchy) - BUILD FIRST
  02_seed_v2.sql                sample seed data (v2 schema, not yet ported) - reference only
  03_additional_objects_v3.sql  views/procs/function the app needs, incl. sp_ResolveAddress
  04_indexes_and_views_v3.sql   performance indexes + vw_PendingQueue
  05_security_v3.sql            logins/users/roles/DDM - creates the login the app uses
  06_profile_edit_workflow_v3.sql  self-service profile edit -> re-approval workflow
  *_v2.sql                      superseded schema (flat Address/Branches, BranchCode) - kept for history
server/
  db.js                         mssql connection pool (reads .env)
  server.js                     Express app, static file serving
  routes/
    lookups.js                  GET /api/lookups (roles, categories, sectors, statuses, govt ID types)
    registration.js             POST /api/register
    search.js                   GET /api/search (directory search/filter)
    admin.js                    queue, analytics, review, approve/reject, branch closure
    auth.js                     POST /api/login
    profile.js                  self-service profile edit request + status check
public/
  registrant.html / admin.html / login.html / dashboard.html   front ends
  js/app.js                     shared client-side logic
  css/style.css
```

## Troubleshooting

- **"Could not find stored procedure ..."** — you skipped one of steps in
  section 3, or ran them out of order (`06` depends on `05`, which depends
  on `03`/`04`, which depend on `01`).
- **"Login failed for user 'revora_admin'"** — you skipped `05_security_v3.sql`,
  or `DB_PASS` doesn't match the password printed by that script.
- **Node can't connect but SSMS can** — TCP/IP is almost certainly disabled
  on the instance (step 1), or `DB_PORT` doesn't match the instance's
  configured static port.
- **"UPDATE failed because ... QUOTED_IDENTIFIER ..."** — an object was
  created outside of these scripts under a session with `QUOTED_IDENTIFIER
  OFF`. Re-run `03_additional_objects_v3.sql` as-is (it sets the correct
  session options before creating anything).
- **"Violation of UNIQUE KEY constraint 'UK_..._Username/Email/PhoneNumber'"**
  — a registrant reused a value that must be unique across all `Users`; have
  them pick a different one. (v3 dropped the old `UK_Password` constraint,
  so identical passwords across accounts no longer error — see the v3 note
  above on why that was an information leak.)
</content>
