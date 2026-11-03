"""gen_cert.py — Generate a self-signed TLS certificate for VidFlow HTTPS.

Works for localhost, LAN VMs, and custom internal domains.

Usage
-----
    # Basic (localhost only)
    python gen_cert.py

    # With a real VM hostname or internal domain
    VIDFLOW_DOMAIN=hclswl2learninghub python gen_cert.py

    # Multiple hostnames / IPs (comma-separated)
    VIDFLOW_DOMAIN=hclswl2learninghub,10.225.16.145 python gen_cert.py

The certificate always includes localhost + 127.0.0.1 as fallback SANs.

For production / public domains use a proper CA-signed cert (e.g. Let's Encrypt)
and drop the sslCertFile / sslKeyFile lines from .streamlit/config.toml — terminate
TLS at nginx/Traefik/k8s Ingress instead.

Requires: pip install cryptography
"""

import os, datetime, ipaddress
from pathlib import Path

try:
    from cryptography import x509
    from cryptography.x509.oid import NameOID
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
except ImportError:
    raise SystemExit(
        "cryptography package not found. Install it with:\n"
        "    pip install cryptography\nthen re-run this script."
    )

ROOT = Path(__file__).parent
CERT = ROOT / "cert.pem"
KEY  = ROOT / "key.pem"

# ── Collect Subject Alternative Names ─────────────────────────────────────────
# Always cover localhost and 127.0.0.1 so local dev still works
san_dns  = ["localhost"]
san_ips  = [ipaddress.IPv4Address("127.0.0.1")]

# Read extra domains/IPs from env var VIDFLOW_DOMAIN (comma-separated)
for entry in os.getenv("VIDFLOW_DOMAIN", "").split(","):
    entry = entry.strip()
    if not entry:
        continue
    try:
        san_ips.append(ipaddress.ip_address(entry))   # numeric IP
    except ValueError:
        if entry not in san_dns:
            san_dns.append(entry)                      # hostname / FQDN

# Pick the primary CN: first custom domain if given, else "localhost"
primary_cn = san_dns[1] if len(san_dns) > 1 else san_dns[0]

print(f"Generating cert for: DNS={san_dns}  IPs={[str(i) for i in san_ips]}")

# ── Generate RSA private key ───────────────────────────────────────────────────
private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

subject = issuer = x509.Name([
    x509.NameAttribute(NameOID.COMMON_NAME, primary_cn),
    x509.NameAttribute(NameOID.ORGANIZATION_NAME, "VidFlow Text to Video AI"),
])

san_entries = [x509.DNSName(d) for d in san_dns] + [x509.IPAddress(ip) for ip in san_ips]

cert = (
    x509.CertificateBuilder()
    .subject_name(subject)
    .issuer_name(issuer)
    .public_key(private_key.public_key())
    .serial_number(x509.random_serial_number())
    .not_valid_before(datetime.datetime.now(datetime.timezone.utc))
    .not_valid_after(datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=3650))
    .add_extension(x509.SubjectAlternativeName(san_entries), critical=False)
    .sign(private_key, hashes.SHA256())
)

CERT.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
KEY.write_bytes(
    private_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    )
)

print(f"✓ cert.pem and key.pem written to {ROOT}")
print()
print("Next steps:")
print("  1. Restart the Streamlit app")
print(f"  2. Open https://{primary_cn}:8501  (accept the browser cert warning once)")
print()
print("For production: use a CA-signed cert or terminate TLS at nginx/Ingress.")

