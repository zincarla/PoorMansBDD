#Requires -PSEdition Core
Param([string]$BackupSource,[string]$BackupDirectory,[switch]$UseDatesForDelta,[string]$DeltaCatalogPath,[switch]$NoContinueOnDeltaFail,[int32]$AutoRemoveTime,[string]$IncludeFilter,[string]$ExcludeFilter)

$BackupDirectory = (Get-Item -LiteralPath $BackupDirectory -ErrorAction Stop).FullName

$Metrics = @{}

$Metrics.Add("StartTime",[DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss"))

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

function Convert-UnixFileModeToChmod {
    Param([System.IO.UnixFileMode]$UnixFileMode)
    $Special = 0
    if ($UnixFileMode.HasFlag([System.IO.UnixFileMode]::StickyBit)) {
        $Special = $Special -bor 1
    }
    if ($UnixFileMode.HasFlag([System.IO.UnixFileMode]::SetGroup)) {
        $Special = $Special -bor 2
    }
    if ($UnixFileMode.HasFlag([System.IO.UnixFileMode]::SetUser)) {
        $Special = $Special -bor 4
    }

    $User = 0
    if ($UnixFileMode.HasFlag([System.IO.UnixFileMode]::UserExecute)) {
        $User = $User -bor 1
    }
    if ($UnixFileMode.HasFlag([System.IO.UnixFileMode]::UserWrite)) {
        $User = $User -bor 2
    }
    if ($UnixFileMode.HasFlag([System.IO.UnixFileMode]::UserRead)) {
        $User = $User -bor 4
    }

    $Group = 0
    if ($UnixFileMode.HasFlag([System.IO.UnixFileMode]::GroupExecute)) {
        $Group = $Group -bor 1
    }
    if ($UnixFileMode.HasFlag([System.IO.UnixFileMode]::GroupWrite)) {
        $Group = $Group -bor 2
    }
    if ($UnixFileMode.HasFlag([System.IO.UnixFileMode]::GroupRead)) {
        $Group = $Group -bor 4
    }

    $Others = 0
    if ($UnixFileMode.HasFlag([System.IO.UnixFileMode]::OtherExecute)) {
        $Others = $Others -bor 1
    }
    if ($UnixFileMode.HasFlag([System.IO.UnixFileMode]::OtherWrite)) {
        $Others = $Others -bor 2
    }
    if ($UnixFileMode.HasFlag([System.IO.UnixFileMode]::OtherRead)) {
        $Others = $Others -bor 4
    }

    return $Special.ToString()+$User.ToString()+$Group.ToString()+$Others.ToString()
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
$NewBackupCatalogPath = Join-Path -Path $BackupCatalogsDirectory -ChildPath "$(Get-Date -Format "yyyy-MM-dd-HH-mm").csv"

$Metrics.Add("CatalogPath", $NewBackupCatalogPath)

if ($DeltaCatalogPath -eq "" -and $UseDatesForDelta) {
    Write-Host "Searching for delta candidate in $BackupCatalogsDirectory"
    $PreviousCatalogs = Get-ChildItem -LiteralPath $BackupCatalogsDirectory -Include "*.csv" | Sort-Object -Descending -Property Name
    if ($PreviousCatalogs.Length -gt 0) {
        $DeltaCatalogPath = $PreviousCatalogs[0]
        Write-Host "Will use $($PreviousCatalogs[0].FullName)"
    } else {
        Write-Warning "Failed to grab delta file, none found"
        if ($NoContinueOnDeltaFail) {
            Remove-FileLock -FileLock $FileLock
            return
        }
        $UseDatesForDelta = $false
        $DeltaCatalogPath = $null
    }
}
$Metrics.Add("DeltaCatalog", [string]$DeltaCatalogPath)

Write-Host "Grabbing list of files to backup"

#Grab a list of files to be backed up
$ToBackup = Get-ChildItem -LiteralPath $BackupSource -Recurse
if ($IsWindows) {
    $ToBackup = $ToBackup | Where-Object {$_.FullName -inotlike "$BackupDirectory*"}
}
if ($IsLinux) {
    $ToBackup = $ToBackup | Where-Object {$_.FullName -cnotlike "$BackupDirectory*"}
}

$Metrics.Add("Files", 0)
$Metrics.Add("Directories", 0)
$Metrics.Add("Excluded",0)

#Build the new catalog
$NewCatalogInfo = @()
$FilesProcessed = 0
$MaxFiles = $ToBackup.Length
Write-Progress -Activity "Parsing files to backup" -PercentComplete 0
foreach ($File in $ToBackup) {
    Write-Progress -Activity "Parsing files to backup" -Status "Initial parse of $($File.FullName)" -PercentComplete ($FilesProcessed*100/$MaxFiles)
    
    $RelPath = $File.FullName.Substring($BackupSource.Length)

    if ($IncludeFilter -ne "" -and $RelPath -notmatch $IncludeFilter) {
        $Metrics["Excluded"]+=1
        continue #Do not add to catalog
    }
    if ($ExcludeFilter -ne "" -and $RelPath -match $ExcludeFilter) {
        $Metrics["Excluded"]+=1
        continue #Do not add to catalog
    }

    $ItemType = ""
    if ($File.Attributes.HasFlag([System.IO.FileAttributes]::Directory)) {
        $ItemType = "Directory"
        $Metrics["Directories"]+=1
    } else {
        $ItemType = "File"
        $Metrics["Files"]+=1
    }
    $Size=0
    $LastWriteTime=""
    $CreateTime = ""
    $Permissions = ""
    $User=""
    $Group=""

    if ($ItemType -ne "Directory") {
        $Size = $File.Length
        $LastWriteTime = $File.LastAccessTimeUtc.ToFileTimeUtc()
        $CreateTime = $File.CreationTimeUtc.ToFileTimeUtc()
    }

    if ($IsLinux) {
        $Permissions = Convert-UnixFileModeToChmod -UnixFileMode $File.UnixFileMode
        $User = $File.User
        $Group = $File.Group
    }

    if ($IsWindows) {
        $Access = (Get-ACL -LiteralPath $File.FullName)
        $Permissions = $Access.SDDL
        $User = $Access.Owner
        $Group = $Access.Group
    }
    
    $NewCatalogInfo += New-Object -TypeName PSObject -Property @{Type=$ItemType; Path=$RelPath; Size=$Size; Hash=""; LastWriteTimeUtc=$LastWriteTime; CreationTimeUtc=$CreateTime; Permissions=$Permissions; User=$User; Group=$Group; Attributes=[int64]$File.Attributes}
    $FilesProcessed++
}
Write-Progress -Activity "Parsing files to backup" -PercentComplete 100 -Completed

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
    Write-Warning "Master catalog not found. A new one will be created."
}


if ($UseDatesForDelta) {
    $Metrics.Add("FilesSkippedByDeltaCheck", 0)
    Write-Host "Importing delta catalog"
    #Compare catalogs, update hashes on what already exists
    $DeltaCatalog = Import-Csv -LiteralPath $DeltaCatalogPath
    #Create LUT of old catalog by file path
    $Lut = @{}

    foreach ($Item in $DeltaCatalog) {
        $Lut.Add($Item.Path,$Item)
    }

    Write-Progress -Activity "Parsing delta" -PercentComplete 0
    $FilesProcessed=0
    for ($I=0; $I-lt $NewCatalogInfo.Length; $I++) {
        if ($NewCatalogInfo[$I].Type -ne "File" -or -not $Lut.ContainsKey($NewCatalogInfo[$I].Path)) {
            $FilesProcessed++
            continue
        }
        $CurrentLu = $Lut[$NewCatalogInfo[$I].Path];
        if ($CurrentLu.Hash -ne $null -and $CurrentLu.Hash -ne "" -and $CurrentLu.LastWriteTimeUtc -eq $NewCatalogInfo[$I].LastWriteTimeUtc -and $CurrentLu.CreationTimeUtc -eq $NewCatalogInfo[$I].CreationTimeUtc -and $CurrentLu.Size -eq $NewCatalogInfo[$I].Size) {
            $NewCatalogInfo[$I].Hash = $CurrentLu.Hash
            $Metrics["FilesSkippedByDeltaCheck"]+=1
        }
        $FilesProcessed++
        Write-Progress -Activity "Parsing files to backup" -Status "Delta parse of $($NewCatalogInfo[$I].Path)" -PercentComplete ($FilesProcessed*100/$MaxFiles)
    }
    Write-Progress -Activity "Parsing files to backup" -PercentComplete 100 -Completed
    $DeltaCatalog = $null
    $Lut = $null
}

#Hash files from new catalog
Write-Progress -Activity "Hashing files" -PercentComplete 0
$Metrics.Add("FilesHashed", 0)
for ($I=0; $I-lt $NewCatalogInfo.Length; $I++) {
    if (($NewCatalogInfo[$I].Hash -eq "" -or $NewCatalogInfo[$I].Hash -eq $null) -and $NewCatalogInfo[$I].Type -eq "File") {
        $HashData = ""
        $HashData = Get-FileHash -LiteralPath (Join-Path -Path $BackupSource -ChildPath $NewCatalogInfo[$I].Path) -Algorithm SHA256
        if ($HashData -ne "" -and $HashData -ne $null) {
            $NewCatalogInfo[$I].Hash = $HashData.Hash.ToString()
            $Metrics["FilesHashed"]+=1
        }
    }
    Write-Progress -Activity "Hashing files" -Status $NewCatalogInfo[$I].Path -PercentComplete ($I*100/$NewCatalogInfo.Length)
}
Write-Progress -Activity "Hashing files" -PercentComplete 100 -Completed

#Compare catalogs, increment old entries as needed and save new files
Write-Progress -Activity "Backing up files" -PercentComplete 0
$Metrics.Add("NewFiles", 0)
for ($I=0; $I-lt $NewCatalogInfo.Length; $I++) {
    if ($NewCatalogInfo[$I].Type -ne "File") {
        continue
    }
    if ($MasterLut.ContainsKey($NewCatalogInfo[$I].Hash)) {
        $MasterLut[$NewCatalogInfo[$I].Hash].Uses=[int]$MasterLut[$NewCatalogInfo[$I].Hash].Uses+1
    } else {
        $MasterLut.Add($NewCatalogInfo[$I].Hash, (New-Object -TypeName PSObject -Property @{Hash=$NewCatalogInfo[$I].Hash; Uses=1;}))
        Backup-File -Hash $NewCatalogInfo[$I].Hash -FilePath (Join-Path -Path $BackupSource -ChildPath $NewCatalogInfo[$I].Path) -BackupDirectory $BackupDirectory
        $Metrics["NewFiles"]+=1
    }
    Write-Progress -Activity "Backing up files" -Status $NewCatalogInfo[$I].Path -PercentComplete ($I*100/$NewCatalogInfo.Length)
}
Write-Progress -Activity "Backing up files" -PercentComplete 100 -Completed

Write-Host "Saving catalogs"
#Save new catalog
$NewCatalogInfo | Export-Csv -LiteralPath $NewBackupCatalogPath -NoTypeInformation
Write-Host "New catalog saved to '$NewBackupCatalogPath'"
#Save new master
$MasterLut.Values | Export-Csv -LiteralPath $MasterCatalogPath -NoTypeInformation

#Remove old catalogs and decrement from master catalog
if ($AutoRemoveTime -lt 0) {
    $Metrics.Add("RemovedFiles", 0)
    Write-Host "Removing old catalogs"

    $AllBackupCatalogs = Get-ChildItem -LiteralPath $BackupCatalogsDirectory
    $CutoffTime = [DateTime]::Now.AddMinutes($AutoRemoveTime)
    $ToRemove = @()
    foreach ($Catalog in $AllBackupCatalogs) {
        $DateParts = $Catalog.BaseName.Split("-")
        if ([DateTime]::new($DateParts[0],$DateParts[1],$DateParts[2],$DateParts[3],$DateParts[4],0) -lt $CutoffTime) {
            $ToRemove+=$Catalog.FullName
        }
    }
    Write-Host "$($ToRemove.Length) catalogs to remove"

    $TRI=0
    
    foreach ($OldCatalog in $ToRemove) {
        Write-Progress -Activity "Removing old catalogs" -Status $OldCatalog -PercentComplete ($TRI*100/$ToRemove.Length) -Id 10
        $OldCatalogInfo = Import-Csv -LiteralPath $OldCatalog
        $IT=0
        foreach ($Item in $OldCatalogInfo) {
            Write-Progress -Activity "Parsing old files" -Status $Item.Path -PercentComplete ($IT*100/$OldCatalogInfo.Length) -Id 11
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

        Remove-Item -LiteralPath $OldCatalog
        $TRI++
    }
    Write-Progress -Activity "Removing old catalogs" -PercentComplete 100 -Completed -Id 10
}

Write-Host "Saving master catalog"
#Save new master
$MasterLut.Values | Export-Csv -LiteralPath $MasterCatalogPath -NoTypeInformation

$Metrics.Add("EndTime",[DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss"))

$ToSave = ""

foreach($Key in $Metrics.Keys) {
    $ToSave += "$Key - "+$Metrics[$Key]+"`r`n"
}

$ToSave | Out-File -FilePath (Join-Path -Path $BackupDirectory -ChildPath "Metrics.txt") -Force

Remove-FileLock -FileLock $FileLock
