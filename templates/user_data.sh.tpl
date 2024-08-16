#!/bin/bash
echo "---   STARTING PRITUNL PROVISIONING   ---"
sudo export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/opt/aws/bin:/root/bin
sudo echo "export PATH=$PATH:/usr/local/bin" >> ~/.bashrc
sudo yum update -y
sudo yum install -y unzip curl
sudo curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
sudo unzip awscliv2.zip
sudo ./aws/install
sudo aws --version
sudo rm -rf awscliv2.zip aws
sudo yum remove -y aws-cli

sudo echo "* hard nofile 64000" >> /etc/security/limits.conf
sudo echo "* soft nofile 64000" >> /etc/security/limits.conf
sudo echo "root hard nofile 64000" >> /etc/security/limits.conf
sudo echo "root soft nofile 64000" >> /etc/security/limits.conf


sudo tee /etc/yum.repos.d/mongodb-org-4.2.repo << EOF
[mongodb-org-4.2]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/7/mongodb-org/4.2/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-4.2.asc
EOF
# sudo tee /etc/yum.repos.d/pritunl.repo << EOF
# [pritunl]
# name=Pritunl Repository
# baseurl=https://repo.pritunl.com/stable/yum/amazonlinux/2/
# gpgcheck=false
# enabled=1
# EOF
sudo yum -y update
sudo amazon-linux-extras install epel -y
sudo yum clean all
sudo yum -y install epel-release
# sudo yum-config-manager --enable ol7_developer_epel
# gpg --keyserver hkp://keyserver.ubuntu.com --recv-keys 7568D9BB55FF9E5287D586017AE645C0CF8E292A
# gpg --armor --export 7568D9BB55FF9E5287D586017AE645C0CF8E292A > key.tmp; sudo rpm --import key.tmp; rm -f key.tmp
sudo yum -y install pritunl mongodb-org
sudo systemctl enable mongod pritunl
sudo systemctl start mongod pritunl

cd /tmp
sudo curl -s https://amazon-ssm-eu-west-1.s3.amazonaws.com/latest/linux_amd64/amazon-ssm-agent.rpm -o amazon-ssm-agent.rpm
sudo yum install -y amazon-ssm-agent.rpm
sudo status amazon-ssm-agent || start amazon-ssm-agent

sudo cat <<EOF > /usr/sbin/mongobackup.sh
#!/bin/bash -e

set -o errexit  # exit on cmd failure
set -o nounset  # fail on use of unset vars
set -o pipefail # throw latest exit failure code in pipes
set -o xtrace   # print command traces before executing command.

export PATH="/usr/local/bin:\$PATH"
export BACKUP_TIME=\$(date +'%Y-%m-%d-%H-%M-%S')
export BACKUP_FILENAME="\$BACKUP_TIME-pritunl-db-backup.tar.gz"
export BACKUP_DEST="/tmp/\$BACKUP_TIME"
mkdir "\$BACKUP_DEST" && cd "\$BACKUP_DEST"
mongodump -d pritunl
tar zcf "\$BACKUP_FILENAME" dump
rm -rf dump
md5sum "\$BACKUP_FILENAME" > "\$BACKUP_FILENAME.md5"
aws s3 sync . s3://${s3_backup_bucket}/backups/
cd && rm -rf "\$BACKUP_DEST"
EOF
sudo chmod 700 /usr/sbin/mongobackup.sh

sudo cat <<EOF > /etc/cron.daily/pritunl-backup
#!/bin/bash -e
export PATH="/usr/local/sbin:/usr/local/bin:\$PATH"
mongobackup.sh && \
  curl -fsS --retry 3 \
  "https://hchk.io/\$( aws --region=${aws_region} --output=text \
                        ssm get-parameters \
                        --names ${healthchecks_io_key} \
                        --with-decryption \
                        --query 'Parameters[*].Value')"
EOF
chmod 755 /etc/cron.daily/pritunl-backup

cat <<EOF > /etc/logrotate.d/pritunl
/var/log/mongodb/*.log {
  daily
  missingok
  rotate 60
  compress
  delaycompress
  copytruncate
  notifempty
}
EOF

sudo cat <<EOF > /home/ec2-user/.bashrc
# https://twitter.com/leventyalcin/status/852139188317278209
if [ -f /etc/bashrc ]; then
  . /etc/bashrc
fi
EOF
