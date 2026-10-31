# Pi 4B Media Server Wizard

`main.sh` is the supported, modular wizard for an Ubuntu or Debian Raspberry Pi
4B media server. Its interactive output is English-only and explains every
planned host change before asking for confirmation.

The wizard configures one host-mounted media filesystem and deploys Jellyfin in
Docker. Transmission and Samba can either remain as existing native services or
move to Docker after an explicit provider choice.

## Safety model

- No disk is formatted.
- No media file is deleted.
- The media filesystem is identified by UUID, not by a volatile `/dev/sdX` name.
- Existing configuration files receive timestamped backups before replacement.
- Existing native services are never disabled without an explicit choice.
- Docker and native services wait for the media mount through systemd.
- `--dry-run` prints the execution without changing the host.

## Run on the Raspberry Pi

Copy the complete repository directory to the Pi so `main.sh` can load its
modules, then run it as a regular user with sudo access:

```bash
chmod +x main.sh
./main.sh --dry-run
./main.sh
```

Useful information commands:

```bash
./main.sh --help
./main.sh --list-steps
./main.sh --version
```

The wizard stages are:

1. Preflight inspection.
2. Persistent storage configuration.
3. Media-group and ACL configuration.
4. Docker Engine and Compose v2 configuration.
5. Jellyfin, Transmission, and Samba provider deployment.
6. systemd mount ordering.
7. Optional UFW rules.
8. Effective-state verification.

## Modules

- `modules/00-common.sh` - terminal UI, validation, backups, and dry-run support.
- `modules/10-preflight.sh` - operating system, hardware, user, and service checks.
- `modules/20-storage.sh` - UUID-based mount and `/etc/fstab` management.
- `modules/30-permissions.sh` - media group and inherited ACLs.
- `modules/40-docker.sh` - Docker Engine and Compose v2.
- `modules/50-applications.sh` - provider choices and generated application files.
- `modules/60-startup.sh` - service-to-mount systemd dependencies.
- `modules/70-firewall.sh` - optional LAN-scoped UFW rules.
- `modules/80-verify.sh` - mount, container, service, port, and HTTP checks.

## Existing Pi migration behavior

The captured Pi currently uses a mixed deployment: Jellyfin and a read-only
Samba share are in Docker, while Transmission and another Samba configuration
run as native host services. The wizard detects this condition and recommends
preserving native providers by default. Selecting a Docker replacement stops
and disables the corresponding native service, but does not delete its settings
or state.

## Read-only configuration report

`inspect-current-config-ro.sh` writes a sanitized effective-state report to
standard output without changing mounts, services, containers, packages,
permissions, or configuration files:

```bash
./inspect-current-config-ro.sh --allow-sudo --media-path /mnt/media \
  --include-sanitized-config > scan-mediaserver-report.txt
```

## Validation

Run the local static checks before copying the wizard to the Pi:

```bash
./tests/test-wizard-static.sh
```

The test checks Bash syntax, generated Compose variants, generated environment
and Docker build files, safety messages, and the ASCII-only contract for all new
wizard-facing files.
