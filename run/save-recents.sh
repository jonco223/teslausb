#!/bin/bash

CACHE=/backingfiles/cache
CAMCOPY=/mnt/camcopy

# make a low-overhead copy of the current cam drive, fsck it, and
# mount it at /mnt/camcopy
function mountcopy {
  if [ ! -d $CAMCOPY ]
  then
    mkdir $CAMCOPY
  fi
 
  if [ -e /backingfiles/cam_disk_copy.bin ]
  then
    umount $CAMCOPY || true
    rm -rf /backingfiles/cam_disk_copy.bin
  fi

  # make a copy-on-write snapshot of the current image
  cp --reflink=always /backingfiles/cam_disk.bin /backingfiles/cam_disk_copy.bin
  # at this point we have a snapshot of the cam image, which is completely
  # independent of the still in-use image exposed to the car

  # create loopback and scan the partition table, this will create an additional loop
  # device in addition to the main loop device, e.g. /dev/loop0 and /dev/loop0p1
  losetup -P -f /backingfiles/cam_disk_copy.bin
  PARTLOOP=$(losetup -j /backingfiles/cam_disk_copy.bin | awk '{print $1}' | sed 's/:/p1/') 
  fsck $PARTLOOP -- -a

  mount $PARTLOOP $CAMCOPY
}

# unmount the previously-made copy
function umountcopy {
  # for some reason "umount -d" doesn't remove the loop device, so we have to remove it ourselves
  LOOP=$(losetup -j /backingfiles/cam_disk_copy.bin | awk '{print $1}' | sed 's/://')
  umount $CAMCOPY
  losetup -d $LOOP
  rm /backingfiles/cam_disk_copy.bin
}

# make enough room in the cache space for one set of recording files,
# deleting the oldest recordings if needed
function make_space {
  freespace=$(df $CACHE | tail -1 | awk '{print $4}')
  # recordings seem to max out at about 30 megabytes per minute,
  # so 100 MB should be enough for one set of left/front/right recordings
  while [ "$freespace" -lt $((100*1024*1024)) ]
  do
    # remove oldest recordings
    oldest=$(ls -1 $CACHE/*.mp4 | head -1)
    # get the base name of the oldest recording
    oldest=$(echo $oldest | sed 's/-[a-z_]*\.mp4//')
    # remove the entire set of recordings for that time
    rm -f $oldest*
    freespace=$(df $CACHE | tail -1 | awk '{print $4}')
  done
}

# Copy all recordings that will be expired soon to the cache.
# This means recordings that are over or close to the 1 hour age limit,
# and the oldest recordings when the cam drive is nearing capacity.

while true
do
  date
  limit=$(date --date "3 minutes ago" +"%Y-%m-%d_%H-%M-")
  mountcopy
  cd $CAMCOPY/TeslaCam/RecentClips

  find -type f | {
    while read name
    do
      base=$(basename "$name")
      if [[ "$base" < "$limit" ]]
      then
        if [ -e "/backingfiles/cache/$base" ]
        then
          echo "skipping $name, already copied"
        else
          echo "moving $name"
          if cp "$name" /backingfiles/cache/newfile
          then
            mv /backingfiles/cache/newfile /backingfiles/cache/$base
          fi
          sleep 5
        fi
      else
        echo "$name is too recent"
      fi
    done
  }
  cd -
  umountcopy
  sleep 600
done

