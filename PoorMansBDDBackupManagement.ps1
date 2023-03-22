#Requires -PSEdition Core
[cmdletbinding(SupportsShouldProcess)]
Param(
[Parameter(Mandatory = $true, ParameterSetName = 'VerifyCatalog')]
    [switch]$VerifyBackupCatalog,
[Parameter(Mandatory = $true, ParameterSetName = 'RemoveOrphans')]
    [switch]$RemoveOrphanedBackupFiles,
[Parameter(Mandatory = $true, ParameterSetName = 'DeleteCatalog')]
    [switch]$DeleteBackupCatalog,
[Parameter(Mandatory = $true, ParameterSetName = 'RebuildMaster')]
    [switch]$RebuildMasterCatalog,
[Parameter(Mandatory = $true, ParameterSetName = 'RebuildMaster')]
[Parameter(Mandatory = $true, ParameterSetName = 'DeleteCatalog')]
[Parameter(Mandatory = $true, ParameterSetName = 'VerifyCatalog')]
[Parameter(Mandatory = $true, ParameterSetName = 'RemoveOrphans')]
[ValidateScript({Test-Path -LiteralPath $_ -PathType ‘Container’})]
    [string]$BackupDirectory,
[Parameter(Mandatory = $true, ParameterSetName = 'DeleteCatalog')]
[Parameter(Mandatory = $true, ParameterSetName = 'VerifyCatalog')]
[ValidateScript({Test-Path -LiteralPath $_ -PathType ‘Leaf’})]
    [string]$BackupCatalogPath
)

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

$Metrics = @{}

$Metrics.Add("StartTime",[DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss"))

if ($IsMacOS) {
    Write-Error "Unsupported OS"
    return
}

function Get-BackupFileHashPath {
    Param($BackupDirectory, $Hash)
    $BackupRoot = Join-path -Path $BackupDirectory -ChildPath "BackupFiles"
    $BackupPath = Join-Path -Path (Join-Path -Path $BackupRoot -ChildPath $Hash[0]) -ChildPath $Hash[1]
    $BackupFilePath = Join-Path -Path $BackupPath -ChildPath $Hash

    return $BackupFilePath
}

#Fill out some path variables
$MasterCatalogPath = Join-Path -Path $BackupDirectory -ChildPath "MasterCatalog.csv"
$BackupCatalogsDirectory = Join-Path -Path $BackupDirectory -ChildPath "BackupCatalogs"
if (-not (Test-Path -LiteralPath $BackupCatalogsDirectory)) {
    $null=New-Item -Path $BackupCatalogsDirectory -ItemType Directory
}

if ($VerifyBackupCatalog -or $DeleteBackupCatalog -or $RemoveOrphanedBackupFiles) {
    #Load the master catalog
    $MasterCatalog = @()
    $MasterLut = @{}
    Write-Host "Importing Master Catalog"

    if (Test-Path -LiteralPath $MasterCatalogPath) {
        $MasterCatalog = Import-Csv -LiteralPath $MasterCatalogPath
        foreach ($Item in $MasterCatalog) {
            $MasterLut.Add($Item.Hash,$Item)
        }
    } else {
        throw "Master catalog not found."
    }
}

if ($DeleteBackupCatalog) {
    #Remove old catalog and decrement from master catalog
    $Metrics.Add("RemovedFiles", 0)
    Write-Host "Removing catalog"

    $OldCatalogInfo = Import-Csv -LiteralPath $BackupCatalogPath
    $IT=0
    foreach ($Item in $OldCatalogInfo) {
        Write-Progress -Activity "Parsing old files" -Status $Item.Path -PercentComplete ($IT*100/$OldCatalogInfo.Length) -Id 11
        if ($Item.Type -ne "File") {
            $IT++
            continue
        }
        if ($MasterLut.ContainsKey($Item.Hash)) {
            if ($MasterLut[$Item.Hash].Uses -eq 1) {
                Write-Debug "Removing $((Get-BackupFileHashPath -BackupDirectory $BackupDirectory -Hash $Item.Hash))"
                Remove-Item -LiteralPath (Get-BackupFileHashPath -BackupDirectory $BackupDirectory -Hash $Item.Hash) -Force
                $Metrics["RemovedFiles"]+=1
                $MasterLut.Remove($Item.Hash)
            } else {
                $MasterLut[$Item.Hash].Uses=[int]$MasterLut[$Item.Hash].Uses-1
            }
        }
        $IT++
    }
    Write-Progress -Activity "Parsing old files" -PercentComplete 100 -Completed -Id 11

    Remove-Item -LiteralPath $BackupCatalogPath

    Write-Host "Saving master catalog"
    #Save new master
    $MasterLut.Values | Export-Csv -LiteralPath $MasterCatalogPath -NoTypeInformation
} elseif ($VerifyBackupCatalog) {
    $Metrics.Add("Files missing in Master Catalog", 0)
    $Metrics.Add("Files missing in backup directory", 0)
    $Metrics.Add("Files confirmed", 0)
    $Metrics.Add("Files with unkown hash", 0)
    $Metrics.Add("Directories", 0)

    $CatalogInfo = Import-Csv -LiteralPath $BackupCatalogPath
    $IT=0
    foreach ($Item in $CatalogInfo) {
        Write-Progress -Activity "Parsing files" -Status $Item.Path -PercentComplete ($IT*100/$CatalogInfo.Length) -Id 11
        $passtest=$true;
        if ($Item.Type -eq "Directory") {
            $Metrics["Directories"]+=1
            continue
        }
        if ($Item.Hash -eq "" -or $Item.Hash -eq $null) {
            $Metrics["Files with unkown hash"]+=1
            $Metrics["Files missing in backup directory"]+=1
            Write-Verbose "$($Item.Path) - $($Item.Hash) : unknown hash in backup catalog"
            continue
        }
        elseif (!$MasterLut.ContainsKey($Item.Hash)) {
            $Metrics["Files missing in Master Catalog"]+=1
            Write-Verbose "$($Item.Path) - $($Item.Hash) : missing from MasterCatalog"
            $passtest=$false
        }
        $BUPath = Get-BackupFileHashPath -BackupDirectory $BackupDirectory -Hash $Item.Hash
        if (-not (Test-Path -LiteralPath $BUPath)) {
            $Metrics["Files missing in backup directory"]+=1
            Write-Verbose "$($Item.Path) - $($Item.Hash) : missing from backup directory"
            $passtest = $false
        }
        if ($passtest) {
            $Metrics["Files confirmed"]+=1
        }
        $IT++
    }
    Write-Progress -Activity "Parsing files" -PercentComplete 100 -Completed -Id 11
} elseif ($RemoveOrphanedBackupFiles) {
    Write-Host "Grabbing list of all backed-up files"
    $AllBackupFiles = Get-ChildItem -LiteralPath (Join-path -Path $BackupDirectory -ChildPath "BackupFiles") -Recurse -File

    $Metrics.Add("Orphan Files Removed", 0)
    $IT=0
    foreach ($File in $AllBackupFiles) {
        if (-not ($MasterLut.ContainsKey($File.Name))) {
            Write-Progress -Activity "Parsing files" -Status $File.Name -PercentComplete ($IT*100/$AllBackupFiles.Length) -Id 11
            Remove-Item -LiteralPath $File.FullName -Force
            $Metrics["Orphan Files Removed"]+=1
            Write-Verbose "$($File.FullName) removed"
        }
        $IT++
    }
    Write-Progress -Activity "Parsing files" -PercentComplete 100 -Completed -Id 11
} elseif ($RebuildMasterCatalog) {
    Write-Host "Parsing Existing BackupFiles"
    $BackupRoot = Join-path -Path $BackupDirectory -ChildPath "BackupFiles"

    $AllBackupFiles = Get-ChildItem -LiteralPath $BackupRoot -Recurse -File

    #Parse backup files to get hashes

    $IT=0
    foreach ($File in $AllBackupFiles) {
        Write-Progress -Activity "Recataloging backup files" -PercentComplete ($IT*100/$AllBackupFiles.Length)
        $NewMasterLut.Add($File.Name, (New-Object -TypeName PSObject -Property @{Hash=$File.Name; Uses=0}))
        $IT++
    }
    Write-Progress -Activity "Recataloging backup files" -PercentComplete 100 -Completed

    #Now parse catalogs for use counts
    $BackupCatalogs = Get-ChildItem -LiteralPath $BackupCatalogsDirectory -Include "*.csv" -File
    $IT=0
    foreach ($File in $BackupCatalogs) {
        Write-Progress -Activity "Parsing catalog files" -PercentComplete ($IT*100/$BackupCatalogs.Length) -ID 10
    
        $CatalogData = Import-Csv -LiteralPath $File.FullName
        $IC = 0
        foreach ($Item in $CatalogData) {
            Write-Progress -Activity "Parsing $($File.FullName)" -PercentComplete ($IC*100/$CatalogData.Length) -ID 11

            if ($Item.Type -ne "File") {
                $IC++
                continue
            }
            if ($NewMasterLut.ContainsKey($Item.Hash)) {
                $NewMasterLut[$Item.Hash].Uses = [int]$NewMasterLut[$Item.Hash].Uses+1
            } else {
                Write-Warning "Matching backup file not found for $($Item.Path)"
            }

            $IC++
        }
        Write-Progress -Activity "Parsing $($File.FullName)" -PercentComplete ($IC*100/$CatalogData.Length) -ID 11

        $IT++
    }
    Write-Progress -Activity "Recataloging backup files" -PercentComplete 100 -Completed -id 10

    Write-Host "Saving master catalog"
    #Save new master
    $NewMasterLut.Values | Export-Csv -LiteralPath $MasterCatalogPath -NoTypeInformation

    Write-Host "You may want to consider running this again with the -RemoveOrphanedBackupFiles parameter after verifying all is well."
}
$Metrics.Add("EndTime",[DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss"))
Remove-FileLock -FileLock $FileLock

foreach($Key in $Metrics.Keys) {
    Write-Host "$Key - $($Metrics[$Key])"
}