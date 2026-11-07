param([switch]$CredentialOnly)
$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.User.Value.EndsWith('-500')) {
    throw 'Windows blocks fingerprint enrollment for the built-in Administrator account.'
}
Add-Type @'
using System;
using System.Security;
using System.Runtime.InteropServices;
public static class AsusBio {
    [DllImport("winbio.dll")] public static extern int WinBioCancel(uint session);
    public static System.Threading.Tasks.Task<Tuple<int,uint>> Capture(uint session) {
        return System.Threading.Tasks.Task.Run(() => {
            uint reject;
            int result=WinBioEnrollCapture(session,out reject);
            return Tuple.Create(result,reject);
        });
    }
    [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("winbio.dll")] public static extern int WinBioOpenSession(uint factor,uint pool,uint flags,IntPtr units,UIntPtr count,IntPtr db,out uint session);
    [DllImport("winbio.dll")] public static extern int WinBioEnumBiometricUnits(uint factor,out IntPtr units,out UIntPtr count);
    [DllImport("winbio.dll")] public static extern int WinBioFree(IntPtr units);
    [DllImport("winbio.dll")] public static extern int WinBioEnrollBegin(uint session,byte finger,uint unit);
    [DllImport("winbio.dll")] public static extern int WinBioEnrollCapture(uint session,out uint reject);
    [DllImport("winbio.dll")] public static extern int WinBioEnrollCommit(uint session,IntPtr id,IntPtr created);
    [DllImport("winbio.dll")] public static extern int WinBioEnrollDiscard(uint session);
    [DllImport("winbio.dll")] public static extern int WinBioCloseSession(uint session);
    [DllImport("winbio.dll")] static extern int WinBioSetCredential(uint type,IntPtr data,UIntPtr size,uint format);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern bool CredProtect(bool asSelf,IntPtr source,uint length,IntPtr target,ref uint size,out int protection);

    public static int SaveCredential(SecureString password) {
        IntPtr plain=Marshal.SecureStringToGlobalAllocUnicode(password), wrapped=IntPtr.Zero;
        uint size=0;
        try {
            int protection;
            uint length=(uint)password.Length+1;
            if (CredProtect(true,plain,length,IntPtr.Zero,ref size,out protection) ||
                Marshal.GetLastWin32Error()!=122 || size==0)
                throw new InvalidOperationException("Could not size the credential buffer.");
            wrapped=Marshal.AllocHGlobal(checked((int)size*2));
            uint actual=size;
            if (!CredProtect(true,plain,length,wrapped,ref actual,out protection))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            return WinBioSetCredential(1,wrapped,(UIntPtr)(actual*2),3);
        } finally {
            Marshal.ZeroFreeGlobalAllocUnicode(plain);
            if (wrapped!=IntPtr.Zero) {
                for(int i=0;i<size*2;i++) Marshal.WriteByte(wrapped,i,0);
                Marshal.FreeHGlobal(wrapped);
            }
        }
    }
}
'@
if ((Get-Process -Id $PID).SessionId -ne [AsusBio]::WTSGetActiveConsoleSessionId()) {
    throw 'Run this on the ASUS console.'
}
function Confirm-BioResult($Result,$Operation) {
    if ($Result -ne 0) { throw ('{0} returned 0x{1:X8}' -f $Operation,$Result) }
}
if (!$CredentialOnly) {
Add-Type -AssemblyName System.Windows.Forms
$form=New-Object Windows.Forms.Form
$form.Text='Fingerprint enrollment'
$form.Width=480
$form.Height=150
$form.StartPosition='CenterScreen'
$form.TopMost=$true
$label=New-Object Windows.Forms.Label
$label.Dock='Fill'
$label.TextAlign='MiddleCenter'
$label.Text='Preparing the fingerprint reader...'
$form.Controls.Add($label)
$form.Show()
$form.Activate()
[Windows.Forms.Application]::DoEvents()
$form.Refresh()
$session=[uint32]0
$zero=[IntPtr]::Zero
Confirm-BioResult ([AsusBio]::WinBioOpenSession(8,1,0,$zero,[UIntPtr]::Zero,$zero,[ref]$session)) 'Opening biometric session'
$pending=$false
try {
    $units=[IntPtr]::Zero
    $count=[UIntPtr]::Zero
    Confirm-BioResult ([AsusBio]::WinBioEnumBiometricUnits(8,[ref]$units,[ref]$count)) 'Enumerating fingerprint readers'
    try {
        if ($count.ToUInt64() -ne 1) { throw "Expected one fingerprint reader. Found $count." }
        $unit=[uint32][Runtime.InteropServices.Marshal]::ReadInt32($units)
    } finally {
        if ($units -ne [IntPtr]::Zero) { [AsusBio]::WinBioFree($units) | Out-Null }
    }
    Write-Host 'Reader found. Starting enrollment.'
    Confirm-BioResult ([AsusBio]::WinBioEnrollBegin($session,2,$unit)) 'Starting enrollment'
    $pending=$true
    do {
        $label.Text='Touch and lift your right index finger. Repeat as samples are accepted.'
        $form.Refresh()
        [Windows.Forms.Application]::DoEvents()
        Write-Host 'Touch and lift your right index finger.'
        $reject=[uint32]0
        $capture=[AsusBio]::Capture($session)
        $deadline=[DateTime]::UtcNow.AddSeconds(45)
        while (!$capture.IsCompleted) {
            [Windows.Forms.Application]::DoEvents()
            if ($form.IsDisposed -or [DateTime]::UtcNow -gt $deadline) {
                [void][AsusBio]::WinBioCancel($session)
                throw 'No sample received. Enrollment stopped.'
            }
            Start-Sleep -Milliseconds 50
        }
        $result=$capture.Result.Item1
        $reject=$capture.Result.Item2
        if (('{0:X8}' -f $result) -eq '80098008') {
            Write-Host "Sample rejected ($reject). Change your finger position slightly."
            $result=0x00090001
        } elseif ($result -ne 0x00090001) {
            Confirm-BioResult $result 'Capturing fingerprint'
        }
    } while ($result -eq 0x00090001)
    $identityBuffer=[Runtime.InteropServices.Marshal]::AllocHGlobal(76)
    try {
        $newTemplate=[Runtime.InteropServices.Marshal]::AllocHGlobal(1)
        try {
            Confirm-BioResult ([AsusBio]::WinBioEnrollCommit($session,$identityBuffer,$newTemplate)) 'Saving fingerprint'
        } finally {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($newTemplate)
        }
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($identityBuffer)
    }
    $pending=$false
} finally {
    if ($pending) { [AsusBio]::WinBioEnrollDiscard($session) | Out-Null }
    [AsusBio]::WinBioCloseSession($session) | Out-Null
    $form.Dispose()
}
}
Write-Host 'Windows uses your protected password credential to enable biometric sign-in.'
$password=Read-Host "Current Windows password for $($identity.Name)" -AsSecureString
try {
    if (!$password.Length) { throw 'No password entered.' }
    Confirm-BioResult ([AsusBio]::SaveCredential($password)) 'Registering biometric sign-in credential'
} finally {
    $password.Dispose()
}
Write-Host 'Press Win+L and test fingerprint sign-in.'
