# Wingot
Automate Package and Deployment of Winget packages into MCM

Wingot downloads applications with winget and imports them into Configuration Manager for
enterprise deployment and monitoring. It's a simpler way to keep 3rd party apps up to date than
packaging each one by hand.

It's a single script with no modules to install alongside it. It needs:

- Windows PowerShell 5.1 or later
- winget 1.8 or later, on the machine that downloads
- The Configuration Manager console, on the machine that imports

## Setup

Edit `$Config` at the top of `wingot.ps1`: site code, site server, content library path,
distribution point groups, and the winget package IDs to process.

To keep your settings out of the script, put any of the same keys in a `wingot.config.psd1`
beside it instead (or point `-ConfigPath` at one). It's then safe to replace the script with a
newer version without losing them:

```powershell
@{
    MCMSiteCode = "PS1"
    MCMPrimarySiteServer = "cm01.example.com"
    MCMApplicationLibraryLocation = "\\cm01\Sources\Apps"
    DPGroups = @("All DPs")
    Apps = @(
        "DominikReichl.KeePass"
        "Notepad++.Notepad++"
    )
}
```

## Usage

Download and import everything in the configuration:

```powershell
.\wingot.ps1
```

Download on one machine and import on another, in case your MCM server doesn't have open
internet access. Copy the `Wingot_Downloads` folder between the two:

```powershell
.\wingot.ps1 -DownloadOnly
.\wingot.ps1 -MCMImportOnly -ImportContentPath D:\Wingot_Downloads
```

Other options:

| Parameter | |
| --- | --- |
| `-AppId` | Process these winget IDs instead of the configured list. |
| `-MakeTaskSequence` | Also add every imported app to a task sequence named for the month. |
| `-Architecture` | `x86`, `x64` or `arm64`. Defaults to winget's choice for the downloading machine. |
| `-Scope` | `machine` (the default, as MCM installs as SYSTEM), `user`, or `any`. |
| `-LogPath` | Where to write the transcript. Defaults to a timestamped log in the current folder. |

The script exits with code 1 if any application failed, so a scheduled task can tell.

## How each app is imported

After downloading, Wingot reads the winget manifest and saves what it needs as `wingot.json`
beside the installer:

- **Install command**: the manifest's silent switch, or the standard one for the installer
  type when the manifest doesn't give one (`/quiet` for MSI and Burn, `/VERYSILENT` for Inno,
  `/S` for NSIS). An exe with no known silent switch gets no install command; Wingot says so
  and skips it.
- **Detection**: MSIs are detected by product code. Other installers are detected by the
  `DisplayVersion` under their Uninstall registry key, in the 64-bit or 32-bit registry view
  depending on the installer's architecture.
- An app with a product code becomes an MCM **Application** with that detection rule. One
  without becomes a **Package** and program.

The import step reads only `wingot.json`. If an app needs a different install command, or its
detection rule never matches, edit that file and run `-MCMImportOnly` again. `Is64Bit` controls
which registry view detection reads.

Content is copied to `<library>\<publisher>\<name>\<version>`. A version that's already there
is skipped, so rerunning is safe.
