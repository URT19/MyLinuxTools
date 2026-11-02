# Hetzner Cloud Full Backup Tool

An interactive Bash script that makes a **full disk backup** of a Hetzner Cloud server, restores it to another server, and transfers backup files between servers.

It uses Hetzner's **Rescue mode**, so the server's disk is copied as a raw image with `dd`, compressed with `gzip`, and verified with `sha256sum`.

---

## Features

- Full raw disk backup (`dd`) with compression (`gzip` or `pigz`)
- Integrity checks: `gzip -t`, SHA-256 checksum, optional second dump with comparison
- Optional AES-256 encryption (`openssl`)
- Restore a backup onto a server in Rescue mode
- Transfer a backup file to another server over SSH (`rsync`, resumable)
- SSH key or password login
- Step-by-step prompts. The script waits for `y` or `n` and never exits on a wrong key press

---

## Requirements

On the machine that **runs** the script (your PC or another Linux server):

- Linux, macOS, or WSL on Windows
- `ssh`, `ssh-keygen`, `gzip`, `sha256sum`
- `rsync` (for transfer)
- `openssl` (optional, for encryption)
- `sshpass` (only if you log in with a password for transfer)

> **Important:** Do **not** run the script from the server you are backing up or restoring. Run it from a different machine.

---

## Before you start (Hetzner panel)

### 1. Create a snapshot of the source server

Snapshot the server in the Hetzner Cloud panel. This gives you a copy to work with, so the live server is not touched.

### 2. Create a temporary server from the snapshot

Create a new server from the snapshot. Use the same or a larger server type.

### 3. Enable Rescue mode on the temporary server

- Open the temporary server
- Go to the **Rescue** tab
- Select an SSH key (see step 4 below) or leave it for a password
- Click **Enable Rescue System**
- Go to the **Power** tab and click **Reboot** (or **Hard Reset**)
- Wait a few minutes

### 4. Login details

- **SSH key (recommended):** the key you selected in Rescue mode
- **Password:** Hetzner emails a root password when you enable Rescue without a key. The first login may ask you to change it. Log in once with SSH and set a new password if asked.

---

## Install

```bash
chmod +x hetzner_backup.sh
./hetzner_backup.sh
```

The script checks required tools and offers to install `openssh-client` with `apt` if missing.

---

## Usage

When you run the script, you will see this menu:

```
1) Backup kamel (temporary server in Rescue -> this machine)
2) Restore (backup file -> server in Rescue)
3) Transfer backup file to another server
0) Exit
```

### Option 1: Backup

The script shows the steps first and asks you to confirm that you are running it from another Linux server or your own PC, not from the temporary server.

1. **Login:** enter the Rescue IP, choose SSH key or password.
2. **Disk:** check the disk name (default `sda`).
3. **Dump:** the full disk is copied and compressed to `~/hetzner_backups/`. This can take a long time.
4. **Verify:** `gzip -t` and SHA-256 checksum. This step may take several minutes. If the connection drops, run the check again (use `tmux` to avoid this).
5. **Optional second dump:** compares two dumps to make sure they are identical.
6. **Optional encryption:** AES-256 with a password you choose. Keep the password safe. Without it the backup cannot be restored.
7. **Optional split into parts:** cuts the file into pieces (like WinRAR volumes) so each piece can be downloaded separately. See [Splitting into parts](#splitting-into-parts).

When finished, you can **disable Rescue** or **delete the temporary server**. Nothing more is needed from the server.

### Option 2: Restore

1. Choose the backup file (`.img.gz` or `.img.gz.enc`), or any one of its `.partNN` pieces. The script finds all the pieces by itself and joins them before restoring. It also checks their hashes first.
2. Enter the IP of the target server (it must be in Rescue mode).
3. Confirm the disk and type `YES` when asked. **The whole disk will be overwritten.**
4. The script streams the backup to the server with `dd`.
5. In the Hetzner panel: **disable Rescue**, then **reboot** the server.

If the server does not boot, you may need to reinstall GRUB from Rescue.

### Option 3: Transfer to another server

1. Choose the backup file, or any one of its `.partNN` pieces. If pieces exist, all of them are sent together.
2. Enter the target server's IP, SSH port, user, and destination folder.
3. Choose SSH key or password.
4. The file is copied with `rsync`. If the connection drops, run the option again and it resumes.
5. The script compares hashes on the target server. For a single file it compares the full file. For parts it checks each part with `sha256sum -c`.

---

## Splitting into parts

Large backups can be split into smaller pieces, like WinRAR volumes. The pieces are only cut, not compressed or encrypted again, so joining them gives back the exact same file.

This is useful for downloading with IDM: each piece can be downloaded separately and the pieces are joined on Windows afterwards.

### Split from the script

In Option 1, after the optional encryption step, answer `y` to "split into parts". Enter the piece size (for example `500M`, `1G`, or `2G`). The script creates these files next to the backup:

- `<name>.img.gz.part00`, `<name>.img.gz.part01`, ... (the pieces)
- `<name>.img.gz.full.sha256` (hash of the full file)
- `<name>.img.gz.parts.sha256` (hash of each piece)

You can choose to delete the full file after splitting. Keep it if you have space, so you can always go back to it.

### Split manually (Linux server)

```bash
cd /root/backups
split -b 1G -d -a 2 server-2026-11-02_1322.img.gz server-2026-11-02_1322.img.gz.part
sha256sum server-2026-11-02_1322.img.gz > full.sha256
sha256sum server-2026-11-02_1322.img.gz.part* > parts.sha256
```

Change `1G` to `500M` or `2G` if you prefer a different size.

### Download the pieces with IDM

Add each piece URL to IDM, or use the same HTTP method from the IDM section above. Download the pieces and the `.parts.sha256` file into the same folder on Windows.

Check each piece in PowerShell:

```powershell
Get-FileHash .\<BACKUP_FILE>.part* -Algorithm SHA256
```

Compare the results with `parts.sha256` on the server.

### Join the pieces on Windows

**Option A: command line**

```powershell
cmd /c copy /b <BACKUP_FILE>.part00 + <BACKUP_FILE>.part01 <BACKUP_FILE>
```

Add more `+ <BACKUP_FILE>.partNN` entries if there are more pieces.

**Option B: 7-Zip**

Right-click the first piece and choose **Combine files**. 7-Zip finds the other pieces automatically.

Then check the joined file:

```powershell
Get-FileHash .\<BACKUP_FILE> -Algorithm SHA256
```

Compare the result with `full.sha256` on the server.

### Join the pieces on Linux

```bash
cat <BACKUP_FILE>.part* > <BACKUP_FILE>
```

### Restore or transfer from the script

You do not need to join the pieces first. When you choose any piece (or the base name) in Option 2 (Restore) or Option 3 (Transfer), the script finds all the pieces and handles them.

---

## Download to your Windows PC with IDM (optional)

IDM only works with HTTP or FTP. It cannot download over SSH. Use this temporary method and close it immediately after the download.

> **Warning:** The backup file is not encrypted in this method unless you encrypted it. Anyone who can reach the open port can download it. Limit access to your own IP and close the port after you finish.

Replace these placeholders with your own values:

- `<SERVER_IP>`: the IP of the server that holds the backup
- `<YOUR_PUBLIC_IP>`: your public IP (check with a site like `whatismyip.com`)
- `<BACKUP_FILE>`: the backup filename

### On the server (Linux)

1. Check the firewall status:
   ```bash
   sudo ufw status
   ```

2. Allow only your IP on port 8000:
   ```bash
   sudo ufw allow from <YOUR_PUBLIC_IP> to any port 8000 proto tcp
   ```
   If `ufw` is inactive, allow SSH first to avoid losing access:
   ```bash
   sudo ufw allow 22/tcp
   sudo ufw allow from <YOUR_PUBLIC_IP> to any port 8000 proto tcp
   sudo ufw enable
   ```

3. Make a folder with a symlink to the backup file only:
   ```bash
   mkdir -p /root/share
   ln -sf /root/backups/<BACKUP_FILE> /root/share/
   ```

4. Start a temporary HTTP server:
   ```bash
   cd /root/share
   python3 -m http.server 8000 --bind 0.0.0.0
   ```

### On Windows

5. In IDM, add this URL and download the file:
   ```
   http://<SERVER_IP>:8000/<BACKUP_FILE>
   ```

6. Check the file hash in PowerShell:
   ```powershell
   Get-FileHash .\<BACKUP_FILE> -Algorithm SHA256
   ```
   Compare the result with the hash on the server:
   ```bash
   sha256sum /root/backups/<BACKUP_FILE>
   ```

### Close access on the server

7. Stop the HTTP server with `Ctrl + C`, then:
   ```bash
   sudo ufw delete allow from <YOUR_PUBLIC_IP> to any port 8000 proto tcp
   rm -rf /root/share
   ```

If your home IP changes, the rule stops working. Create a new one with the new IP.

---

## Security notes

- Backups contain SSH keys, passwords, configs, and user data. Treat them as sensitive.
- Encrypt backups before storing them in shared or cloud locations.
- Do not commit backup files, `.sha256` files, or real IP addresses to Git.
- Close firewall rules and HTTP servers when you finish.
- Delete temporary servers and snapshots when they are no longer needed (they cost money).

---

## Notes

- The source disk is `sda` by default. Check it with `lsblk` if your server uses another name.
- Compression depends on the data. Empty disk space compresses well. Already compressed files (media, archives) do not.
- Restore overwrites the whole target disk. Double-check the IP.
- Splitting does not change the data. Joining the pieces gives back the original file byte for byte.
- Keep the encryption password in a password manager.
