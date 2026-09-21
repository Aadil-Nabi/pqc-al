# Corporate CA drop folder

If the lab host sits behind a TLS-inspecting proxy (Zscaler, Netskope, Palo Alto
SSL decryption, etc.), image pulls and the `dnf` / `apk` steps inside the builds
fail with `x509: certificate signed by unknown authority`.

Fix: put the proxy's CA chain here as one or more PEM files named `*.crt`.
Every Dockerfile copies this folder and trusts whatever `*.crt` it finds before
the first package install. The folder is gitignored, so the CA never reaches the
repo. With no `*.crt` present the builds behave exactly as before.

The lab host itself needs the same CA in its own trust store for `docker pull`:

```bash
sudo cp certs/corp-ca/*.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
sudo systemctl restart docker
```
