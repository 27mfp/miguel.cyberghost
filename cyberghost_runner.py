#!/usr/bin/env python3
"""
CyberGhost VPN WireGuard Native Backend & CLI
Directly negotiates WireGuard keys with CyberGhost dialup servers and manages wg-quick.
"""

import sys
import os
import argparse
import configparser
import json
import subprocess
import re
import glob
import pwd
import urllib3

urllib3.disable_warnings()

try:
    import requests
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "requests", "--break-system-packages"])
    import requests

WG_CONF_PATH = "/etc/wireguard/cyberghost.conf"
INTERFACE = "cyberghost"


def find_config_path(override_path=None):
    if override_path and os.path.exists(override_path):
        return override_path

    env_override = os.environ.get("CYBERGHOST_CONFIG")
    if env_override and os.path.exists(env_override):
        return env_override

    candidates = []
    user = os.environ.get("SUDO_USER") or os.environ.get("LOGNAME") or os.environ.get("USER")
    if user and user != "root":
        candidates.append(f"/home/{user}/.cyberghost/config.ini")

    # Scan /home/*/
    for p in glob.glob("/home/*/.cyberghost/config.ini"):
        candidates.append(p)

    # Scan user databases
    try:
        for entry in pwd.getpwall():
            if entry.pw_uid >= 1000 and os.path.isdir(entry.pw_dir):
                candidates.append(os.path.join(entry.pw_dir, ".cyberghost", "config.ini"))
    except Exception:
        pass

    candidates.append(os.path.expanduser("~/.cyberghost/config.ini"))

    for c in candidates:
        if os.path.exists(c):
            return c

    return os.path.expanduser("~/.cyberghost/config.ini")


def get_credentials(config_path=None):
    path = find_config_path(config_path)
    if not os.path.exists(path):
        raise RuntimeError(f"Configuration file not found: {path}")

    cfg = configparser.ConfigParser()
    cfg.read(path)

    if not cfg.has_section("device") or not cfg.has_option("device", "token") or not cfg.has_option("device", "secret"):
        raise RuntimeError(f"Device credentials missing from {path}. Please run 'cyberghostvpn --setup'")

    token = cfg.get("device", "token")
    secret = cfg.get("device", "secret")
    return token, secret


def get_servers_for_country(country_code, server_type="traffic"):
    """
    Query available server instances for a country.
    """
    cmd = ["cyberghostvpn", f"--{server_type}", "--country-code", country_code.upper()]
    res = subprocess.run(cmd, capture_output=True, text=True)

    servers = []
    if res.returncode == 0:
        for line in res.stdout.splitlines():
            m = re.match(r"\|\s*\d+\s*\|\s*([A-Za-z\s]+)\s*\|\s*(\d+)\s*\|\s*(\d+)%", line)
            if m:
                city = m.group(1).strip()
                instance = m.group(2).strip()
                load = int(m.group(3))
                servers.append({"city": city, "instance": instance, "load": load})
    return servers


def generate_wireguard_keys():
    priv = subprocess.check_output(["wg", "genkey"]).decode().strip()
    pub = subprocess.check_output(["wg", "pubkey"], input=priv.encode()).decode().strip()
    return priv, pub


def connect(country_code="PT", server_type="traffic", city=None, config_path=None):
    token, secret = get_credentials(config_path)
    priv_key, pub_key = generate_wireguard_keys()

    servers = get_servers_for_country(country_code, server_type)

    city_slug = "lisbon"
    cc = country_code.upper()
    if cc == "PT":
        city_slug = "lisbon"
    elif cc == "ES":
        city_slug = "madrid"
    elif cc == "DE":
        city_slug = "frankfurt"
    elif cc == "GB" or cc == "UK":
        city_slug = "london"
    elif cc == "US":
        city_slug = "newyork"
    elif cc == "FR":
        city_slug = "paris"
    elif cc == "NL":
        city_slug = "amsterdam"
    elif cc == "CH":
        city_slug = "zurich"
    elif cc == "IT":
        city_slug = "milan"
    elif cc == "BR":
        city_slug = "saopaulo"
    elif cc == "CA":
        city_slug = "montreal"
    elif cc == "SE":
        city_slug = "stockholm"
    elif servers:
        city_slug = servers[0]["city"].lower().replace(" ", "")

    candidates = [
        f"{city_slug}-s405-i03.cg-dialup.net",
        f"{city_slug}-s405-i02.cg-dialup.net",
        f"{city_slug}-s405-i01.cg-dialup.net",
        f"{city_slug}-s401-i01.cg-dialup.net",
        f"{city_slug}-s401-i02.cg-dialup.net",
        f"{city_slug}-s401-i03.cg-dialup.net",
    ]

    addkey_data = None
    connected_host = None

    for host in candidates:
        url = f"https://{host}:1337/addKey"
        try:
            r = requests.get(url, params={"pubkey": pub_key}, auth=(token, secret), verify=False, timeout=4)
            if r.status_code == 200:
                data = r.json()
                if data.get("status") == "OK" and data.get("server_key"):
                    addkey_data = data
                    connected_host = host
                    break
        except Exception:
            continue

    if not addkey_data:
        raise RuntimeError(f"Could not negotiate WireGuard key with CyberGhost servers in {country_code.upper()}.")

    # Generate WireGuard configuration
    dns_servers = ", ".join(addkey_data.get("dns_servers", ["10.0.0.243", "10.0.0.242", "1.1.1.1"]))
    server_ip = addkey_data.get("server_ip") or connected_host
    server_port = addkey_data.get("server_port", 1337)
    peer_ip = addkey_data.get("peer_ip")
    server_key = addkey_data.get("server_key")

    wg_config = f"""[Interface]
PrivateKey = {priv_key}
Address = {peer_ip}/32
DNS = {dns_servers}

[Peer]
PublicKey = {server_key}
AllowedIPs = 0.0.0.0/0
Endpoint = {server_ip}:{server_port}
PersistentKeepalive = 25
"""

    os.makedirs("/etc/wireguard", exist_ok=True)
    with open(WG_CONF_PATH, "w") as f:
        f.write(wg_config)
    os.chmod(WG_CONF_PATH, 0o600)

    # Bring down any existing connection first
    subprocess.run(["wg-quick", "down", INTERFACE], capture_output=True)

    # Bring up wireguard connection
    up_res = subprocess.run(["wg-quick", "up", INTERFACE], capture_output=True, text=True)
    if up_res.returncode != 0:
        raise RuntimeError(f"wg-quick up failed: {up_res.stderr.strip() or up_res.stdout.strip()}")

    print("VPN connection established.")
    print(f"Connected to {country_code.upper()} via {connected_host} (IP: {server_ip})")


def disconnect():
    subprocess.run(["wg-quick", "down", INTERFACE], capture_output=True)
    subprocess.run(["cyberghostvpn", "--stop"], capture_output=True)
    print("VPN connection terminated.")


def status(config_path=None):
    ip_res = subprocess.run(["ip", "link", "show", INTERFACE], capture_output=True, text=True)
    if ip_res.returncode == 0 and "cyberghost" in ip_res.stdout:
        wg_res = subprocess.run(["wg", "show", INTERFACE], capture_output=True, text=True)
        print("VPN connection found.")
        print(f"Interface: {INTERFACE}")
        if wg_res.returncode == 0:
            for line in wg_res.stdout.splitlines():
                if "endpoint:" in line or "transfer:" in line or "latest handshake:" in line:
                    print("  " + line.strip())
    else:
        print("No VPN connections found.")


def main():
    parser = argparse.ArgumentParser(description="CyberGhost WireGuard Controller")
    parser.add_argument("action", choices=["connect", "disconnect", "status"], help="Action to perform")
    parser.add_argument("--country", "-c", default="PT", help="Country code (e.g. PT, ES, US, DE)")
    parser.add_argument("--server-type", "-t", default="traffic", choices=["traffic", "streaming", "torrent"])
    parser.add_argument("--city", help="Optional city name")
    parser.add_argument("--config", help="Explicit path to ~/.cyberghost/config.ini")

    args = parser.parse_args()

    if args.action == "connect":
        connect(args.country, args.server_type, args.city, args.config)
    elif args.action == "disconnect":
        disconnect()
    elif args.action == "status":
        status(args.config)


if __name__ == "__main__":
    main()
