#!/bin/sh
# seed Sahara EFS images (image id 16/17/20) from the raw AP partitions,
# equivalent to Android ks reading mdm1m9kefs1/2/3 via -u
D=/lib/firmware/qcom/sdx50m
for i in 1 2 3; do
  P=/dev/disk/by-partlabel/mdm1m9kefs$i
  [ -b $P ] || continue
  dd if=$P of=$D/efs$i.bin bs=1M count=1 status=none
  echo "seed efs$i.bin from $P done"
done
