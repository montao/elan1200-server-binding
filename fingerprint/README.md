# Goodix fingerprint enrollment on Windows Server 2025

Tested on an ASUS with Goodix Fingerprint SPI Device (ACPI\GXFP3200, driver 1.0.20.24) and Intel Serial IO SPI Host Controller (PCI\VEN_8086&DEV_9D29, driver 30.100.1713.2). Windows logged enrollment, credential registration, and a fingerprint match for a standard domain account. The Windows Biometric Service blocks enrollment for the built-in Administrator account (SID ending in -500).

## Reinstall

In elevated Windows PowerShell on a working installation, identify the signed driver packages:

```powershell
Get-CimInstance Win32_PnPSignedDriver |
    Where-Object { $_.DeviceID -like 'ACPI\GXFP3200*' -or $_.DeviceID -like 'PCI\VEN_8086&DEV_9D29*' } |
    Select-Object DeviceName, DriverVersion, InfName, IsSigned
```

Use `pnputil /export-driver oemNN.inf <folder>` with each actual published INF name and an existing destination folder. Back up the folders separately. On Server 2025, install the Intel package first, then Goodix:

```powershell
pnputil /add-driver "C:\Drivers\Intel\*.inf" /subdirs /install
pnputil /add-driver "C:\Drivers\Goodix\*.inf" /subdirs /install
dism /online /Enable-Feature /FeatureName:BiometricFramework /NoRestart
```

Restart Server, confirm the reader in Device Manager, and check the applicable Group Policy for biometrics, biometric logon, and biometric logon for domain users.

## Enroll

At the physical console, sign in as the account being enrolled. In Windows PowerShell, run `.\Enroll.ps1` from its folder. Touch and lift your right index finger as prompted. After capture, enter your current Windows password at the local prompt. Windows receives the password in its protected credential format. Use `-CredentialOnly` to retry the password step for an existing template. Press **Win+L** and test the same finger. Enroll again after a fresh installation.

The Microsoft-Windows-Biometrics/Operational log records enrollment (1010), credential storage (1500), and identification (1004).

See [PnPUtil](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax) and [WinBioSetCredential](https://learn.microsoft.com/en-us/windows/win32/api/winbio/nf-winbio-winbiosetcredential).
