#!/usr/bin/env bash

set -euo pipefail
umask 077

VERSION=1.0.0

BIN=/usr/local/bin/hysteria
SHARE=/usr/local/share/hysteria
ETC=/etc/hysteria
CONF=$ETC/config.yaml
CERT=$ETC/server.crt
KEY=$ETC/server.key
STATE=$ETC/hysteria2-hop.env
USERS=$ETC/users
UNIT=/etc/systemd/system/hysteria-server.service
SYSCTL=/etc/sysctl.d/99-hysteria.conf
REPO=apernet/hysteria
GEO_REPO=Loyalsoldier/v2ray-rules-dat

port=
sni=
masq=
hop=
user=main
address=
hy_ver=latest
cert_in=
key_in=
up_mbps=
down_mbps=
firewall=0
new_keys=0
no_geo=0
qr=0
yaml_out=0
json_out=0

usage() {
	cat <<EOF
hysteria2-hop $VERSION

usage: bash install.sh [install] [options]
       bash install.sh show [NAME] [--qr|--yaml|--json]
       bash install.sh hop <START:END|off>
       bash install.sh status
       bash install.sh add NAME | del NAME | users
       bash install.sh uninstall

install options:
  --sni DOMAIN       certificate CN / TLS SNI (www.bing.com)
  --masquerade URL   reverse-proxy decoy URL (https://SNI)
  --port N           main UDP listen port (443)
  --hop START:END    UDP port-hopping range redirected to --port (20000:50000, or off)
  --cert FILE        use a real PEM certificate instead of self-signed
  --key FILE         private key for --cert
  --user NAME        first user name (main)
  --address HOST     server IP or domain put in client links (auto)
  --up MBPS          cap server upload bandwidth in mbps (uncapped)
  --down MBPS        cap server download bandwidth in mbps (uncapped)
  --hysteria vX.Y.Z  pin a Hysteria release (latest)
  --no-geo           skip geoip.dat / geosite.dat download (suffix .ir block stays on)
  --firewall         turn ufw on: ssh + existing xray + hysteria UDP ports
  --new-keys         rotate self-signed cert and salamander key on reinstall
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '[%s/6] %-8s %s\n' "$1" "$2" "$3"; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run it with sudo"; }
have() { command -v "$1" >/dev/null 2>&1; }

valid_name() { [[ $1 =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "names may use A-Z a-z 0-9 _ - (max 32): $1"; }
valid_domain() { [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || die "not a domain name: $1"; }
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || die "bad port: $1"; }
valid_mbps() { [[ $1 =~ ^[1-9][0-9]{0,5}$ ]] || die "bandwidth must be an integer in mbps: $1"; }
valid_masq() {
	local re='^https?://[A-Za-z0-9._~:/?@!$&()*+,;=%-]+$'
	[[ $1 =~ $re ]] || die "bad masquerade URL: $1"
}

norm_hop() {
	local h=${1//-/':'} a b
	if [ "$h" = off ] || [ "$h" = none ]; then
		echo off
		return
	fi
	[[ $h =~ ^([0-9]+):([0-9]+)$ ]] || die "bad hop range (expected START:END or off): $1"
	a=${BASH_REMATCH[1]}
	b=${BASH_REMATCH[2]}
	[ "$a" -ge 1024 ] && [ "$b" -le 65535 ] && [ "$a" -lt "$b" ] ||
		die "hop range must satisfy 1024 <= START < END <= 65535: $1"
	echo "$a:$b"
}

urlenc() {
	local s=$1 out='' c i
	for ((i = 0; i < ${#s}; i++)); do
		c=${s:i:1}
		case $c in
		[a-zA-Z0-9._~-]) out+=$c ;;
		*) printf -v c '%%%02X' "'$c"; out+=$c ;;
		esac
	done
	printf '%s' "$out"
}

arch_name() {
	case $(uname -m) in
	x86_64 | amd64) echo amd64 ;;
	aarch64 | arm64) echo arm64 ;;
	*) die "unsupported cpu: $(uname -m)" ;;
	esac
}

default_iface() {
	local dev
	dev=$(ip -4 route show default 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit } }')
	if [ -z "$dev" ]; then
		dev=$(ip -o link show up 2>/dev/null | awk -F': ' '$2 != "lo" { sub(/@.*/, "", $2); print $2; exit }')
	fi
	[ -n "$dev" ] || die "can't detect network interface"
	echo "$dev"
}

public_ip() {
	local ip
	ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{ split($4, a, "/"); print a[1] }' |
		grep -Ev '^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' | head -n1 || true)
	if [ -z "$ip" ]; then
		for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
			ip=$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]') && [ -n "$ip" ] && break
		done
	fi
	[ -n "$ip" ] || die "can't find the public address, pass --address"
	echo "$ip"
}

ssh_ports() {
	ss -tlnpH 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }' | sort -u
}

xray_ports() {
	ss -tlnpH 2>/dev/null | awk '/"xray"/ { n = split($4, a, ":"); print a[n] }' | sort -u
}

cert_pin() {
	openssl x509 -noout -fingerprint -sha256 -in "$1" | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'
}

load_state() {
	[ -f "$STATE" ] || die "not installed yet"
	. "$STATE"
	UP_MBPS=${UP_MBPS:-}
	DOWN_MBPS=${DOWN_MBPS:-}
	GEO=${GEO:-0}
	IFACE=${IFACE:-$(default_iface)}
}

use_state() {
	port=$PORT
	sni=$SNI
	masq=$MASQ
	hop=$HOP
	address=$ADDRESS
	obfs_key=$OBFS_KEY
	insecure=$INSECURE
	pin_sha256=$PIN_SHA256
	iface=$IFACE
	up_mbps=$UP_MBPS
	down_mbps=$DOWN_MBPS
	geo=$GEO
}

save_state() {
	cat >"$STATE" <<EOF
PORT=$port
SNI=$sni
MASQ=$masq
HOP=$hop
ADDRESS=$address
OBFS_KEY=$obfs_key
INSECURE=$insecure
PIN_SHA256=$pin_sha256
IFACE=$iface
UP_MBPS=$up_mbps
DOWN_MBPS=$down_mbps
GEO=$geo
EOF
	chmod 600 "$STATE"
}

install_binary() {
	local a bin tag want got src tmp
	a=$(arch_name)
	bin=hysteria-linux-$a
	tmp=$(mktemp -d)
	TMPD=$tmp
	trap 'rm -rf "${TMPD:-}"' EXIT
	if [ -f "./$bin" ]; then
		[ -f "./hashes.txt" ] || die "found ./$bin but not ./hashes.txt next to it"
		cp "./$bin" "./hashes.txt" "$tmp/"
		src="local $bin"
	else
		if [ "$hy_ver" = latest ]; then
			tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")
			tag=${tag##*releases/tag/}
			tag=${tag//%2F//}
			[[ $tag == app/v* ]] || die "can't read the latest Hysteria release from GitHub"
		else
			hy_ver=${hy_ver#app/}
			[[ $hy_ver == v* ]] || hy_ver=v$hy_ver
			tag=app/$hy_ver
		fi
		local enc_tag=${tag/\//%2F}
		curl -fsSL --retry 2 -o "$tmp/$bin" "https://github.com/$REPO/releases/download/$enc_tag/$bin" ||
			die "download failed: $tag/$bin"
		curl -fsSL --retry 2 -o "$tmp/hashes.txt" "https://github.com/$REPO/releases/download/$enc_tag/hashes.txt" ||
			die "download failed: $tag/hashes.txt"
		src="github $bin"
	fi
	want=$(awk -v f="$bin" '$2 == f || $2 == "build/" f { print $1; exit }' "$tmp/hashes.txt")
	got=$(sha256sum "$tmp/$bin" | cut -d' ' -f1)
	[ -n "$want" ] && [ "$want" = "$got" ] || die "sha256 mismatch for $bin, not installing it"
	install -m 755 "$tmp/$bin" "$BIN"

	geo=0
	if [ $no_geo -eq 0 ]; then
		install -d -m 755 "$SHARE"
		if [ -f ./geoip.dat ] && [ -f ./geosite.dat ]; then
			[ -f ./geoip.dat.sha256sum ] && [ -f ./geosite.dat.sha256sum ] ||
				die "found local geo .dat files without .sha256sum files next to them"
			cp ./geoip.dat ./geoip.dat.sha256sum ./geosite.dat ./geosite.dat.sha256sum "$tmp/"
		else
			curl -fsSL --retry 2 -o "$tmp/geoip.dat" "https://github.com/$GEO_REPO/releases/latest/download/geoip.dat" &&
				curl -fsSL --retry 2 -o "$tmp/geoip.dat.sha256sum" "https://github.com/$GEO_REPO/releases/latest/download/geoip.dat.sha256sum" &&
				curl -fsSL --retry 2 -o "$tmp/geosite.dat" "https://github.com/$GEO_REPO/releases/latest/download/geosite.dat" &&
				curl -fsSL --retry 2 -o "$tmp/geosite.dat.sha256sum" "https://github.com/$GEO_REPO/releases/latest/download/geosite.dat.sha256sum" ||
				die "geo rules download failed (pass --no-geo on offline hosts)"
		fi
		[ "$(awk '{ print $1 }' "$tmp/geoip.dat.sha256sum")" = "$(sha256sum "$tmp/geoip.dat" | cut -d' ' -f1)" ] ||
			die "sha256 mismatch for geoip.dat"
		[ "$(awk '{ print $1 }' "$tmp/geosite.dat.sha256sum")" = "$(sha256sum "$tmp/geosite.dat" | cut -d' ' -f1)" ] ||
			die "sha256 mismatch for geosite.dat"
		install -m 644 "$tmp/geoip.dat" "$tmp/geosite.dat" "$SHARE/"
		geo=1
	elif [ -s "$SHARE/geoip.dat" ] && [ -s "$SHARE/geosite.dat" ]; then
		geo=1
	fi

	local ver
	ver=$("$BIN" version | awk '/^Version:/ { print $2 }')
	step 2 binary "$ver, $src, sha256 ok"
}

setup_tls() {
	local recreate=$1 tmp
	if [ -n "$cert_in" ] || [ -n "$key_in" ]; then
		[ -n "$cert_in" ] && [ -n "$key_in" ] || die "pass both --cert and --key"
		[ -f "$cert_in" ] || die "no certificate at $cert_in"
		[ -f "$key_in" ] || die "no private key at $key_in"
		openssl x509 -in "$cert_in" -noout 2>/dev/null || die "$cert_in is not a PEM certificate"
		[ "$(openssl x509 -in "$cert_in" -noout -pubkey 2>/dev/null)" = "$(openssl pkey -in "$key_in" -pubout 2>/dev/null)" ] ||
			die "$key_in is not the private key of $cert_in"
		openssl x509 -in "$cert_in" -noout -checkhost "$sni" 2>/dev/null | grep -q 'does match' ||
			die "$cert_in is not valid for $sni"
		openssl x509 -in "$cert_in" -noout -checkend 86400 >/dev/null || die "$cert_in has expired"
		install -m 640 -o root -g hysteria "$cert_in" "$CERT"
		install -m 640 -o root -g hysteria "$key_in" "$KEY"
		insecure=0
		pin_sha256=$(cert_pin "$CERT")
		local end
		end=$(openssl x509 -in "$CERT" -noout -enddate | cut -d= -f2)
		end=$(date -u -d "$end" +%F 2>/dev/null || echo "$end")
		step 3 tls "custom cert for $sni (valid until $end)"
		return
	fi

	if [ "$recreate" -eq 1 ] || [ ! -s "$CERT" ] || [ ! -s "$KEY" ]; then
		tmp=$(mktemp -d)
		openssl ecparam -name P-256 -genkey -out "$tmp/server.key" 2>/dev/null
		openssl req -x509 -new -key "$tmp/server.key" -days 3650 \
			-subj "/CN=$sni" -addext "subjectAltName=DNS:$sni" \
			-out "$tmp/server.crt" 2>/dev/null
		install -m 640 -o root -g hysteria "$tmp/server.crt" "$CERT"
		install -m 640 -o root -g hysteria "$tmp/server.key" "$KEY"
		rm -rf "$tmp"
		insecure=1
	fi
	pin_sha256=$(cert_pin "$CERT")
	step 3 tls "self-signed P-256 (CN=$sni), sha256 pin ${pin_sha256:0:12}..."
}

users_yaml() {
	awk 'NF == 2 { printf "    %s: %s\n", $1, $2 }' "$USERS"
}

write_config() {
	local bw='' geo_cfg='' geo_rules='' tmp_check out
	if [ -n "$up_mbps" ] || [ -n "$down_mbps" ]; then
		bw=$'\nbandwidth:'
		[ -n "$up_mbps" ] && bw+=$'\n'"  up: $up_mbps mbps"
		[ -n "$down_mbps" ] && bw+=$'\n'"  down: $down_mbps mbps"
	fi
	if [ "$geo" -eq 1 ] && [ -s "$SHARE/geoip.dat" ] && [ -s "$SHARE/geosite.dat" ]; then
		geo_cfg=$'\n'"  geoip: $SHARE/geoip.dat"$'\n'"  geosite: $SHARE/geosite.dat"
		geo_rules=$'\n'"    - reject(geoip:ir)"$'\n'"    - reject(geosite:category-ir)"
	fi
	cat >"$ETC/config.new.yaml" <<EOF
listen: :$port

tls:
  cert: $CERT
  key: $KEY

auth:
  type: userpass
  userpass:
$(users_yaml)

obfs:
  type: salamander
  salamander:
    password: $obfs_key
$bw
masquerade:
  type: proxy
  proxy:
    url: $masq
    rewriteHost: true

outbounds:
  - name: direct
    type: direct

acl:$geo_cfg
  inline:
    - reject(127.0.0.0/8)
    - reject(10.0.0.0/8)
    - reject(172.16.0.0/12)
    - reject(192.168.0.0/16)
    - reject(100.64.0.0/10)
    - reject(169.254.0.0/16)
    - reject(0.0.0.0/8)
    - reject(::1/128)
    - reject(fc00::/7)
    - reject(fe80::/10)$geo_rules
    - reject(suffix:ir)
    - direct(all)
EOF
	tmp_check=$(mktemp --suffix=.yaml)
	sed '1s/^listen: .*/listen: 127.0.0.1:0/' "$ETC/config.new.yaml" >"$tmp_check"
	out=$(HYSTERIA_ACL_DIR=/tmp timeout 1.2 "$BIN" server --disable-update-check -c "$tmp_check" 2>&1 || true)
	rm -f "$tmp_check"
	grep -q 'server up and running' <<<"$out" || {
		rm -f "$ETC/config.new.yaml"
		printf '%s\n' "$out" >&2
		die "hysteria rejected the generated config"
	}
	chown root:hysteria "$ETC/config.new.yaml"
	chmod 640 "$ETC/config.new.yaml"
	mv "$ETC/config.new.yaml" "$CONF"
}

write_unit() {
	cat >"$UNIT" <<EOF
[Unit]
Description=Hysteria 2 (hysteria2-hop)
Documentation=https://github.com/v74all/hysteria2-hop
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hysteria
Group=hysteria
StateDirectory=hysteria
Environment=HYSTERIA_ACL_DIR=/var/lib/hysteria
ExecStart=$BIN server --disable-update-check -c $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
	chmod 644 "$UNIT"
}

restart_service() {
	systemctl daemon-reload
	systemctl enable hysteria-server >/dev/null 2>&1
	systemctl restart hysteria-server
	sleep 1
	systemctl is-active --quiet hysteria-server || {
		journalctl -u hysteria-server -n 20 --no-pager >&2 || true
		die "hysteria-server did not start"
	}
}

clear_nat_rule() {
	local dev=$1 rng=$2 dst=$3
	[ -n "$rng" ] && [ "$rng" != off ] || return 0
	if have iptables; then
		while iptables -t nat -D PREROUTING -i "$dev" -p udp --dport "$rng" -j REDIRECT --to-ports "$dst" 2>/dev/null; do :; done
		while iptables -t nat -D PREROUTING -p udp --dport "$rng" -j REDIRECT --to-ports "$dst" 2>/dev/null; do :; done
	fi
	if have ip6tables; then
		while ip6tables -t nat -D PREROUTING -i "$dev" -p udp --dport "$rng" -j REDIRECT --to-ports "$dst" 2>/dev/null; do :; done
		while ip6tables -t nat -D PREROUTING -p udp --dport "$rng" -j REDIRECT --to-ports "$dst" 2>/dev/null; do :; done
	fi
}

apply_nat_rule() {
	local dev=$1 rng=$2 dst=$3
	[ "$rng" != off ] || return 0
	have iptables || die "iptables is not installed"
	iptables -t nat -C PREROUTING -i "$dev" -p udp --dport "$rng" -j REDIRECT --to-ports "$dst" 2>/dev/null ||
		iptables -t nat -A PREROUTING -i "$dev" -p udp --dport "$rng" -j REDIRECT --to-ports "$dst"
	if have ip6tables && ip -6 addr show dev "$dev" scope global 2>/dev/null | grep -q inet6 &&
		ip6tables -t nat -L PREROUTING >/dev/null 2>&1; then
		ip6tables -t nat -C PREROUTING -i "$dev" -p udp --dport "$rng" -j REDIRECT --to-ports "$dst" 2>/dev/null ||
			ip6tables -t nat -A PREROUTING -i "$dev" -p udp --dport "$rng" -j REDIRECT --to-ports "$dst" || true
	fi
}

save_firewall() {
	if have netfilter-persistent; then
		netfilter-persistent save >/dev/null 2>&1 || true
	fi
}

tune_udp_buffers() {
	cat >"$SYSCTL" <<EOF
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=2621440
net.core.wmem_default=2621440
EOF
	chmod 644 "$SYSCTL"
	{
		echo 16777216 >/proc/sys/net/core/rmem_max
		echo 16777216 >/proc/sys/net/core/wmem_max
		echo 2621440 >/proc/sys/net/core/rmem_default
		echo 2621440 >/proc/sys/net/core/wmem_default
	} 2>/dev/null || sysctl --system >/dev/null 2>&1 || true
}

setup_network() {
	local old_hop=$1 old_port=$2 old_iface=$3 hop_note fw_note rmem p
	clear_nat_rule "$old_iface" "$old_hop" "$old_port"
	if [ "$hop" != off ]; then
		apply_nat_rule "$iface" "$hop" "$port"
		save_firewall
		hop_note="udp $hop -> $port ($iface)"
	else
		save_firewall
		hop_note="hop off (udp $port only)"
	fi

	if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
		ufw allow "$port/udp" >/dev/null
		[ "$hop" != off ] && ufw allow "$hop/udp" >/dev/null
		fw_note="ufw updated"
	elif [ $firewall -eq 1 ]; then
		have ufw || { DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null 2>&1 || die "can't install ufw"; }
		ufw default deny incoming >/dev/null
		ufw default allow outgoing >/dev/null
		for p in $(ssh_ports) 22; do ufw allow "$p/tcp" >/dev/null; done
		for p in $(xray_ports); do ufw allow "$p/tcp" >/dev/null; done
		ufw allow "$port/udp" >/dev/null
		[ "$hop" != off ] && ufw allow "$hop/udp" >/dev/null
		ufw --force enable >/dev/null
		fw_note="ufw on"
	else
		fw_note="ufw untouched"
	fi

	if have iptables && iptables -S INPUT 2>/dev/null | grep -q 'icmp-host-prohibited'; then
		iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null ||
			iptables -I INPUT 1 -p udp --dport "$port" -j ACCEPT
		if [ "$hop" != off ]; then
			iptables -C INPUT -p udp --dport "$hop" -j ACCEPT 2>/dev/null ||
				iptables -I INPUT 1 -p udp --dport "$hop" -j ACCEPT
		fi
		save_firewall
		fw_note="$fw_note, oracle input open"
	fi

	tune_udp_buffers
	rmem=$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo unknown)
	step 6 network "$hop_note, $fw_note, rmem_max $rmem"
}

cmd_install() {
	need_root
	have systemctl && [ -d /run/systemd/system ] || die "this needs a systemd server"
	valid_name "$user"

	local reinstall=0 old_hop=off old_port=443 old_iface=''
	if [ -f "$STATE" ]; then
		reinstall=1
		load_state
		old_hop=$HOP
		old_port=$PORT
		old_iface=$IFACE
		port=${port:-$PORT}
		sni=${sni:-$SNI}
		masq=${masq:-$MASQ}
		hop=${hop:-$HOP}
		address=${address:-$ADDRESS}
		up_mbps=${up_mbps:-$UP_MBPS}
		down_mbps=${down_mbps:-$DOWN_MBPS}
		obfs_key=$OBFS_KEY
		insecure=$INSECURE
		pin_sha256=$PIN_SHA256
	fi

	port=${port:-443}
	sni=${sni:-www.bing.com}
	sni=${sni,,}
	masq=${masq:-https://$sni}
	hop=$(norm_hop "${hop:-20000:50000}")

	valid_port "$port"
	valid_domain "$sni"
	valid_masq "$masq"
	[ -z "$up_mbps" ] || valid_mbps "$up_mbps"
	[ -z "$down_mbps" ] || valid_mbps "$down_mbps"
	iface=$(default_iface)
	old_iface=${old_iface:-$iface}

	local os missing=() p
	os=$(. /etc/os-release 2>/dev/null && echo "$ID $VERSION_ID") || os=linux
	for p in curl openssl iptables qrencode; do have "$p" || missing+=("$p"); done
	if [ "$hop" != off ] && ! have netfilter-persistent; then
		missing+=("iptables-persistent")
	fi
	if [ ${#missing[@]} -gt 0 ]; then
		have apt-get || die "install these first: ${missing[*]}"
		{
			DEBIAN_FRONTEND=noninteractive apt-get update -qq &&
				DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" ca-certificates
		} >/dev/null 2>&1 || die "apt-get install ${missing[*]} failed"
	fi
	step 1 system "$os, $(uname -m), systemd"

	if ss -ulnpH "sport = :$port" 2>/dev/null | grep -v '"hysteria"' | grep -q .; then
		die "udp port $port is already used by: $(ss -ulnpH "sport = :$port" | grep -o 'users:(("[^"]*' | cut -d'"' -f2 | head -n1)"
	fi

	install_binary

	id -u hysteria >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin hysteria
	install -d -m 750 -o root -g hysteria "$ETC"

	local rotate_tls=0
	if [ $reinstall -eq 0 ] || [ $new_keys -eq 1 ]; then
		rotate_tls=1
		obfs_key=$(openssl rand -hex 16)
	fi
	setup_tls "$rotate_tls"

	[ -s "$USERS" ] || printf '%s %s\n' "$user" "$(openssl rand -hex 16)" >"$USERS"
	chmod 600 "$USERS"
	[ -n "$address" ] || address=$(public_ip)

	save_state
	write_config
	local acl_label="suffix .ir + private blocked"
	[ "$geo" -eq 1 ] && acl_label="geoip/geosite ir + private blocked"
	step 4 config "$CONF, salamander on, $acl_label"

	write_unit
	restart_service
	step 5 service "hysteria-server.service active, runs as user hysteria"

	setup_network "$old_hop" "$old_port" "$old_iface"
	echo "done. your link: sudo bash install.sh show"
}

format_host() {
	if [[ $1 == *:* ]] && [[ $1 != \[* ]]; then
		printf '[%s]' "$1"
	else
		printf '%s' "$1"
	fi
}

uri_v2ray() {
	local name=$1 pass=$2 host q hop_dash
	host=$(format_host "$ADDRESS")
	q="sni=$SNI&insecure=$INSECURE"
	[ "$INSECURE" -eq 1 ] && [ -n "${PIN_SHA256:-}" ] && q+="&pinSHA256=$PIN_SHA256"
	q+="&obfs=salamander&obfs-password=$(urlenc "$OBFS_KEY")"
	if [ "$HOP" != off ]; then
		hop_dash=${HOP/:/-}
		q+="&mport=$hop_dash"
	fi
	printf 'hysteria2://%s:%s@%s:%s?%s#%s\n' "$(urlenc "$name")" "$(urlenc "$pass")" "$host" "$PORT" "$q" "$(urlenc "$name")"
}

uri_standard() {
	local name=$1 pass=$2 host port_spec q
	host=$(format_host "$ADDRESS")
	port_spec=$PORT
	[ "$HOP" != off ] && port_spec="$PORT,${HOP/:/-}"
	q="sni=$SNI&insecure=$INSECURE"
	[ "$INSECURE" -eq 1 ] && [ -n "${PIN_SHA256:-}" ] && q+="&pinSHA256=$PIN_SHA256"
	q+="&obfs=salamander&obfs-password=$(urlenc "$OBFS_KEY")"
	printf 'hysteria2://%s:%s@%s:%s/?%s#%s\n' "$(urlenc "$name")" "$(urlenc "$pass")" "$host" "$port_spec" "$q" "$(urlenc "$name")"
}

client_yaml() {
	local name=$1 pass=$2 host port_spec pin_line='' hop_block=''
	host=$(format_host "$ADDRESS")
	port_spec=$PORT
	if [ "$HOP" != off ]; then
		port_spec="$PORT,${HOP/:/-}"
		hop_block=$'\ntransport:\n  udp:\n    hopInterval: 30s'
	fi
	[ "$INSECURE" -eq 1 ] && [ -n "${PIN_SHA256:-}" ] && pin_line=$'\n'"  pinSHA256: $PIN_SHA256"
	cat <<EOF
server: $host:$port_spec
auth: $name:$pass
tls:
  sni: $SNI
  insecure: $( [ "$INSECURE" -eq 1 ] && echo true || echo false )$pin_line
obfs:
  type: salamander
  salamander:
    password: $OBFS_KEY$hop_block
socks5:
  listen: 127.0.0.1:10808
http:
  listen: 127.0.0.1:10809
EOF
}

client_singbox() {
	local name=$1 pass=$2 ports_block=''
	if [ "$HOP" != off ]; then
		ports_block=$(printf ',\n      "server_ports": ["%s:%s", "%s"],\n      "hop_interval": "30s"' "$PORT" "$PORT" "$HOP")
	fi
	cat <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    { "type": "socks", "tag": "socks-in", "listen": "127.0.0.1", "listen_port": 10808 }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "proxy",
      "server": "$ADDRESS",
      "server_port": $PORT$ports_block,
      "password": "$name:$pass",
      "obfs": { "type": "salamander", "password": "$OBFS_KEY" },
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "insecure": $( [ "$INSECURE" -eq 1 ] && echo true || echo false )
      }
    }
  ]
}
EOF
}

cmd_show() {
	need_root
	load_state
	local target=${1:-} n pw found=0 u1 u2
	while read -r n pw; do
		[ -z "$target" ] || [ "$n" = "$target" ] || continue
		found=1
		if [ $yaml_out -eq 1 ]; then
			client_yaml "$n" "$pw"
			return
		fi
		if [ $json_out -eq 1 ]; then
			client_singbox "$n" "$pw"
			return
		fi
		u1=$(uri_v2ray "$n" "$pw")
		u2=$(uri_standard "$n" "$pw")
		if [ "$HOP" != off ]; then
			printf '%s (v2rayNG / v2rayN / NekoBox):\n%s\n' "$n" "$u1"
			printf '%s (Hiddify / Hysteria):\n%s\n' "$n" "$u2"
		else
			[ -z "$target" ] && printf '%s\n' "$n"
			printf '%s\n' "$u1"
		fi
		if [ $qr -eq 1 ]; then
			have qrencode || die "qrencode is not installed"
			printf '%s\n' "$u1" | qrencode -t ANSIUTF8 -m 1
		fi
	done <"$USERS"
	[ $found -eq 1 ] || die "no user named $target"
}

cmd_hop() {
	need_root
	load_state
	use_state
	[ -n "${1:-}" ] || die "usage: install.sh hop <START:END|off>"
	local new_hop
	new_hop=$(norm_hop "$1")
	clear_nat_rule "$iface" "$hop" "$port"
	hop=$new_hop
	if [ "$hop" != off ]; then
		apply_nat_rule "$iface" "$hop" "$port"
		if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
			ufw allow "$hop/udp" >/dev/null
		fi
	fi
	save_firewall
	save_state
	if [ "$hop" = off ]; then
		printf 'hop       off (udp %s only)\n' "$port"
	else
		printf 'hop       udp %s -> %s on %s (saved)\n' "$hop" "$port" "$iface"
	fi
	printf 'link      sudo bash install.sh show\n'
}

cmd_status() {
	need_root
	load_state
	local svc ver sock nat rmem end
	svc=$(systemctl is-active hysteria-server 2>/dev/null || true)
	ver=$("$BIN" version 2>/dev/null | awk '/^Version:/ { print $2 }')
	sock=$(ss -ulnpH "sport = :$PORT" 2>/dev/null | awk 'NR == 1 { print $4 }' || true)
	if [ "$HOP" != off ] && have iptables &&
		iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport "$HOP" -j REDIRECT --to-ports "$PORT" 2>/dev/null; then
		nat="udp $HOP -> $PORT ($IFACE)"
	elif [ "$HOP" = off ]; then
		nat="off"
	else
		nat="missing ($HOP -> $PORT)"
	fi
	rmem=$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo unknown)
	end=$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | cut -d= -f2 || echo unknown)
	end=$(date -u -d "$end" +%F 2>/dev/null || echo "$end")
	printf 'service   %s (%s)\n' "${svc:-inactive}" "${ver:-unknown}"
	printf 'listen    %s (udp %s)\n' "${sock:-not bound}" "$PORT"
	printf 'hop       %s\n' "$nat"
	printf 'sni       %s (valid until %s)\n' "$SNI" "$end"
	printf 'pin       %s\n' "$PIN_SHA256"
	printf 'rmem_max  %s\n' "$rmem"
	printf 'users     %s\n' "$(awk '{ print $1 }' "$USERS" | paste -sd' ' -)"
}

cmd_add() {
	need_root
	load_state
	local name=${1:-}
	[ -n "$name" ] || die "usage: install.sh add NAME"
	valid_name "$name"
	grep -q "^$name " "$USERS" && die "$name already exists"
	printf '%s %s\n' "$name" "$(openssl rand -hex 16)" >>"$USERS"
	use_state
	write_config
	restart_service
	cmd_show "$name"
}

cmd_del() {
	need_root
	load_state
	local name=${1:-}
	[ -n "$name" ] || die "usage: install.sh del NAME"
	grep -q "^$name " "$USERS" || die "no user named $name"
	[ "$(grep -c . "$USERS")" -gt 1 ] || die "$name is the last user; uninstall instead"
	sed -i "/^$name /d" "$USERS"
	use_state
	write_config
	restart_service
	echo "removed $name (its link stops working now)"
}

cmd_uninstall() {
	need_root
	if [ -f "$STATE" ]; then
		load_state
		clear_nat_rule "$IFACE" "$HOP" "$PORT"
		save_firewall
	fi
	systemctl disable --now hysteria-server >/dev/null 2>&1 || true
	rm -f "$UNIT" "$BIN" "$SYSCTL"
	rm -rf "$ETC" "$SHARE" /var/lib/hysteria
	systemctl daemon-reload
	id -u hysteria >/dev/null 2>&1 && userdel hysteria
	echo "removed hysteria, port-hopping rules, config and user (ufw rules stay as they are)"
}

cmd=install
case ${1:-} in
install | show | hop | status | add | del | users | uninstall) cmd=$1; shift ;;
esac
args=()
while [ $# -gt 0 ]; do
	case $1 in
	--sni) sni=${2:?--sni needs a domain}; shift ;;
	--masquerade) masq=${2:?--masquerade needs a URL}; shift ;;
	--port) port=${2:?--port needs a number}; shift ;;
	--hop) hop=${2:?--hop needs START:END or off}; shift ;;
	--cert) cert_in=${2:?--cert needs a file}; shift ;;
	--key) key_in=${2:?--key needs a file}; shift ;;
	--user) user=${2:?--user needs a name}; shift ;;
	--address) address=${2:?--address needs a host}; shift ;;
	--up) up_mbps=${2:?--up needs mbps}; shift ;;
	--down) down_mbps=${2:?--down needs mbps}; shift ;;
	--hysteria) hy_ver=${2:?--hysteria needs a version}; shift ;;
	--no-geo) no_geo=1 ;;
	--firewall) firewall=1 ;;
	--new-keys) new_keys=1 ;;
	--qr) qr=1 ;;
	--yaml) yaml_out=1 ;;
	--json) json_out=1 ;;
	-h | --help) usage; exit 0 ;;
	--version) echo "$VERSION"; exit 0 ;;
	-*) die "unknown option: $1 (see --help)" ;;
	*) args+=("$1") ;;
	esac
	shift
done

case $cmd in
install) cmd_install ;;
show) cmd_show "${args[0]:-}" ;;
hop) cmd_hop "${args[0]:-}" ;;
status) cmd_status ;;
add) cmd_add "${args[0]:-}" ;;
del) cmd_del "${args[0]:-}" ;;
users) need_root; load_state; awk '{ print $1 }' "$USERS" ;;
uninstall) cmd_uninstall ;;
esac
