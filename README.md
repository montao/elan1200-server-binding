# ELAN1200 touchpad binding for Windows Server 2025

Tested on the ASUS Zenbook Flip S UX370UAF, with Windows Server 2025 x64 and an `ACPI\ELAN1200` touchpad. This is an unsupported workaround for this hardware and OS combination.

The Server 2025 inbox `hidi2c.inf` on the test machine matches the HID-over-I²C compatible ID only on workstation editions. The build script reads the matching, locally installed Microsoft INF and verifies its driver binary. It generates a package that matches only `ACPI\ELAN1200`, targeting x64 build 26100 or later. It signs the generated catalog with a local test certificate.

## Build and install

1. On the target Windows Server machine, put the Microsoft Enterprise WDK ISO at `C:\ElanProbe\EWDK.iso`. Run `build-server-binding.ps1` in elevated Windows PowerShell. It builds the package in `C:\ElanProbe\ServerBinding`.
2. To stage the binding with normal driver signature enforcement, temporarily trust the generated catalog certificate locally while running PnPUtil. Run the following in elevated Windows PowerShell. The script removes only the certificate entries it added.

   ```powershell
   $certFile = 'C:\ElanProbe\ElanServerBinding.cer'
   $cert = Get-PfxCertificate -FilePath $certFile
   $added = @()
   try {
       foreach ($store in 'Root', 'TrustedPublisher') {
           $path = "Cert:\LocalMachine\$store"
           $entry = "$path\$($cert.Thumbprint)"
           if (!(Test-Path $entry)) {
               Import-Certificate -FilePath $certFile -CertStoreLocation $path -ErrorAction Stop | Out-Null
               $added += $entry
           }
       }
       pnputil /add-driver C:\ElanProbe\ServerBinding\ElanServerBinding.inf /install
       if ($LASTEXITCODE -ne 0) { throw "PnPUtil exited with code $LASTEXITCODE" }
   } finally {
       foreach ($entry in $added) { Remove-Item -LiteralPath $entry }
   }
   ```

3. Obtain ASUS Precision Touchpad 11.0.0.30 from the [ASUS support page](https://www.asus.com/laptops/for-home/zenbook/zenbook-flip-s-ux370/helpdesk_download?model2Name=ZenBook-Flip-S-UX370), or from the Windows 11 driver store on the same machine. Install the signed `AsusPTPFilter.inf` with `pnputil /add-driver <path-to-INF> /install`. It binds to `HID\ELAN1200&Col02`.
4. Check for **I2C HID Device** and **ASUS Precision Touchpad** in Device Manager. Test pointer movement and clicking with the built-in pad. On the test machine both drivers loaded again after reboot.

To roll back, identify each package's published name with `pnputil /enum-drivers` and remove the ASUS filter followed by the binding with `pnputil /delete-driver <published-name> /uninstall`.

This repository contains the build script and instructions. The Microsoft driver and INF, ASUS package, generated catalog, and signing credentials are obtained or generated locally.
