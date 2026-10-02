# Local Ubuntu VM in VirtualBox

Goal: an Ubuntu Server VM that your Windows machine can reach at a fixed IP, so you can open
`http://mizal.test` in your browser and SSH into the VM from Windows Terminal.

## 1. Download Ubuntu Server

Get **Ubuntu Server 26.04 LTS** (64-bit, amd64) from <https://ubuntu.com/download/server>.
Pick the **manual install** option to download the `.iso` (about 3 GB).

Why this one:

- **Server**, not Desktop: no graphical interface, like real servers and VPSs. Lighter on RAM, and you learn the terminal.
- **LTS** (Long Term Support): security updates for 5 years. Most VPS providers offer the same image, so
  everything you practise here works the same way on a VPS.

## 2. Create the VM

In VirtualBox: **New**.

| Setting | Value |
|---|---|
| Name | `nginx-lab` |
| ISO Image | the Ubuntu Server `.iso` |
| Unattended install | **skip it** (the checkbox wording differs between VirtualBox versions), so you go through the installer yourself and see each choice |
| Memory | 2048 MB |
| CPUs | 2 |
| Disk | 25 GB (dynamically allocated: only uses space as it fills) |

## 3. Networking: add a second adapter (before you install)

The default **NAT** adapter gives the VM internet access, but Windows can't reach the VM through it.
Add a **Host-only** adapter as well: a private network between Windows and the VM only.

**Settings → Network**

- Adapter 1: **NAT** (leave it), for internet access: `apt install`, `git clone`
- Adapter 2: tick **Enable**, Attached to **Host-only Adapter**, for Windows ↔ VM

If the Host-only dropdown is empty: **File → Tools → Network Manager → Host-only Networks → Create**.
The default network is `192.168.56.0/24` with DHCP on.

## 4. Install Ubuntu

Start the VM and go through the installer. Defaults are fine except:

- **Network**: both adapters should show an address (`10.0.2.15` for NAT, `192.168.56.x` for Host-only).
- **Profile**: choose your username and password. You'll use this to log in and for `sudo`.
- **SSH**: tick **Install OpenSSH server**. This lets you work from Windows Terminal instead of the VM window.
- **Featured snaps**: skip all.

Reboot when asked (if it complains about the install medium, press Enter; VirtualBox ejects it).

## 5. Find the VM's IP and connect over SSH

Log in in the VM window, then:

```bash
ip -4 addr        # look for the 192.168.56.x address, e.g. 192.168.56.101
```

From **Windows Terminal / PowerShell**:

```powershell
ssh yourname@192.168.56.101
```

From now on you can minimise the VM window and work over SSH (copy-paste works here).

> The Host-only DHCP usually gives the same IP every time. If it changes, set a fixed one with netplan,
> or just check `ip -4 addr` again and update your hosts file.

## 6. Point a local domain at the VM (Windows hosts file)

There's no real DNS for `mizal.test`, so tell Windows where it is. Open **Notepad as Administrator**,
open `C:\Windows\System32\drivers\etc\hosts`, and add at the bottom:

```
192.168.56.101   mizal.test
```

Save. Now `mizal.test` on your Windows machine means the VM.

**Why `.test`?** It's reserved for testing and never exists on the real internet, so it can't clash with a real site.
Avoid `.dev` (a real TLD that forces HTTPS) and `.local` (used by network discovery and can be slow to resolve).

## 7. Run the starter

Back in your SSH session:

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/amirizalrahmat0799/nginx-starter.git
cd nginx-starter
cp site.env.example site.env       # DOMAIN=mizal.test is already the default
sudo ./scripts/setup.sh
```

Open **http://mizal.test** in your Windows browser.

## Snapshots: your undo button

Before experimenting, take a snapshot: VirtualBox → VM → **Snapshots → Take**.
If you break something, restore it and you're back in seconds.
