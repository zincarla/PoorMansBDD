#Requires -PSEdition Core
Param([string]$BackupDirectory)

if ($IsMacOS) {
    Write-Error "Unsupported OS"
    return
}

#Fill out some path variables
$MasterCatalogPath = Join-Path -Path $BackupDirectory -ChildPath "MasterCatalog.csv"
$BackupCatalogsDirectory = Join-Path -Path $BackupDirectory -ChildPath "BackupCatalogs"
if (-not (Test-Path -LiteralPath $BackupCatalogsDirectory)) {
    $null=New-Item -Path $BackupCatalogsDirectory -ItemType Directory
}

Write-Host "Parsing Existing BackupFiles"
$BackupRoot = Join-path -Path $BackupDirectory -ChildPath "BackupFiles"

$AllBackupFiles = Get-ChildItem -LiteralPath $BackupRoot -Recurse -File

$NewMasterLut = @{}

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