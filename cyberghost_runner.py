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
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "requests", "--break-system-packages"])
        import requests
    except Exception:
        sys.exit("Error: 'requests' library is required. Please install python-requests.")

WG_CONF_PATH = "/etc/wireguard/cyberghost.conf"
INTERFACE = "cyberghost"

# Comprehensive mapping of Country Code -> Primary CyberGhost city slug
CITY_MAP = {
    "PT": "lisbon",
    "ES": "madrid",
    "DE": "frankfurt",
    "GB": "london",
    "UK": "london",
    "US": "newyork",
    "FR": "paris",
    "NL": "amsterdam",
    "CH": "zurich",
    "IT": "milan",
    "BR": "saopaulo",
    "CA": "montreal",
    "SE": "stockholm",
    "JP": "tokyo",
    "AU": "sydney",
    "AT": "vienna",
    "BE": "brussels",
    "PL": "warsaw",
    "RO": "bucharest",
    "NO": "oslo",
    "DK": "copenhagen",
    "FI": "helsinki",
    "IE": "dublin",
    "SG": "singapore",
    "MX": "mexicocity",
    "IN": "mumbai",
    "ZA": "johannesburg",
    "NZ": "auckland",
    "CZ": "prague",
    "GR": "athens",
    "TR": "istanbul",
    "HU": "budapest",
    "BG": "sofia",
    "HR": "zagreb",
    "IS": "reykjavik",
    "IL": "telaviv",
    "KR": "seoul",
    "AR": "buenosaires",
    "CL": "santiago",
    "CO": "bogota",
    "AE": "dubai",
    "HK": "hongkong",
    "TW": "taipei",
    "MY": "kualalumpur",
    "TH": "bangkok",
    "ID": "jakarta",
    "PH": "manila",
    "VN": "hanoi",
    "UA": "kyiv",
    "RS": "belgrade",
    "SK": "bratislava",
    "SI": "ljubljana",
    "LU": "luxembourg",
}


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
        raise RuntimeError(f"Configuration file not found: {path}. Please run 'cyberghostvpn --setup' first.")

    cfg = configparser.ConfigParser()
    try:
        cfg.read(path)
    except Exception as e:
        raise RuntimeError(f"Failed to parse config file at {path}: {e}")

    if not cfg.has_section("device") or not cfg.has_option("device", "token") or not cfg.has_option("device", "secret"):
        raise RuntimeError(f"Device credentials missing from {path}. Please run 'cyberghostvpn --setup'")

    token = cfg.get("device", "token").strip()
    secret = cfg.get("device", "secret").strip()
    return token, secret


def get_servers_for_country(country_code, server_type="traffic"):
    """
    Query available server instances for a country if cyberghostvpn is present.
    """
    try:
        cmd = ["cyberghostvpn", f"--{server_type}", "--country-code", country_code.upper()]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=5)

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
    except Exception:
        return []


def generate_wireguard_keys():
    try:
        priv = subprocess.check_output(["wg", "genkey"]).decode().strip()
        pub = subprocess.check_output(["wg", "pubkey"], input=priv.encode()).decode().strip()
        return priv, pub
    except Exception as e:
        raise RuntimeError(f"Failed to generate WireGuard keys using 'wg': {e}. Ensure wireguard-tools is installed.")


def connect(country_code="PT", server_type="traffic", city=None, config_path=None):
    token, secret = get_credentials(config_path)
    priv_key, pub_key = generate_wireguard_keys()

    cc = country_code.upper().strip()
    city_slug = None

    if city:
        city_slug = city.lower().replace(" ", "")
    elif cc in CITY_MAP:
        city_slug = CITY_MAP[cc]
    else:
        servers = get_servers_for_country(cc, server_type)
        if servers:
            city_slug = servers[0]["city"].lower().replace(" ", "")
        else:
            city_slug = "lisbon"

    # Build server pool candidates with multiple instance numbers and server tiers
    candidates = [
        f"{city_slug}-s405-i01.cg-dialup.net",
        f"{city_slug}-s405-i02.cg-dialup.net",
        f"{city_slug}-s405-i03.cg-dialup.net",
        f"{city_slug}-s401-i01.cg-dialup.net",
        f"{city_slug}-s401-i02.cg-dialup.net",
        f"{city_slug}-s401-i03.cg-dialup.net",
        f"{city_slug}-s406-i01.cg-dialup.net",
        f"{city_slug}-s407-i01.cg-dialup.net",
    ]

    addkey_data = None
    connected_host = None
    last_error_msg = None

    for host in candidates:
        url = f"https://{host}:1337/addKey"
        try:
            r = requests.get(url, params={"pubkey": pub_key}, auth=(token, secret), verify=False, timeout=3.5)
            if r.status_code == 200:
                data = r.json()
                if data.get("status") == "OK" and data.get("server_key"):
                    addkey_data = data
                    connected_host = host
                    break
                elif "error" in data:
                    last_error_msg = data.get("error")
            elif r.status_code == 401 or r.status_code == 403:
                raise RuntimeError("Authentication failed. Please verify your CyberGhost subscription or run 'cyberghostvpn --setup'.")
        except requests.exceptions.RequestException as req_err:
            last_error_msg = str(req_err)
            continue

    if not addkey_data:
        err = f"Could not establish WireGuard key exchange with CyberGhost servers in {cc}."
        if last_error_msg:
            err += f" ({last_error_msg})"
        raise RuntimeError(err)

    # Generate WireGuard configuration
    dns_list = addkey_data.get("dns_servers", ["10.0.0.243", "10.0.0.242", "1.1.1.1"])
    dns_servers = ", ".join(dns_list) if isinstance(dns_list, list) else str(dns_list)
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

    # Clean up any leftover interface first to avoid collisions
    subprocess.run(["wg-quick", "down", INTERFACE], capture_output=True)

    # Bring up WireGuard connection
    up_res = subprocess.run(["wg-quick", "up", INTERFACE], capture_output=True, text=True)
    if up_res.returncode != 0:
        # If DNS configuration failed in wg-quick, retry with DNS fallback
        if "resolvconf" in up_res.stderr or "resolv" in up_res.stderr:
            no_dns_config = f"""[Interface]
PrivateKey = {priv_key}
Address = {peer_ip}/32

[Peer]
PublicKey = {server_key}
AllowedIPs = 0.0.0.0/0
Endpoint = {server_ip}:{server_port}
PersistentKeepalive = 25
"""
            with open(WG_CONF_PATH, "w") as f:
                f.write(no_dns_config)
            up_res = subprocess.run(["wg-quick", "up", INTERFACE], capture_output=True, text=True)

        if up_res.returncode != 0:
            raise RuntimeError(f"wg-quick up failed: {up_res.stderr.strip() or up_res.stdout.strip()}")

    print("VPN connection established.")
    print(f"Connected to {cc} via {connected_host} (IP: {server_ip})")


def disconnect():
    subprocess.run(["wg-quick", "down", INTERFACE], capture_output=True)
    subprocess.run(["cyberghostvpn", "--stop"], capture_output=True)
    print("VPN connection terminated.")


def status(config_path=None, as_json=False):
    ip_res = subprocess.run(["ip", "link", "show", INTERFACE], capture_output=True, text=True)
    is_connected = (ip_res.returncode == 0 and INTERFACE in ip_res.stdout)

    if as_json:
        result = {
            "connected": is_connected,
            "interface": INTERFACE if is_connected else None
        }
        if is_connected:
            wg_res = subprocess.run(["wg", "show", INTERFACE], capture_output=True, text=True)
            if wg_res.returncode == 0:
                for line in wg_res.stdout.splitlines():
                    if "endpoint:" in line:
                        result["endpoint"] = line.split(":", 1)[1].strip()
                    elif "transfer:" in line:
                        result["transfer"] = line.split(":", 1)[1].strip()
        print(json.dumps(result))
        return

    if is_connected:
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
    parser.add_argument("--json", action="store_true", help="Output status as JSON")

    args = parser.parse_args()

    try:
        if args.action == "connect":
            connect(args.country, args.server_type, args.city, args.config)
        elif args.action == "disconnect":
            disconnect()
        elif args.action == "status":
            status(args.config, args.json)
    except Exception as e:
        sys.stderr.write(f"Error: {e}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
