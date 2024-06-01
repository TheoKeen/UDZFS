#!/bin/bash


function getconfig(){

#Make sure curl is installed.
curl -V > /dev/null || {
apt-get update
apt-get install -y curl
}

if [ !  -f ${configfile} ] && [ ! -z ${DNSDOMAIN} ] ;  then
  echo "Attempting auto discovery of config file"
  discoverurl=$(dig TXT deploy.udz.${DNSDOMAIN} +short | tr -d '"')
  if [ ! -z ${discoverurl} ]; then
    curl -fs  --output ${configfile} --connect-timeout 2  $(dig TXT deploy.udz.${DNSDOMAIN} +short | tr -d '"')
  fi
fi
if [ !  -f ${configfile} ]; then
  echo "Downloading example config from github. You probably don't want the example config!!"
  curl -fs  --output ${configfile} --connect-timeout 2  https://raw.githubusercontent.com/TheoKeen/UDZFS/main/playbooks/config.yml.example
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
if [  -z ${SIZEZFS} ]; then
sgdisk -N ${zfspartno} -t 0:bf00 ${TARGETDISK}        #ZFS
else
sgdisk -n ${zfspartno}:0:+${SIZEZFS} -t 0:bf00 ${TARGETDISK}
fi


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
zfs mount ${poolname}/DATA/opt

#Update device symlinks
udevadm trigger
}

function Debootstrap()
{
uversion=$1

apt-get update
apt-get install -y debootstrap
debootstrap ${uversion} ${mountdir} https://nl.archive.ubuntu.com/ubuntu/
}

function CopyFilesBeforeInstall()
{
cp /etc/hostid ${mountdir}/etc/hostid
cp /etc/resolv.conf ${mountdir}/etc/
mkdir ${mountdir}/etc/zfs
cp /etc/zfs/zpool.cache ${mountdir}/etc/zfs
cp /etc/zfs/zroot.key ${mountdir}/etc/zfs
cp ${configfile} ${mountdir}/root
if [ -f ${vaultpassfile} ]; then cp ${vaultpassfile} ${mountdir}/root; fi

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

uversion=$1

cat << EOF > ${mountdir}/etc/apt/sources.list
deb http://nl.archive.ubuntu.com/ubuntu ${uversion} main restricted
deb http://nl.archive.ubuntu.com/ubuntu ${uversion}-updates main restricted
deb http://nl.archive.ubuntu.com/ubuntu ${uversion} universe
deb http://nl.archive.ubuntu.com/ubuntu ${uversion}-updates universe
deb http://nl.archive.ubuntu.com/ubuntu ${uversion} multiverse
deb http://nl.archive.ubuntu.com/ubuntu ${uversion}-updates multiverse
deb http://nl.archive.ubuntu.com/ubuntu ${uversion}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${uversion}-security main restricted
deb http://security.ubuntu.com/ubuntu ${uversion}-security universe
deb http://security.ubuntu.com/ubuntu ${uversion}-security multiverse
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
#pip install ansible #Version 7.4.0 was not working with dconf module.
pip install 'ansible==7.3.0'

sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
dpkg-reconfigure --frontend=noninteractive locales
update-locale LANG=en_US.UTF-8

CEOF
}

function RunPlayBookUbuntuDesktopZFS()
{

playbookdir=/var/apb
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
if [ ! -f  /root/.vaultpass.txt ]; then sed -i '/vault_password_file/d' ./ansible.cfg ; fi
ansible-playbook -e "hostname=$hostname targetdisk=${TARGETDISK} efipartno=${efipartno} poolname=${poolname}" ChrootInstall.yaml
set +x
CEOF

echo "(RunPlayBookUbuntuDesktopZFS) done."

}

