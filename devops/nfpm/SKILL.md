---
name: nfpm
description: |
  Linux package creation (deb/rpm/apk). Use for creating Linux packages.
  NOT for Windows/macOS packages or container images.
---

# nfpm - Linux Package Creation

## Quick Start

```bash
# Install nfpm
go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest
# Or download from https://github.com/goreleaser/nfpm/releases

# Initialize config
nfpm init

# Build package
nfpm pkg --config .nfpm.yaml --target ./dist/
```

## Core Config (.nfpm.yaml)

```yaml
# Required fields
name: myapp
arch: amd64
platform: linux
version: "1.0.0"
section: default
priority: extra
maintainer: "Your Name <you@example.com>"
description: |
  Short description here.
  Longer description on subsequent lines.

# Package type (deb|rpm|apk)
# Set via: nfpm pkg --packager deb
```

## File Mappings

```yaml
contents:
  # Binary to /usr/bin
  - src: ./myapp
    dst: /usr/bin/myapp
    file_info:
      mode: 0755
      owner: root
      group: root

  # Config file (marked as config - won't overwrite on upgrade)
  - src: ./config/myapp.conf
    dst: /etc/myapp/myapp.conf
    type: config|noreplace
    file_info:
      mode: 0644

  # Systemd service
  - src: ./systemd/myapp.service
    dst: /lib/systemd/system/myapp.service

  # Directory creation
  - dst: /var/lib/myapp
    type: dir
    file_info:
      mode: 0750
      owner: myapp
      group: myapp

  # Symlink
  - src: /usr/bin/myapp
    dst: /usr/local/bin/myapp-cli
    type: symlink

  # Glob patterns
  - src: ./assets/*
    dst: /usr/share/myapp/
```

## Dependencies & Relationships

```yaml
depends:
  - libc6
  - adduser
  - "systemd (>= 240)"

# RPM-specific deps (overrides depends for RPM)
rpm:
  dependencies:
    - glibc
    - systemd

# APK-specific deps
apk:
  dependencies:
    - libc6-compat

# Conflicts with other packages
conflicts:
  - myapp-legacy

# Replaces (for package renaming)
replaces:
  - oldpackage

# Provides (virtual packages)
provides:
  - myapp-virtual

# Suggests/Recommends (deb only)
suggests:
  - myapp-doc
recommends:
  - myapp-config-defaults
```

## Scripts (Pre/Post Install/Remove)

```yaml
scripts:
  # Run before install
  preinstall: ./scripts/preinstall.sh
  
  # Run after install
  postinstall: ./scripts/postinstall.sh
  
  # Run before remove
  preremove: ./scripts/preremove.sh
  
  # Run after remove
  postremove: ./scripts/postremove.sh

# Or inline (use | for multi-line)
scripts:
  postinstall: |
    #!/bin/sh
    systemctl daemon-reload
    systemctl enable myapp
    systemctl start myapp
```

### Script Best Practices

```bash
#!/bin/sh
set -e

# Preinstall: Create user
case "$1" in
  install|upgrade)
    if ! id -u myapp >/dev/null 2>&1; then
      useradd --system --home /var/lib/myapp --shell /bin/false myapp
    fi
    ;;
esac

# Postinstall: Start service
if [ "$1" = "configure" ] || [ "$1" = "1" ]; then
  systemctl daemon-reload
  systemctl enable myapp
  systemctl start myapp || true
fi

# Preremove: Stop service
if [ "$1" = "remove" ] || [ "$1" = "0" ]; then
  systemctl stop myapp || true
  systemctl disable myapp || true
fi

# Postremove: Cleanup
if [ "$1" = "purge" ] || [ "$1" = "0" ]; then
  userdel myapp 2>/dev/null || true
  rm -rf /var/lib/myapp
fi
```

## Package Signing

### GPG Signing

```yaml
# In .nfpm.yaml
rpm:
  signature:
    key_file: /path/to/gpg-private.key
    # Or use key_id if key in keyring
    key_id: ABCD1234

deb:
  signature:
    key_file: /path/to/gpg-private.key
    # Method: dpkg-sig or debsigs
    method: dpkg-sig
    # Or debsigs
    # method: debsigs

apk:
  signature:
    key_file: /path/to/rsa-private.key
    # APK uses RSA keys, not GPG
```

### Generate Signing Keys

```bash
# GPG for deb/rpm
gpg --full-generate-key
# Select RSA/RSA, 4096 bits
gpg --export-secret-keys --armor YOUR_KEY_ID > private.key
gpg --export --armor YOUR_KEY_ID > public.key

# RSA for APK
openssl genrsa -out apk.rsa.priv 4096
openssl rsa -in apk.rsa.priv -pubout -out apk.rsa.pub
```

## Multi-Arch & Multi-Packager

```yaml
# Use env vars or templates for multi-arch
name: myapp
arch: ${ARCH}
version: ${VERSION}

# Build script
for arch in amd64 arm64 armhf; do
  for packager in deb rpm apk; do
    nfpm pkg \
      --config .nfpm.yaml \
      --packager $packager \
      --target ./dist/myapp_${VERSION}_${arch}.${packager}
  done
done
```

## Advanced Features

### Changelog

```yaml
changelog: ./CHANGELOG.md
# Format: Debian changelog format for deb
#         RPM changelog format for rpm
```

### Empty Package (meta-package)

```yaml
name: myapp-full
version: "1.0.0"
depends:
  - myapp
  - myapp-cli
  - myapp-server
# No contents - just dependencies
```

### Overwrites

```yaml
# Control file overwrite behavior
deb:
  breaks:
    - myapp (<< 0.9.0)
  enhances:
    - some-other-package

rpm:
  # Scriptlet expansion
  # %pre, %post, %preun, %postun
```

## Complete Example

```yaml
name: myserver
arch: amd64
platform: linux
version: "2.1.0"
section: net
priority: optional
maintainer: "DevOps Team <devops@company.com>"
description: |
  High-performance server application.
  Handles concurrent connections with minimal resource usage.
vendor: "MyCompany Inc."
homepage: https://github.com/company/myserver
license: MIT

contents:
  - src: ./bin/myserver
    dst: /usr/bin/myserver
    file_info:
      mode: 0755

  - src: ./config/myserver.yaml
    dst: /etc/myserver/config.yaml
    type: config|noreplace
    file_info:
      mode: 0640
      owner: root
      group: myserver

  - src: ./systemd/myserver.service
    dst: /lib/systemd/system/myserver.service

  - dst: /var/lib/myserver
    type: dir
    file_info:
      mode: 0750
      owner: myserver
      group: myserver

depends:
  - libc6
  - systemd (>= 240)

suggests:
  - myserver-doc
  - myserver-debug

scripts:
  preinstall: |
    #!/bin/sh
    set -e
    if ! id -u myserver >/dev/null 2>&1; then
      useradd --system --home /var/lib/myserver --shell /bin/false myserver
    fi

  postinstall: |
    #!/bin/sh
    set -e
    systemctl daemon-reload
    if [ "$1" = "configure" ] || [ "$1" = "1" ]; then
      systemctl enable myserver
      systemctl start myserver || true
    fi

  preremove: |
    #!/bin/sh
    if [ "$1" = "remove" ] || [ "$1" = "0" ]; then
      systemctl stop myserver || true
      systemctl disable myserver || true
    fi

  postremove: |
    #!/bin/sh
    if [ "$1" = "purge" ]; then
      userdel myserver 2>/dev/null || true
      rm -rf /var/lib/myserver
    fi

deb:
  breaks:
    - myserver (<< 2.0.0)
  signature:
    key_file: ./keys/deb-private.key
    method: dpkg-sig

rpm:
  group: "System Environment/Daemons"
  signature:
    key_file: ./keys/rpm-private.key
```

## Build Commands

```bash
# Build specific packager
nfpm pkg --config .nfpm.yaml --packager deb --target ./dist/

# Build all (if multiple configs)
nfpm pkg --config .nfpm.yaml --packager deb
nfpm pkg --config .nfpm.yaml --packager rpm
nfpm pkg --config .nfpm.yaml --packager apk

# With env substitution
VERSION=1.2.3 ARCH=arm64 nfpm pkg --config .nfpm.yaml --packager deb

# Validate config
nfpm config --config .nfpm.yaml
```

## Verification

```bash
# Inspect deb package
dpkg-deb -I myapp_1.0.0_amd64.deb
dpkg-deb -c myapp_1.0.0_amd64.deb  # List contents
dpkg-deb -f myapp_1.0.0_amd64.deb  # Show control fields

# Inspect rpm package
rpm -qip myapp-1.0.0-1.x86_64.rpm
rpm -qlp myapp-1.0.0-1.x86_64.rpm  # List contents

# Inspect apk package
tar -tzf myapp-1.0.0-r0.apk

# Test install in container
docker run --rm -v $(pwd)/dist:/pkgs ubuntu:22.04 \
  bash -c "dpkg -i /pkgs/*.deb && apt-get install -f"
```

## Best Practices

1. **Use semantic versioning** - `version: "1.2.3"` not `v1.2.3`
2. **Mark config files** - Use `type: config|noreplace` to preserve user changes
3. **Create system users** - In preinstall, create dedicated users for services
4. **Handle upgrades** - Scripts receive args: install=1, upgrade=2 (deb), or package count (rpm)
5. **Use set -e** - Fail scripts on error
6. **Make scripts idempotent** - Handle reinstalls gracefully
7. **Test in clean containers** - Verify on minimal base images
8. **Sign packages** - Always sign packages for production repos
9. **Version constraints** - Use `(>= 1.0)` syntax for dependencies
10. **File permissions** - Explicitly set mode/owner in file_info

## Common Issues

| Issue | Solution |
|-------|----------|
| `arch` not recognized | Use nfpm arch names: `amd64`, `arm64`, `armhf`, `386` |
| Scripts not executable | Ensure scripts have shebang and are executable |
| Config overwritten | Use `type: config\|noreplace` |
| Service fails to start | Check script args - deb/rpm use different conventions |
| Signing fails | Verify key format: GPG for deb/rpm, RSA for APK |

## CI/CD Integration

```yaml
# .github/workflows/release.yml
- name: Build packages
  run: |
    for packager in deb rpm apk; do
      nfpm pkg \
        --config .nfpm.yaml \
        --packager $packager \
        --target dist/
    done

- name: Sign packages
  env:
    GPG_PRIVATE_KEY: ${{ secrets.GPG_PRIVATE_KEY }}
  run: |
    echo "$GPG_PRIVATE_KEY" | gpg --import
    for pkg in dist/*.deb; do
      dpkg-sig --sign builder -k "$GPG_KEY_ID" "$pkg"
    done
```
