# Review: ssh-configuration

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 5.0/5

Issues: none

Outstanding SSH configuration guide. Standard description format. Covers key management (Ed25519, RSA 4096 fallback, FIDO2 ed25519-sk, passphrases, ssh-agent with timeout, key rotation), ssh_config patterns (Host blocks with wildcards, Match blocks for conditional config, IdentitiesOnly), port forwarding (local -L, remote -R, dynamic -D SOCKS proxy, autossh for persistence), tunneling patterns (database through bastion, NAT traversal reverse tunnels), agent forwarding (risks of socket hijacking, ProxyJump as safer alternative), sshd_config hardening (authentication, access control, network, crypto algorithms, fail2ban, TOTP 2FA), certificate-based authentication (CA setup, user/host key signing with validity periods, trust configuration, key revocation lists), multiplexing (ControlMaster/ControlPath/ControlPersist, management commands), jump hosts (ProxyJump chains, multi-hop, session recording with ForceCommand), file transfer (SCP/SFTP/rsync through jump hosts), troubleshooting (verbose debugging, common issues table with fixes, permission requirements), modern features (FIDO2 resident keys, SSH over HTTPS with nginx stream, QUIC-based SSH), and anti-patterns (wildcard ForwardAgent, permissive sshd, weak crypto, key sharing).
