Provide your solution here:

# Problem 2: Diagnose Me Doctor

### Incident Context
- **Instance:** Ubuntu 24.04 LTS, 64GB root EBS storage.
- **Service:** NGINX reverse proxy / load balancer.
- **Symptom:** Disk usage pinned at 99%.

---

### 1. Step-by-Step Triage Commands

```bash
# 1. Verify storage usage and inode counts
df -hT
df -i

# 2. Check for deleted files held open by active processes
sudo lsof +L1

# 3. Identify the largest directories on the root mount
sudo du -xhd 1 / | sort -hr

# 4. Check NGINX-specific directories
sudo du -sh /var/log/nginx /var/cache/nginx /tmp /var/log/journal
```

---

### 2. Root Cause Analysis, Impacts & Recovery

#### Cause A: Unrotated or Runaway NGINX Access Logs
- **Why It Happens:** High request volume fills the disk when log rotation is disabled or log levels are set to `debug`.
- **System Impact:** NGINX worker writes fail with `No space left on device`. Incoming requests return HTTP 500.
- **Immediate Recovery:**
  - Truncate the file in place to release blocks without breaking active file descriptors:
  ```bash
  sudo truncate -s 0 /var/log/nginx/access.log
  sudo truncate -s 0 /var/log/nginx/error.log
  ```
- **Permanent Fix:**
  - Configure `/etc/logrotate.d/nginx`:
  ```nginx
  /var/log/nginx/*.log {
      daily
      missingok
      rotate 7
      compress
      delaycompress
      notifempty
      create 0640 www-data adm
      sharedscripts
      postrotate
          invoke-rc.d nginx rotate >/dev/null 2>&1
      endscript
  }
  ```

#### Cause B: Deleted Files Held Open by Active Processes (`lsof +L1`)
- **Why It Happens:** An engineer ran `rm /var/log/nginx/access.log` directly. The directory entry is deleted, but NGINX keeps the open file descriptor, so space is not freed.
- **System Impact:** `df -h` shows 99% usage while `du -sh /*` reports only minimal storage used.
- **Immediate Recovery:**
  - Signal NGINX to re-open file handles:
  ```bash
  sudo nginx -s reopen
  # Or reload the service:
  sudo systemctl reload nginx
  ```

#### Cause C: Proxy Buffering Writing to Disk
- **Why It Happens:** When upstream services return large response bodies and `proxy_max_temp_file_size` is unconstrained, NGINX buffers payloads to `/var/cache/nginx` or `/tmp`.
- **System Impact:** Sudden disk exhaustion during traffic spikes, producing HTTP 502 Bad Gateway errors.
- **Immediate Recovery:**
  ```bash
  sudo find /var/cache/nginx/ -type f -delete
  ```
- **Permanent Fix:**
  - Update `/etc/nginx/nginx.conf`:
  ```nginx
  proxy_buffering on;
  proxy_buffer_size 8k;
  proxy_buffers 64 8k;
  proxy_max_temp_file_size 0; # Disable buffering to disk
  ```

#### Cause D: Unbounded `systemd-journald` Logs
- **Why It Happens:** Ubuntu 24.04 defaults allow system logs to consume up to 10% of the filesystem if `SystemMaxUse` is unset.
- **Immediate Recovery:**
  ```bash
  sudo journalctl --vacuum-size=500M
  ```
- **Permanent Fix:**
  - Set `SystemMaxUse=1G` in `/etc/systemd/journald.conf` and restart the daemon:
  ```bash
  sudo systemctl restart systemd-journald
  ```