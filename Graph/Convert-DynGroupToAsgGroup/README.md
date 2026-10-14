# Convert Dynamic Group to Assigned Group (Convert-DynGroupToAsgGroup)

A PowerShell script that converts a **dynamic-membership** Entra ID group to **assigned (static)** membership with Microsoft Graph. It keeps every current member and, for Teams-connected Microsoft 365 groups, every member of the team's **private and shared channels**.

---

## Features

- **Group verification**: finds the group by display name. The script stops if the name matches zero groups or more than one, or if the group isn't dynamic.
- **Workload detection**: reports whether the group is a Microsoft 365 group, whether it's connected to **Microsoft Teams**, and whether it's a **Viva Engage** community (best effort, see [Limitations](#limitations)).
- **Snapshot before change**: exports group members and private/shared channel members to CSV *before* changing anything.
- **Safe conversion**: removes only `DynamicMembership` from `groupTypes` (other values such as `Unified` are kept) and pauses the membership rule.
- **Member restore**: compares the membership after conversion with the snapshot and adds back any missing members, 20 per request.
- **Channel restore**: adds back missing private/shared channel members with their original **owner** role. Failed adds are retried in passes because Teams can lag behind Entra ID.
- **Confirmation gates**: asks for confirmation before each critical step. The conversion itself requires you to type the group's display name.
- **`-WhatIf` dry run**: runs discovery and the snapshot only.
- **Logging and CSV output**: colour-coded console log (Info / Warning / Error), a timestamped log file, and a results CSV.

---

## Prerequisites

| Requirement | Details |
|---|---|
| PowerShell | 7.x (cross-platform) |
| Module | `Microsoft.Graph.Authentication` (all calls use `Invoke-MgGraphRequest`) |
| Licence | Not needed for the conversion. Dynamic groups require Entra ID P1. |

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

---

## Permissions

The script uses **delegated (interactive)** authentication.

| Permission | Purpose |
|---|---|
| `Group.ReadWrite.All` | Read the group and update `groupTypes` / `membershipRuleProcessingState` |
| `GroupMember.ReadWrite.All` | Read and add group members |
| `Channel.ReadBasic.All` | List team channels |
| `ChannelMember.ReadWrite.All` | Read and add private/shared channel members |

Recommended Entra roles: **Groups Administrator** (for the conversion) and **Teams Administrator** (for channel membership), or equivalent.

---

## Usage

```powershell
# Dry run: discover and snapshot only, no changes
.\Convert-DynGroupToAsgGroup.ps1 -GroupName "Sales Team" -WhatIf

# Interactive conversion
.\Convert-DynGroupToAsgGroup.ps1 -GroupName "Sales Team"

# Specify tenant; skip channel handling
.\Convert-DynGroupToAsgGroup.ps1 -GroupName "Sales Team" -TenantId "contoso.onmicrosoft.com" -SkipChannels

# Longer channel retry window (10 passes x 2 minutes)
.\Convert-DynGroupToAsgGroup.ps1 -GroupName "Sales Team" -ChannelRetryCount 10 -ChannelRetryDelaySeconds 120
```

### Parameters

| Parameter | Mandatory | Default | Description |
|---|---|---|---|
| `GroupName` | Yes | — | Display name of the dynamic group. Must match exactly one group. |
| `TenantId` | No | — | Tenant ID or domain, used only when a new Graph connection is made. |
| `SkipChannels` | No | `$false` | Don't snapshot or restore private/shared channel membership. |
| `ChannelRetryCount` | No | `5` | Extra passes for failed channel adds (0–20). |
| `ChannelRetryDelaySeconds` | No | `60` | Wait between channel retry passes (10–600). |
| `Force` | No | `$false` | Skip all confirmation prompts. Use with care. |
| `WhatIf` | No | — | Discovery and snapshot only. |

---

## Workflow

| Phase | What happens | Confirmation |
|---|---|---|
| 1. Discovery | Find the group, check it's dynamic, detect Microsoft 365 / Teams / Viva Engage | Prompt only if it isn't a Microsoft 365 group |
| 2. Snapshot | Export group members and private/shared channel members to CSV | — |
| 3. Conversion | `PATCH` the group: remove `DynamicMembership`, set rule processing to `Paused`, then check the change took effect | **Type the group display name** |
| 4. Restore members | Add back any snapshot member that's missing (batches of 20, then one at a time if a batch fails) | Type `YES` |
| 5. Restore channels | Add back missing private/shared channel members, keeping the owner role; retry in passes | Type `YES` |
| 6. Verification | Compare final membership with the snapshot and export the results | — |

> The membership rule is written to the log before conversion so you can roll back (see [Rollback](#rollback)).

---

## Output

All files are written to the script folder.

| File | Content |
|---|---|
| `Convert-DynGroupToAsgGroup_<timestamp>.log` | Full run log |
| `Convert-DynGroupToAsgGroup_<Group>_GroupMembers_<timestamp>.csv` | Group members before conversion (`Id`, `ObjectType`, `DisplayName`, `UserPrincipalName`, `Mail`) |
| `Convert-DynGroupToAsgGroup_<Group>_ChannelMembers_<timestamp>.csv` | Private/shared channel members before conversion (`ChannelId`, `ChannelName`, `MembershipType`, `UserId`, `DisplayName`, `Email`, `Roles`, `TenantId`) |
| `Convert-DynGroupToAsgGroup_<Group>_Results_<timestamp>.csv` | One row per member/channel membership: `Scope`, `Channel`, `Id`, `DisplayName`, `Result` (`AlreadyPresent` / `Added` / `Failed`), `Detail` |

---

## Limitations

- **Standard channels** aren't processed. Their membership is inherited from the team, so restoring group members covers them.
- **Shared channels**: only *direct* members are restored. Access that comes from teams the channel is shared with stays tied to those teams and isn't affected. Members from other tenants are re-added with their `tenantId`. This needs B2B direct connect to still be in place.
- **Private channels**: a user must already be a team member before they can be added. If Teams hasn't caught up with Entra ID yet, adds fail at first. The retry passes handle this; any that still fail are listed in the results CSV.
- **Viva Engage detection** checks the group's `creationOptions` for a `Yammer` value. `creationOptions` isn't a documented property of the Graph `group` resource, so treat a negative result as "not detected", not "not Viva Engage". Conversion and member restore work the same either way.
- **Group owners** aren't changed by the conversion and aren't touched by the script.
- **Duplicate display names**: the script stops instead of guessing which group you meant.

---

## Rollback

To make the group dynamic again, use the membership rule recorded in the log:

```powershell
$groupId = '<group-object-id>'
$rule    = '<membership rule from log>'
$types   = @((Invoke-MgGraphRequest GET "v1.0/groups/$groupId`?`$select=groupTypes").groupTypes) + 'DynamicMembership'
$body    = @{ groupTypes = $types; membershipRule = $rule; membershipRuleProcessingState = 'On' } | ConvertTo-Json
Invoke-MgGraphRequest PATCH "v1.0/groups/$groupId" -Body $body -ContentType 'application/json'
```

> When a group goes from static back to dynamic, members who don't match the rule are removed.

---

## References

- [Change static groups to dynamic membership groups (and back)](https://learn.microsoft.com/entra/identity/users/groups-change-type)
- [group resource type: `groupTypes`, `resourceProvisioningOptions`](https://learn.microsoft.com/graph/api/resources/group?view=graph-rest-1.0)
- [Add members (up to 20 per request)](https://learn.microsoft.com/graph/api/group-post-members?view=graph-rest-1.0)
- [List members of a channel](https://learn.microsoft.com/graph/api/channel-list-members?view=graph-rest-1.0)
- [Add member to channel (private/shared only; roles `owner` or empty)](https://learn.microsoft.com/graph/api/channel-post-members?view=graph-rest-1.0)
- [Managing channel memberships (direct vs. indirect)](https://learn.microsoft.com/graph/manage-channel-memberships)
- [Overview of dynamic membership for teams](https://learn.microsoft.com/microsoftteams/dynamic-memberships)
- [Teams and channels overview: channel feature comparison](https://learn.microsoft.com/microsoftteams/teams-channels-overview)
- [Dynamic groups in Viva Engage](https://learn.microsoft.com/viva/engage/manage-viva-engage-groups/create-a-dynamic-group)
