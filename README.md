# UDZFS

The goal of this script is to install Ubuntu 22.04 with ZFS on root (ZFSBootMenu) from an Ubuntu live session with a single command.

## Run

`wget -qO- https://raw.githubusercontent.com/TheoKeen/UDZFS/main/udz.sh) | bash -s -- -f -d /dev/vda`



### Encrypty secrets

ansible-vault encrypt data.yml

echo "password" > ~/.vault_pass.txt

`ansible-vault view data.yml`



