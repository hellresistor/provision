#!/usr/bin/env bash

# Generate a random string of length $1 (64).
random() {
	local LC_CTYPE=C
	tr -dc A-Za-z0-9 < /dev/urandom | head -c ${1:-64}
}

# Make a backup copy.
backup() {
	if test -f $1; then
		cp $1 $1.$(date +"%Y%m%d%H%M%S")
	fi
}

# Parse flags.
argv="$@"
while test $# -gt 0; do
	case "$1" in
		--log|-l) log="$2"; shift ;;
		--debug|-x) debug=true ;;
	esac
	shift
done

# Restore positional arguments.
set -- "$argv"

# Set defaults.
log=${log:-provision-$(date +"%Y%m%d%H%M%S").log}
debug=${debug:-false}

# -
# -
# -

# Log everything.
exec > >(tee $log) 2>&1

# Require privilege, i.e. sudo.
if test $(id -u) -ne 0; then
	echo "🚫 Try again using sudo or as root." >&2
	exit 1
fi

# Test for the presence of required software.
dependency="apt-get apt-key curl iptables sysctl"
for dep in $dependency; do
	if ! type $dep >/dev/null 2>&1; then
		echo "🚫 '$dep' could not be found, which is a hard dependency along with: $dependency." >&2
		exit 1
	fi
done

printf "
  ____                 _     _
 |  _ \\ _ __ _____   _(_)___(_) ___  _ __
 | |_) | '__/ _ \\ \\ / / / __| |/ _ \\| '_ \\
 |  __/| | | (_) \\ V /| \\__ \\ | (_) | | | |
 |_|   |_|  \\___/ \\_/ |_|___/_|\\___/|_| |_|

⚠ Please note that this script will:

	- Reset root password.
	- Create a new user and add your public key.
	- Reconfigure SSH on an alternative port (822).
	- Disable IPv6.
	- Upgrade existing packages and install new software.
	- Block all incoming traffic except on ports 822 (for SSH), 80, and 443.
	- Configure automatic unattended upgrades for security patches.
	- Setup swap space equals to the available memory.
	- \e[1mOutput secrets in plain text\e[0m.

🗒 You should have at hand:

	- Your RSA public key.

🕵 Note that you can re-execute this script with --debug flag to have each step printed on screen.

"

# Confirm before continueing.
read -rsp "🚦 Press ENTER to continue or CTRL-C to abort..." _

# Enable debug with either --debug or -x.
test "$debug" = true && set -x 

# Halt on errors and undeclared variables.
set -ue

# Let debconf know we won't interact.
export DEBIAN_FRONTEND=noninteractive

# Add Docker repository to the source list.
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
echo "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" >> /etc/apt/sources.list.d/docker.list

# Refresh repositories and upgrade installed packages.
apt-get update
apt-get upgrade -y
apt-get autoremove -y

# Configure environment encoding.
export LANGUAGE=en_US.UTF-8
export LC_ALL=en_US.UTF-8
update-locale LANGUAGE=en_US.UTF-8 LC_ALL=en_US.UTF-8
locale-gen en_US.UTF-8

# Disable IPV6 because we're likely on DigitalOcean.
# - https://github.com/dokku/dokku/blob/4008919a3c8b1cf440d010f448215d0776938f88/docs/getting-started/install/digitalocean.md
# - https://twitter.com/ksaitor/status/1021435996230045697
cat >> /etc/sysctl.conf <<-EOF
	net.ipv6.conf.all.disable_ipv6 = 1
	net.ipv6.conf.default.disable_ipv6 = 1
	net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -p
cat /proc/sys/net/ipv6/conf/all/disable_ipv6

# Clear firewall rules.
iptables -F
iptables -t nat -F
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT

# Accept anything from/to loopback interface.
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Docker client/server communication.
iptables -A INPUT -s 127.0.0.1 -p tcp --dport 2375 -j ACCEPT

# Keep established or related connections.
iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Allow TCP connections using ports for HTTP, HTTPS and SSH.
ports="80 443 822"
for port in $ports; do
	iptables -A INPUT -p tcp --dport $port -j ACCEPT;
done

# Allow regular pings.
iptables -A INPUT -p icmp -m icmp --icmp-type 8 -j ACCEPT

# Block any other incoming connections.
iptables -A INPUT -j DROP

# Log all the traffic.
iptables -A INPUT -j LOG --log-tcp-options --log-prefix "[iptables] "
iptables -A FORWARD -j LOG --log-tcp-options --log-prefix "[iptables] "

# Pipe it to its own file.
cat > /etc/rsyslog.d/10-iptables.conf <<-EOF
	:msg, contains, "[iptables] " -/var/log/iptables.log
	& stop
EOF
service rsyslog restart

# Rotate the log so it doesn't fill up the disk.
cat > /etc/logrotate.d/iptables <<-EOF
	/var/log/iptables.log
	{
		rotate 7
		daily
		missingok
		notifempty
		delaycompress
		compress
		postrotate
			invoke-rc.d rsyslog rotate > /dev/null
		endscript
	}
EOF

# Setup common software.
apt-get install -y build-essential apt-transport-https ca-certificates software-properties-common ntp git fail2ban unattended-upgrades docker-ce

# Setup Dokku.
DOKKU_TAG=v0.14.6
curl -fsSL https://raw.githubusercontent.com/dokku/dokku/$DOKKU_TAG/bootstrap.sh | bash

# Only dump iptables configuration after installing fail2ban and Docker.
iptables-save > /etc/iptables.conf

# Load iptables config when network device is up.
cat > /etc/network/if-up.d/iptables <<-EOF
	#!/usr/bin/env bash
	iptables-restore < /etc/iptables.conf
EOF
chmod +x /etc/network/if-up.d/iptables

# Clean downloaded packages.
apt-get clean

# Reset root password.
password="$(random)"
chpasswd <<< "root:$password"
echo "🔒 root:$password"

# Create a new SSH group.
groupadd op

# Create a new administrator user.
read -p "👉 Administrator username (arthur): " username
username=${username:-arthur}
password="$(random)"
useradd -d /home/$username -m -s /bin/bash $username
chpasswd <<< "$username:$password"
usermod -aG sudo,docker,op $username
echo "🔒 $username:$password"

# Do not ask for password when sudoing.
sed -i '/^%sudo/c\%sudo\tALL=(ALL:ALL) NOPASSWD:ALL' /etc/sudoers

# Setup RSA key for secure SSH authorization.
read -e -p "👉 $username's public key: " public_key
mkdir -p /home/$username/.ssh
echo "$public_key" >> /home/$username/.ssh/authorized_keys
chown -R $username:$username /home/$username/.ssh

# Save a copy.
backup /etc/ssh/sshd_config

# Configure the SSH server.
cat > /etc/ssh/sshd_config <<-EOF
	# Supported HostKey algorithms by order of preference.
	HostKey /etc/ssh/ssh_host_ed25519_key
	HostKey /etc/ssh/ssh_host_rsa_key
	HostKey /etc/ssh/ssh_host_ecdsa_key

	KexAlgorithms curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256
	Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr

	# LogLevel VERBOSE logs user's key fingerprint on login. Needed to have a clear audit track of which key was using to log in.
	LogLevel VERBOSE
	
	# Use kernel sandbox mechanisms where possible in unprivileged processes
	# Systrace on OpenBSD, Seccomp on Linux, seatbelt on MacOSX/Darwin, rlimit elsewhere.
	# Note: This setting is deprecated in OpenSSH 7.5 (https://www.openssh.com/txt/release-7.5)
	UsePrivilegeSeparation sandbox

	# Don't let users set environment variables.
	PermitUserEnvironment no

	# Log sftp level file access (read/write/etc.) that would not be easily logged otherwise.
	Subsystem sftp internal-sftp -f AUTHPRIV -l INFO

	# Only use the newer more secure protocol.
	Protocol 2

	# Dorwarding as X11 is very insecure.
	# You really shouldn't be running X on a server anyway.
	X11Forwarding no

	# Disable port forwarding.
	AllowTcpForwarding no
	AllowStreamLocalForwarding no
	GatewayPorts no
	PermitTunnel no

	# Don't allow login if the account has an empty password.
	PermitEmptyPasswords no

	# Ignore .rhosts and .shosts.
	IgnoreRhosts yes

	# Verify hostname matches IP.
	UseDNS no

	Compression no
	TCPKeepAlive no
	AllowAgentForwarding no
	PermitRootLogin no

	# Don't allow .rhosts or /etc/hosts.equiv.
	HostbasedAuthentication no

	AllowGroups op
	ClientAliveCountMax 0
	ClientAliveInterval 300
	ListenAddress 0.0.0.0
	LoginGraceTime 30
	MaxAuthTries 2
	MaxSessions 2
	MaxStartups 2
	PasswordAuthentication no
	DebianBanner no
	Port 822
EOF

# The Diffie-Hellman algorithm is used by SSH to establish a secure connection. 
# The larger the moduli (key size) the stronger the encryption.
# Remove all moduli smaller than 3072 bits.
cp --preserve /etc/ssh/moduli /etc/ssh/moduli.default
awk '$5 >= 3071' /etc/ssh/moduli | tee /etc/ssh/moduli.tmp
mv /etc/ssh/moduli.tmp /etc/ssh/moduli

# Restart SSH server.
service ssh restart

# Configure unattended upgrades for security patches.
cat > /etc/apt/apt.conf.d/51unattended-upgrades <<-EOF
	// Enable the update/upgrade script (0=disable)
	APT::Periodic::Enable "1";

	// Do "apt-get update" automatically every n-days (0=disable)
	APT::Periodic::Update-Package-Lists "1";

	// Do "apt-get upgrade --download-only" every n-days (0=disable)
	APT::Periodic::Download-Upgradeable-Packages "1";

	// Do "apt-get autoclean" every n-days (0=disable)
	APT::Periodic::AutocleanInterval "7";

	// Send report mail to root
	//     0:  no report             (or null string)
	//     1:  progress report       (actually any string)
	//     2:  + command outputs     (remove -qq, remove 2>/dev/null, add -d)
	//     3:  + trace on    APT::Periodic::Verbose "2";    
	APT::Periodic::Unattended-Upgrade "0";

	// Automatically upgrade packages from these 
	Unattended-Upgrade::Origins-Pattern {
		"o=Debian,a=stable";
		"o=Debian,a=stable-updates";
		"origin=Debian,codename=\${distro_codename},label=Debian-Security";
	};

	// You can specify your own packages to NOT automatically upgrade here
	Unattended-Upgrade::Package-Blacklist {
	};

	// Run dpkg --force-confold --configure -a if a unclean dpkg state is detected to true to ensure that updates get installed even when the system got interrupted during a previous run
	Unattended-Upgrade::AutoFixInterruptedDpkg "true";

	//Perform the upgrade when the machine is running because we wont be shutting our server down often
	Unattended-Upgrade::InstallOnShutdown "false";

	// Remove all unused dependencies after the upgrade has finished
	Unattended-Upgrade::Remove-Unused-Dependencies "true";

	// Remove any new unused dependencies after the upgrade has finished
	Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
EOF

# Setup swap space with half the memory available.
memory=$(free -m | awk '/^Mem:/{print $2}')
fallocate -l ${memory}MB /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
echo 'vm.swappiness = 10' >> /etc/sysctl.conf
sysctl -p

printf "\n🎉 Done!\n\n"