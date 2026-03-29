# nfpm References

## Official Documentation

- **nfpm Official Docs**: https://nfpm.goreleaser.com/
  - Configuration reference
  - Usage examples
  - Packager-specific options

- **nfpm GitHub Repository**: https://github.com/goreleaser/nfpm
  - Source code
  - Issues and discussions
  - Release notes

## Related Projects

- **GoReleaser**: https://goreleaser.com/
  - nfpm is part of the GoReleaser ecosystem
  - GoReleaser uses nfpm for package building

## Package Format Documentation

### Debian (.deb)
- **Debian Policy Manual**: https://www.debian.org/doc/debian-policy/
- **Debian Maintainer Guide**: https://www.debian.org/doc/manuals/maint-guide/
- **dpkg-deb man page**: https://manpages.debian.org/dpkg-deb

### RPM (.rpm)
- **RPM Packaging Guide**: https://rpm-packaging-guide.github.io/
- **RPM Documentation**: https://rpm.org/documentation.html
- **Fedora Packaging Guidelines**: https://docs.fedoraproject.org/en-US/packaging-guidelines/

### Alpine (.apk)
- **Alpine Package Format**: https://wiki.alpinelinux.org/wiki/Apk_spec
- **Alpine Packaging**: https://wiki.alpinelinux.org/wiki/Creating_an_Alpine_package

## Useful Tools

- **dpkg-deb**: Debian package manipulation
- **rpm**: RPM package manager
- **apk**: Alpine Package Keeper
- **alien**: Convert between package formats (not recommended for production)

## Signing Resources

- **GnuPG**: https://gnupg.org/documentation/
- **OpenSSL**: https://www.openssl.org/docs/
- **APK Signing**: https://wiki.alpinelinux.org/wiki/Alpine_Package_Signing

## CI/CD Examples

- **GitHub Actions**: See nfpm repository for official actions
- **GitLab CI**: Can use GoReleaser or direct nfpm installation
- **Docker**: Multi-stage builds for package creation
