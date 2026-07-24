# Update-DNSNameServer: Add-side IP verification

## Context

`Active Directory/Update-DNSNameServer/Update-DNSNameServer.ps1` adds or
removes a domain controller as a name server (NS record) across DNS forward
lookup zones, for use during DC promotion/demotion.

In practice, DC promotion/demotion is a two-step manual DNS cleanup in the
DNS Manager console (see reference screenshots from the triggering
conversation):

1. The demoted DC's NS record is removed from every forward lookup zone
   (already covered by `-RemoveNameServer` - no change).
2. The newly promoted DC's NS record is added to every forward lookup zone.
   DNS Manager immediately shows this new NS record, but its "IP Address"
   column reads `Unknown` until the DC's own A (host) record - which it
   self-registers via dynamic DNS update - appears and resolves. The admin
   currently has to manually re-open each zone's Name Servers dialog later
   to confirm the IP has shown up.

This spec covers improving the `-AddNameServer` path only, adding a
read-only verification step so the script reports whether the target host's
A record now exists and matches the IP the admin expects, across *all*
candidate zones - not just ones where the NS record was just added.

Confirmed out of scope (from brainstorming):

- No combined "swap" mode. `-AddNameServer` and `-RemoveNameServer` stay
  fully separate parameter sets, run independently as today.
- The script still never creates, modifies, or deletes A records. DCs
  self-register those via dynamic DNS update; this script only checks and
  reports on them.
- No new switches (e.g. no standalone `-VerifyOnly` mode). Verification is
  folded into the existing `-AddNameServer` flow.

## Parameter changes

- `-NameServerIPAddress` changes from optional to
  `Mandatory = $true` on the `Add` parameter set. Verification requires a
  known-good IP to compare against, so it no longer makes sense to allow an
  IP-less Add run.
- No changes to `-RemoveNameServer`, `-ZoneName`, `-ExcludeZone`,
  `-DnsServer`, `-WhatIf`, or `-Force`.

## Verification logic

For every candidate zone in `$ForwardZones` (i.e. every zone that passed the
`ZoneName`/`ExcludeZone` filters - regardless of whether that zone's NS
record needed adding this run), when `-AddNameServer` is used, look up the A
record for `$HostShortName` in that zone via the existing
`Get-DnsServerResourceRecord -RRType A` call and classify the result into
one of three states:

| Status      | Meaning                                                              |
|-------------|-----------------------------------------------------------------------|
| `Matched`   | A record found; its IPv4 address equals `-NameServerIPAddress`.       |
| `Mismatch`  | A record found; its IPv4 address differs from `-NameServerIPAddress`. |
| `NotFound`  | No A record found, or the lookup itself failed/errored.               |

`NotFound` intentionally covers both "the DC hasn't dynamically registered
yet" and any lookup failure - the script already treats a failed
`Get-DnsServerResourceRecord` call as "no record" via a single `catch`
block, and there is no reliable way to distinguish "record does not exist"
from other DNS query failures via the module's error output. Splitting this
into two statuses would add complexity without a clear action the admin
would take differently.

This check is 100% read-only. It never creates, updates, or deletes any DNS
record - it only reports.

## Reporting changes

- Each per-zone result object (the object type used for both the in-memory
  work list and the exported CSV) gains an `IPVerificationStatus` property,
  populated for every candidate zone on an Add run - whether or not that
  zone's NS record was changed this run.
- The console summary gains an "IP verification" section: any zone with
  `Mismatch` or `NotFound` is listed (zone name, expected IP, what was
  found), plus a one-line count like `7 of 9 zones verified (2 need
  attention)`.
- The "no zones require a change" early-exit is removed for `-AddNameServer`
  runs. Today, if every zone already has the NS record, the script prints
  "Nothing to do" and returns immediately - skipping verification entirely.
  Going forward: the NS-add step can still have "nothing to do", but the
  script continues on to run IP verification across all candidate zones,
  print the verification summary, and export the CSV. The interactive
  confirmation prompt (Step 6) still only appears when there is at least one
  actual NS record to add - verification alone never prompts, since it makes
  no changes.
- `-RemoveNameServer` runs are unaffected: same early-exit behavior, same
  CSV schema (no `IPVerificationStatus` column - it's meaningless for a
  removal), no verification step.

## Logging

- `Matched` -> `Info` (green).
- `Mismatch` -> `Warning` (yellow) - could indicate a stale record or a typo
  in the supplied IP.
- `NotFound` -> `Warning` (yellow) - expected immediately after promotion,
  but worth surfacing so the admin knows to check back rather than assuming
  it's done.

## Error handling

Unchanged pattern from the existing script: the A-record lookup is wrapped
in `try/catch`; a failure is treated as `NotFound` with the exception
message captured in the result's detail/message field for troubleshooting.
No error here is fatal to the overall script run - a lookup problem on one
zone doesn't stop processing of the others.

## Testing / validation

The script requires a real domain controller with the `DnsServer` module
(Windows-only) to exercise end-to-end, so this change will be validated via:

- `[System.Management.Automation.Language.Parser]::ParseFile()` for syntax
  correctness (as done for the prior 5.1/7 compatibility change).
- Manual code review of the diff against this spec.
- `-WhatIf` dry runs are recommended on a lab DC before production use, same
  as today.

Automated Pester tests with mocked `Get-DnsServerResourceRecord` /
`Add-DnsServerResourceRecord` calls were discussed but are out of scope for
this change - flagged to the user as a possible follow-up, not included
here.
