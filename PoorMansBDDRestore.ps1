#Requires -PSEdition Core
Param([string]$RestorePath,[string]$BackupDirectory,[string]$IncludeFilter,[string]$ExcludeFilter,[string]$BackupCatalog,[switch]$Overwrite)

if ($IsMacOS) {
    Write-Error "Unsupported OS"
    return
}

function Backup-File {
    Param($FilePath, $BackupDirectory, $Hash)
    #Build Dirs
    $BackupRoot = Join-path -Path $BackupDirectory -ChildPath "BackupFiles"
    $BackupPath = Join-Path -Path (Join-Path -Path $BackupRoot -ChildPath $Hash[0]) -ChildPath $Hash[1]
    $BackupFilePath = Join-Path -Path $BackupPath -ChildPath $Hash

    if (-not (Test-Path -LiteralPath $BackupPath)) {
        $null=New-Item -ItemType Directory -Path $BackupPath -Force
    }

    if (-not (Test-Path -LiteralPath $BackupFilePath)) {
        #Copy File
        $null=Copy-Item -LiteralPath $FilePath -Destination (Join-Path -Path $BackupPath -ChildPath $Hash)
    }
}

function Get-BackupFileHashPath {
    Param($BackupDirectory, $Hash)
    $BackupRoot = Join-path -Path $BackupDirectory -ChildPath "BackupFiles"
    $BackupPath = Join-Path -Path (Join-Path -Path $BackupRoot -ChildPath $Hash[0]) -ChildPath $Hash[1]
    $BackupFilePath = Join-Path -Path $BackupPath -ChildPath $Hash

    return $BackupFilePath
}

function Get-FileLock {
    param(
        [parameter(Mandatory=$True)]
        [string]$LiteralPath
    )

    try {
        $LockFile = [System.IO.FileInfo]::new($LiteralPath)
        $LockStream = $LockFile.Open([System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        return $LockStream
    } 
    catch
    {
        return $null
    }
}
function Remove-FileLock {
    param(
        [parameter(Mandatory=$True)]
        [System.IO.Stream]$FileLock
    )

    $FileLock.Close()
    $FileLock.Dispose()

    Remove-Item -Path $FileLock.Name -ErrorAction SilentlyContinue
}

#Prevent attempting to do stuff when another script is messing with the files
$FileLockPath = (Join-Path -Path $BackupDirectory -ChildPath "BackupLock.lck")
$FileLock = Get-FileLock -LiteralPath $FileLockPath
if ($FileLock -eq $null) {
    throw "A backup operation already appears to be in progress. Please wait for that to finish before manipulating backup files. If no backup operations are in progress, then a open powershell session likely was used for a backup that was cancelled. Restart PowerShell if so. (A lock to $FileLockPath could not be established)"
}

#Fill out some path variables
$MasterCatalogPath = Join-Path -Path $BackupDirectory -ChildPath "MasterCatalog.csv"
$BackupCatalogsDirectory = Join-Path -Path $BackupDirectory -ChildPath "BackupCatalogs"
if (-not (Test-Path -LiteralPath $BackupCatalogsDirectory)) {
    $null=New-Item -Path $BackupCatalogsDirectory -ItemType Directory
}

#Load backup catalog
$BackupCatalogData = Import-Csv -LiteralPath $BackupCatalog -ErrorAction Stop

#Loop through each file in catalog
$FI =0
foreach ($File in $BackupCatalogData) {
    Write-Progress -Activity "Restoring Files" -Status $File.Path -PercentComplete ($FI*100/$BackupCatalogData.Length)
    if ($IncludeFilter -ne "" -and $File.Path -notmatch $IncludeFilter) {
        $FI++
        continue
    }
    if ($ExcludeFilter -ne "" -and $File.Path -match $ExcludeFilter) {
        $FI++
        continue
    }
    $RestoreTarget = (Join-Path -Path $RestorePath -ChildPath $File.Path)
    if ($File.Type -eq "Directory" -and -not (Test-Path -LiteralPath $RestoreTarget)) {
        $Null = New-Item -Path $RestoreTarget -ItemType Directory
    }
    if ($File.Type -eq "File" -and ($Overwrite -or -not (Test-Path -LiteralPath $RestoreTarget))) {
        
        if (-not (Test-Path -LiteralPath (Split-Path -Path $RestoreTarget -Parent))) {
            $Null = New-Item -Path (Split-Path -LiteralPath $RestoreTarget -Parent) -ItemType Directory -Force
        }

        #Restore the file, overwrite if selected
        $null = Copy-Item -LiteralPath (Get-BackupFileHashPath -BackupDirectory $BackupDirectory -Hash $File.Hash) -Destination $RestoreTarget -Force
    }
    #Restore the permissions
    if ($IsLinux) {
        #Restore User, Group
        &chown "$($File.User):$($File.Group)" "$RestoreTarget"
        
        #Restore Permissions
        &chmod $File.Permissions "$RestoreTarget"

    } elseif ($IsWindows) {
        $CurrentACL = Get-ACL -LiteralPath $RestoreTarget
        $null = $CurrentACL.SetSecurityDescriptorSddlForm($File.Permissions)
        $null = $CurrentACL.SetOwner([System.Security.Principal.NTAccount]::new($File.User))
        $null = $CurrentACL.SetGroup([System.Security.Principal.NTAccount]::new($File.Group))
        try {
            $null = Set-Acl -LiteralPath $RestoreTarget -AclObject $CurrentACL -ErrorAction Stop
        } catch {
            Write-Host "Debug for error below: $($File.User) - $($File.Group) on $($File.Path)"
            $_
        }

        #TODO: Does this account for broken inheritance? Audit or other access?
    }

    #Restore the attributes
    $AttributeFilter = [System.IO.FileAttributes]::Archive -bor [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::Normal -bor [System.IO.FileAttributes]::ReadOnly -bor [System.IO.FileAttributes]::System
    Set-ItemProperty -LiteralPath $RestoreTarget -Name attributes -Value ([System.IO.FileAttributes]$File.Attributes -band $AttributeFilter)

    $FI++
}
Write-Progress -Activity "Restoring Files" -PercentComplete 100 -Completed
Remove-FileLock -FileLock $FileLock