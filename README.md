This is a variation of https://github.com/blaz0r/AppleTV-RetroArch-Sync because my Synology NAS was not able to execute the old script as a task.

The main idea:
- run the script inside a container
- map the relevant folders to the container
- execute the scripts 

I hacked this approach together. There are some fixes for special characters ("!" or ","). Feel free to correct my efforts or build on this :) 


# AppleTV-RetroArch-Sync
see https://github.com/blaz0r/AppleTV-RetroArch-Sync for thoughts behind this.
  
This also is very much alpha at time of release. Use at own risk.  I strongly recommend having a separate one-off backup before testing.  

## Configuration

### Variables in `compose.yaml`

| Variable                 | Default Value          | Description                                                                |
|--------------------------|------------------------|----------------------------------------------------------------------------|
| `ATVHOST`                | `192.168.X.X`         | The IP address of the RetroArch server (Apple TV).                          |
| `ATVPORT`                | `80`                  | The port RetroArch's HTTP server is running on.                             |
| `LOCAL_BASE_DIR`         | `./syncfolder`        | Internally mapped directory for backups and syncs.                          |

Please set the volumes (!)

### Variables in `retroarch-sync.sh`

| Variable                 | Default Value          | Description                                                                |
|--------------------------|------------------------|----------------------------------------------------------------------------|
| `REMOTE_BASE_PATH`       | `/RetroArch`          | Base directory on the remote server (Apple TV).                             |
| `TWOWAY_SYNC_PATHS`      | Array of paths        | Folders to sync bi-directionally.                                           |
| `BACKUP_ONLY_PATHS`      | Array of paths        | Folders to back up from the remote server without syncing back.             |
| `EXCLUDE_PATHS`          | Array of paths        | Folders to exclude entirely from both sync and backup.                      |
| `MAX_RETRIES`            | `3`                   | Maximum number of retries for failed operations.                            |
| `CURL_CONNECT_TIMEOUT`   | `5`                   | Timeout for establishing a connection with the remote server (seconds).     |
| `CURL_MAX_TIME`          | `120`                 | Maximum time for a `curl` operation (seconds).                              |
| `SYNC_LOOP_INTERVAL`     | `120`                 | Time interval (in seconds) between successive sync loops.                   |

