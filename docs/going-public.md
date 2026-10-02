# Going public: a real domain with HTTPS

The local VM is only reachable from your own computer. For a domain anyone can open, run the same
starter on a **VPS**: a Linux VM in a data centre with a fixed public IP.

## 1. What you need

| Thing | Where | Notes |
|---|---|---|
| A domain | Any registrar: Cloudflare, Namecheap, Porkbun... | Prices vary by TLD |
| A VPS | DigitalOcean, Hetzner, AWS Lightsail, Vultr... | Smallest plan is enough. Choose **Ubuntu 26.04 LTS** (or 24.04 LTS) |
| SSH key | Your Windows machine | `ssh-keygen -t ed25519`, then paste the `.pub` file into the VPS dashboard when creating it |

## 2. Point the domain at the server (DNS)

In your registrar's / DNS provider's dashboard, add:

| Type | Name | Value |
|---|---|---|
| `A` | `@` (the domain itself) | your VPS public IPv4 |
| `A` | `www` | same IP (only if you'll set `INCLUDE_WWW=true`) |

Check it from Windows (can take a few minutes, sometimes longer):

```powershell
nslookup yourdomain.com
```

It must return your VPS IP **before** you ask for a certificate, because Let's Encrypt checks it.

> Using Cloudflare DNS? Set the record to **DNS only** (grey cloud) for the first certificate.

## 3. Run the starter on the VPS

```bash
ssh root@<vps-ip>          # or the user your provider created
git clone https://github.com/amirizalrahmat0799/nginx-starter.git
cd nginx-starter
cp site.env.example site.env
nano site.env               # DOMAIN=yourdomain.com  HTTPS=letsencrypt  EMAIL=you@...
sudo ./scripts/setup.sh
```

What happens with `HTTPS=letsencrypt`:

1. Nginx starts serving your domain on HTTP (port 80).
2. **certbot** asks Let's Encrypt for a certificate. Let's Encrypt calls `http://yourdomain.com/.well-known/acme-challenge/...`
   to prove you control the domain (the "HTTP-01 challenge"), which is why DNS and port 80 must work first.
3. certbot edits your site config to add HTTPS on port 443 and an HTTP → HTTPS redirect.
4. A systemd timer renews the certificate automatically before its 90-day expiry. Test renewal with:
   ```bash
   sudo certbot renew --dry-run
   ```

## 4. Put an app behind it

Run your app on the server (e.g. a Spring Boot jar or a Docker container on port 8080), then:

```bash
# site.env
MODE=proxy
UPSTREAM=http://127.0.0.1:8080
```

Re-run `sudo ./scripts/setup.sh`. Your app is now at `https://yourdomain.com`, with Nginx handling HTTPS.

Keep the app itself **off the public internet**: only ports 22, 80 and 443 are open in the firewall,
so port 8080 is reachable from Nginx on the same machine but not from outside.

## Troubleshooting

| Symptom | Check |
|---|---|
| certbot: "Timeout during connect" | DNS not pointing at this server yet (`nslookup`), or the provider's cloud firewall blocks port 80 |
| certbot: "too many certificates" | Let's Encrypt rate limits: wait, or add `--staging` while experimenting |
| `502 Bad Gateway` | Nginx is fine but the app isn't running on `UPSTREAM`: `curl http://127.0.0.1:8080` on the server |
| `504 Gateway Timeout` | App is too slow; raise `proxy_read_timeout` in `nginx/snippets/proxy.conf` |
| Config change not showing | `sudo nginx -t` then `sudo systemctl reload nginx` (setup.sh does both) |
