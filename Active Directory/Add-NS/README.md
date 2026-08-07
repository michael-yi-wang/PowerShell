# Add-NS.ps1

This script adds a host as a name server (NS record) across DNS zones — forward *and* reverse — on a domain controller, covering both zone-apex NS records and delegation NS records. It only does so after verifying the host resolves **and** is actually authoritative for the zone concerned, so it cannot create the broken delegations it is meant to prevent.

It is the direct counterpart to [`Remove-StaleNS.ps1`](../Remove-StaleNS/) — same parameters, same scope model, same logging, inverted action.

| | `Add-NS.ps1` | `Remove-StaleNS.ps1` |
|---|---|---|
| Action | Adds the target as a name server | Removes the target as a name server |
| Gate requires | Target **does** resolve (`OK`) | Target **does not** resolve (`ResolveFailed`) |
| Extra check | Target is authoritative for the served zone | — |
| Guard | Skips zones the target does not host | Never empties a node's name server list |

## Background

When a domain controller is promoted, it should be registered as a name server on the zones it serves. Promotion normally handles the apex NS record for the AD-integrated domain zone, but leaves other zones — and any delegations in parent zones — untouched.

The failure mode this script is built to avoid is the mirror image of the one `Remove-StaleNS.ps1` cleans up. Listing a name server that cannot answer for a zone is a **lame delegation**: resolvers referred to it wait for a timeout before trying the next one, which surfaces as intermittently slow name resolution. Microsoft's guidance is explicit that an NS record without a resolvable, authoritative server behind it is a broken delegation.

So adding an NS record is not simply the reverse of deleting one — it needs *more* verification, not less.

## Two places NS records live

A name server needs to be registered in two distinct places, and promotion commonly populates one but not the other:

| `RecordScope` | Stored in | Node | In DNS Manager |
|---|---|---|---|
| `ZoneRoot` | The zone itself | `@` (apex) | Zone → Properties → **Name Servers** tab |
| `Delegation` | The **parent** zone | The child's label, e.g. `bal` | A **greyed-out folder** under the parent zone |

Both are processed by default. `-Scope ZoneRoot` or `-Scope Delegation` restricts the run to one.

**Existing delegations are added to; no new delegation is ever created.** Creating a delegation is a deliberate design decision requiring glue addresses — use `Add-DnsServerZoneDelegation` for that.

## Verification gate

Nothing is added until the target is proven usable:

1. **Flush the local DNS client cache** — so a stale negative answer cannot cause a healthy host to be rejected.
2. **Control lookup** — resolve the local computer's own FQDN first, to distinguish "the target is genuinely missing" from "name resolution is broken".
3. **Target lookup** — resolve `-TargetHostName` (A and AAAA) against every server in `-ResolutionDnsServer`. Status must be **`OK`**.
4. **Authority check** — one query to the target returns every zone it hosts. An NS record is added only for a zone the target is authoritative for.

| Status | Meaning | Outcome |
|---|---|---|
| `OK` | Resolved to an address | **Proceed** |
| `NoHostRecord` | Name exists but returned no A/AAAA | Abort — create its host record first |
| `ResolveFailed` | Name does not exist in DNS | Abort — check spelling, or run `ipconfig /registerdns` on the target |

`-Force` skips the confirmation prompt only. **It does not bypass the gate.**

### The served zone is the child, not the parent

For a delegation this distinction matters. Given node `bal` inside zone `fshq.fs`, the name server must be authoritative for **`bal.fshq.fs`** — the child — not for `fshq.fs`. The script checks the correct zone for each scope.

### When the authority check cannot run

If the target is unreachable over RPC/WMI, or the DNS Server tools aren't available on it, step 4 fails. The script does **not** silently proceed as if the check passed. It logs the failure and prints a prominent warning above the confirmation prompt:

```
WARNING: could not verify which zones 'dc03.contoso.com' hosts (<error>).
         The list above is UNVERIFIED. Adding a name server for a zone it does not host
         creates a lame delegation. Confirm the target hosts every zone listed.
```

At that point you are the only remaining safeguard — review the list before confirming.

## Features

- Enumerates **all** zones on the DNS server, forward and reverse, excluding auto-created zones and `TrustAnchors`.
- Handles **both** zone-apex and delegation NS records, in one query per zone; `-Scope` restricts to either.
- Confirms it is running on a domain controller and that `DnsServer` / `DnsClient` are available before doing anything.
- Verifies the target resolves and is authoritative before any addition (see above).
- **Idempotent** — nodes that already list the target are skipped, so re-runs are safe.
- Evaluates the apex even for a zone with no NS records at all.
- Non-writable zones (Secondary, Stub, Forwarder) are skipped and recorded in the CSV with the reason, rather than silently dropped.
- Shows a summary split by scope and prompts for confirmation (skip with `-Force`).
- Supports `-WhatIf` for a dry run.
- Logs every action (Info/Warning/Error, colour-coded) to a timestamped `.log` file and exports results to a timestamped `.csv` — both written to a `logs` subfolder beside the script.

## Output files

Both output files are written to a `logs` subfolder next to the script, created automatically on first run:

```
Add-NS/
├── Add-NS.ps1
├── README.md
└── logs/
    ├── Add-NS_20260807_161331.log
    └── Add-NS_Results_20260807_161331.csv
```

Each run gets its own timestamped pair, so nothing is ever overwritten.

The CSV covers the whole run — additions and every skipped entry — with these columns:

| Column | Notes |
|---|---|
| `ZoneName`, `ZoneType`, `IsReverseLookupZone` | Which zone the record goes in |
| `RecordScope` | `ZoneRoot` or `Delegation` |
| `HostName` | `@` for apex, the child label for a delegation |
| `ServedZone` | The zone the name server must be authoritative for |
| `NameServer` | The NS record data written (fully qualified, trailing dot) |
| `ResolutionStatus` | Always `OK` on a run that made changes |
| `ResolvedAddress` | What the target resolved to |
| `Action` | `Add`, `WouldAdd` (dry run), or `Skipped` |
| `Result` | `Success`, `Failed`, or `Skipped` |
| `Message` | Outcome, or the reason it was skipped |
| `Timestamp` | |

If this folder is inside a Git repository, consider adding `logs/` to `.gitignore` — the output contains your DNS zone and server names.

## Prerequisites

- Must be run on a domain controller (checked automatically; the script aborts otherwise).
- `DnsServer` PowerShell module (RSAT DNS Server Tools — `Install-WindowsFeature RSAT-DNS-Server`) and the `DnsClient` module.
- An account with DNS administrative privileges, and read access to the target's zone list for the authority check.
- Compatible with both Windows PowerShell 5.1 and PowerShell 7+.

> **Platform note.** `DnsServer` and `DnsClient` are Windows-only modules with no cross-platform equivalent for managing Windows DNS Server zone data, and the requirement to run on a domain controller makes Windows mandatory regardless. The script is written in PowerShell 7–compatible syntax and runs unmodified under PowerShell 7 on Windows (where `DnsServer` loads via the Windows PowerShell compatibility layer).

## Usage

Always preview first:

```powershell
.\Add-NS.ps1 -TargetHostName dc03.contoso.com -WhatIf
```

Add after reviewing, with an interactive prompt:

```powershell
.\Add-NS.ps1 -TargetHostName dc03.contoso.com
```

Delegations only — the greyed-out folders in DNS Manager:

```powershell
.\Add-NS.ps1 -TargetHostName dc03.contoso.com -Scope Delegation -WhatIf
```

Verify resolution against several DCs, target a remote DNS server, skip a zone, run unattended:

```powershell
.\Add-NS.ps1 -TargetHostName dc03.contoso.com `
             -DnsServer dc02.contoso.com `
             -ResolutionDnsServer dc01.contoso.com,dc02.contoso.com `
             -ExcludeZone legacy.contoso.com `
             -Force
```

## Parameters

Identical to `Remove-StaleNS.ps1`.

| Parameter | Required | Description |
|---|---|---|
| `-TargetHostName` | Yes | Host to add as a name server, e.g. `dc03.contoso.com`. An NS record must hold an FQDN; if a single label is supplied, the local DNS domain is appended and logged, and the resolution gate then validates it. |
| `-DnsServer` | No | DNS server whose zones are read and modified. Defaults to the local computer name. |
| `-Scope` | No | `All` (default), `ZoneRoot`, or `Delegation`. Which class of NS record to add. |
| `-ResolutionDnsServer` | No | One or more servers used to verify the target resolves. Defaults to `-DnsServer`. Only one needs to resolve it. |
| `-ExcludeZone` | No | Zones to skip, in addition to auto-created zones and `TrustAnchors`, which are always excluded. |
| `-WhatIf` | No | Dry run — shows what would be added without changing anything. |
| `-Force` | No | Skips the confirmation prompt. Does **not** bypass the verification gate. |

## Workflow

1. Confirms the script is running on a domain controller and that the required modules are present.
2. Normalises `-TargetHostName` to an FQDN, appending the local DNS domain if a single label was supplied.
3. Runs the verification gate: cache flush → control lookup → target lookup. Aborts unless the status is `OK`.
4. Queries the target for the list of zones it hosts.
5. Enumerates all forward and reverse zones, excluding auto-created zones, `TrustAnchors`, and anything in `-ExcludeZone`.
6. For each writable zone, evaluates the apex and every existing delegation node: skips nodes that already list the target, skips zones the target does not host, flags the rest.
7. Displays a summary split by scope — with an explicit warning if the authority check could not run — and prompts for confirmation.
8. Adds each flagged NS record individually, logging every result.
9. Exports all results — additions and skipped entries — to CSV.

## Scope and limitations

- **Primary zones only are modified.** Secondary and Stub zone data is owned by the master server and cannot be edited locally; Forwarder zones hold no NS records. These appear in the CSV as `Skipped` with the reason.
- **No glue or host records are created.** If the target's own A/AAAA record is missing, DNS Manager's Name Servers tab will show its IP as `Unknown`. That is a separate fix — see [`Update-DNSNameServer.ps1`](../Update-DNSNameServer/), which locates the owning zone and creates the host record.
- **`Add-DnsServerResourceRecord` is used for both scopes**, not `Add-DnsServerZoneDelegation`. The latter creates a delegation and requires glue IP addresses; adding the individual resource record adds to an existing delegation without replacing it and has no side effects.
- **No new delegations are created.** Only existing delegation nodes are added to.
- If the NS name being added lives *inside* the delegated child zone (e.g. adding `ns1.bal.fshq.fs` to the `bal` delegation), glue records are required and this script does not create them. Use `Add-DnsServerZoneDelegation -IPAddress` instead. This does not apply when the name server lives in the parent zone, which is the usual AD-integrated arrangement.

## Safety & recommendations

- Run with `-WhatIf` first, every time. Review the listed zones and delegations before committing.
- Never ignore the "could not verify which zones … hosts" warning — that path is the only way a lame delegation can slip through.
- Verify AD/DNS replication is healthy before and after running.
- The script writes to **one** DNS server. AD-integrated zone data then replicates on its own; file-backed zones do not. After the run, allow replication to converge and re-run with `-WhatIf` against a *different* DC to confirm.
- Rollback is straightforward: `Remove-StaleNS.ps1` is the counterpart, or remove an individual record with `Remove-DnsServerResourceRecord -ZoneName <zone> -RRType NS -Name <node> -RecordData <fqdn.>`. The CSV records exactly what was added and where.
- Follow up with `dcdiag /test:dns /DnsDelegation /e /v`.

## Troubleshooting

- **"This script must be run on a domain controller"** — run it on the DC itself; `DomainRole` must be 4 (BDC) or 5 (PDC).
- **"Control lookup failed"** — the DC cannot resolve its own FQDN. Fix name resolution first.
- **"Verification gate failed… got 'ResolveFailed'"** — the target does not exist in DNS. Check the spelling, or run `ipconfig /registerdns` and `net stop netlogon && net start netlogon` on the target, then re-run.
- **"Verification gate failed… got 'NoHostRecord'"** — the name exists but has no address. Create its A/AAAA record first.
- **Everything skipped as "Target does not host zone"** — confirm the target really is a DNS server for those zones. On a newly promoted DC, the zones may not have replicated to it yet.
- **New name server shows "Unknown" in DNS Manager** — its A record is missing, or the console is bound to a DC that hasn't received it yet. Flush the workstation's cache and reopen the console; if it persists, create the host record (`Update-DNSNameServer.ps1`).

## Notes

- Uses `Get-DnsServerZone`, `Get-DnsServerResourceRecord`, `Add-DnsServerResourceRecord`, `Resolve-DnsName`, and `Clear-DnsClientCache`.
- NS records are read **without** `-Node`, which returns every node in the zone in one call — apex and delegations together — then classified by `HostName` (`@` = apex, anything else = delegation).
- `TrustAnchors` is excluded **by name**, not by `IsAutoCreated`. It is a genuine AD-integrated primary forward zone with `IsAutoCreated = False`; only `0/127/255.in-addr.arpa` carry that flag.
- NS record data is written fully qualified with a trailing dot, matching how Windows DNS stores it.

## References

- [Reviewing DNS Concepts — Delegation (NS vs. A/AAAA)](https://learn.microsoft.com/windows-server/identity/ad-ds/plan/reviewing-dns-concepts#delegation)
- [Troubleshooting DNS servers — broken delegation](https://learn.microsoft.com/windows-server/networking/dns/troubleshoot/troubleshoot-dns-server#checking-for-recursion-problems)
- [`Add-DnsServerResourceRecord`](https://learn.microsoft.com/powershell/module/dnsserver/add-dnsserverresourcerecord) — the `NS` parameter set
- [`Add-DnsServerZoneDelegation`](https://learn.microsoft.com/powershell/module/dnsserver/add-dnsserverzonedelegation) — creating a delegation with glue
- [`Get-DnsServerZone`](https://learn.microsoft.com/powershell/module/dnsserver/get-dnsserverzone)
- [Active Directory-Integrated DNS Zones](https://learn.microsoft.com/windows-server/identity/ad-ds/plan/active-directory-integrated-dns-zones) — how the change reaches other DCs
- [`dcdiag` DNS test switches](https://learn.microsoft.com/windows-server/administration/windows-commands/dcdiag#dns-syntax)
