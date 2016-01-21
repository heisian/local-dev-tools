sudo su

touch /tmp/ebs-backup.log

chmod a+x /usr/bin/ebs-backup.sh

crontab -e

1 0 * * * export AWS_ACCESS_KEY=; export AWS_SECRET_KEY=; /usr/bin/ebs-backup.sh >> /tmp/ebs-backup.log
