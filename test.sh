#!/bin/sh
# set -euxo pipefail
# File: adbhostgen.sh
#
# Script to generate massive block lists for DD-WRT
#
# AUTHOR: Manish Parashar
#
# https://github.com/m-parashar/adbhostgen
# https://gist.github.com/m-parashar/ee38454c27f7a4f4e4ab28249a834ccc
# https://www.dd-wrt.com/phpBB2/viewtopic.php?t=307533
#
# Thanks: Pi-Hole, Christopher Vella, Arthur Borsboom, list providers, and the users.
#
# Installation:
# Give the script permissions to execute:
# chmod +x adbhostgen.sh
#
# Add the hosts file and extra configuration to DD-WRT's dnsmasq config via Services -> Additional DNSMasq Options
# conf-file=/jffs/dnsmasq/mpdomains
# addn-hosts=/jffs/dnsmasq/mphosts
#
# optional:
# Never forward plain names (without a dot or domain part)
# domain-needed
# Never forward addresses in the non-routed address spaces.
# bogus-priv
#
# Log each DNS query as it passes through dnsmasq.
# log-queries
# log-facility=/jffs/dnsmasq/dnsmasq.log
# log-async
#
# Go to Administration -> Cron (Sets the script to update itself. Choose your own schedule.)
# Build the adblock files on MON and THU at 6AM
# 0 6 * * 1,4 root /jffs/dnsmasq/adbhostgen.sh
#

VERSION="20180323b2"

logger ">>> $(basename "$0") started"

# define aggressiveness: [ 0 | 1 | 2 | 3 ]
# 0: bare minimum protection from ads and malware
# 1: toned down, tuxedo wearing ad-slaying professional mode
# 2: optimum protection [DEFAULT]
# 3: ramped up, stone cold ad-killing maniac mode
# either change this here or use command line argument
BLITZ=1

# distribution mode / defaults switch
# if set to 1, ignores myblacklist/mywhitelist files
# DO NOT CHANGE; use command line argument instead
DISTRIB=0

# online/offline mode switch
# DO NOT CHANGE; use command line argument instead
ONLINE=1

# secure communication switch
# if enabled, cURL uses certificates for safe and
# secure TLS/SSL communication
SECURL=0

# day of week
DAYOFWEEK=$(date +"%u")

# where ads go to die
supermassiveblackhole="0.0.0.0"

# define dnsmasq directory and path
# needn't be /jffs, could be /opt
# preferably use a USB drive for this
MPDIR="/jffs/dnsmasq"

# temporary directory
TMPDIR="/tmp"

# dnsmasq hosts & domain files
mphosts="${MPDIR}/mphosts"
mphostspaused="${MPDIR}/mphosts.zzz"
tmphosts="${TMPDIR}/mphosts.tmp"

# temporary dnsmasq hosts & domain files
mpdomains="${MPDIR}/mpdomains"
mpdomainspaused="${MPDIR}/mpdomains.zzz"
tmpdomains="${TMPDIR}/mpdomains.tmp"

# pause flag
pauseflag="${MPDIR}/PAUSED"

# blacklist file: a list of blacklisted domains one per line
blacklist="${MPDIR}/blacklist"

# whitelist file: a list of whitelisted domains one per line
whitelist="${MPDIR}/whitelist"

# user's custom blacklist file: a list of blacklisted domains one per line
myblacklist="${MPDIR}/myblacklist"

# user's custom whitelist file: a list of whitelisted domains one per line
mywhitelist="${MPDIR}/mywhitelist"

# log file
MPLOG="${MPDIR}/mphosts.log"
#[ -s $MPLOG ] && rm $MPLOG

###############################################################################

# cURL certificates and options
export CURL_CA_BUNDLE="${MPDIR}/cacert.pem"
alias MPGET="curl -f -s -k"
alias MPGETSSL="curl -f -s -k"
[ $SECURL -eq 1 ] && unalias MPGETSSL && alias MPGETSSL="curl -f -s --capath ${MPDIR} --cacert cacert.pem"
alias MPGETMHK="curl -f -s -A "Mozilla/5.0" -e http://forum.xda-developers.com/"
if [ -z "$(which curl)" ]; then
	echo ">>> WARNING: cURL not installed. Using local mpcurl (armv7l)"
	if [ ! -x ${MPDIR}/mpcurl ] ; then
		echo ">>> ERROR: ${MPDIR}/mpcurl not found"
		echo ">>> ERROR: if file exists, chmod +x it and try again"
		echo ">>> ERROR: ABORTING"
		exit 1
	fi
	alias MPGET="${MPDIR}/mpcurl -f -s -k"
	alias MPGETSSL="${MPDIR}/mpcurl -f -s -k"
	[ $SECURL -eq 1 ] && unalias MPGETSSL && alias MPGETSSL="${MPDIR}/mpcurl -f -s --capath ${MPDIR} --cacert cacert.pem"
	alias MPGETMHK="${MPDIR}/mpcurl -f -s -A "Mozilla/5.0" -e http://forum.xda-developers.com/"
fi

###############################################################################

# echo & log
lognecho ()
{
	echo "$1"
	echo "$1" >> $MPLOG
}

# restart dnsmasq
restart_dnsmasq ()
{
	logger ">>> $(basename "$0") restarting dnsmasq"
	restart_dns || killall -1 dnsmasq
	logger ">>> $(basename "$0") restarted dnsmasq"
}

# resume protection
protectOn ()
{
	if [ -f $pauseflag ] && { [ -f $mphostspaused ] || [ -f $mpdomainspaused ]; }; then
		echo ">>> RESUMING PROTECTION"
		mv $mphostspaused $mphosts
		mv $mpdomainspaused $mpdomains
		rm $pauseflag
		restart_dnsmasq
	fi
	logger ">>> $(basename "$0") finished"
	exit 0
}

# pause protection
protectOff ()
{
	echo ">>> WARNING: PAUSING PROTECTION"
	[ -f $mphosts ] && mv $mphosts $mphostspaused
	[ -f $mpdomains ] && mv $mpdomains $mpdomainspaused
	echo "" > $mphosts
	echo "" > $mpdomains
	echo "PAUSED" > $pauseflag
	restart_dnsmasq
	echo ">>> Type $(basename "$0") --resume to resume protection."
	logger ">>> $(basename "$0") finished"
	exit 0
}

# print help options
printHelp ()
{
	echo ""
	echo "USAGE:"
	printf '\t'; echo "$(basename "$0") [-? | -h | --help] [-v | --version] [-1] [-2] [-b | --bl=<domain.name>] [-w | --wl=<domain.name>] ..."
	echo ""
	echo "OPERATION:"
	printf '\t'; echo -n "[-0]"; printf '\t\t\t\t'; echo "Safe minimum protection, set BLITZ=0"
	printf '\t'; echo -n "[-1]"; printf '\t\t\t\t'; echo "Increased protection, set BLITZ=1, [DEFAULT]"
	printf '\t'; echo -n "[-2]"; printf '\t\t\t\t'; echo "Optimum protection, set BLITZ=2"
	printf '\t'; echo -n "[-3]"; printf '\t\t\t\t'; echo "Unlock maximum protection, set BLITZ=3"
	printf '\t'; echo -n "[-d | -D]"; printf '\t\t\t'; echo "Ignore personal lists, set DISTRIB=1"
	printf '\t'; echo -n "[-b | --bl=]"; printf '\t'; echo -n "domain.name"; printf '\t'; echo "Add domain.name to myblacklist"
	printf '\t'; echo -n "[-w | --wl=]"; printf '\t'; echo -n "domain.name"; printf '\t'; echo "Add domain.name to mywhitelist"
	printf '\t'; echo -n "[-p | --pause]"; printf '\t\t\t'; echo "Pause protection"
	printf '\t'; echo -n "[-r | --resume]"; printf '\t\t\t'; echo "Resume protection"
	printf '\t'; echo -n "[-o | --secure]"; printf '\t\t\t'; echo "Use cURL CA certs for secure file transfer"
	printf '\t'; echo -n "[-o | --offline]"; printf '\t\t'; echo "Process existing lists without downloading"
	printf '\t'; echo -n "[-h | --help]"; printf '\t\t\t'; echo "Display this help screen and exit"
	printf '\t'; echo -n "[-u | --update]"; printf '\t\t\t'; echo "Update $(basename "$0") to the latest version"
	printf '\t'; echo -n "[-v | --version]"; printf '\t\t'; echo "Print $(basename "$0") version and exit"
	echo ""
	echo "EXAMPLES:"
	printf '\t'; echo "$(basename "$0") -2 --bl=example1.com --wl=example2.com"
	printf '\t'; echo "$(basename "$0") -b example1.com -w example2.com --wl=example3.com"
	echo ""
	logger ">>> $(basename "$0") finished"
	exit 0
}

# update to the latest version
selfUpdate ()
{
	TMPFILE="/tmp/mpupdate"

	echo ">>> Checking for updates."

	if ping -q -c 1 -W 1 google.com >/dev/null; then
		MPGETSSL https://raw.githubusercontent.com/m-parashar/adbhostgen/master/$(basename "$0") > $TMPFILE

		if [ 0 -eq $? ]; then
			old_md5=`md5sum $0 | cut -d' ' -f1`
			new_md5=`md5sum $TMPFILE | cut -d' ' -f1`

			if [ "$old_md5" != "$new_md5" ]; then
				NEWVER=`grep -w -m 1 "VERSION" $TMPFILE`
				echo ">>> Update available: $NEWVER"
				chmod 755 $TMPFILE
				mv $TMPFILE $0
				echo ">>> Updated to the latest version."
			else
				echo ">>> No updates available."
			fi
		else
			echo ">>> Update failed. Try again."
		fi
		rm -f $TMPFILE
	fi
	logger ">>> $(basename "$0") finished"
	exit 0
}

###############################################################################

# process command line arguments
while getopts "h?v0123dDpPrRoOuUb:w:-:" opt; do
	case ${opt} in
		h|\? ) printHelp ;;
		v    ) echo "$VERSION" ; logger ">>> $(basename "$0") finished" ; exit 0 ;;
		0    ) BLITZ=0 ;;
		1    ) BLITZ=1 ;;
		2    ) BLITZ=2 ;;
		3    ) BLITZ=3 ;;
		d|D  ) DISTRIB=1 ;;
		p|P  ) protectOff ;;
		r|R  ) protectOn ;;
		o|O  ) ONLINE=0 ;;
		u|U  ) selfUpdate ;;
		b    ) echo "$OPTARG" >> $myblacklist ;;
		w    ) echo "$OPTARG" >> $mywhitelist ;;
		-    ) LONG_OPTARG="${OPTARG#*=}"
		case $OPTARG in
			bl=?*   ) ARG_BL="$LONG_OPTARG" ; echo $ARG_BL >> $myblacklist ;;
			bl*     ) echo ">>> ERROR: no arguments for --$OPTARG option" >&2; exit 2 ;;
			wl=?*   ) ARG_WL="$LONG_OPTARG" ; echo $ARG_WL >> $mywhitelist ;;
			wl*     ) echo ">>> ERROR: no arguments for --$OPTARG option" >&2; exit 2 ;;
			9000    ) BLITZ=9000 ;;
			pause   ) protectOff ;;
			resume  ) protectOn ;;
			secure  ) SECURL=1 ;;
			offline ) ONLINE=0 ;;
			help    ) printHelp ;;
			update  ) selfUpdate ;;
			version ) echo "$VERSION" ; logger ">>> $(basename "$0") finished" ; exit 0 ;;
			help* | pause* | resume* | version* | offline* | update* | secure* | 9000* )
					echo ">>> ERROR: no arguments allowed for --$OPTARG option" >&2; exit 2 ;;
			'' )    break ;; # "--" terminates argument processing
			* )     echo ">>> ERROR: unsupported option --$OPTARG" >&2; exit 2 ;;
		esac ;;
  	  \? ) exit 2 ;;  # getopts already reported the illegal option
	esac
done

shift $((OPTIND-1)) # remove parsed options and args from $@ list

###############################################################################

# display banner
TIMERSTART=`date +%s`
lognecho "======================================================"
lognecho "|                adbhostgen for DD-WRT               |"
lognecho "|      https://github.com/m-parashar/adbhostgen      |"
lognecho "|           Copyright 2018 Manish Parashar           |"
lognecho "======================================================"
lognecho "             `date`"
lognecho "# VERSION: $VERSION"

###############################################################################

# force resume if user forgets to turn it back on
if [ -f $pauseflag ] && { [ -f $mphostspaused ] || [ -f $mpdomainspaused ]; }; then
	echo "# USER FORGOT TO RESUME PROTECTION AFTER PAUSING"
	echo "> Resuming protection"
	protectOn
fi

###############################################################################

# if internet is accessible, download files
if [ $ONLINE -eq 1 ] && ping -q -c 1 -W 1 google.com >/dev/null; then

	lognecho "# NETWORK: UP | MODE: ONLINE"
	lognecho "# Cranking up the ad-slaying engine"

	if [ ! -s cacert.pem ] || { [ "${DAYOFWEEK}" -eq 1 ] || [ "${DAYOFWEEK}" -eq 4 ]; }; then
		lognecho "> Downloading / updating cURL certificates"
		MPGETSSL --remote-name --time-cond cacert.pem https://curl.haxx.se/ca/cacert.pem
	fi

	lognecho "# SECURE [0=NO|1=YES]: $SECURL"
	lognecho "# BLITZ LEVEL [0|1|2|3]: $BLITZ"

	lognecho "# Creating mpdomains file"
	MPGETSSL https://raw.githubusercontent.com/oznu/dns-zone-blacklist/master/dnsmasq/dnsmasq.blacklist | sed 's/#.*$//;/^\s*$/d' | grep -v "::" > $tmpdomains
	MPGETSSL https://raw.githubusercontent.com/notracking/hosts-blocklists/master/domains.txt | sed 's/#.*$//;/^\s*$/d' | grep -v "::" >> $tmpdomains
	MPGETSSL -d mimetype=plaintext -d hostformat=dnsmasq https://pgl.yoyo.org/adservers/serverlist.php? | sed 's/127.0.0.1/0\.0\.0\.0/' >> $tmpdomains

	lognecho "# Creating mphosts file"
	lognecho "> Processing StevenBlack lists"
	MPGETSSL https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' > $tmphosts

	lognecho "> Processing notracking blocklists"
	MPGETSSL https://raw.githubusercontent.com/notracking/hosts-blocklists/master/hostnames.txt | grep -v "::" | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts

	lognecho "> Processing Disconnect.me lists"
	MPGETSSL https://s3.amazonaws.com/lists.disconnect.me/simple_ad.txt | sed 's/#.*$//;/^\s*$/d' >> $tmphosts
	MPGETSSL https://s3.amazonaws.com/lists.disconnect.me/simple_malware.txt | sed 's/#.*$//;/^\s*$/d' >> $tmphosts
	MPGETSSL https://s3.amazonaws.com/lists.disconnect.me/simple_tracking.txt | sed 's/#.*$//;/^\s*$/d' >> $tmphosts
	MPGETSSL https://s3.amazonaws.com/lists.disconnect.me/simple_malvertising.txt | sed 's/#.*$//;/^\s*$/d' >> $tmphosts

	lognecho "> Processing quidsup/notrack lists"
	MPGETSSL https://raw.githubusercontent.com/quidsup/notrack/master/trackers.txt | sed 's/#.*$//;/^\s*$/d' >> $tmphosts
	MPGETSSL https://raw.githubusercontent.com/quidsup/notrack/master/malicious-sites.txt | sed 's/#.*$//;/^\s*$/d' >> $tmphosts

	lognecho "> Processing MalwareDomains lists"
	MPGETSSL https://mirror1.malwaredomains.com/files/justdomains >> $tmphosts
	MPGETSSL https://mirror1.malwaredomains.com/files/immortal_domains.txt | grep -v "#" >> $tmphosts

	lognecho "> Processing abuse.ch blocklists"
	MPGETSSL https://zeustracker.abuse.ch/blocklist.php?download=domainblocklist | grep -v "#" >> $tmphosts

	lognecho "> Processing Ransomware blocklists"
	MPGETSSL https://ransomwaretracker.abuse.ch/downloads/RW_DOMBL.txt | grep -v "#" >> $tmphosts
	MPGETSSL https://ransomwaretracker.abuse.ch/downloads/CW_C2_DOMBL.txt | grep -v "#" >> $tmphosts
	MPGETSSL https://ransomwaretracker.abuse.ch/downloads/LY_C2_DOMBL.txt | grep -v "#" >> $tmphosts
	MPGETSSL https://ransomwaretracker.abuse.ch/downloads/TC_C2_DOMBL.txt | grep -v "#" >> $tmphosts

	lognecho "> Processing adaway list"
	MPGETSSL https://adaway.org/hosts.txt | grep -v "::1" | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts

	if [ $BLITZ -ge 1 ]; then
		lognecho "# Unlocking BLITZ=1 level lists"

		lognecho "> Processing more StevenBlack lists"
		MPGETSSL https://raw.githubusercontent.com/StevenBlack/hosts/master/data/tyzbit/hosts | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://raw.githubusercontent.com/StevenBlack/hosts/master/data/add.2o7Net/hosts | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://raw.githubusercontent.com/StevenBlack/hosts/master/data/add.Risk/hosts | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://raw.githubusercontent.com/StevenBlack/hosts/master/data/add.Spam/hosts | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts

		lognecho "> Processing hosts-file ATS/EXP/GRM lists"
		MPGETSSL https://hosts-file.net/ad_servers.txt | grep -v "::1" | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://hosts-file.net/exp.txt | grep -v "::1" | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://hosts-file.net/grm.txt | grep -v "::1" | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts

		lognecho "> Processing hosts-file HJK/PUP lists"
		MPGETSSL https://hosts-file.net/hjk.txt | grep -v "::1" | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://hosts-file.net/pup.txt | grep -v "::1" | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts

		lognecho "> Processing dshield lists"
		MPGETSSL https://www.dshield.org/feeds/suspiciousdomains_High.txt | grep -v "#" >> $tmphosts
		MPGETSSL https://www.dshield.org/feeds/suspiciousdomains_Medium.txt | grep -v "#" >> $tmphosts
		MPGETSSL https://www.dshield.org/feeds/suspiciousdomains_Low.txt | grep -v "#" >> $tmphosts

		lognecho "> Processing pgl.yoyo.org list"
		MPGETSSL -d mimetype=plaintext -d hostformat=unixhosts https://pgl.yoyo.org/adservers/serverlist.php? | grep -v "#" | awk '{print $2}' >> $tmphosts

		lognecho "> Processing Securemecca list"
		MPGETSSL https://hostsfile.org/Downloads/hosts.txt | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts

		lognecho "> Processing cryptomining and porn lists"
		MPGETSSL https://raw.githubusercontent.com/Marfjeh/coinhive-block/master/domains | grep -v "#" >> $tmphosts
		MPGETSSL https://raw.githubusercontent.com/ZeroDot1/CoinBlockerLists/master/hosts | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://raw.githubusercontent.com/chadmayfield/my-pihole-blocklists/master/lists/pi_blocklist_porn_top1m.list | grep -v "#" >> $tmphosts

		lognecho "> Processing Easylist & w3kbl lists"
		MPGETSSL https://v.firebog.net/hosts/AdguardDNS.txt | grep -v "#" >> $tmphosts
		MPGETSSL https://v.firebog.net/hosts/Airelle-hrsk.txt | grep -v "#" >> $tmphosts
		MPGETSSL https://v.firebog.net/hosts/Airelle-trc.txt | grep -v "#" >> $tmphosts
		MPGETSSL https://v.firebog.net/hosts/BillStearns.txt | grep -v "#" >> $tmphosts
		MPGETSSL https://v.firebog.net/hosts/Easylist.txt | grep -v "#" >> $tmphosts
		MPGETSSL https://v.firebog.net/hosts/Easyprivacy.txt | grep -v "#" >> $tmphosts
		MPGETSSL https://v.firebog.net/hosts/Prigent-Ads.txt | grep -v "#" >> $tmphosts
		MPGETSSL https://v.firebog.net/hosts/Prigent-Malware.txt | grep -v "#" >> $tmphosts
		MPGETSSL https://v.firebog.net/hosts/Prigent-Phishing.txt | grep -v "#" >> $tmphosts
		MPGETSSL https://v.firebog.net/hosts/Shalla-mal.txt | grep -v "#" >> $tmphosts
		MPGETSSL https://v.firebog.net/hosts/static/SamsungSmart.txt | grep -v "#" >> $tmphosts
		MPGETSSL https://v.firebog.net/hosts/static/w3kbl.txt | sed -e 's/#.*$//;/^\s*$/d' >> $tmphosts
	fi

	if [ $BLITZ -ge 2 ]; then
		lognecho "# Unlocking BLITZ=2 level lists"

		lognecho "> Processing even more StevenBlack lists"
		MPGETSSL https://raw.githubusercontent.com/StevenBlack/hosts/master/data/KADhosts/hosts | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://raw.githubusercontent.com/StevenBlack/hosts/master/data/UncheckyAds/hosts | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-porn/hosts | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts

		lognecho "> Processing hosts-file EMD/FSA lists"
		MPGETSSL https://hosts-file.net/emd.txt | grep -v "::1" | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://hosts-file.net/fsa.txt | grep -v "::1" | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts

		lognecho "> Processing hosts-file MMT/PHA lists"
		MPGETSSL https://hosts-file.net/mmt.txt | grep -v "::1" | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://hosts-file.net/pha.txt | grep -v "::1" | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts

		lognecho "> Processing Cameleon list"
		MPGET http://sysctl.org/cameleon/hosts | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts

		lognecho "> Processing winhelp2002 list"
		MPGET http://winhelp2002.mvps.org/hosts.txt | grep -v "::1" | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts

		lognecho "> Processing someonewhocares list"
		MPGET http://someonewhocares.org/hosts/zero/hosts | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts

		lognecho "> Processing anudeepND lists"
		MPGETSSL https://raw.githubusercontent.com/anudeepND/blacklist/master/adservers.txt | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://raw.githubusercontent.com/anudeepND/blacklist/master/CoinMiner.txt | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://raw.githubusercontent.com/anudeepND/youtubeadsblacklist/master/domainlist.txt | grep -v "#" >> $tmphosts

		lognecho "> Processing CHEF-KOCH lists"
		MPGETSSL https://raw.githubusercontent.com/CHEF-KOCH/WebRTC-tracking/master/WebRTC.txt | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://raw.githubusercontent.com/CHEF-KOCH/Spotify-Ad-free/master/Spotifynulled.txt | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://raw.githubusercontent.com/CHEF-KOCH/Audio-fingerprint-pages/master/AudioFp.txt | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://raw.githubusercontent.com/CHEF-KOCH/Canvas-fingerprinting-pages/master/Canvas.txt | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://raw.githubusercontent.com/CHEF-KOCH/Canvas-Font-Fingerprinting-pages/master/Canvas.txt | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts

		lognecho "> Processing joewein.de LLC list"
		MPGETSSL https://www.joewein.net/dl/bl/dom-bl-base.txt | grep -v "#" >> $tmphosts

		lognecho "> Processing Windows telemetry lists"
		MPGETSSL https://raw.githubusercontent.com/tyzbit/hosts/master/data/tyzbit/hosts | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/win10/spy.txt | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts

		lognecho "> Processing a few more blocklists"
		MPGETSSL https://raw.githubusercontent.com/vokins/yhosts/master/hosts | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://raw.githubusercontent.com/mitchellkrogza/Badd-Boyz-Hosts/master/hosts | grep -v "::1" | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://raw.githubusercontent.com/piwik/referrer-spam-blacklist/master/spammers.txt | grep -v "#" >> $tmphosts
		MPGETSSL https://raw.githubusercontent.com/HenningVanRaumle/pihole-ytadblock/master/ytadblock.txt | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
	fi

	if [ $BLITZ -ge 3 ]; then
		lognecho "# Unlocking BLITZ=3 level lists"

		lognecho "> Processing hosts-file PSH/PUP/WRZ lists"
		MPGETSSL https://hosts-file.net/psh.txt | grep -v "::1" | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
		MPGETSSL https://hosts-file.net/wrz.txt | grep -v "::1" | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts

		lognecho "> Processing Mahakala list"
		MPGETMHK http://adblock.mahakala.is/hosts | grep -v "#" | awk '{print $2}' >> $tmphosts

		lognecho "> Processing HostsFile.mine.nu list"
		MPGETSSL https://hostsfile.mine.nu/hosts0.txt | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts

		lognecho "> Processing Kowabit list"
		MPGETSSL https://v.firebog.net/hosts/Kowabit.txt | grep -v "#" >> $tmphosts

		lognecho "> Processing ADZHOSTS list"
		MPGETSSL https://adzhosts.fr/hosts/adzhosts-mac-linux.txt | grep -v "::1" | sed 's/#.*$//;/^\s*$/d' | awk '{print $2}' >> $tmphosts
	fi

	if [ $BLITZ -eq 9000 ]; then
		lognecho ">>> WHY, YOU ABSOLUTE MADMAN!"
		lognecho ">>> JOG ON NOW. THIS WILL TAKE SOME TIME."
		lognecho "# Unlocking BLITZ=9000 level lists"

		lognecho "> Processing supermassive porn blocklist"
		MPGETSSL https://raw.githubusercontent.com/chadmayfield/my-pihole-blocklists/master/lists/pi_blocklist_porn_all.list >> $tmphosts
	fi

	lognecho "> Updating official blacklist/whitelist files"
	MPGETSSL https://raw.githubusercontent.com/m-parashar/adbhostgen/master/blacklist | grep -v "#" > $blacklist
	MPGETSSL https://raw.githubusercontent.com/m-parashar/adbhostgen/master/whitelist | grep -v "#" > $whitelist

else
	lognecho "# NETWORK: DOWN | MODE: OFFLINE"
	# just in case connectivity is down for the moment
	# process the blacklists and whitelists anyway
	[ -s $mphosts ] && cat $mphosts | awk '{print $2}' > $tmphosts
	[ -s $mpdomains ] && cp $mpdomains $tmpdomains
fi

###############################################################################

# calculate file sizes
fileSize=`du -h $tmphosts | awk '{print $1}'`
lognecho "# Size of $tmphosts before formatting: $fileSize"
fileSize=`du -h $tmpdomains | awk '{print $1}'`
lognecho "# Size of $tmpdomains before formatting: $fileSize"

# remove duplicates and extra whitespace, sort alphabetically
lognecho "> Processing blacklist/whitelist files"
sed -r 's/^\s*//; s/\s*$//; /^$/d' $blacklist | sort -u > tmpbl && cp tmpbl $blacklist
sed -r 's/^\s*//; s/\s*$//; /^$/d' $whitelist | sort -u > tmpwl && cp tmpwl $whitelist

# if not building for distribution, process myblacklist and mywhitelist files
# remove duplicates and extra whitespace, sort alphabetically
# and allow users' myblacklist precedence over defaults
if [ $DISTRIB -eq 0 ] && { [ -s "$myblacklist" ] || [ -s "$mywhitelist" ]; }; then
	lognecho "> Processing myblacklist/mywhitelist files"
	sed -r 's/^\s*//; s/\s*$//; /^$/d' $myblacklist | sort -u > tmpmybl && mv tmpmybl $myblacklist
	sed -r 's/^\s*//; s/\s*$//; /^$/d' $mywhitelist | sort -u > tmpmywl && mv tmpmywl $mywhitelist
	cat $blacklist | cat $myblacklist - > tmpbl
	cat $whitelist | cat $mywhitelist - | grep -Fvwf $myblacklist > tmpwl
fi

lognecho "> Processing final mphosts/mpdomains files"
cat $tmphosts | sed $'s/\r$//' | cat tmpbl - | grep -Fvwf tmpwl | sort -u | sed '/^$/d' | awk -v "IP=$supermassiveblackhole" '{sub(/\r$/,""); print IP" "$0}' > $mphosts
cat $tmpdomains | grep -Fvwf tmpwl | sort -u  > $mpdomains

lognecho "> Removing temporary files"
rm $tmphosts
rm $tmpdomains
rm tmpbl
rm tmpwl

# calculate file sizes
fileSize=`du -h $mphosts | awk '{print $1}'`
lognecho "# Size of $mphosts after formatting: $fileSize"
fileSize=`du -h $mpdomains | awk '{print $1}'`
lognecho "# Size of $mpdomains after formatting: $fileSize"

# Count how many domains/whitelists were added so it can be displayed to the user
numberOfAdsBlocked=$(cat $mphosts | wc -l | sed 's/^[ \t]*//')
lognecho "# Number of ad domains blocked: approx $numberOfAdsBlocked"

lognecho "> Restarting DNS server (dnsmasq)"
restart_dnsmasq

TIMERSTOP=`date +%s`
RTMINUTES=$(( $((TIMERSTOP - TIMERSTART)) /60 ))
RTSECONDS=$(( $((TIMERSTOP - TIMERSTART)) %60 ))
lognecho "# Total time: $RTMINUTES:$RTSECONDS minutes"
lognecho "# DONE"
logger ">>> $(basename "$0") finished"
exit 0
# FIN