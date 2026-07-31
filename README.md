# Revora

Integrated relational database platform for verified material exchange —
registration, government-ID/TIN verification, admin approval workflow, and
branch closure, built on SQL Server + a thin Node/Express API + static
HTML/JS front ends.

This README assumes you already have a SQL Server instance running with an
**`INFODBM_REVORA` database whose schema matches `db/01_schema_v2.sql`**
(the 10-table design: `Roles`, `Categories`, `AccountStatus`, `Sectors`,
`GID`, `Address`, `Branches`, `Entities`, `Users`, `AuditLog`, plus the
three `Users` triggers). You do **not** need to run `01_schema_v2.sql` or
`02_seed_v2.sql` — those are only for building the database from scratch.
You do still need to apply `db/03_additional_objects_v2.sql` (see step 4).

## 1. Prerequisites

- Node.js 18+ and npm
- SQL Server (SSMS or any client) with the `INFODBM_REVORA` database already
  created and reachable
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

## 3. Create a dedicated SQL login for the app

Run this against your instance (adjust the password):

```sql
USE [master];
CREATE LOGIN [revora_app] WITH PASSWORD = N'ChangeMe!123', CHECK_POLICY = ON,
    CHECK_EXPIRATION = OFF, DEFAULT_DATABASE = [INFODBM_REVORA];

USE [INFODBM_REVORA];
CREATE USER [revora_app] FOR LOGIN [revora_app];
ALTER ROLE db_datareader ADD MEMBER [revora_app];
ALTER ROLE db_datawriter ADD MEMBER [revora_app];
GRANT EXECUTE ON SCHEMA::dbo TO [revora_app];
```

## 4. Apply the additional database objects

The app depends on views, stored procedures, and a function that live on
top of the base schema (`ApproveUserAccount`, `sp_RejectRegistrant`,
`sp_RegisterUser`, `sp_CloseBranch`, `fn_SLAStatus`,
`vw_ApplicantDirectory`, `vw_ApplicantDetail`, `vw_PendingThenApproved`,
`vw_EntityBasedRegistrants`). Apply them once:

```powershell
sqlcmd -S "<your-server>\<your-instance>" -E -C -i "db\03_additional_objects_v2.sql"
```

(`-E` uses your current Windows login to run the script — that's separate
from the `revora_app` SQL login the *app* uses at runtime. Substitute
`-U -P` if you need SQL auth here instead.)

This script is idempotent — re-running it drops and recreates each object,
so it's safe to run again after pulling schema changes.

> **Note:** every object here is created with `SET QUOTED_IDENTIFIER ON`
> and `SET ANSI_NULLS ON` immediately beforehand. Those settings are baked
> into a procedure/view at the moment it's compiled — if your database's
> default differs and you hand-edit or re-create any of these objects
> outside this script, DML against `Users` may fail with an error about
> `QUOTED_IDENTIFIER`/filtered indexes.

## 5. Configure environment variables

Copy the example file and fill in your connection details:

```powershell
Copy-Item .env.example .env
```

```
DB_SERVER=localhost
DB_PORT=1435
DB_DATABASE=INFODBM_REVORA
DB_USER=revora_app
DB_PASS=ChangeMe!123
PORT=3000
```

- `DB_SERVER` / `DB_PORT`: for a **named instance**, do *not* use the
  `server\instance` syntax here — set `DB_SERVER` to the host only and
  `DB_PORT` to the static TCP port you configured in step 1. For a
  **default instance** (`MSSQLSERVER`), `DB_PORT` is normally `1433`.
- `.env` is gitignored — never commit real credentials.

## 6. Run it

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
- `http://localhost:3000/admin.html` — admin dashboard: onboarding
  analytics, pending queue with SLA flags, per-applicant review modal
  (approve/reject with notes), applicant directory search, and branch
  closure

## Project layout

```
db/
  01_schema_v2.sql              full schema (10 tables + triggers) - reference only
  02_seed_v2.sql                sample seed data - reference only
  03_additional_objects_v2.sql  views/procs/function the app needs - APPLY THIS
server/
  db.js                         mssql connection pool (reads .env)
  server.js                     Express app, static file serving
  routes/
    lookups.js                  GET /api/lookups (roles, categories, sectors, statuses, govt ID types)
    registration.js             POST /api/register
    search.js                   GET /api/search (directory search/filter)
    admin.js                    queue, analytics, review, approve/reject, TIN update, branch closure
public/
  registrant.html / admin.html  front ends
  js/app.js                     shared client-side logic
  css/style.css
```

## Troubleshooting

- **"Could not find stored procedure ..."** — you skipped step 4, or the
  `revora_app` login lacks `EXECUTE` on schema `dbo`.
- **Node can't connect but SSMS can** — TCP/IP is almost certainly disabled
  on the instance (step 1), or `DB_PORT` doesn't match the instance's
  configured static port.
- **"UPDATE failed because ... QUOTED_IDENTIFIER ..."** — an object was
  created outside of `03_additional_objects_v2.sql` under a session with
  `QUOTED_IDENTIFIER OFF`. Re-run `03_additional_objects_v2.sql` as-is (it
  sets the correct session options before creating anything).
- **"Violation of UNIQUE KEY constraint 'UK_Password'"** — two users
  registered with the identical plaintext password (the schema uniques the
  *hashed* password per `Users` design); have the registrant pick a
  different password.
