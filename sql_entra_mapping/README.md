# SQL_Remap_EntraLogin.ps1

Rebuilds a Windows SQL Server login after a **Hybrid AD → Entra ID migration**, picks up the new Entra SID, and re-links every orphaned database user — without touching their role memberships or grants.

---

## The Problem

When a machine moves from Hybrid AD to Entra ID, the SID for every Windows account changes. SQL Server stores login SIDs at creation time and has no `ALTER LOGIN ... WITH SID` command, so the only fix is to drop and recreate the login. Recreating it causes every database user that was mapped to the old SID to become orphaned. This script handles the full chain automatically:

1. Captures all state (roles, permissions, owned databases, database user mappings)
2. Writes a JSON backup and a runnable recovery `.sql` before touching anything
3. Drops the login
4. Recreates it from Windows (picks up the new Entra SID automatically)
5. Restores server roles and explicit permissions
6. Re-links every orphaned database user with `ALTER USER ... WITH LOGIN` (preserves all role memberships and grants)
7. Restores database ownership
8. Verifies no orphans remain

---

## Requirements

- **PowerShell 5.1+**, run **elevated**
- **SqlServer module**: `Install-Module SqlServer -Scope CurrentUser -AllowClobber`
- The account running the script must be a **SQL Server sysadmin** (but must not be the login being rebuilt — or use `-Force`)
- For bootstrap mode: the account must also be a **local Windows administrator** on the SQL Server machine
- Run **after** the workstation has migrated and the account resolves to the new Entra SID  
  Verify with: `whoami /user`

---

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-LoginName` | Current user (`whoami`) | The Windows login to rebuild, e.g. `DOMAIN\username` |
| `-SqlInstance` | `localhost` | Target SQL Server instance |
| `-HoldingOwner` | `sa` | Temporary owner for databases during the rebuild |
| `-DryRun` | — | Scan and print the plan with generated T-SQL. No changes made; backup files are still written |
| `-Force` | — | Skip the confirmation prompt and bypass the self-rebuild safety check |
| `-Bootstrap` | Auto-detected | Emergency mode for total lockout — see below |
| `-LogDirectory` | `%USERPROFILE%\SqlLoginRebuild` | Where transcript, JSON backup, and recovery `.sql` are written |

---

## Usage

**Fix your own login (most common post-migration case):**
```powershell
.\SQL_Remap_EntraLogin.ps1
```
No arguments needed — the script defaults `LoginName` to the current user via `whoami`.

**Fix a specific login:**
```powershell
.\SQL_Remap_EntraLogin.ps1 -LoginName 'DOMAIN\username'
```

**Dry run — see what would happen without making changes:**
```powershell
.\SQL_Remap_EntraLogin.ps1 -LoginName 'DOMAIN\username' -DryRun
```

**Skip confirmation prompt (scripted/unattended use):**
```powershell
.\SQL_Remap_EntraLogin.ps1 -LoginName 'DOMAIN\username' -Force
```

**Remote SQL instance:**
```powershell
.\SQL_Remap_EntraLogin.ps1 -LoginName 'DOMAIN\username' -SqlInstance 'SQLSERVER01\PROD'
```

---

## Execution Flow

```
START
  │
  ├─[Connection probe]──────────────────────────────────────────────────────────
  │   Try: SELECT 1
  │   Success ──────────────────────────────────────────────────► continue normally
  │   Fail (18456 / 18452 / Login failed) ──────────────────────► auto-enable Bootstrap
  │   Fail (any other error) ───────────────────────────────────► throw, do not bootstrap
  │
  ├─[Bootstrap] (if needed) ────────────────────────────────────────────────────
  │   1. Stop SQL Agent          (prevents it stealing the single connection slot)
  │   2. Stop SQL Server service
  │   3. Add SQLArgN = -m        (registry: locate params key, find next free slot)
  │   4. Start SQL Server        (single-user mode, local admins get sysadmin)
  │   5. Wait for sqlcmd.exe to connect (polls every 4 s, 90 s timeout)
  │   6. sqlcmd.exe ──► CREATE LOGIN [BUILTIN\Administrators] FROM WINDOWS
  │                      ALTER SERVER ROLE [sysadmin] ADD MEMBER [BUILTIN\Administrators]
  │   7. Stop SQL Server
  │   8. Remove SQLArgN = -m     (registry cleanup)
  │   9. Start SQL Server        (normal multi-user mode)
  │  10. Wait for sqlcmd.exe to connect (polls every 4 s, 90 s timeout)
  │       ► SQL is now running normally with BUILTIN\Administrators as sysadmin
  │
  ├─[Pre-flight]────────────────────────────────────────────────────────────────
  │   SELECT SUSER_SNAME(), ORIGINAL_LOGIN(), SERVERPROPERTY('ProductVersion')
  │   Guard: refuse to rebuild the connected login unless -Force or -Bootstrap
  │
  ├─[Step 1 — Validate login]───────────────────────────────────────────────────
  │   READ  sys.server_principals
  │         WHERE name = @LoginName AND type IN ('U','G','S')
  │   Captures: type, is_disabled, default_database_name,
  │             default_language_name, sid (stored as old SID hex)
  │   Guard: abort if type = 'S' (SQL login — SID remap does not apply)
  │
  ├─[Step 2 — Capture server roles]─────────────────────────────────────────────
  │   READ  sys.server_role_members
  │         JOIN sys.server_principals (role + member)
  │         WHERE member.name = @LoginName
  │
  ├─[Step 2 — Capture server permissions]───────────────────────────────────────
  │   READ  sys.server_permissions
  │         JOIN sys.server_principals
  │         WHERE grantee = @LoginName AND class = 100 (server scope)
  │   Captures: state_desc (GRANT / GRANT_WITH_GRANT / DENY), permission_name
  │
  ├─[Step 3 — Scan all online databases]────────────────────────────────────────
  │   READ  sys.databases WHERE state_desc = 'ONLINE' AND name <> 'tempdb'
  │   For each database:
  │     READ  sys.database_principals WHERE sid = @oldSid AND name <> 'dbo'
  │     For each matched user:
  │       READ  sys.database_role_members
  │             JOIN sys.database_principals (role + member)
  │             WHERE member.name = @user
  │     ► Builds list of {Database, User, Roles} — these will orphan after DROP LOGIN
  │     ► dbo is excluded here; handled by database ownership reassignment
  │
  ├─[Step 4 — Find owned databases]─────────────────────────────────────────────
  │   READ  sys.databases WHERE owner_sid = @oldSid
  │
  ├─[Step 5 — Write backup files]───────────────────────────────────────────────
  │   Write state_*.json    (full captured state — roles, SID, permissions, mappings)
  │   Write recovery_*.sql  (runnable T-SQL to finish manually if interrupted)
  │   ◄ NO SQL CHANGES HAVE BEEN MADE YET ►
  │
  ├─[Step 6 — Show plan + confirmation gate]────────────────────────────────────
  │   ─DryRun? ──► print plan, exit (no changes)
  │   ─Force?  ──► skip confirmation prompt
  │   Otherwise ──► prompt: type the login name to confirm
  │
  ├─[Phase A — Reassign database ownership to holding owner]────────────────────
  │   For each owned database:
  │     WRITE  ALTER AUTHORIZATION ON DATABASE::[db] TO [HoldingOwner]
  │   Rollback: on any failure, re-run ALTER AUTHORIZATION back to original login
  │             and abort before DROP LOGIN
  │
  ├─[Phase B — Drop the login] ◄ POINT OF NO RETURN ►──────────────────────────
  │   WRITE  DROP LOGIN [LoginName]
  │          ► All database users mapped to the old SID are now orphaned
  │
  ├─[Phase C — Recreate with new Entra SID]─────────────────────────────────────
  │   WRITE  CREATE LOGIN [LoginName] FROM WINDOWS
  │             WITH DEFAULT_DATABASE=[...], DEFAULT_LANGUAGE=[...]
  │          ► No SID specified — SQL Server resolves it from the OS right now,
  │            picking up the new Entra SID automatically
  │   WRITE  ALTER LOGIN [LoginName] DISABLE        (if originally disabled)
  │   WRITE  ALTER SERVER ROLE [role] ADD MEMBER [LoginName]   (per captured role)
  │   WRITE  GRANT / DENY [permission] TO [LoginName]          (per captured perm)
  │
  ├─[Phase D — Re-link orphaned database users]─────────────────────────────────
  │   For each {Database, User} captured in Step 3:
  │     WRITE  USE [Database]
  │            ALTER USER [User] WITH LOGIN = [LoginName]
  │            ► Re-binds the existing user to the login's new SID
  │            ► Role memberships and grants inside the database are PRESERVED
  │
  ├─[Phase E — Restore database ownership]──────────────────────────────────────
  │   For each previously owned database:
  │     WRITE  ALTER AUTHORIZATION ON DATABASE::[db] TO [LoginName]
  │
  └─[Step 9 — Verify]───────────────────────────────────────────────────────────
      For each database that had a mapped user:
        READ  sys.database_principals dp
              LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
              WHERE dp.name = @LoginName AND sp.sid IS NULL
      ► Reports any users still orphaned after the rebuild
```

---

## SQL Server Objects Read

| Object | Scope | What is read |
|---|---|---|
| `sys.server_principals` | Instance | Login type, SID, disabled state, default DB/language |
| `sys.server_role_members` | Instance | Which server roles the login belongs to |
| `sys.server_permissions` | Instance | Explicit GRANT/DENY permissions at server scope |
| `sys.databases` | Instance | All online databases; databases owned by the login |
| `sys.database_principals` | Per database | Users whose SID matches the old login SID |
| `sys.database_role_members` | Per database | Role memberships of matched users (audit only) |

---

## SQL Statements Written

| Phase | Statement | Purpose |
|---|---|---|
| A | `ALTER AUTHORIZATION ON DATABASE::[db] TO [sa]` | Move ownership off the login before dropping it |
| B | `DROP LOGIN [LoginName]` | Remove the stale SID — **point of no return** |
| C | `CREATE LOGIN [LoginName] FROM WINDOWS WITH DEFAULT_DATABASE=..., DEFAULT_LANGUAGE=...` | Recreate — OS resolves the account to the new Entra SID at this moment |
| C | `ALTER LOGIN [LoginName] DISABLE` | Restore disabled state if the login was originally disabled |
| C | `ALTER SERVER ROLE [role] ADD MEMBER [LoginName]` | Restore each server role membership |
| C | `GRANT [permission] TO [LoginName]` | Restore each explicit server permission |
| C | `GRANT [permission] TO [LoginName] WITH GRANT OPTION` | Restore grant-with-grant permissions |
| C | `DENY [permission] TO [LoginName]` | Restore each explicit server deny |
| D | `ALTER USER [user] WITH LOGIN = [LoginName]` | Re-bind the database user to the login's new SID |
| E | `ALTER AUTHORIZATION ON DATABASE::[db] TO [LoginName]` | Restore database ownership |

---

## What the Script Does NOT Change

- Database users are **never dropped or recreated** — only re-bound with `ALTER USER ... WITH LOGIN`
- Database role memberships inside each database are **untouched** — `ALTER USER WITH LOGIN` preserves them automatically
- Explicit grants and denies inside each database are **untouched**
- Schema ownership inside databases is **untouched**
- The login's default database and language are **restored exactly** as captured
- SQL logins are **refused entirely** — the script will not touch a SQL auth login

---

## Bootstrap Mode (Total Lockout Recovery)

If **all** Windows logins on the instance are broken and nobody can connect at all, the script detects the authentication failure automatically and enters bootstrap mode.

Bootstrap mode:
1. Stops SQL Agent (prevents it stealing the single-user connection slot)
2. Stops SQL Server
3. Injects `-m` into the service startup parameters
4. Starts SQL Server in single-user mode
5. Grants `BUILTIN\Administrators` sysadmin via a single `sqlcmd.exe` call
6. Removes `-m`, restarts SQL Server normally
7. Proceeds with the full login rebuild as normal

Auto-detection only triggers on login authentication failures (SQL Server error 18456/18452). Network errors, wrong instance names, and planned maintenance outages are not treated as bootstrap conditions.

> **After bootstrap completes**, the `BUILTIN\Administrators` sysadmin login is left in place intentionally. The exact cleanup command is shown in the result summary and written to the recovery `.sql`:
> ```sql
> DROP LOGIN [BUILTIN\Administrators];
> ```
> Run this once access is fully confirmed restored.

Bootstrap can also be forced explicitly:
```powershell
.\SQL_Remap_EntraLogin.ps1 -LoginName 'DOMAIN\username' -Bootstrap -Force
```

**Bootstrap requirements:**
- Must run **elevated** on the SQL Server machine (or with remote service management rights)
- Must be a **local administrator** on that machine
- Must have rights to stop/start the SQL Server service

---

## Output Files

All written to `-LogDirectory` (default `%USERPROFILE%\SqlLoginRebuild`), stamped with the login name and timestamp:

| File | Purpose |
|---|---|
| `transcript_*.txt` | Full PowerShell transcript of the run |
| `state_*.json` | Complete captured state — login type, SID, roles, permissions, mapped users, owned databases |
| `recovery_*.sql` | Runnable T-SQL to finish manually if the script is interrupted after `DROP LOGIN` |

The backup and recovery files are written **before any changes are made**.

---

## How Orphaned Users Are Re-linked

The script uses `ALTER USER [name] WITH LOGIN = [name]` — **not** `DROP/CREATE USER`. This re-binds the existing database user to the login's new SID and preserves all role memberships and explicit grants. Dropping and recreating the user would wipe permissions.

---

## Safety Notes

- The script refuses to rebuild the login it is currently connected as, unless `-Force` or `-Bootstrap` is used
- A full state backup and recovery script are always written before any destructive operation
- Database ownership is reassigned to a holding owner (`sa` by default) before the login is dropped, and restored immediately after recreation
- If ownership reassignment fails for any database, the script rolls back all ownership changes and aborts before `DROP LOGIN`
