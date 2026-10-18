[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$LogPath)

Set-Content -LiteralPath $LogPath -Value 'mock miner started' -Encoding UTF8
while ($true) { Start-Sleep -Milliseconds 250 }
