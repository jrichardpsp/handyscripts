# supress_esp

Suppresses the user-phase Enrollment Status Page (ESP) on PPKG-enrolled devices, so users are not held at the "Preparing your device" screen after sign-in.

## What it does

1. Polls `HKLM:\SOFTWARE\Microsoft\Enrollments` (up to 15 minutes, every 10 seconds) for an active MDM enrollment - a GUID subkey with `ProviderID = MS DM Server` and `EnrollmentState = 1`.
2. Creates the `FirstSync` subkey under that enrollment if it does not exist.
3. Sets `SkipUserStatusPage` and `SkipDeviceStatusPage` to `0xFFFFFFFF` (DWORD -1), which tells Windows to skip both ESP phases.
4. Prints the enrollment GUID and the resulting values for verification.

Exits with code 1 if no matching enrollment appears before the timeout.

## Requirements

- Run as SYSTEM (writes to HKLM).
- Windows PowerShell 5.1, no external modules, ASCII-only source.

## Files

- `supress_esp.ps1` - the script.
- `cmdline.cmd` - launcher used by PSP; runs the script with `-ExecutionPolicy Bypass`.
- `supress_esp.zip` - PSP completion script package (both files at the zip root).

## Deployment

Upload `supress_esp.zip` as a completion script in PSP, so it runs after migration when the device is joined to the target Entra tenant but before the user signs in for the first time. That is the window where the ESP skip flags must be written: the MDM enrollment exists (or appears shortly), and the user-phase ESP has not yet been triggered by a first sign-in.

PSP extracts the package and runs `cmdline.cmd`, which waits for the script to finish. If the device's MDM enrollment has not finished registering when the script starts, the poll loop covers it; on a device that never enrolls, the script holds for the full 15-minute timeout before failing.
