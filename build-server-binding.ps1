$ErrorActionPreference = 'Stop'
$root = 'C:\ElanProbe\ServerBinding'
New-Item -ItemType Directory -Path $root -Force | Out-Null

$inboxInf = Join-Path $env:windir 'INF\hidi2c.inf'
$inf = Get-Content -LiteralPath $inboxInf -Raw
if ($inf -notmatch '(?m)^%hidi2c\.DeviceDesc%=hidi2c_Device, ACPI\\PNP0C50\s*$' -or
    $inf -notmatch 'NTamd64\.\.\.1') {
    throw 'The inbox INF no longer has the expected device match.'
}

$store = Join-Path $env:windir 'System32\DriverStore\FileRepository'
$binary = Get-ChildItem $store -Directory -Filter 'hidi2c.inf_amd64_*' |
    ForEach-Object { Get-Item (Join-Path $_.FullName 'hidi2c.sys') -ErrorAction SilentlyContinue } |
    Where-Object { (Get-Content (Join-Path $_.DirectoryName 'hidi2c.inf') -Raw) -eq $inf } |
    Select-Object -First 1
if (!$binary -or (Get-AuthenticodeSignature $binary.FullName).Status -ne 'Valid') {
    throw 'Could not verify the matching inbox hidi2c.sys.'
}
Copy-Item -LiteralPath $binary.FullName -Destination $root

$inf = $inf.Replace('NTamd64...1', 'NTamd64.10.0...26100')
$inf = $inf.Replace('ACPI\PNP0C50', 'ACPI\ELAN1200')
$inf = $inf.Replace('Provider=%MSFT%', "Provider=%BindingProvider%`r`nCatalogFile=ElanServerBinding.cat")
$inf = $inf.Replace('[Strings]', "[Strings]`r`nBindingProvider=`"Local ELAN Server binding`"")
$inf | Set-Content (Join-Path $root 'ElanServerBinding.inf') -Encoding ascii

$image = Get-DiskImage -ImagePath 'C:\ElanProbe\EWDK.iso'
if (!$image.Attached) { $image = Mount-DiskImage -ImagePath $image.ImagePath -PassThru }
$volume = $image | Get-Volume | Where-Object DriveLetter | Select-Object -First 1
if (!$volume) { throw 'EWDK has no drive letter.' }
$kit = Join-Path "$($volume.DriveLetter):\" 'Program Files\Windows Kits\10\bin'
$inf2cat = Get-ChildItem $kit -Recurse -Filter inf2cat.exe |
    Where-Object { $_.Directory.Name -eq 'x86' } | Select-Object -First 1
$signtool = Get-ChildItem $kit -Recurse -Filter signtool.exe |
    Where-Object { $_.Directory.Name -eq 'x64' } | Select-Object -First 1
if (!$inf2cat -or !$signtool) { throw 'EWDK signing tools not found.' }

& $inf2cat.FullName "/driver:$root" /os:Server2025_X64
if ($LASTEXITCODE -ne 0) { throw 'Inf2Cat failed.' }
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
    Where-Object Subject -eq 'CN=ELAN1200 Server binding test' | Select-Object -First 1
if (!$cert) {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -CertStoreLocation Cert:\CurrentUser\My -Subject 'CN=ELAN1200 Server binding test'
}
$catalog = Join-Path $root 'ElanServerBinding.cat'
& $signtool.FullName sign /fd SHA256 /sha1 $cert.Thumbprint $catalog
if ($LASTEXITCODE -ne 0) { throw 'Catalog signing failed.' }
Export-Certificate -Cert $cert -FilePath 'C:\ElanProbe\ElanServerBinding.cer'
