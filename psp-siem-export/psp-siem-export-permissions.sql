-- ============================================================================
-- PSP Log Exporter: Least-Privilege SQL Principal
-- Run once as sysadmin on the SQL Server / SQL Express instance.
-- Works on SQL Server and SQL Server Express (all editions).
-- ============================================================================

-- STEP 1: Create the server-level login (choose ONE option)
-- -------------------------------------------------------

-- Option A: gMSA (recommended for production) -- trailing $ is required
-- CREATE LOGIN [DOMAIN\psp_siem_export$] FROM WINDOWS;

-- Option B: Windows domain service account
-- CREATE LOGIN [DOMAIN\psp_siem_export] FROM WINDOWS;

-- Option C: SQL authentication (only if Windows auth is unavailable)
--           Store the password in a secrets vault -- never hardcode it here.
-- CREATE LOGIN [psp_siem_export] WITH PASSWORD = N'<strong-password-from-vault>';


-- STEP 2: Map the login to a database user and grant SELECT on exactly three tables
-- ---------------------------------------------------------------------------------
USE [PowerSyncProDB];
GO

-- Adjust the login name below to match whichever option you chose in Step 1.
CREATE USER [psp_siem_export] FOR LOGIN [DOMAIN\psp_siem_export$];
GO

GRANT SELECT ON dbo.RunbookLogEntries TO [psp_siem_export];
GRANT SELECT ON dbo.Agents            TO [psp_siem_export];
GRANT SELECT ON dbo.Runbooks          TO [psp_siem_export];
GO

-- Belt-and-suspenders: explicit DENYs block even if the account later picks up
-- a role (e.g. db_datareader) via group membership.
DENY INSERT, UPDATE, DELETE ON dbo.RunbookLogEntries TO [psp_siem_export];
DENY INSERT, UPDATE, DELETE ON dbo.Agents            TO [psp_siem_export];
DENY INSERT, UPDATE, DELETE ON dbo.Runbooks          TO [psp_siem_export];
GO


-- STEP 3: Verify (impersonate the new user and confirm access boundaries)
-- -----------------------------------------------------------------------
-- EXECUTE AS USER = 'psp_siem_export';
--
-- SELECT TOP 1 Id FROM dbo.RunbookLogEntries;  -- must succeed
-- SELECT TOP 1 Id FROM dbo.Agents;             -- must succeed
-- SELECT TOP 1 Id FROM dbo.Runbooks;           -- must succeed
--
-- SELECT TOP 1 * FROM dbo.SomeOtherTable;      -- must fail (permission denied)
-- INSERT INTO dbo.RunbookLogEntries DEFAULT VALUES; -- must fail
--
-- REVERT;
GO


-- ============================================================================
-- OPTIONAL: SQL Agent job (full SQL Server only -- NOT available on Express)
-- On Express use Register-PSPLogExportTask.ps1 (Windows Task Scheduler) instead.
-- ============================================================================
/*
USE msdb;
GO

EXEC dbo.sp_add_job
    @job_name = N'PSPLogExport_Tenant1',
    @enabled  = 1,
    @description = N'Exports PSP RunbookLogEntries to NDJSON for SIEM ingestion.';

EXEC dbo.sp_add_jobstep
    @job_name           = N'PSPLogExport_Tenant1',
    @step_name          = N'Run exporter',
    @subsystem          = N'PowerShell',
    @command            = N'& "C:\PSPLogExport\psp-agentlogs-to-siem.ps1" -ConfigFile "C:\PSPLogExport\psp-siem-export.json"',
    @on_success_action  = 1,
    @on_fail_action     = 2;

EXEC dbo.sp_add_schedule
    @schedule_name        = N'Every5Min',
    @freq_type            = 4,
    @freq_interval        = 1,
    @freq_subday_type     = 4,
    @freq_subday_interval = 5,
    @active_start_time    = 0,
    @active_end_time      = 235959;

EXEC dbo.sp_attach_schedule
    @job_name      = N'PSPLogExport_Tenant1',
    @schedule_name = N'Every5Min';

EXEC dbo.sp_add_jobserver
    @job_name = N'PSPLogExport_Tenant1';
GO
*/
