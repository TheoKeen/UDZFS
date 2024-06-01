#!/bin/bash
#Install Ubuntu 22.04 with ZFS on root (ZFSBootMenu)
#Inspired by:

#https://forum.openmediavault.org/index.php?thread/40525-how-to-auto-load-key-and-mount-natively-encrypted-zfs-pool-no-luks/
#https://docs.zfsbootmenu.org/en/latest/guides/ubuntu/uefi.html
#https://bugs.launchpad.net/snapd/+bug/2003667
#https://gist.github.com/carlwgeorge/c560a532b6929f49d9c0df52f75a68ae

#ENV VARS Used:
#VAULTPASS - (Optional) Used for optionally decrypting config file
#DNSDOMAIN - (Optional) Used for autodiscovering config file
#TARGETDISK - (Optional but highly recommended to set manual) If not set wil use the first disk not being used for /cdrom. Will be ok for laptops with single drive.
#TARGETHOSTNAME - (Optional) if not set will be ubz01

#Other configuration options are read from config file config.yml . If it doesn't exist AND the config file cannot be autodiscovered it will be downloaded from git.
#Location of config on ubuntu live medium will be ~/config.yml
#Location of optional vault password file on ubuntu live medium ~/.vault_pass.txt
#The config file and vault password will be copied to the target system on /var/lib/udz/

confirmflag=true
print_usage() {
  printf "Usage script:\n -d (Set Targetdisk for installation)\n -f (Force. Proceeds without confirmation. Must be used with -d)\n -h (Set hostname for target installation)\n -p (ANSIBLE-VAULT password)\n"
}

while getopts 'fd:h:p:s:v' flag; do
  case "${flag}" in
    d) TARGETDISK="${OPTARG}" ;;
    f) confirmflag=false ;;
    h) hostname="${OPTARG}" ;;
    p) VAULTPASS="${OPTARG}" ;;
    s) SIZEZFS="${OPTARG}" ;;
    v) verbose=false ;;
    *) print_usage
       exit 1 ;;
  esac
done
if ! ${confirmflag} && [  -z ${TARGETDISK} ]; then echo "Cowardly refusing to guess TARGETDISK without confirmation."; exit 1; fi
#Get available DISKS 1) Get all real block devices. 2) Filter out the Disk with a partition mounted on /cdrom
AVAILABLEDISKS=$(lsblk -I 8,259,252,253 -d -no NAME | grep --invert-match --file <(findmnt -D /cdrom -n -o SOURCE | xargs -r lsblk -no pkname | grep .  || echo "NULL") | awk '{print "/dev/"$1}' )
if [ ! -z ${TARGETDISK} ]; then
  if  [ -z $(echo "${AVAILABLEDISKS}" | grep ${TARGETDISK} ) ]; then
    echo "Disk ${TARGETDISK} not found";echo "Please select one of the following disks:";echo "${AVAILABLEDISKS}"
    exit 1
  fi
fi
#Use specified targetdisk or first available DISK
TARGETDISK=${TARGETDISK:=$(echo "${AVAILABLEDISKS}" |  head -n 1)}

configfile=~/config.yml
vaultpassfile=~/.vaultpass.txt
giturl=https://github.com/TheoKeen/UDZFS

hostname=${TARGETHOSTNAME:=ubz01}
poolname=$(echo ${hostname} | sed 's/-//')

efipartno=15
zfspartno=1
swappartno=2


#Get DNS domain from resolver (Passed to resolver by dhcp option 15)
DNSDOMAIN=${DNSDOMAIN:=$(resolvectl  | grep "DNS Domain" | cut -d ":" -f2 | xargs)}
#Determine /  Guess what the target disk should be 1) Use TARGETDISK ENV VAR if set. 2) Get all real block devices. 3) Filter out the Disk with a partition mounted on /cdrom . 4) Pick the First one. 
#TARGETDISK=${TARGETDISK:=/dev/$(lsblk -I 8,259,252 -d -no NAME | grep --invert-match --file <(findmnt -D /cdrom -n -o SOURCE | xargs -r lsblk -no pkname | grep .  || echo "NULL") |  head -n 1)}
#If using nvme the "p" needs to be inserted for the partition number to get the partition.
PARTLABEL=$(if grep -iq nvme <<< "$TARGETDISK"; then echo "p"; fi)

EFIPART="${TARGETDISK}${PARTLABEL}${efipartno}"
ZFSPART="${TARGETDISK}${PARTLABEL}${zfspartno}"

URLGOVDEC=https://github.com/TheoKeen/goAnsibleVaultDecrypt/releases/download/v0.0.2/go_vdecrypt
BINVDEC=/usr/local/bin/go_vdecrypt
BINVDEC_SHA256="7de699cfeff739289c2aeaafeb50936a46da10ad2505a059a9b1a183faaa1786"

mountdir=/target
chrootdir=/target/

resolveconfdir=/run/systemd/resolve/stub-resolv.conf
source /etc/os-release
export ID="$ID"

codename="${VERSION_CODENAME}-desktop-zfs"
scriptrundate=$(date --utc +%Y%m%d_%H%M%SZ)

ubuntuversion=noble

#---End Variables---

source <(curl https://raw.githubusercontent.com/TheoKeen/UDZFS/udz_bashfunc.sh)


set -e
trap 'catch $? $LINENO' EXIT
catch() {
#  echo "catching!"
  if [ "$1" != "0" ]; then
    # error handling goes here
    echo "Error $1 occurred on $2"
    UmountAll
  fi
}


function debug()
{
getconfig
PrepareChroot
read -n 1 -p "Press any key to continue"
UmountAll
}

function Install()
{
Confirm
getconfig
init
CreatePartitions
CreateZFSPool
CreateZFSfs
ZFStempMount
Debootstrap ${ubuntuversion}
CopyFilesBeforeInstall
PrepareChroot
CreateAptSources ${ubuntuversion}
InstallAnsible
RunPlayBookUbuntuDesktopZFS
CopyFilesFinal
UmountAll
}

function Update()
{
Confirm
getconfig
PrepareChroot
RunPlayBookUbuntuDesktopZFS
UmountAll

echo "update"
}

function test()
{
PrepareChroot
UmountAll
}

#if [  -z ${ZFSPASS} ]; then
# echo "ZFSPASS var needs to be set."
# exit 1
#fi

#UmountAll
#debug
Install 2>&1 | tee /var/log/${scriptrundate}-${codename}-install.log
#UmountAll
#Update 2>&1 | tee /var/log/${scriptrundate}-${codename}-update.log
#test 2>&1 | tee ./my.log
