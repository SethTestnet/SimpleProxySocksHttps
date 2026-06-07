# SimpleProxySocksHttps

SimpleProxySocksHttps is a small set of installation scripts for creating a personal proxy on a VPS.

There are two installation modes:

1. **Basic 3proxy SOCKS5/HTTP proxy** — simple public proxy with username/password.
2. **WireGuard + 3proxy private proxy** — recommended mode. Proxy ports are not exposed to the public internet.

---

## Quick choice

Use **WireGuard + 3proxy** if:

- your client IP is dynamic;
- you need the proxy to work 24/7;
- you do not want to expose proxy ports to the internet;
- you want to use the proxy only in scripts/apps where you explicitly set it.

Use **basic 3proxy** only if you understand the risks of a public proxy and can restrict access by IP.

---

# Option 1: Basic 3proxy SOCKS5/HTTP

This script creates a simple proxy directly on the VPS public IP.

Default endpoints:

```text
SOCKS5: VPS_IP:1080
HTTP:   VPS_IP:3128
```

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SethTestnet/SimpleProxySocksHttps/main/install_3proxy_socks5_https.sh)
```

Safer variant:

```bash
curl -fsSL -o install_3proxy_socks5_https.sh https://raw.githubusercontent.com/SethTestnet/SimpleProxySocksHttps/main/install_3proxy_socks5_https.sh
sudo bash install_3proxy_socks5_https.sh
```

## Security note

Do not leave the proxy open to the whole internet unless you really know what you are doing.

If the script asks for `ALLOW_IP`, it is better to enter your own IP address. If your IP is dynamic and you need 24/7 access, use the recommended **WireGuard + 3proxy** mode below.

---

# Option 2: WireGuard + 3proxy private proxy

Recommended mode.

This script creates a private proxy available only through WireGuard:

```text
SOCKS5: 10.66.66.1:1080
HTTP:   10.66.66.1:3128
```

The public internet will not see ports `1080` and `3128`.

Only the WireGuard UDP port is exposed:

```text
51820/udp
```

## Important: this is not a full-machine VPN

The generated WireGuard client config uses:

```ini
AllowedIPs = 10.66.66.1/32
```

This means WireGuard does **not** route all your traffic. It only gives your machine access to the private proxy address `10.66.66.1`.

Your normal internet connection remains unchanged. Only apps/scripts where you manually set the proxy will use the VPS IP.

---

## What the script installs

The script installs and configures:

```text
WireGuard server
3proxy SOCKS5
3proxy HTTP / HTTPS CONNECT
UFW firewall
systemd autostart
WireGuard client config
```

After installation:

```text
WireGuard: 51820/udp
SOCKS5:    10.66.66.1:1080
HTTP:      10.66.66.1:3128
```

---

## Install

Run on your VPS:

```bash
curl -fsSL https://raw.githubusercontent.com/SethTestnet/SimpleProxySocksHttps/main/install_proxy_wg_3proxy.sh | sudo bash
```

Or download first:

```bash
curl -fsSL -o install_proxy_wg_3proxy.sh https://raw.githubusercontent.com/SethTestnet/SimpleProxySocksHttps/main/install_proxy_wg_3proxy.sh
sudo bash install_proxy_wg_3proxy.sh
```

The script will ask:

```text
Upgrade system packages before installation?
SOCKS5 port
HTTP proxy port
WireGuard UDP port
Proxy username
Proxy password
```

You can press Enter to use defaults.

---

# AWS EC2 setup guide

This section is for creating a VPS on AWS, for example in the Thailand region.

## 1. Create EC2 instance

1. Open **AWS Console**.
2. In the top-right region menu, select your desired region, for example:

```text
Asia Pacific (Thailand) ap-southeast-7
```

3. Open:

```text
EC2
```

4. Go to:

```text
Instances → Launch instances
```

5. Select Ubuntu:

```text
Ubuntu Server 22.04 LTS
```

or:

```text
Ubuntu Server 24.04 LTS
```

6. Choose instance type, for example:

```text
t3.micro
```

7. Create or select an SSH key pair.
8. Enable:

```text
Auto-assign public IP
```

9. Launch the instance.

---

## 2. Configure AWS Security Group

For **WireGuard + 3proxy**, your Security Group should allow:

```text
22/tcp      SSH
51820/udp   WireGuard
```

Do **not** open proxy ports publicly:

```text
1080/tcp    do not open
3128/tcp    do not open
```

### Add WireGuard UDP port

1. Open **EC2**.
2. Select your instance.
3. Open the **Security** tab.
4. Click the Security Group link, for example:

```text
sg-xxxxxxxx
```

5. Open:

```text
Inbound rules
```

6. Click:

```text
Edit inbound rules
```

7. Click:

```text
Add rule
```

8. Add:

```text
Type:        Custom UDP
Port range:  51820
Source:      0.0.0.0/0
Description: WireGuard
```

9. Click:

```text
Save rules
```

Important: choose **UDP**, not TCP.

---

## 3. Connect to the VPS

From macOS/Linux:

```bash
ssh -i ~/Downloads/YOUR_KEY.pem ubuntu@YOUR_VPS_IP
```

Example:

```bash
ssh -i ~/Downloads/aws-key.pem ubuntu@43.210.117.200
```

If macOS/Linux complains about key permissions:

```bash
chmod 400 ~/Downloads/YOUR_KEY.pem
```

---

## 4. Run installer

```bash
curl -fsSL https://raw.githubusercontent.com/SethTestnet/SimpleProxySocksHttps/main/install_proxy_wg_3proxy.sh | sudo bash
```

After installation, show the WireGuard client config:

```bash
sudo cat /root/wg-client-private-proxy.conf
```

Show all generated info:

```bash
sudo cat /root/proxy-info.txt
```

Copy the WireGuard client config into your WireGuard client app.

---

# Usage

After enabling the WireGuard client on your local machine, use these proxy URLs in scripts/apps.

HTTP / HTTPS proxy:

```text
http://proxyuser:PASSWORD@10.66.66.1:3128
```

SOCKS5 proxy:

```text
socks5://proxyuser:PASSWORD@10.66.66.1:1080
```

For SOCKS5 with remote DNS resolution:

```text
socks5h://proxyuser:PASSWORD@10.66.66.1:1080
```

---

## Puppeteer example

HTTP proxy:

```js
const browser = await puppeteer.launch({
  headless: false,
  args: [
    '--proxy-server=http://10.66.66.1:3128'
  ]
});

const page = await browser.newPage();

await page.authenticate({
  username: 'proxyuser',
  password: 'PASSWORD'
});
```

---

# Check that everything works

## 1. Check WireGuard tunnel

On your local machine:

```bash
ping 10.66.66.1
```

If ping works, the WireGuard tunnel is active.

## 2. Check HTTP proxy

```bash
curl -x 'http://proxyuser:PASSWORD@10.66.66.1:3128' https://ipinfo.io
```

## 3. Check SOCKS5 proxy

```bash
curl --socks5-hostname 'proxyuser:PASSWORD@10.66.66.1:1080' https://ipinfo.io
```

The response should show your VPS public IP.

---

# Useful VPS commands

WireGuard status:

```bash
sudo wg show
```

Services:

```bash
sudo systemctl status wg-quick@wg0 --no-pager
sudo systemctl status 3proxy --no-pager
```

Listening ports:

```bash
sudo ss -lntup | grep -E '1080|3128|51820'
```

Expected result:

```text
0.0.0.0:51820
10.66.66.1:1080
10.66.66.1:3128
```

Firewall rules:

```bash
sudo ufw status numbered
```

Expected rules include:

```text
1080/tcp on wg0    ALLOW
3128/tcp on wg0    ALLOW
51820/udp          ALLOW
1080/tcp           DENY
3128/tcp           DENY
```

3proxy logs:

```bash
sudo ls -la /var/log/3proxy
sudo tail -f /var/log/3proxy/3proxy.log.*
```

---

# Change proxy password

Edit the 3proxy config:

```bash
sudo nano /usr/local/3proxy/conf/3proxy.cfg
```

Find:

```text
users proxyuser:CL:OLD_PASSWORD
```

Replace the password, then restart 3proxy:

```bash
sudo systemctl restart 3proxy
```

---

# Security notes

- Do not open `1080/tcp` or `3128/tcp` in AWS Security Group when using WireGuard mode.
- Only `51820/udp` is needed for WireGuard.
- Restrict `22/tcp` SSH access to your own IP if possible.
- Do not share your WireGuard client config.
- Do not share your proxy password.
- If your password or config was leaked in a chat, screenshot, log, or commit history, change it.
- For dynamic client IPs and 24/7 usage, use **WireGuard + 3proxy**, not a public proxy.
