# Poor Man's Backup and DeDupe

This is a set of powershell scripts designed to backup a directory without duplicating files and allowing multiple snapshots in time. It does this on a file-level and does not track block-level changes. These scripts need to be run in PowerShell core, and support Linux and Windows.

## PoorMansBackupAndDedup.ps1

This is the script to run to create a new backup. 

```powershell
PoorMansBackupAndDedupe.ps1 [[-BackupSource] <string>] [[-BackupDirectory] <string>] [[-DeltaCatalogPath] <string>] [[-AutoRemoveTime] <int>] [[-IncludeFilter] <string>] [[-ExcludeFilter] <string>] [-UseDatesForDelta] [-NoContinueOnDeltaFail]
```

`-BackupSource` is the directory you intend to backup. 

`-BackupDirectory` is the root location of where the backup catalogs and files will be saved. 

`-UseDatesForDelta` is a switch that if set, will cause the script to only hash new files found as compared to an older catalog file. This saves alot of time in creating a snapshot. When a file is marked for backup, it will be compared to the old catalog. If the size, created time, and last write time all match, the hash will be assumed to be the same as what the old catalog has. This can be used with `-DeltaCatalogPath` to explicitly set a catalog to use for the delta comparison. If not set, the script will automatically use the latest catalog.

`-AutoRemoveTime` if set, will remove any catalog older than the amount of minutes specified. This will delete the old catalogs and remove the backup files if no other catalogs have a hold on a file.

`-NoContinueOnDeltaFail` will prevent the script from ignoring a run if delta was selected, but no delta file provided.

`-IncludeFilter` anything not matching this optional regex filter, will be excluded.

`-ExcludeFilter` anything matching this optional regex filter, will be excluded.

``

The general recommended use will be to manually create a backup with 

```powershell
PoorMansBackupAndDedupe.ps1 -BackupSource "C:\SomePath\ToBackup\" -BackupDirectory "D:\SomePath\ToSaveBackups\" 
```

and then on a daily schedule run

```powershell
PoorMansBackupAndDedupe.ps1 -BackupSource "C:\SomePath\ToBackup\" -BackupDirectory "D:\SomePath\ToSaveBackups\" -UseDatesForDelta -AutoRemoveTime 10080
```

which will keep 7 days worth of backups.

### Backup Directory Structure

The backup directory will contain:

A file named `MasterCatalog.csv`. This file keeps track of the backup hashes, and how many times a backedup file is used. When a catalog is removed, the use count drops, and when a use count drops to 0, the backed up file is removed.

A folder called `BackupCatalogs`. This will contain several CSV files, each keeping a complete list of files, directories, hashes and attributes needed to restore a backup.

A folder called BackupFiles, with sub folders 2 levels deep. These folder are named after the first to characters of a hash, and each file backed up will appear in the deepest part of this tree. For example, if a file is backed up and hashed as AABD..., it will be backed up as `/BackupFiles/A/A/AABD...`

## PoorMansBDDBackupManagement.ps1

Allows you to do various maintenance taskes on the backup files and catalogs. Primarily, you can Rebuild the MasterCatalog in case it is ever deleted or falls out of sync with the other catalogs. Verify a specific backup to ensure you have the necessary files to restore it. Delete a specific backup catalog and it's associated files assuming those files are not used for another backup catalog. Or you can delete orphaned backup files that are not in the MasterCatalog.

```powershell
PoorMansBDDBackupManagement.ps1 -VerifyBackupCatalog -BackupDirectory <string> -BackupCatalogPath <string> [-WhatIf] [-Confirm] [<CommonParameters>]
PoorMansBDDBackupManagement.ps1 -RemoveOrphanedBackupFiles -BackupDirectory <string> [-WhatIf] [-Confirm] [<CommonParameters>]
PoorMansBDDBackupManagement.ps1 -DeleteBackupCatalog -BackupDirectory <string> -BackupCatalogPath <string> [-WhatIf] [-Confirm] [<CommonParameters>]
PoorMansBDDBackupManagement.ps1 -RebuildMasterCatalog -BackupDirectory <string> [-WhatIf] [-Confirm] [<CommonParameters>]
```

## PoorMansBDDRestore.ps1

This script allows you to restore a backup.

```powershell
PoorMansBDDRestore.ps1 [[-RestorePath] <string>] [[-BackupDirectory] <string>] [[-IncludeFilter] <string>] [[-ExcludeFilter] <string>] [[-BackupCatalog] <string>] [-Overwrite]
```

`-RestorePath` is the root path you want to restore the backup to. This may be the same as the `-BackupSource` parameter in `PoorMansBackupAndDedup.ps1`

`-BackupDirectory` is the path to the root of the backup directory. Should be the same path as used in `PoorMansBackupAndDedup.ps1`

`-IncludeFilter` is a regex filter you can optionally specify to filter what gets restored. If you want to only restore images you could use `"(jpg|png|bmp)$"` or another such filter. This filter is run on the subpath of the file as compared to the backup root, so you can restore only specific folders with the same paramter.

`-ExcludeFilter` is a regex filter you can optionally specify to filter what gets restore. If you want to restore everything except images you could use `"(jpg|png|bmp)$"` or another such filter. This filter is run on the subpath of the file as compared to the backup root, so you can exclude only specific folders with the same paramter.

`-BackupCatalog` is the full path to the specific catalog you want to restore, usually found in the `BackupDirectory` in the `BackupCatalogs` directory.

`-Overwrite` specifies the script should overwrite a file if it already exists.