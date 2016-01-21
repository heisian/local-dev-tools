#!/bin/bash

#Setting parameters to run ec2 commands
export RUBYLIB=$RUBYLIB:/usr/lib/ruby/site_ruby:/usr/lib64/ruby/site_ruby
export JAVA_HOME="/usr/lib/jvm/java-1.8.0-openjdk-1.8.0.65-3.b17.el7.x86_64/jre"
export EC2_HOME=/usr/local/ec2/ec2-api-tools-1.7.5.1
export PATH=$PATH:$EC2_HOME/bin

# WE HAD TO INSTALL RUBY, JAVA, EC2 API TOOLS, ETC.
# IN ORDER FOR THIS TO WORK.
# YOU CAN FIND HOW TO INSTALL IN ONLINE AMAZON DOCS


#Instance & EBS Volume details
MY_INSTANCE_ID=[INSTANCE_ID]
VOLUME_LIST=[VOLUME_ID]

sync
DAY=$(date +%Y-%m-%d)
#creating the snapshots
for volume in $(echo $VOLUME_LIST); do

# create snapshot and put the resulting id into a variable
read SNAPSHOT_ID <<< $(ec2-create-snapshot $volume --description "$DAY" | awk '/SNAPSHOT[[:space:]]/ { print $2 }')

# set tag:
ec2-create-tags $SNAPSHOT_ID --tag Name="BACKUP"

done
