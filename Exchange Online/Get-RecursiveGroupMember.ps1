# Function to recursively get members of a distribution group
param (
      [Parameter(Mandatory = $true)]
      [string]$TargetGroupName
)

#Initialize the variable to hold user mailboxes
#$userMailboxes = @()
function Get-NestedGroupMembers {
    param (
        [Parameter(Mandatory = $true)]
        [string]$GroupName
    )
    
    $userMailboxes = @()
    $members = Get-DistributionGroupMember -Identity $GroupName
    
    foreach ($member in $members) {
        if ($member.RecipientType -eq 'UserMailbox') {
            $resultEntry = [PSCustomObject]@{
                  Name = $member.DisplayName
                  Email = $member.PrimarySmtpAddress
            }
            $userMailboxes += $resultEntry
        } 
        elseif ($member.RecipientType -eq 'MailUniversalDistributionGroup' -or $member.RecipientType -eq 'MailUniversalSecurityGroup') {
            Get-NestedGroupMembers -GroupName $member.Identity
        }
    }
    return $userMailboxes
}

# Call the function to get members of nested groups
Get-NestedGroupMembers -GroupName $TargetGroupName

# Output the user mailboxes