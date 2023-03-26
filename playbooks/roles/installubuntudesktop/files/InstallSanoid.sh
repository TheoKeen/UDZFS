#!/bin/bash

function InstallSanoid()
{

source /etc/os-release


mkdir /opt/compose/build -p
cd /opt/compose/build
# Download the repo as root to avoid changing permissions later
sudo git clone https://github.com/jimsalterjrs/sanoid.git
cd sanoid
# checkout latest stable release or stay on master for bleeding edge stuff (but expect bugs!)
git checkout $(git tag | grep "^v" | tail -n 1)
ln -s packages/debian .
dpkg-buildpackage -uc -us
apt install ../sanoid_*_all.deb

# enable and start the sanoid timer
sudo systemctl enable sanoid.timer
sudo systemctl start sanoid.timer


cat << EOF >  /etc/sanoid/sanoid.conf
[${poolname}/ROOT/${ID}]
    use_template = production
[${poolname}/DATA/home]
    use_template = production
[${poolname}/DATA/var/data]
        use_template = production
[${poolname}/DATA/opt]
        use_template = production


#############################
# templates below this line #
#############################

[template_production]
        frequently = 0
        hourly = 10
        daily = 5
        monthly = 1
        yearly = 0
        autosnap = yes
        autoprune = yes
EOF



# enable and start the sanoid timer
sudo systemctl enable sanoid.timer
#sudo systemctl start sanoid.timer

}

InstallSanoid