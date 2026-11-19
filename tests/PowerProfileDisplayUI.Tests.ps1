$ErrorActionPreference='Stop'
$project=if($env:POWERPROFILE_DISPLAY_TEST_ROOT){$env:POWERPROFILE_DISPLAY_TEST_ROOT}else{Split-Path -Parent $PSScriptRoot}
. (Join-Path $project 'PowerProfileDisplay.ps1')
Initialize-DisplayNative
Add-Type -Path @((Join-Path $project 'PowerProfileWorkspace.cs'),(Join-Path $project 'PowerProfileCards.cs'),(Join-Path $project 'PowerProfileSkin.cs'),(Join-Path $project 'PowerProfileInsightsUI.cs')) -ReferencedAssemblies System.Drawing,System.Windows.Forms,System.Core,Accessibility
[ProfileSkin]::MonitorWindows()
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DisplayFocusTest { [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); }
'@
$foreground=[DisplayFocusTest]::GetForegroundWindow()
try {
    [PowerProfileDisplay]::ScreensOff()
    [Windows.Forms.Application]::DoEvents()
    if([PowerProfileDisplay]::BlackScreenCount -ne [Windows.Forms.Screen]::AllScreens.Length){throw 'Not all screens covered'}
    Write-Host 'PASS native blackout covers every connected display'
    if([DisplayFocusTest]::GetForegroundWindow() -ne $foreground){throw 'Blackout stole keyboard focus'}
    Write-Host 'PASS blackout preserves foreground application'
    [PowerProfileDisplay]::ScreensOff()
    if([PowerProfileDisplay]::BlackScreenCount -ne [Windows.Forms.Screen]::AllScreens.Length){throw 'Duplicate masks'}
    Write-Host 'PASS repeated blackout does not accumulate windows'
    foreach($skin in @('Liquid','ClassicGlass','Standard')){foreach($dark in @($false,$true)){
        [ProfileSkin]::Set($skin);[ProfileTheme]::Dark=$dark
        [Windows.Forms.Application]::RaiseIdle([EventArgs]::Empty)
        foreach($form in [Windows.Forms.Application]::OpenForms){
            [ProfileTheme]::ApplyWindow($form)
            [ProfileTheme]::Apply($form,$dark)
            if($form.BackColor.ToArgb() -ne [Drawing.Color]::Black.ToArgb()){throw "Theme recolored blackout: $skin dark=$dark"}
            $bitmap=New-Object Drawing.Bitmap($form.ClientSize.Width,$form.ClientSize.Height)
            try {
                $form.DrawToBitmap($bitmap,$form.ClientRectangle)
                for($y=0;$y -lt $bitmap.Height;$y+=31){for($x=0;$x -lt $bitmap.Width;$x+=31){
                    if($bitmap.GetPixel($x,$y).ToArgb() -ne [Drawing.Color]::Black.ToArgb()){throw "Non-black rendered pixel: $skin dark=$dark at $x,$y"}
                }}
            }finally{$bitmap.Dispose()}
        }
        Write-Host "PASS global idle and explicit $skin dark=$dark keep blackout pixels black"
    }}
}finally{[PowerProfileDisplay]::ScreensOn()}
if([PowerProfileDisplay]::BlackScreenCount -ne 0){throw 'Wake left blackout windows'}
Write-Host 'PASS wake disposes every blackout window'

. (Join-Path $project 'PowerProfileDetection.ps1')
$ScriptDir=Join-Path ([IO.Path]::GetTempPath()) ('PowerProfileDisplayMenu-'+[Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($ScriptDir)
$menu=New-Object Windows.Forms.ContextMenuStrip
$menuSettings=New-Object Windows.Forms.ToolStripMenuItem
function Write-ProfileEvent {param($Event,$Message,$Level,$Data)}
try {
    # Load the production menu and event handlers, then click each actual choice.
    $source=[IO.File]::ReadAllText((Join-Path $project 'PowerProfileTray.ps1'))
    $start=$source.IndexOf('$menuDisplay=');$end=$source.IndexOf('$menuSettings.Image',$start)
    . ([scriptblock]::Create($source.Substring($start,$end-$start)))
    if($menuDisplayDelay.DropDownItems.Count -ne 5){throw 'Expected five time choices'}
    foreach($item in $menuDisplayDelay.DropDownItems){
        $item.PerformClick()
        $options=Get-DisplayOptions $ScriptDir
        if($options.idleMinutes -ne [int]$item.Tag -or -not $options.enabled){throw 'Menu selection not persisted'}
        Write-Host "PASS production menu saves $($item.Tag) minutes without disabling"
    }
    $menuDisplay.PerformClick()
    if((Get-DisplayOptions $ScriptDir).enabled){throw 'Toggle not persisted'}
    Write-Host 'PASS time menu retains independent enable switch'
}finally{
    $menu.Dispose();$menuSettings.Dispose()
    $prefix=([IO.Path]::GetTempPath()).TrimEnd('\')+'\PowerProfileDisplayMenu-'
    if(-not ([IO.Path]::GetFullPath($ScriptDir)).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup'}
    Remove-Item -LiteralPath $ScriptDir -Recurse -Force
}
