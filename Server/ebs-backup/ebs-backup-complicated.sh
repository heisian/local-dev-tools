#!/bin/bash

# EC2 environment variables and JAVA_HOME must already be defined
source /etc/profile

# Configuration
allow_root_freeze="no" # if set to "yes" then root XFS partitions will still be frozen and backed up.

# Dependencies:
#   ec2-api-tools
#   ec2-metadata
#   cloud-utils
#   pvdisplay (for volume group tests)
#   lvdisplay (for volume group tests)
#   xfs_freeze (for XFS filesystems to get consistent snapshots)

# Identify API commands and dependency paths
CMD_LVDISPLAY=/sbin/lvdisplay
CMD_METADATA=ec2-metadata
CMD_PVDISPLAY=/sbin/pvdisplay
CMD_SNAPSHOT_CREATE=ec2-create-snapshot
CMD_SNAPSHOT_DESCRIBE=ec2-describe-snapshots
CMD_SNAPSHOT_DELETE=ec2-delete-snapshot
CMD_TAG_CREATE=ec2-create-tags
CMD_TAG_DESCRIBE=ec2-describe-tags
CMD_VOLUME_DESCRIBE=ec2-describe-volumes
CMD_XFS_FREEZE=/usr/sbin/xfs_freeze

# Functions
function contains() {
    local n=$#
    local value=${!n}
    for ((i=1;i < $#;i++)) {
    if [ "${!i}" == "${value}" ]; then
        echo "y"
        return 0
    fi
    }
    echo "n"
    return 1
}

# Fetch EC2 metadata to get current instance id
ec2_instance_id=$($CMD_METADATA --instance-id | awk '{print $2}')

if [ "$ec2_instance_id" == "" ] || [ "$ec2_instance_id" == "" ]; then
    ec2_instance_id=$($CMD_METADATA --instance-id | awk '{print $1}')
fi

if [ "$ec2_instance_id" == "" ] || [ "$ec2_instance_id" == "" ]; then
    echo -e "Unable to determine EC2 instance id, please check this code before continuing in order to prevent corruption or deletion of unrelated snapshots.\r"
    exit -1;
fi

if [ "$ec2_instance_id" == "Command" ]; then
    echo -e "You must first set EC2_PRIVATE_KEY and EC2_CERT environment variables (in /etc/profile) in order for this script to work.\r"
    exit -1;
else
    echo -e "Identified instance as $ec2_instance_id.\r"
fi

# Fetch list of all volumes attached to this instance
echo -e "Getting volume list...\r"
volume_list=$($CMD_VOLUME_DESCRIBE | grep "${ec2_instance_id}" | awk '{print $2}')
printf -- '%s\n' "${volume_list[@]}"
# Identify root device
root_mount_point=$(mountpoint -d /)
use_xd_device_prefix="no"
for file in $(find /dev)
do
    device_major=$(stat --printf="%t" "$file")
    device_minor=$(stat --printf="%T" "$file")
    if [ "$device_major:$device_minor"  == "$root_mount_point" ]; then
        root_device="$file"
        break;
    else # Try decimal comparison
        device_major=$(printf "%d\n" "0x$device_major")
        device_minor=$(printf "%d\n" "0x$device_minor")
        if [ "$device_major:$device_minor"  == "$root_mount_point" ]; then
            root_device="$file"
            break;
        fi
    fi
done
if [ "$root_device" == "" ]; then
    root_device=$(readlink -f "/dev/root")
fi
if [[ "$root_device" == *"xvd"* ]]; then
    use_xd_device_prefix="yes"
fi
root_device=$(echo "$root_device" | sed 's/[0-9]*//g')
echo -e "Identified root device as $root_device.\r"

root_device_last_character=${root_device#${root_device%?}}

use_block_device_offset="no"
if [[ "$root_device_last_character" != "a" ]]; then
    use_block_device_offset="yes"
    root_device_last_character=$(echo "$root_device_last_character" | awk '{print tolower($0)}')
    ascii_block_device_last_character=$(printf "%d\n" "'$root_device_last_character")
    block_device_offset=`expr $ascii_block_device_last_character - 97`
    echo -e "  Detected that root device is offset (to ___$root_device_last_character) and will shift additional devices $block_device_offset places accordingly [if not found in /dev]."
fi

# Determine which volumes are isolated, XFS, and LVM groups (they need to be backed up differently)
ignored_volumes=()
isolated_volumes=()
xfs_volumes=()
virtual_group_volumes=()
virtual_group_names=()
virtual_groups=()
root_volume="%ROOT%"
skipped_root_volume=""
for ec2_volume in ${volume_list[@]}
do
    volume_virtual_group=""
    volume_mount_point=$($CMD_VOLUME_DESCRIBE $ec2_volume | grep "ATTACHMENT" | awk '{print $4}')
    if [ "$use_xd_device_prefix" == "yes" ] && [ "$volume_mount_point" != *"xvd"* ]; then
        volume_mount_point=$(echo "$volume_mount_point" | sed 's/\/sd/\/xvd/g')
    fi
    volume_filesystem=$(df -T | grep "${volume_mount_point}" | awk 'NF == 1 {printf($1); next}; {print}' | awk '{print $2}')
    if [ -z $volume_filesystem ]; then
        # Test if volume is part of an LVM/VG
        volume_virtual_group=$($CMD_PVDISPLAY $volume_mount_point | grep "VG Name" | awk '{print $3}')
        if [ -z "$volume_virtual_group" ] && [ "$use_block_device_offset" == "yes" ]; then
            volume_mount_point_last_letter=${volume_mount_point#${volume_mount_point%?}}
            ascii_volume_mount_point_last_letter=$(printf "%d\n" "'$volume_mount_point_last_letter")
            ascii_offset_volume_mount_point_last_letter=`expr $ascii_volume_mount_point_last_letter + $block_device_offset`
            offset_volume_mount_point_last_letter=$(awk -v char=$ascii_offset_volume_mount_point_last_letter 'BEGIN { printf "%c\n", char; exit }')
            volume_mount_point_prefix=$(echo "${volume_mount_point%?}")
            volume_mount_point=$volume_mount_point_prefix$offset_volume_mount_point_last_letter
            echo -e "   * Testing offset volume mount point, $volume_mount_point ..."
            volume_virtual_group=$($CMD_PVDISPLAY $volume_mount_point | grep "VG Name" | awk '{print $3}')
        fi
        if [ -z "$volume_virtual_group" ]; then
            # Test if volume is root device
            if [ "$volume_mount_point" == "$root_device" ] || [ -n "$(file -s $volume_mount_point | grep "rootfs")" ]; then
                volume_filesystem=$(df -T | grep '/$' | awk 'NF == 1 {printf($1); next}; {print}' | awk '{print $2}')
            else
                echo -e "   Ignoring volume $ec2_volume attached to $volume_mount_point, could not determine filesystem.\r"
                ignored_volumes=( "${ignored_volumes[@]}" "$ec2_volume" )
            fi
        fi
        if [ "$volume_virtual_group" != "" ]; then
            echo -e "   Identified volume $ec2_volume attached to $volume_mount_point part of virtual group \"$volume_virtual_group\".\r"
            virtual_group_volumes=( "${virtual_group_volumes[@]}" "$ec2_volume" )
            virtual_group_names=( "$volume_virtual_group" )
            if [ $(contains "${virtual_groups[@]}" "$volume_virtual_group") == "n" ]; then
                virtual_groups=( "${virtual_groups[@]}" "$volume_virtual_group" )
            fi
        fi
    fi
    if [ "$volume_virtual_group" == "" ] && [ "$volume_filesystem" != "" ]; then
        echo -e "   Identified isolated volume $ec2_volume attached to $volume_mount_point with filesystem type $volume_filesystem.\r"
        if [ "$volume_filesystem" == "xfs" ]; then
            xfs_volumes=( "${xfs_volumes[@]}" "$ec2_volume" )
        else
            isolated_volumes=( "${isolated_volumes[@]}" "$ec2_volume" )
        fi
    fi
    if [ "$volume_mount_point" == "$root_device" ] || [ -n "$(file -s $volume_mount_point | grep "rootfs")" ]; then
        root_volume="$ec2_volume"
        echo -e "   Identified volume $ec2_volume attached to $volume_mount_point as root device with filesystem type $volume_filesystem.\r"
    fi
done

# Identify old snapshots for deletion (do not delete until new snapshots are in progress)
#echo -e "Identifying old snapshots for deletion...\r"
#i=0
#for ec2_volume in ${volume_list[@]}
#do
#    volume_snapshots=( $($CMD_SNAPSHOT_DESCRIBE | grep "SNAPSHOT" | grep "${ec2_volume}" | awk '{ print $2 }') )
#    for volume_snapshot in ${volume_snapshots[@]}
#    do
#        volume_id=$($CMD_SNAPSHOT_DESCRIBE $volume_snapshot | grep "SNAPSHOT" | awk '{print $3}')
#        volume_name=$($CMD_TAG_DESCRIBE --filter "resource-id=$volume_id" --filter "key=Name" | cut -f5)
#        if [ "$volume_name" != "" ]; then
#            snapshots[i]=$volume_snapshot
#            echo -e "   Found and marked snapshot $volume_snapshot for deletion.\r"
#            snapshot_label="PENDING: $volume_name"
#            echo -e "   Labeling snapshot $volume_snapshot as \"$snapshot_label\""
#            $CMD_TAG_CREATE $volume_snapshot --tag "Name=$snapshot_label"
#            let i+=1
#        else
#            echo -e "  Error detecting volume associated with snapshot $volume_snapshot, will not relabel or attempt to delete."
#        fi
#    done
#done

# Initiate isolated volume snapshots
echo -e "Creating snapshots of isolated volumes...\r"
i=0
pids=()
for ec2_volume in ${isolated_volumes[@]}
do
    current_date=$(date +%Y-%m-%d)
    new_snapshot=$($CMD_SNAPSHOT_CREATE $ec2_volume -d "$current_date - RR.com Daily Backup" &)
    volume_snapshot=$(echo $new_snapshot | awk '{print $2}')
    volume_id=$(echo $new_snapshot | awk '{print $3}')
    volume_name=`$CMD_TAG_DESCRIBE --filter "resource-id=$volume_id" --filter "key=Name" | cut -f5`
    snapshot_label="$current_date: $volume_name"
    echo -e "   Labeling snapshot $volume_snapshot as \"$snapshot_label\""
    $CMD_TAG_CREATE $volume_snapshot --tag "Name=$snapshot_label"
    pids[i]=$!
    let i+=1
done
for pid in ${pids[@]}
do
    wait $pid
done

# Initiate XFS volume snapshots
if [ ${#xfs_volumes[@]} != 0 ]; then
    echo -e "Creating snapshots of XFS volumes (mounts frozen during snapshot initiation)...\r"
    i=0
    pids=()
    mount_points=()
    for ec2_volume in ${xfs_volumes[@]}
    do
        if [ "$ec2_volume" == "$root_volume" ] && [ "$allow_root_freeze" != "yes" ]; then
            echo -e "  Skipping volume $ec2_volume because it is a root volume and will cause the system to hang indefinitely...\r"
            skipped_root_volume=$root_volume
        else
            volume_mount_point=$($CMD_VOLUME_DESCRIBE $ec2_volume | grep "ATTACHMENT" | awk '{print $4}')
            volume_mount_path=$(df -T | grep "$volume_mount_point" | awk 'NF == 1 {printf($1); next}; {print}' | awk '{print $7}')
            if [ -n $volume_mount_path ]; then
                mount_points=( "${mount_points[@]}" "$volume_mount_point" )
                echo -e "   Freezing mount at $volume_mount_path...\r"
                $CMD_XFS_FREEZE -f $volume_mount_path
                new_snapshot=$($CMD_SNAPSHOT_CREATE $ec2_volume &)
                volume_snapshot=$(echo $new_snapshot | awk '{print $2}')
                volume_id=$(echo $new_snapshot | awk '{print $3}')
                volume_name=`$CMD_TAG_DESCRIBE --filter "resource-id=$volume_id" --filter "key=Name" | cut -f5`
                current_date=$(date +%Y-%m-%d)
                snapshot_label="$current_date: (XFS) $volume_name"
                echo -e "   Labeling snapshot $volume_snapshot as \"$snapshot_label\"\r"
                $CMD_TAG_CREATE $volume_snapshot --tag "Name=$snapshot_label"
                pids[i]=$!
                let i+=1
            else
                echo -e "  Error freezing mount point for volume $ec2_volume because mount path was not found, skipping..."
                ignored_volumes=( "${ignored_volumes[@]}" "$ec2_volume" )
            fi
        fi
    done
    for pid in ${pids[@]}
    do
        wait $pid
    done
    for volume_mount_path in ${mount_points[@]}
    do
        echo -e "   Thawing mount at $volume_mount_path...\r"
        $CMD_XFS_FREEZE -u $volume_mount_path
    done
else
    echo -e "  No XFS volumes (${#xfs_volumes[@]}) were detected.\r"
fi

# Initiate virtual group volume snapshots
if [ ${#virtual_group_volumes[@]} != 0 ] && [ ${#virtual_groups[@]} != 0 ]; then
    echo -e "Creating snapshots of virtual group volumes (mounts frozen during snapshot initiation)...\r"
    i=0
    pids=()
    mount_points=()
    echo -e
    for virtual_group in ${virtual_groups[@]}
    do
        virtual_group_mount_point=$($CMD_LVDISPLAY $virtual_group | grep "LV Path" | awk '{print $3}')
        if [ -d "$virtual_group_mount_point" ]; then
            virtual_group_mount_pointer=$(mountpoint -d "$virtual_group_mount_point")
        else
            virtual_group_mount_pointer=$(mountpoint -x "$virtual_group_mount_point")
        fi
        if [ "$virtual_group_mount_pointer" == "" ]; then
            if [ -L "$virtual_group_mount_point" ]; then
                virtual_group_device_path=$(readlink -f $virtual_group_mount_point)
            fi
        else
            for file in $(find /dev)
            do
                device_major=$(stat --printf="%t" "$file")
                device_minor=$(stat --printf="%T" "$file")
                if [ "$device_major:$device_minor"  == "$virtual_group_mount_pointer" ]; then
                    virtual_group_device_path="$file"
                    break;
                else # Try decimal comparison
                    device_major=$(printf "%d\n" "0x$device_major")
                    device_minor=$(printf "%d\n" "0x$device_minor")
                    if [ "$device_major:$device_minor"  == "$virtual_group_mount_pointer" ]; then
                        virtual_group_device_path="$file"
                        break;
                    fi
                fi
            done
        fi
        virtual_group_mount_path=$(df -a | grep "$virtual_group_device_path" | awk '{print $6}')
        # Try reverse lookup in /dev/mapper directly
        if [ "$virtual_group_mount_path" == "" ]; then
            for file in $(find /dev/mapper)
            do
                target=$(readlink -f "$file")
                if [ "$target" == "$virtual_group_device_path" ]; then
                    virtual_group_device_path="$file"
                    break;
                fi
            done
            virtual_group_mount_path=$(df -a | grep "$virtual_group_device_path" | awk '{print $6}')
        fi
        if [ "$virtual_group_mount_path" != "" ] && [ "$virtual_group_device_path" != "" ]; then
            mount_points=( "${mount_points[@]}" "$virtual_group_mount_path" )
            echo -e "   Freezing mount at $virtual_group_mount_path for virtual group \"$virtual_group\"...\r"
            $CMD_XFS_FREEZE -f "$virtual_group_mount_path"
        else
            echo -e "  Error: Could not identify mountpoint to freeze, proceeding without freezing. This may not be consistent!\r"
        fi
    done
    for ec2_volume in ${virtual_group_volumes[@]}
    do
        # This check is probably irrelavant since I don't believe you could have a root partition as part of a volume group without a custom kernel
        if [ "$ec2_volume" == "$root_volume" ] && [ "$allow_root_freeze" != "yes" ]; then
            echo -e "  Skipping volume $ec2_volume because it is a root volume and will cause the system to hang indefinitely...\r"
            skipped_root_volume=$root_volume
        else
            current_date=$(date +%Y-%m-%d)
            new_snapshot=$($CMD_SNAPSHOT_CREATE $ec2_volume &)
            volume_snapshot=$(echo $new_snapshot | awk '{print $2}')
            volume_id=$(echo $new_snapshot | awk '{print $3}')
            volume_name=`$CMD_TAG_DESCRIBE --filter "resource-id=$volume_id" --filter "key=Name" | cut -f5`
            virtual_group_name=${virtual_group_names[@]}
            snapshot_label="$current_date: (VG - $virtual_group_name) $volume_name"
            echo -e "   Labeling snapshot $volume_snapshot as \"$snapshot_label\""
            $CMD_TAG_CREATE $volume_snapshot --tag "Name=$snapshot_label"
            pids[i]=$!
            let i+=1
        fi
    done
    for pid in ${pids[@]}
    do
        wait $pid
    done
    for virtual_group_mount_path in ${mount_points[@]}
    do
        echo -e "   Thawing mount at $virtual_group_mount_path...\r"
        $CMD_XFS_FREEZE -u "$virtual_group_mount_path"
    done
else
    echo -e "  No virtual volumes (${#virtual_group_volumes[@]}) and no virtual groups (${#virtual_groups[@]}) were detected.\r"
fi

# Snapshots initiated, delete old snapshots
#echo -e "Snapshots initiated, delete old snapshots...\r"
#for snapshot in ${snapshots[@]}
#do
#    result=$($CMD_SNAPSHOT_DELETE "$snapshot")
#    # This does not currently work as the result of the delete command cannot be captured
#    if [[ "$result" == *"InvalidSnapshot.InUse"* ]]; then
#        echo -e "  Error: Could not delete snapshot $snapshot because it is currently in use by an AMI, renaming accorindgly."
#        volume_id=$($CMD_SNAPSHOT_DESCRIBE "$snapshot" | grep "SNAPSHOT" | awk '{print $3}')
#        volume_name=`$CMD_TAG_DESCRIBE --filter "resource-id=$volume_id" --filter "key=Name" | cut -f5`
#        current_date=$(date +%Y-%m-%d)
#        snapshot_label="$current_date: [AMI] $volume_name"
#        echo -e "   Labeling snapshot $snapshot as \"$snapshot_label\""
#        $CMD_TAG_CREATE $snapshot --tag "Name=$snapshot_label"
#    fi
#done

# All done!
echo -e 'Backup complete, deprecated snapshots removed, and new snapshots labeled as "YYYY-MM-DD: [(type)] Volume Id".\r'
if [ "$skipped_root_volume" != "" ]; then
    echo -e "The root volume $skipped_root_volume was skipped because it is an XFS volume and would cause the system to hang indefinitely.\r"
fi
if [ ${#ignored_volumes[@]} != 0 ]; then
    echo -e "The following volumes were ignored due to unknown filesystem (to prevent corruption) or unknown mount path (could not freeze XFS mount):\r"
    echo $ignored_volumes
fi
exit 0;
#Result (Sample Output)
#
#Identified instance as i-#######d.
#Identified root device as /dev/sda1.
#   Identified isolated volume vol-#######0 attached to /dev/sda1 with filesystem type xfs.
#   Identified volume vol-#######0 attached to /dev/sda1 as root device with filesystem type xfs.
#   Identified isolated volume vol-#######2 attached to /dev/sdf with filesystem type ext4.
#Identifying old snapshots for deletion...
#   Found and marked snapshot snap-#######0 for deletion.
#   Labeling snapshot snap-#######0 as "PENDING: Some EBS Volume Root"
#TAG	snapshot	snap-#######0	Name	PENDING: Some EBS Volume Root
#   Found and marked snapshot snap-#######4 for deletion.
#   Labeling snapshot snap-#######4 as "PENDING: Some EBS Volume Data"
#TAG	snapshot	snap-#######4	Name	PENDING: Some EBS Volume Data
#   Found and marked snapshot snap-#######2 for deletion.
#   Labeling snapshot snap-#######2 as "PENDING: Some Other EBS Volume"
#TAG	snapshot	snap-#######2	Name	PENDING: Some Other EBS Volume
#Creating snapshots of isolated volumes...
#   Labeling snapshot snap-#######8 as "2012-12-01: Some Other EBS Volume"
#TAG	snapshot	snap-#######8	Name	2012-12-01: Some Other EBS Volume
#Creating snapshots of XFS volumes (mounts frozen during snapshot initiation)...
#  Skipping volume vol-#######0 because it is a root volume and will cause the system to hang indefinitely...
#  No virtual volumes (0) and no virtual groups (0) were detected.
#Snapshots initiated, delete old snapshots...
#Client.InvalidSnapshot.InUse: The snapshot snap-#######2 is currently in use by ami-#######a
#Client.InvalidSnapshot.InUse: The snapshot snap-#######4 is currently in use by ami-#######b
#Backup complete, deprecated snapshots removed, and new snapshots labeled as "YYYY-MM-DD: [(type)] Volume Id".
#The root volume vol-#######0 was skipped because it is an XFS volume and would cause the system to hang indefinitely.
