# UDZFS

The goal of this script is to install Ubuntu 22.04 with ZFS on root (ZFSBootMenu) from an Ubuntu live session with a single command.

## Run

Example:

`wget -qO- https://raw.githubusercontent.com/TheoKeen/UDZFS/main/udz.sh | bash -s -- -f -d /dev/vda`

For the security

### Options

(Starting after "--" in the run example)
- -f Force. Proceeds without confirmation. (Must use with pipe to bash)
- -h Hostname. The hostname of the new installation. (**optional**)
- -p Vaultpass. The Ansible Vault password. (**optional**)

### Encrypty secrets

`ansible-vault encrypt config.yml`

`ansible-vault view config.yml`



