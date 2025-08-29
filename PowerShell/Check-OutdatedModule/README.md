Check-OutdatedModule.ps1
========================

Purpose
-------
Checks installed PowerShell modules against the latest versions in registered repositories (for example, PSGallery) and lists any outdated modules. Optionally removes older installed versions when run with the `-DeleteConfirm` switch.

Requirements
------------
- PowerShell 5.1+ or PowerShell (Core).
- Internet access and at least one registered repository (e.g. PSGallery) for version lookups.
- `Find-Module`, `Get-InstalledModule`, `Uninstall-Module` are used when available (PowerShellGet). When `Get-InstalledModule` is not available the script falls back to `Get-Module -ListAvailable` for discovery, but those may not be removable with `Uninstall-Module`.

Usage
-----
Place `Check-OutdatedModule.ps1` and this `README.md` in the same folder. Run the script from PowerShell.

Examples
--------
List outdated modules (no destructive action):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "./Check-OutdatedModule.ps1"
```

List outdated modules and remove older installed versions (no interactive prompts):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "./Check-OutdatedModule.ps1" -DeleteConfirm
```

Notes and behavior
------------------
- The script uses `Find-Module` to query the latest version available in registered repositories. If a module cannot be located remotely, the script will report the latest available version as blank and will not treat it as outdated.
- When `-DeleteConfirm` is used the script will attempt to remove only installed versions that are older than the latest available version. It uses `Uninstall-Module -RequiredVersion <version> -Force` and will report any failures.
- If modules were installed by other means (manually placed in module paths, or installed without PowerShellGet), they might not be removable by `Uninstall-Module`.

Safety
------
The `-DeleteConfirm` switch performs removal operations. Review the list of outdated modules before running with the switch in environments where module removal may affect services or automation.

Troubleshooting
---------------
- If the script cannot reach the gallery, ensure network access and that `PSGallery` (or another repository) is registered (`Get-PSRepository`).
- To manually check a module version, use `Find-Module -Name <ModuleName>` and `Get-InstalledModule -Name <ModuleName> -AllVersions`.

License
-------
This file is part of the repository and follows the repository license.
