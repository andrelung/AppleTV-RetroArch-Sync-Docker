# AppleTV-RetroArch-Sync
Backup and Sync RetroArch files between NAS and AppleTV

Rationale:

Apple TV will delete retroarch's files, ROMs, saves, when it's low on disk space.  Disabling screensaver download can help, but the risk is ever-present.  This script is intended to be a mitigation for this to ensure that if the files are deleted, they're automatically restored.

Features:

Waits for RetroArch to be running on the AppleTV (i.e. the web server is avaialble).  
Backup - Just backs-up AppleTV RetroArch to the NAS (where the script runs).  
Two-way Sync - Syncronises files between AppleTV RetroArch and the NAS.  Intended to automatically copy ROMs, and in the future multi-AppleTV support will be added to sync game saves between AppleTVs.  
Last-Modified sync - uses Last-Modified header from RetroArch webserver to determine if file has changed.  Sets the modified time on the backups to be same as AppleTV.  
Uses .part files for partial downloads/uploads to avoid corruption.  
  
The script can be run manually, and there's also a run_retroarch-sync.sh which kills the existing process and restarts a new one seding output to retroarch-sync.log.  The intention for the cron is to run it once daily.  The script will wait until RetroArch is running, and because very long running scritps can be unrelialbbe, the pattern to restart it daily was adopted.  
  
This is very much alpha at time of release. Use at own risk.  I strongly recommend having a separate one-off backup before testing.  

## Configuration

### Variables in `retroarch-sync.sh`

| Variable                 | Default Value          | Description                                                                |
|--------------------------|------------------------|----------------------------------------------------------------------------|
| `HOST`                   | `192.168.1.41`        | The IP address of the RetroArch server (Apple TV).                          |
| `PORT`                   | `80`                  | The port RetroArch's HTTP server is running on.                             |
| `LOCAL_BASE_DIR`         | `./LivingRoom`        | Base directory on the local server for backups and syncs.                   |
| `REMOTE_BASE_PATH`       | `/RetroArch`          | Base directory on the remote server (Apple TV).                             |
| `TWOWAY_SYNC_PATHS`      | Array of paths        | Folders to sync bi-directionally.                                           |
| `BACKUP_ONLY_PATHS`      | Array of paths        | Folders to back up from the remote server without syncing back.             |
| `EXCLUDE_PATHS`          | Array of paths        | Folders to exclude entirely from both sync and backup.                      |
| `MAX_RETRIES`            | `3`                   | Maximum number of retries for failed operations.                            |
| `CURL_CONNECT_TIMEOUT`   | `5`                   | Timeout for establishing a connection with the remote server (seconds).     |
| `CURL_MAX_TIME`          | `120`                 | Maximum time for a `curl` operation (seconds).                              |
| `SYNC_LOOP_INTERVAL`     | `120`                 | Time interval (in seconds) between successive sync loops.                   |

