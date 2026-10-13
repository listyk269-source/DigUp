#requires -Version 7.2
param([Parameter(Mandatory)][string]$Path)
. "$PSScriptRoot/Common.ps1"
if (!$env:DIGUP_CERT_THUMBPRINT) { throw 'DIGUP_CERT_THUMBPRINT must name a certificate in CurrentUser/My.' }
$signtool = (Get-Command signtool.exe -ErrorAction Stop).Source
Invoke-Checked $signtool @('sign', '/sha1', $env:DIGUP_CERT_THUMBPRINT, '/s', 'My', '/fd', 'SHA256',
    '/tr', 'http://timestamp.digicert.com', '/td', 'SHA256', $Path)
Invoke-Checked $signtool @('verify', '/pa', $Path)
