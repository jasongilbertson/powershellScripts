<#
.SYNOPSIS
# script to schedule task
# schedule-task.ps1
# writes event 4103 to Microsoft-Windows-Powershell on completion in Operational event log

.LINK
    invoke-webRequest "https://raw.githubusercontent.com/jagilber/powershellScripts/master/schedule-task.ps1" -outFile "$pwd\schedule-task.ps1";
    .\schedule-task.ps1 -start -scriptFile https://raw.githubusercontent.com/jagilber/powershellScripts/master/temp/task.ps1 -overwrite
#>

param(
    [string]$scriptFileStoragePath = 'c:\taskscripts', #$pwd, #$PSScriptRoot,
    [string]$scriptFile = '',
    [string]$taskName = 'az-vmss-cse-task',
    [string]$action = 'powershell.exe',
    [string]$actionParameter = '-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -NoLogo -NoProfile',
    [string]$triggerTime = '3am',
    [ValidateSet('startup', 'once', 'daily', 'weekly')]
    [string]$triggerFrequency = 'startup',
    [string]$principal = 'BUILTIN\ADMINISTRATORS', #'SYSTEM',
    [ValidateSet('none', 'password', 's4u', 'interactive', 'serviceaccount', 'interactiveorpassword', 'group')]
    [string]$principalLogonType = 'group',
    [switch]$overwrite,
    [switch]$start,
    [ValidateSet('highest', 'limited')]
    [string]$runLevel = 'limited'
)

$PSModuleAutoLoadingPreference = 2
$ErrorActionPreference = $VerbosePreference = $DebugPreference = 'continue'
Start-Transcript -Path "$PSScriptRoot\trasncript.log"
$error.Clear()


$global:currentTask = $null

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

if (!$isAdmin) {
    write-error "not administrator"
}

write-output (whoami /groups)

if ($scriptFile) {
    if (!(Test-Path $scriptFileStoragePath -PathType Container)) { 
        mkdir $scriptFileStoragePath
    }
    
    $scriptFileName = [io.path]::GetFileName($scriptFile)

    if ($scriptFile.StartsWith('http')) {
        Invoke-WebRequest -Uri $scriptFile -OutFile "$($scriptFileStoragePath)\$($scriptFileName)" -UseBasicParsing
    }
    else {
        copy-item $scriptFile -Destination $scriptFileStoragePath
    }

    $scriptFile = "$($scriptFileStoragePath)\$($scriptFileName)"
    write-output "script file: $scriptFile"

    if (!(test-path $scriptFile)) {
        write-error "$scriptFile does not exist"
    }

    $scriptFile = " -File `"$($scriptFileStoragePath)\$($scriptFileName)`""
}

$global:currentTask = Get-ScheduledTask -TaskName $taskName

if ($global:currentTask -and $overwrite) {
    write-output "deleting current task $taskname" -ForegroundColor Red
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

write-output "`$taskAction = New-ScheduledTaskAction -execute $action -argument $actionParameter$scriptFile"
$taskAction = New-ScheduledTaskAction -execute $action -argument "$actionParameter$scriptFile"

$taskTrigger = $null
switch ($triggerFrequency) {
    "startup" { $taskTrigger = New-ScheduledTaskTrigger -AtStartup }
    "once" { $taskTrigger = New-ScheduledTaskTrigger -once -At $triggerTime }
    "daily" { $taskTrigger = New-ScheduledTaskTrigger -daily -At $triggerTime }
    "weekly" { $taskTrigger = New-ScheduledTaskTrigger -weekly -At $triggerTime }
}

$taskPrincipal = $null
if ($principalLogonType -ieq 'group') {
    $taskPrincipal = New-ScheduledTaskPrincipal -GroupId $principal -RunLevel $runLevel
}
else {
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $principal -LogonType $principalLogonType -RunLevel $runLevel
}

$settings = New-ScheduledTaskSettingsSet -MultipleInstances Parallel

write-output "$result = Register-ScheduledTask -TaskName $taskName `
    -Action $taskAction `
    -Trigger $taskTrigger `
    -Settings $settings `
    -Principal $taskPrincipal `
    -Force:$overwrite
"

$result = Register-ScheduledTask -TaskName $taskName `
    -Action $taskAction `
    -Trigger $taskTrigger `
    -Settings $settings `
    -Principal $taskPrincipal `
    -Force:$overwrite

write-output ($result | convertto-json) -ForegroundColor Green
write-output ($MyInvocation | convertto-json)

$global:currentTask = Get-ScheduledTask -TaskName $taskName
write-output ($global:currentTask | convertto-json)

if ($start) {
    $startResults = Start-ScheduledTask -TaskName $taskName
}

write-output ($startResults | convertto-json)

New-WinEvent -ProviderName Microsoft-Windows-Powershell `
    -id 4103 `
    -Payload @(
        "context:`r`n$(($MyInvocation | convertto-json -Depth 1))", 
        "user data:`r`n$(([environment]::GetEnvironmentVariables() | convertto-json))", 
        "start results:`r`n$(($startResults | convertto-json -Depth 1))`r`ncurrent task:`r`n$(($global:currentTask | convertto-json -Depth 1))`r`nerror:`r`n$(($error | convertto-json -Depth 1))"
    )

Stop-Transcript