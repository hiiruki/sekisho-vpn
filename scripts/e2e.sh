#!/bin/sh
# End-to-end tunnel test against a local SoftEther VPN Server (SSTP + SecureNAT on 192.168.30.0/24), run by CI:
# TLS with a pinned self-signed certificate, SSTP crypto binding, MS-CHAPv2, IPCP, utun, split-tunnel subnet and
# hostname routes, disconnect cleanup and the session history. Needs sudo; usage: e2e.sh <SoftEther build dir>.
# Split tunnel only: a full tunnel would take the machine's own connection (and SecureNAT's) into the tunnel.
set -eu
SE=$1
SOCK=/tmp/sekisho-e2e.sock
cd "$(dirname "$0")/.."

sudo "$SE/vpnserver" start
for _ in $(seq 30); do nc -z 127.0.0.1 5555 2>/dev/null && break; sleep 1; done
vpncmd() { "$SE/vpncmd" localhost:5555 /SERVER "$@"; }
vpncmd /CMD SstpEnable yes
vpncmd /ADMINHUB:DEFAULT /CMD UserCreate test /GROUP:none /REALNAME:none /NOTE:none
vpncmd /ADMINHUB:DEFAULT /CMD UserPasswordSet test /PASSWORD:e2e-pass
vpncmd /ADMINHUB:DEFAULT /CMD SecureNatEnable
PIN=$(openssl s_client -connect 127.0.0.1:443 </dev/null 2>/dev/null | openssl x509 -outform der | shasum -a 256 | cut -d' ' -f1)
echo "server certificate SHA-256 $PIN"

swift build --product sstpd
sudo env SSTPD_SOCKET=$SOCK "$(swift build --show-bin-path)/sstpd" > /tmp/sstpd.log 2>&1 &
for _ in $(seq 30); do [ -S $SOCK ] && break; sleep 1; done

# root client: the helper accepts root without the app's code signature
sudo python3 - "$SOCK" "$PIN" <<'EOF'
import json, socket, subprocess, sys, time

sock_path, pin = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX)
s.connect(sock_path)
f = s.makefile("rwb")

def send(req):
    f.write((json.dumps(req) + "\n").encode())
    f.flush()

def wait(done, secs):
    s.settimeout(secs)
    end = time.time() + secs
    while time.time() < end:
        line = f.readline()
        if not line:
            sys.exit("helper closed the socket")
        e = json.loads(line)
        for l in e.get("log") or []:
            print("  |", l)
        st = e.get("status")
        if st and done(st):
            return st
    sys.exit("timeout")

def out(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout

def check(ok, what):
    if not ok:
        sys.exit("FAIL: " + what)
    print("ok:", what)

wait(lambda st: True, 10)  # first event: current status and log backlog
send({"cmd": "connect", "profile": {
    "name": "e2e", "server": "127.0.0.1", "port": 443, "username": "test@DEFAULT", "password": "e2e-pass",
    "pinnedCert": pin, "routes": "192.168.30.0/24, example.com", "autoReconnect": False}})
st = wait(lambda st: st["state"] == "connected" or (st["state"] == "disconnected" and st.get("message")), 60)
check(st["state"] == "connected", "connected: " + st.get("message", ""))
ip, ifname = st["localIP"], st["interface"]
check(ip.startswith("192.168.30."), f"address {ip} from SecureNAT")
check(f"interface: {ifname}" in out("route", "-n", "get", "192.168.30.1"), f"subnet route via {ifname}")
check(subprocess.run(["ping", "-c", "3", "-t", "10", "192.168.30.1"]).returncode == 0, "ping through the tunnel")

# hostname: resolved by the VPN's DNS (SecureNAT) and routed by address
for _ in range(20):
    if f"interface: {ifname}" in out("route", "-n", "get", "example.com"):
        break
    time.sleep(1)
check(f"interface: {ifname}" in out("route", "-n", "get", "example.com"), f"example.com routed via {ifname}")
code = out("curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "20", "http://example.com/")
check(code == "200", f"HTTP through the tunnel ({code})")

send({"cmd": "disconnect"})
wait(lambda st: st["state"] == "disconnected", 15)
check(ifname not in out("ifconfig", "-l").split(), f"{ifname} removed")
check(f"interface: {ifname}" not in out("route", "-n", "get", "192.168.30.1"), "routes removed")
h = json.load(open("/var/db/sekisho.sessions.json"))
check(h and h[0]["profile"] == "e2e" and not h[0]["dropped"], "session recorded as disconnected")
print("e2e passed")
EOF
