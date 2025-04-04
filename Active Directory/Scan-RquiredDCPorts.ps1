<#
.SYNOPSIS
.DESCRIPTION
      This script check all mandatory ports for Active Directory.
.PARAMETER TargetDC
      FQDN for the target domain controller
.EXAMPLE
#>

param (
    [Parameter(Mandatory)]
    [string]$TargetDC
)

#Define function
function PauseContinue {
      Write-Host "Press any key to continue..."
      $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');
  }

#Define all mandatory domain controller ports
$DCPorts = 53,135,139,3268,3269,88,464,50187,5722,389,43243,445,636

Write-Host "==========================DC Port Scan==========================" -ForegroundColor Cyan
Write-Host "The script will scan mandatory ports to below domainc controller:" -ForegroundColor Cyan
Write-Host "Target Domain Controller: $($TargetDC)" -ForegroundColor Green
Write-Host "Ports: TCP-53, TCP-135, TCP-139,TCP-3268, TCP-3269, TCP-88, TCP-464, TCP-50187, TCP-5722, TCP-389, TCP-43243, TCP-445, TCP-636, UDP-53, UDP-389, UDP-88, UDP-123, UDP-137:138, UDP-445, UDP-464, UDP-3268, PING" -ForegroundColor Cyan
PauseContinue

if (Test-Connection -Ping -Count 1 $TargetDC -ErrorAction SilentlyContinue) {
      Write-Host "$($TargetDC) respond to ICMP Ping." -ForegroundColor Green
      PauseContinue
}
else {
      Write-Host "$($TargetDC) NOT respond to ICMP Ping. Abort Script" -ForegroundColor Red
      break
}

foreach ($SinglePort in $DCPorts) {
      $Socket = New-Object Net.Sockets.TcpClient
      $Socket.Connect($TargetDC, $SinglePort)
      if ($Socket.Connected) {      
            # Close the socket.
            $Socket.Close()
            # Return success string
            Write-Host "Connection to $($TargetDC) on $($SinglePort) Successful"
        }
        else {
            Write-Host "Connection to $($TargetDC) on $($SinglePort) Not Successful" -ForegroundColor Red
        }
}