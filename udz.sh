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

while getopts 'fd:h:p:v' flag; do
  case "${flag}" in
    d) TARGETDISK="${OPTARG}" ;;
    f) confirmflag=false ;;
    h) hostname="${OPTARG}" ;;
    p) VAULTPASS="${OPTARG}" ;;
    v) verbose=false ;;
    *) print_usage
       exit 1 ;;
  esac
done
if ! ${confirmflag} && [  -z ${TARGETDISK} ]; then echo "Cowardly refusing to guess TARGETDISK without confirmation."; exit 1; fi
#Get available DISKS 1) Get all real block devices. 2) Filter out the Disk with a partition mounted on /cdrom
AVAILABLEDISKS=$(lsblk -I 8,259,252 -d -no NAME | grep --invert-match --file <(findmnt -D /cdrom -n -o SOURCE | xargs -r lsblk -no pkname | grep .  || echo "NULL") | awk '{print "/dev/"$1}' )
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

#---End Variables---


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


function getconfig(){

#Make sure curl is installed.
curl -V > /dev/null || {
apt-get update
apt-get install -y curl
}

if [ !  -f ${configfile} ] && [ ! -z ${DNSDOMAIN} ] ;  then
  echo "Attempting auto discovery of config file"
  curl -fs  --output ${configfile} --connect-timeout 2  $(dig TXT deploy.udz.${DNSDOMAIN} +short | tr -d '"')
fi
if [ !  -f ${configfile} ]; then
  echo "Downloading config from github"
fi
if [ !  -f ${configfile} ]; then echo "Failed to obtain config file abort!"; exit 1; fi

if (head -n1 config.yml | grep -qi "\$ANSIBLE_VAULT;"); then
  echo "Config encrypted!"
  if [ ! -z ${VAULTPASS} ]; then
    echo ${VAULTPASS} > ${vaultpassfile}
  else
    echo "Config encrypted and no VAULTPASS var found."
    exit 1
  fi
  if [ !  -f ${BINVDEC} ]; then
   echo "Downloading vault decrypt tool" #And verifying checksum
   curl -s -L ${URLGOVDEC} | sudo tee ${BINVDEC} | sha256sum -c <(echo "$BINVDEC_SHA256  -") || sudo rm -f ${BINVDEC}
   if [ !  -f ${BINVDEC} ]; then echo "Download failed."; exit 1; fi
   sudo chmod +x ${BINVDEC}
  fi
  #Decrypting Config.
  CONFIG=$(${BINVDEC} ${configfile} ${VAULTPASS})
  if [ ${#CONFIG} -lt 20 ];then  echo "Unable to decrypt config."; exit 1; fi
else
  echo "Config NOT encrypted."
  CONFIG=$(cat ${configfile})
fi
ZFSPASS=$(echo "${CONFIG}"  | grep zfspass | cut -d ':' -f 2 | xargs)


echo "$ZFSPASS"
echo "(getconfig) finished"

}

function init()
{

zgenhostid -f 0x00bab10c
}

function CreatePartitions()
{
if [ -z ${NoWipe} ] & [ ! "$NoWipe" = true  ]; then
cat << SEOF | (sudo bash)

wipefs -a ${TARGETDISK}
echo "Creating disk partitions (CreatePartitions)"
sgdisk -Z ${TARGETDISK}
sgdisk -n ${efipartno}:1m:+512m -t 0:ef00 ${TARGETDISK}       #EFI
sgdisk -n ${swappartno}:0:+16G -t 0:8200 ${TARGETDISK}        #Linux SWAP
sgdisk -N ${zfspartno} -t 0:bf00 ${TARGETDISK}        #ZFS



SEOF
else
 echo "Skipping disk partitioning. NoWipe set"
fi

mkfs.vfat -F32 ${EFIPART}
dosfslabel ${EFIPART} UEFI
}


function CreateZFSPool()
{
set -x

echo "${ZFSPASS}" > /etc/zfs/zroot.key
chmod 000 /etc/zfs/zroot.key

zpool create -f -o ashift=12 \
 -O compression=lz4 \
 -O acltype=posixacl \
 -O xattr=sa \
 -O relatime=on \
 -O encryption=aes-256-gcm \
 -O keylocation=file:///etc/zfs/zroot.key \
 -O keyformat=passphrase \
 -o autotrim=on \
 -m none ${poolname} "${ZFSPART}"

zpool set cachefile=/etc/zfs/zpool.cache ${poolname}

set +x
}

function CreateZFSfs()
{
zfs create -o mountpoint=none ${poolname}/ROOT
zfs create -o mountpoint=/ -o canmount=noauto ${poolname}/ROOT/${ID}
zfs create -o mountpoint=none ${poolname}/DATA
zfs create -o mountpoint=/home ${poolname}/DATA/home
zfs create -o mountpoint=/opt ${poolname}/DATA/opt
zfs create -o mountpoint=none ${poolname}/DATA/var
zfs create -o mountpoint=/var/data ${poolname}/DATA/var/data
zpool set bootfs=${poolname}/ROOT/${ID} ${poolname}
}

function ZFStempMount()
{
if [ ! -d "${mountdir}" ];
then
  mkdir ${mountdir}
fi

echo "${ZFSPASS}" > /etc/zfs/zroot.key

zpool export ${poolname}
zpool import -N -R ${mountdir} ${poolname}

echo "${ZFSPASS}" | zfs load-key ${poolname}
#zfs load-key -L prompt ${poolname}

zfs mount ${poolname}/ROOT/${ID}
zfs mount ${poolname}/DATA/home

#Update device symlinks
udevadm trigger
}

function Debootstrap()
{
apt-get update
apt-get install -y debootstrap
debootstrap jammy ${mountdir} https://nl.archive.ubuntu.com/ubuntu/
}

function CopyFilesBeforeInstall()
{
cp /etc/hostid ${mountdir}/etc/hostid
cp /etc/resolv.conf ${mountdir}/etc/
mkdir ${mountdir}/etc/zfs
cp /etc/zfs/zpool.cache ${mountdir}/etc/zfs
cp /etc/zfs/zroot.key ${mountdir}/etc/zfs
cp ${configfile} ${mountdir}/root
cp  ${vaultpassfile} ${mountdir}/root

mkdir ${mountdir}/boot/efi
mkdir ${mountdir}/var/lib/snapd
mkdir ${mountdir}/var/lib/flatpak
mkdir ${mountdir}/var/data

cat << EOF >> ${mountdir}/etc/fstab
UUID=$( lsblk -no uuid ${EFIPART} ) /boot/efi vfat defaults 0 0
EOF
}

#Last Function before unmounting and finishing script
function CopyFilesFinal()
{
#Copy the current network settings
cp -a /etc/NetworkManager/system-connections ${mountdir}/etc/NetworkManager/system-connections

echo "Install ${codename} finished"
#Copy the log files
cp /var/log/${scriptrundate}-${codename}-*.log  /${mountdir}/var/log/
}

function PrepareChroot(){
ZFStempMount
mount --bind ${resolveconfdir} ${mountdir}/${resolveconfdir}
mount ${EFIPART} ${mountdir}/boot/efi
#mount -t efivarfs efivarfs /sys/firmware/efi/efivars
for d in proc sys dev; do mount --bind /$d ${mountdir}/$d; done
mount -t devpts pts ${mountdir}/dev/pts
}

function Confirm()
{
if ${confirmflag}; then
read -p "This Script will repartition and Destroy everyting on ${TARGETDISK} Do you want to proceed? (yes/no) " yn

case $yn in
	yes ) echo ok, we will proceed;;
	no ) echo exiting...;
		exit;;
	* ) echo invalid response;
		exit 1;;
esac
else
  echo "Targetdisk = ${TARGETDISK}"
fi
}

function UmountAll() {
#umount /sys/firmware/efi/efivars
sleep 2
umount  -RA ${mountdir}
#zpool export zroot
}


function CreateAptSources()
{
cat << EOF > ${mountdir}/etc/apt/sources.list
deb http://nl.archive.ubuntu.com/ubuntu jammy main restricted
deb http://nl.archive.ubuntu.com/ubuntu jammy-updates main restricted
deb http://nl.archive.ubuntu.com/ubuntu jammy universe
deb http://nl.archive.ubuntu.com/ubuntu jammy-updates universe
deb http://nl.archive.ubuntu.com/ubuntu jammy multiverse
deb http://nl.archive.ubuntu.com/ubuntu jammy-updates multiverse
deb http://nl.archive.ubuntu.com/ubuntu jammy-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu jammy-security main restricted
deb http://security.ubuntu.com/ubuntu jammy-security universe
deb http://security.ubuntu.com/ubuntu jammy-security multiverse
EOF

#Enter the chroot
sudo chroot ${mountdir} /bin/bash  <<CEOF
apt-get update
CEOF
}

function InstallAnsible()
{
#Enter the chroot
sudo chroot ${mountdir} /bin/bash  <<CEOF

export DEBIAN_FRONTEND=noninteractive
apt-get install -y python3-pip git
pip install --upgrade pip
pip install ansible

sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
dpkg-reconfigure --frontend=noninteractive locales
update-locale LANG=en_US.UTF-8

CEOF
}

function RunPlayBookUbuntuDesktopZFS()
{

playbookdir=/var/data/apb
#Enter the chroot
sudo chroot ${mountdir} /bin/bash  <<CEOF

if [ ! -d "${playbookdir}" ];
then
  mkdir ${playbookdir} -p
fi

set -x
cd ${playbookdir}
if [ ! -d "${playbookdir}/UDZFS" ]; then git clone ${giturl}; fi
cd UDZFS/playbooks
ansible-playbook -e "hostname=$hostname" vartest.yaml
set +x
CEOF

echo "(RunPlayBookUbuntuDesktopZFS) done."

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
Debootstrap
CopyFilesBeforeInstall
PrepareChroot
CreateAptSources
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
