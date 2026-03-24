# SSH Certificate Authority Setup Guide

Step-by-step guide to setting up a complete SSH Certificate Authority for both user
and host authentication. Eliminates `authorized_keys` management at scale.

## Prerequisites

- OpenSSH 5.4+ (for certificate support; 8.2+ for FIDO2)
- Root access on CA machine and target servers
- Secure storage for CA private keys (ideally air-gapped or HSM)

## Architecture

```
┌─────────────────┐
│   SSH CA         │  Signs user and host certificates
│   (Air-gapped)   │
└────────┬─────────┘
         │ Signs
    ┌────┴────┐
    │         │
    ▼         ▼
┌────────┐ ┌────────┐
│ User   │ │ Host   │
│ Certs  │ │ Certs  │
└───┬────┘ └───┬────┘
    │          │
    ▼          ▼
┌────────────────────┐
│  SSH Servers       │  Trust User CA → accept user certs
│  (TrustedUserCA)   │  Present Host Cert → clients verify
└────────────────────┘
    ▲
    │
┌───┴────────────────┐
│  SSH Clients       │  Trust Host CA → verify host certs
│  (@cert-authority) │  Present User Cert → authenticate
└────────────────────┘
```

---

## Step 1: Generate CA Key Pairs

Create **separate** CAs for users and hosts:

```bash
# Create CA directory
sudo mkdir -p /etc/ssh/ca
sudo chmod 700 /etc/ssh/ca

# Generate User CA (signs user certificates)
sudo ssh-keygen -t ed25519 -f /etc/ssh/ca/user_ca -C "SSH User CA - $(hostname) - $(date +%Y)"
# Set a strong passphrase when prompted

# Generate Host CA (signs host certificates)
sudo ssh-keygen -t ed25519 -f /etc/ssh/ca/host_ca -C "SSH Host CA - $(hostname) - $(date +%Y)"
# Set a strong passphrase when prompted

# Lock down permissions
sudo chmod 600 /etc/ssh/ca/user_ca /etc/ssh/ca/host_ca
sudo chmod 644 /etc/ssh/ca/user_ca.pub /etc/ssh/ca/host_ca.pub
```

## Step 2: Configure Servers to Trust User CA

On **every SSH server** that should accept certificate-based login:

```bash
# Copy the User CA public key to the server
sudo cp /etc/ssh/ca/user_ca.pub /etc/ssh/ssh_user_ca.pub

# Add to sshd_config
echo "TrustedUserCAKeys /etc/ssh/ssh_user_ca.pub" | sudo tee -a /etc/ssh/sshd_config

# (Optional) Set up authorized principals for fine-grained access
sudo mkdir -p /etc/ssh/authorized_principals

# Create principals file for each user
echo -e "alice\ndeploy-team" | sudo tee /etc/ssh/authorized_principals/deploy
echo "alice" | sudo tee /etc/ssh/authorized_principals/alice
echo "root-emergency" | sudo tee /etc/ssh/authorized_principals/root

# Enable principals in sshd_config
echo "AuthorizedPrincipalsFile /etc/ssh/authorized_principals/%u" | sudo tee -a /etc/ssh/sshd_config

# Validate and restart
sudo sshd -t && sudo systemctl restart sshd
```

## Step 3: Sign User Certificates

Sign a user's public key to create a certificate:

```bash
# Basic user certificate (valid 24 hours)
sudo ssh-keygen -s /etc/ssh/ca/user_ca \
  -I "alice-laptop-$(date +%Y%m%d)" \
  -n alice \
  -V +24h \
  -z $(date +%s) \
  /home/alice/.ssh/id_ed25519.pub

# Multi-principal certificate (can login as alice or deploy)
sudo ssh-keygen -s /etc/ssh/ca/user_ca \
  -I "alice-workstation" \
  -n alice,deploy,deploy-team \
  -V +8h \
  -z $(date +%s) \
  /home/alice/.ssh/id_ed25519.pub

# Restricted certificate (specific source IPs only)
sudo ssh-keygen -s /etc/ssh/ca/user_ca \
  -I "alice-vpn-only" \
  -n alice \
  -V +24h \
  -O source-address=10.0.0.0/8 \
  -z $(date +%s) \
  /home/alice/.ssh/id_ed25519.pub

# Certificate with forced command
sudo ssh-keygen -s /etc/ssh/ca/user_ca \
  -I "ci-bot-deploy" \
  -n deploy \
  -V +1h \
  -O force-command="/usr/local/bin/deploy.sh" \
  -O no-port-forwarding \
  -O no-x11-forwarding \
  -z $(date +%s) \
  /home/ci/.ssh/id_ed25519.pub
```

The certificate is created as `id_ed25519-cert.pub` next to the public key.

## Step 4: Sign Host Certificates

Sign host keys so clients can verify server identity without TOFU:

```bash
# Sign the host's Ed25519 key
sudo ssh-keygen -s /etc/ssh/ca/host_ca \
  -I "web01.example.com-$(date +%Y)" \
  -h \
  -n web01.example.com,web01,10.0.1.10 \
  -V +52w \
  -z $(date +%s) \
  /etc/ssh/ssh_host_ed25519_key.pub

# Configure sshd to present the certificate
echo "HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub" | sudo tee -a /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl restart sshd
```

## Step 5: Configure Clients to Trust Host CA

On **every client** machine, add the Host CA to known_hosts:

```bash
# Global (all users on this machine)
echo "@cert-authority *.example.com $(cat /etc/ssh/ca/host_ca.pub)" | \
  sudo tee -a /etc/ssh/ssh_known_hosts

# Per-user
echo "@cert-authority *.example.com $(cat /etc/ssh/ca/host_ca.pub)" >> ~/.ssh/known_hosts
```

Now clients will automatically trust any server with a valid host certificate — no
more "unknown host key" warnings for managed hosts.

## Step 6: Verify Certificates

```bash
# Inspect a user certificate
ssh-keygen -L -f ~/.ssh/id_ed25519-cert.pub
# Check: Type, Key ID, Serial, Valid, Principals, Critical Options, Extensions

# Inspect a host certificate
ssh-keygen -L -f /etc/ssh/ssh_host_ed25519_key-cert.pub

# Test user certificate authentication
ssh -v user@server 2>&1 | grep -i cert
# Look for: "Offering public key: ... ED25519-CERT"
# Look for: "Server accepts key: ... ED25519-CERT"
```

## Step 7: Certificate Revocation (KRL)

Revoke compromised certificates using a Key Revocation List:

```bash
# Create a KRL revoking specific certificates
sudo ssh-keygen -k -f /etc/ssh/revoked_keys \
  -s /etc/ssh/ca/user_ca.pub \
  /path/to/compromised-cert.pub

# Add to sshd_config
echo "RevokedKeys /etc/ssh/revoked_keys" | sudo tee -a /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl restart sshd

# Add more revocations to existing KRL
sudo ssh-keygen -k -u -f /etc/ssh/revoked_keys \
  -s /etc/ssh/ca/user_ca.pub \
  /path/to/another-compromised-cert.pub
```

## Step 8: Automation with Vault (Optional)

For dynamic, short-lived certificates at scale:

```bash
# Enable Vault SSH secret engine
vault secrets enable -path=ssh ssh

# Configure Vault as a signing CA
vault write ssh/config/ca \
  private_key=@/etc/ssh/ca/user_ca \
  public_key=@/etc/ssh/ca/user_ca.pub

# Create a role for signing
vault write ssh/roles/admin \
  key_type=ca \
  allowed_users="admin,deploy" \
  default_user="admin" \
  ttl=2h \
  max_ttl=24h \
  allow_user_certificates=true \
  allowed_extensions="permit-pty,permit-agent-forwarding"

# Users sign their keys via Vault
vault write ssh/sign/admin \
  public_key=@$HOME/.ssh/id_ed25519.pub
# Returns a signed certificate valid for 2 hours
```

## Maintenance Checklist

- [ ] CA private keys stored securely (air-gapped, HSM, or encrypted backup)
- [ ] User certificates issued with short validity (hours/days, not months)
- [ ] Host certificates renewed before expiry (track with monitoring)
- [ ] `AuthorizedPrincipalsFile` maintained per-host for access control
- [ ] KRL updated when certificates are compromised
- [ ] CA key rotation planned (every 2-5 years)
- [ ] Certificate serial numbers tracked for audit
- [ ] Fallback access method available (break-glass authorized_keys)
