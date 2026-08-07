# Remove-StaleNS.ps1

This script removes a decommissioned host's leftover name server (NS) records from every DNS zone — forward *and* reverse — on a domain controller, covering both zone-apex NS records and delegation NS records. It only does so after proving the host no longer resolves, so a healthy server can never be accidentally stripped out of a zone's name server list.

It is the cleanup counterpart to [`Update-DNSNameServer.ps1`](../Update-DNSNameServer/): that script manages a *named* DC's NS records zone by zone, while this one hunts a *single stale* host across the whole server and removes it everywhere.

## Background

When a domain controller is demoted, its NS records should be removed automatically from every zone it served. In practice they are frequently left behind.

A zone-root NS record pointing at a host that no longer exists is a **broken delegation**. Microsoft's DNS troubleshooting guidance is explicit: *"If you do not find at least one valid IP address of an A resource record for each NS resource record in a zone, you have a broken delegation."* The practical symptom is intermittently slow name resolution — resolvers referred to the dead name server wait for a timeout before trying the next one.

### The GUI's IP column is not evidence

DNS Manager's **Name Servers** tab shows an IP Address column that often reads `Unknown`. That is **not** a stored value and **not** proof a name server is dead:

- An NS record's data is a **name only**. Microsoft: *"The name server (NS) resource record provides the name of an authoritative server. Host (A) and host (AAAA) resource records provide IPv4 and IPv6 addresses."*
- The column is a live lookup performed by the console when it draws the list. The dialog's own footnote says so: *"\* represents an IP address retrieved as the result of a DNS query and may not represent actual records stored on this server."*
- `Unknown` therefore appears for reasons as benign as a cached negative answer on the workstation running the console, or the console being connected to a DC that hasn't received the replicated host record yet.

This script ignores the GUI entirely and performs its own resolution test against the DNS servers you nominate.

## Two places NS records live

A stale host is typically referenced twice, and demotion cleanup commonly fixes one but not the other:

| `RecordScope` | Stored in | Node | In DNS Manager |
|---|---|---|---|
| `ZoneRoot` | The zone itself | `@` (apex) | Zone → Properties → **Name Servers** tab |
| `Delegation` | The **parent** zone | The child's label, e.g. `bal` | A **greyed-out folder** under the parent zone |

Both are processed by default. `-Scope ZoneRoot` or `-Scope Delegation` restricts the run to one.

The distinction matters because they're two independent copies that can drift apart. An apex list that's been cleaned while the parent's delegation still points at a dead server keeps handing out referrals to it.

### Guard: never strip a node bare

The script will **not** remove every NS record from a node, even when they all match `-TargetHostName`:

- At the **apex**, that would leave a zone with no name servers.
- At a **delegation** node, it deletes the delegation itself, making the entire child subtree unresolvable through that parent.

Such matches are printed prominently before the confirmation prompt, written to the CSV with the reason, and left untouched. Resolving them is a deliberate human decision — either add a valid name server first, or remove the delegation on purpose with `Remove-DnsServerZoneDelegation`.

Glue and host (A/AAAA) records are never modified.

## Safety gate

Removing NS records from every zone at once is destructive and tedious to reverse, so the script refuses to remove anything until it proves the target is genuinely gone:

1. **Flush the local DNS client cache** — so neither a stale positive nor a stale negative answer can decide the outcome.
2. **Control lookup** — resolve the local computer's own FQDN first. If *that* fails, the resolver itself is broken, every lookup would falsely report `ResolveFailed`, and the script aborts. Without this check, a DNS outage would cause the script to strip name servers from every zone on the server.
3. **Target lookup** — resolve `-TargetHostName` (A and AAAA) against every server in `-ResolutionDnsServer`. The status must be exactly **`ResolveFailed`** — no server could resolve the name at all.

Any other status aborts the run with no changes:

| Status | Meaning | Outcome |
|---|---|---|
| `ResolveFailed` | Name does not exist on any resolution server | **Proceed** |
| `OK` | Name resolved to an address | Abort — host is alive |
| `NoHostRecord` | Name exists but returned no A/AAAA | Abort — investigate manually; not proof of decommissioning |

`-Force` skips the confirmation prompt only. **It does not bypass the safety gate** — a host that still resolves is never removed.

## Features

- Enumerates **all** zones on the DNS server, forward and reverse, excluding auto-created zones and `TrustAnchors`.
- Handles **both** zone-apex and delegation NS records, in one query per zone; `-Scope` restricts to either.
- Confirms it is running on a domain controller and that `DnsServer` / `DnsClient` are available before doing anything.
- Proves the target no longer resolves before any removal (see above).
- Removes each matching NS record individually using `-RecordData`, so a zone's other name servers are never touched.
- Refuses to empty a node's name server list, guarding against deleting a delegation outright.
- Non-writable zones (Secondary, Stub, Forwarder) are skipped and recorded in the CSV with the reason, rather than silently dropped.
- Shows a removal summary and prompts for confirmation (skip with `-Force`).
- Supports `-WhatIf` for a dry run.
- Logs every action (Info/Warning/Error, colour-coded) to a timestamped `.log` file and exports results to a timestamped `.csv` — both written to a `logs` subfolder beside the script.

## Output files

Both output files are written to a `logs` subfolder next to the script, created automatically on first run:

```
Remove-StaleNS/
├── Remove-StaleNS.ps1
├── README.md
└── logs/
    ├── Remove-StaleNS_20260807_161331.log
    └── Remove-StaleNS_Results_20260807_161331.csv
```

Each run gets its own timestamped pair, so nothing is ever overwritten.

The CSV covers the whole run — removals, guarded records, and skipped zones — with these columns:

| Column | Notes |
|---|---|
| `ZoneName`, `ZoneType`, `IsReverseLookupZone` | Which zone the record was in |
| `RecordScope` | `ZoneRoot` or `Delegation` |
| `HostName` | `@` for apex, the child label for a delegation |
| `NameServer` | The NS record's data |
| `ResolutionStatus` | Always `ResolveFailed` on a run that made changes |
| `Action` | `Remove`, `WouldRemove` (dry run), or `Skipped` |
| `Result` | `Success`, `Failed`, or `Skipped` |
| `Message` | Outcome, or the reason it was held back |
| `Timestamp` | |

If this folder is inside a Git repository, consider adding `logs/` to `.gitignore` — the output contains your DNS zone and server names.

## Prerequisites

- Must be run on a domain controller (checked automatically; the script aborts otherwise).
- `DnsServer` PowerShell module (RSAT DNS Server Tools — `Install-WindowsFeature RSAT-DNS-Server`) and the `DnsClient` module.
- An account with DNS administrative privileges.
- Compatible with both Windows PowerShell 5.1 and PowerShell 7+.

> **Platform note.** `DnsServer` and `DnsClient` are Windows-only modules with no cross-platform equivalent for managing Windows DNS Server zone data, and the requirement to run on a domain controller makes Windows mandatory regardless. The script is written in PowerShell 7–compatible syntax and runs unmodified under PowerShell 7 on Windows (where `DnsServer` loads via the Windows PowerShell compatibility layer).

## Usage

Always preview first:

```powershell
.\Remove-StaleNS.ps1 -TargetHostName dc01.contoso.com -WhatIf
```

Remove after confirming, with an interactive prompt:

```powershell
.\Remove-StaleNS.ps1 -TargetHostName dc01.contoso.com
```

Check the host is unresolvable on several DCs before removing, unattended:

```powershell
.\Remove-StaleNS.ps1 -TargetHostName dc01.contoso.com `
                     -ResolutionDnsServer dc02.contoso.com,dc03.contoso.com `
                     -Force
```

Target a remote DNS server, and leave one zone alone:

```powershell
.\Remove-StaleNS.ps1 -TargetHostName dc01.contoso.com `
                     -DnsServer dc02.contoso.com `
                     -ExcludeZone legacy.contoso.com
```

Work on delegations only — the greyed-out folders in DNS Manager — leaving apex records alone:

```powershell
.\Remove-StaleNS.ps1 -TargetHostName dc01.contoso.com -Scope Delegation -WhatIf
```

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-TargetHostName` | Yes | Host whose NS records are removed, e.g. `dc01.contoso.com`. An FQDN matches the full NS record data; a single label matches the leftmost label only (less precise — prefer the FQDN). |
| `-DnsServer` | No | DNS server whose zones are read and modified. Defaults to the local computer name. |
| `-Scope` | No | `All` (default), `ZoneRoot`, or `Delegation`. Which class of NS record to act on. |
| `-ResolutionDnsServer` | No | One or more servers used to test whether the target still resolves. Defaults to `-DnsServer`. If **any** listed server resolves the name, the script aborts. |
| `-ExcludeZone` | No | Zones to skip, in addition to auto-created zones and `TrustAnchors`, which are always excluded. |
| `-WhatIf` | No | Dry run — shows what would be removed without changing anything. |
| `-Force` | No | Skips the confirmation prompt. Does **not** bypass the resolution safety gate. |

## Workflow

1. Confirms the script is running on a domain controller and that the required modules are present.
2. Normalises `-TargetHostName` and warns if a single label was supplied.
3. Runs the safety gate: cache flush → control lookup → target lookup. Aborts unless the status is `ResolveFailed`.
4. Enumerates all forward and reverse zones, excluding auto-created zones, `TrustAnchors`, and anything in `-ExcludeZone`.
5. Reads every NS record in each writable zone, groups them by node, classifies each node as `ZoneRoot` or `Delegation`, and flags records referencing the target.
6. Applies the last-name-server guard, holding back any node where every NS record matches.
7. Displays a summary — split by scope, with guarded items called out — and prompts for confirmation.
8. Removes each flagged NS record individually, logging every result.
9. Exports all results — removals, guarded records, and skipped zones — to CSV.

## Scope and limitations

- **Primary zones only are modified.** Secondary and Stub zone data is owned by the master server and cannot be edited locally; Forwarder zones hold no NS records. These appear in the CSV as `Skipped` with the reason.
- **Glue and host records are not touched.** The script removes NS records only. If the stale host also has an A/AAAA record, remove it separately after confirming nothing else depends on it — in an AD-integrated setup where name servers live in the parent zone, that record is an ordinary host record, not glue.
- **`Remove-DnsServerResourceRecord` is used for both scopes**, not `Remove-DnsServerZoneDelegation`. The latter is purpose-built for delegations but [deletes the entire delegation when the last name server goes](https://learn.microsoft.com/powershell/module/dnsserver/remove-dnsserverzonedelegation). Removing the individual resource record keeps the blast radius identical for apex and delegation nodes and has no glue side effects.
- The script does not remove the stale host's own CNAME or SRV records. After a demotion, also verify its `_msdcs` CNAME and host records are gone.

## Safety & recommendations

- Run with `-WhatIf` first, every time. Review the listed zones before committing.
- Pass several DCs to `-ResolutionDnsServer` in multi-site environments — a single server may have a blind spot due to an unreplicated or scavenged host record.
- Verify AD/DNS replication is healthy before and after running.
- After the run, allow replication to converge, then re-run with `-WhatIf` to confirm nothing remains.
- Follow up with `dcdiag /test:dns /DnsDelegation /e /v` to confirm no other references to the demoted DC survive.
- Rollback is straightforward if needed: `Add-DnsServerResourceRecord -ZoneName <zone> -Name '@' -Ns -NameServer <fqdn.>`. The CSV records exactly what was removed from where.

## Troubleshooting

- **"This script must be run on a domain controller"** — run it on the DC itself; `DomainRole` must be 4 (BDC) or 5 (PDC).
- **"Control lookup failed"** — the DC cannot resolve its own FQDN. Fix name resolution first; the script is refusing to trust a `ResolveFailed` result while DNS is unhealthy.
- **"Safety gate failed... got 'OK'"** — the host still resolves, so it isn't stale. If it was genuinely decommissioned, a leftover A record is the likely cause; remove that first, then re-run.
- **"Safety gate failed... got 'NoHostRecord'"** — the name exists in DNS but has no address (e.g. a CNAME or an orphaned node). Investigate before forcing anything; the script will not treat this as proof of decommissioning.
- **"SKIPPED — these need manual review"** — the guard fired: the stale host is the *only* name server on that node. For a delegation, add a working name server to it first (`Add-DnsServerZoneDelegation`) then re-run, or delete the delegation deliberately with `Remove-DnsServerZoneDelegation -Name <parent> -ChildZoneName <child>`. For an apex, the zone has no other name servers at all — investigate before changing anything.
- **No zones matched** — confirm the spelling and that you're pointed at the right `-DnsServer`.

## Notes

- Uses `Get-DnsServerZone`, `Get-DnsServerResourceRecord`, `Remove-DnsServerResourceRecord`, `Resolve-DnsName`, and `Clear-DnsClientCache`.
- NS records are read **without** `-Node`, which returns every node in the zone in one call — apex and delegations together — then classified by `HostName` (`@` = apex, anything else = delegation).
- `TrustAnchors` is excluded **by name**, not by `IsAutoCreated`. It is a genuine AD-integrated primary forward zone with `IsAutoCreated = False`; only `0/127/255.in-addr.arpa` carry that flag.
- `Remove-DnsServerResourceRecord` is always called with `-RecordData`. Per the cmdlet documentation, *"If you do not specify RecordData, the cmdlet deletes all records that match RRtype and Name"* — which would wipe a zone's entire name server list.

## References

- [Reviewing DNS Concepts — Delegation (NS vs. A/AAAA)](https://learn.microsoft.com/windows-server/identity/ad-ds/plan/reviewing-dns-concepts#delegation)
- [Troubleshooting DNS servers — broken delegation](https://learn.microsoft.com/windows-server/networking/dns/troubleshoot/troubleshoot-dns-server#checking-for-recursion-problems)
- [`Remove-DnsServerResourceRecord`](https://learn.microsoft.com/powershell/module/dnsserver/remove-dnsserverresourcerecord)
- [`Get-DnsServerResourceRecord`](https://learn.microsoft.com/powershell/module/dnsserver/get-dnsserverresourcerecord)
- [`Get-DnsServerZone`](https://learn.microsoft.com/powershell/module/dnsserver/get-dnsserverzone)
- [`dcdiag` DNS test switches](https://learn.microsoft.com/windows-server/administration/windows-commands/dcdiag#dns-syntax)
