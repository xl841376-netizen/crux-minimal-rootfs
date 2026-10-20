#!/bin/sh
# mark a clean shutdown so the next boot knows a crash happened
mkdir -p /var/lib/crux
date -Is > /var/lib/crux/lastboot.ok
