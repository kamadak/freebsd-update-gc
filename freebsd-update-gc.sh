#!/bin/sh
# $Id$
#
# Copyright (c) 2014 KAMADA Ken'ichi.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#

set -e

export PATH=/sbin:/bin:/usr/sbin:/usr/bin
export LC_ALL=C

DBDIR=/var/db/freebsd-update

doit=""
#doit="echo"
progname=$(basename "$0")

# List the rollback points from the newest to the oldest.
get_rollback_list() {
	local pointer rp

	if [ ! -r $DBDIR ]; then
		error "$DBDIR: not readable"
	fi
	set -- $DBDIR/*-rollback
	if [ $# -gt 1 ]; then
		error "unexpected multiple rollback points"
	fi
	pointer=$1
	if [ ! -h "$pointer" ]; then
		error "$pointer: must be a symlink"
	fi

	while [ -h "$pointer" ]; do
		rp=$(readlink "$pointer")
		echo "$rp"
		pointer=$DBDIR/$rp/rollback
	done
	if [ -e "$pointer" ]; then
		error "$pointer: unexpected file"
	fi
}

# List installation directory that are not yet installed.
get_pending_list() {
	local pointer

	for pointer in $DBDIR/*-install; do
		if [ ! -e "$pointer" ]; then
			# Probably the wild card was not expanded.
			continue
		fi
		if [ ! -h "$pointer" ]; then
			error "$pointer: must be a symlink"
		fi
		readlink "$pointer"
	done
}

# Check if the rollback point exists and is the oldest one.
check_if_last_rp() {
	local exist last prev rp rollback_list target

	rollback_list=$1
	target=$2

	for rp in $rollback_list; do
		if [ x"$rp" == x"$target" ]; then
			exist=yes
		fi
		prev=$last
		last=$rp
	done
	if [ -z "$exist" ]; then
		error "$target: no such rollback point"
	fi
	if [ x"$last" != x"$target" ]; then
		error "$target: not the oldest rollback point"
	fi
	if [ -z "$prev" ]; then
		error "cannot remove the most recent rollback point"
	fi
	echo "$prev"
}

# List object hashes (+ trailing .gz).  Each hash is followed by the
# newest rollback point that refers the object.
get_newest_ref() {
	local rp rollback_list find_garbage

	rollback_list=$1
	find_garbage=$2

	# Output newer rollback points first.  sort -u implies a stable sort,
	# so the newest point is preserved.
	{
		# tag points to tINDEX.present, which is not in the "files".
		#cut -d"|" -f5 $DBDIR/tag | sed 's/$/.gz tag/'
		cut -d"|" -f2 $DBDIR/tINDEX.present | \
		    sed 's/$/.gz tINDEX.present/'
		for rp in $rollback_list; do
			awk -F"|" -vrp="$rp" '
				$2 != "L" && $2 != "d" && $2 != "-" {
					print $7 ".gz", rp;
				}' $DBDIR/$rp/INDEX-OLD $DBDIR/$rp/INDEX-NEW
		done
		if [ -n "$find_garbage" ]; then
			# find is faster than "ls -f" on FreeBSD 10.0.
			(cd $DBDIR/files && find . -mindepth 1 -maxdepth 1 | \
			    sed 's|^\./||; s/$/ unref/')
		fi
	} | sort -u -k1,1
}

# List rollback points.
list() {
	local rp rollback_list pending_list
	local newest_ref ref_count ref_count_list

	rollback_list=$1
	pending_list=$2
	newest_ref=$3

	ref_count_list=$(awk '{
		count[$2]++;
	} END {
		for (key in count) { print key, count[key]; }
	}' <<-EOS)
		$newest_ref
	EOS

	for rp in $pending_list; do
		print_rp $rp "$ref_count_list" "PENDING   "
	done
	for rp in $rollback_list; do
		print_rp $rp "$ref_count_list" ""
	done
}

print_rp() {
	local rp version mtime
	local ref_count ref_count_list
	local nold nnew nboth

	rp=$1
	ref_count_list=$2
	mtime=$3

	version=$(get_freebsd_version $rp)
	if [ -z "$mtime" ]; then
		mtime=$(stat -f %Sm -t "%F" $DBDIR/$rp)
	fi
	ref_count=$(awk "/^$rp/ { print \$2 }" <<-EOS)
		$ref_count_list
	EOS

	printf "%s " "$mtime $version ($rp)"
	nold=$(wc -l < $DBDIR/$rp/INDEX-OLD)
	nnew=$(wc -l < $DBDIR/$rp/INDEX-NEW)
	nboth=$(cut -d"|" -f1 $DBDIR/$rp/INDEX-OLD $DBDIR/$rp/INDEX-NEW | \
	    sort | uniq -d | wc -l)
	printf "+%d -%d %%%d ref %d\n" \
	    $((nnew - nboth)) $((nold - nboth)) "$nboth" "${ref_count:-0}"
}

# Get the userland version from /bin/freebsd-version, or the kernel
# version from /boot/kernel/kernel.
get_freebsd_version() {
	# The freebsd-version command was introduced in FreeBSD 10.0.
	hash=$(grep '^/bin/freebsd-version|' $DBDIR/"$1"/INDEX-NEW | \
	    cut -d"|" -f7)
	if [ -n "$hash" ]; then
		gzcat $DBDIR/files/"$hash".gz | \
		    sed -n '/^USERLAND_VERSION=/ { s/"$//; s/.*="//; p; }'
		return
	fi
	# For older versions, look for the SCCS ID embedded in the kernel.
	hash=$(grep '^/boot/kernel/kernel|' $DBDIR/"$1"/INDEX-NEW | \
	    cut -d"|" -f7)
	if [ -n "$hash" ]; then
		gzcat $DBDIR/files/"$hash".gz | \
		    strings -n 48 | awk '/^@\(#\)FreeBSD/ { print $2; exit; }'
		return
	fi
	echo "UNKNOWN"
}

# Remove the oldest rollback point.
remove() {
	local mtime newest_ref rp prev_rp

	newest_ref=$1
	rp=$2
	prev_rp=$3

	# XXX Subsecond information will be lost.
	mtime=$(stat -f %Sm -t "%FT%T" $DBDIR/$prev_rp)
	$doit rm "$DBDIR/$prev_rp/rollback"
	$doit touch -d $mtime "$DBDIR/$prev_rp"
	$doit rm "$DBDIR/$rp"/*
	$doit rmdir "$DBDIR/$rp"
	sed -n "/ $rp\$/ { s| .*\$||; s|^|$DBDIR/files/|; p; }" <<-EOS | \
	    xargs $doit rm
		$newest_ref
	EOS
}

show() {
	local rp

	rp=$1

	echo "The following files were removed:"
	{
		awk -F"|" '{ print "1|" $1 }' $DBDIR/$rp/INDEX-OLD
		awk -F"|" '{ print "2|" $1 }' $DBDIR/$rp/INDEX-NEW
	} | sort -t"|" -k2,2 | uniq -s2 -u | awk -F"|" '$1 == "1" { print $2 }'
	echo
	echo "The following files were added:"
	{
		awk -F"|" '{ print "1|" $1 }' $DBDIR/$rp/INDEX-OLD
		awk -F"|" '{ print "2|" $1 }' $DBDIR/$rp/INDEX-NEW
	} | sort -t"|" -k2,2 | uniq -s2 -u | awk -F"|" '$1 == "2" { print $2 }'
	echo
	echo "The following files were updated:"
	cut -d"|" -f1 $DBDIR/$rp/INDEX-OLD $DBDIR/$rp/INDEX-NEW | sort | uniq -d
}

find_garbage() {
	local newest_ref rp rollback_list

	newest_ref=$1
	rollback_list=$2

	# Unreferenced files/*.
	awk '/ unref$/ { print "files/" $1 }' <<-EOS
		$newest_ref
	EOS

	# Unreferenced install.*.
	{
		for rp in $rollback_list; do
			printf "%s ref\n" $rp
		done
		(cd $DBDIR && ls -df install.*)
	} | sort -u -k1,1 | grep -v ' ref$' || true
}

usage() {
	printf "usage: %s list\n" "$progname"
	printf "       %s remove install.id\n" "$progname"
	printf "       %s show install.id\n" "$progname"
	printf "       %s find-garbage\n" "$progname"
	exit 1
}

error() {
	printf "%s: %s\n" "$progname" "$*" 1>&2
	exit 1
}

if [ $# -eq 1 -a x"$1" = xlist ]; then
	rollback_list=$(get_rollback_list)
	pending_list=$(get_pending_list)
	newest_ref=$(get_newest_ref "$pending_list $rollback_list" "")
	list "$rollback_list" "$pending_list" "$newest_ref"
elif [ $# -eq 2 -a x"$1" = xremove ]; then
	rollback_list=$(get_rollback_list)
	pending_list=$(get_pending_list)
	prev_rp=$(check_if_last_rp "$rollback_list" "$2")
	newest_ref=$(get_newest_ref "$pending_list $rollback_list" "")
	remove "$newest_ref" "$2" "$prev_rp"
elif [ $# -eq 2 -a x"$1" = xshow ]; then
	show "$2"
elif [ $# -eq 1 -a x"$1" = xfind-garbage ]; then
	rollback_list=$(get_rollback_list)
	pending_list=$(get_pending_list)
	newest_ref=$(get_newest_ref "$pending_list $rollback_list" find_garbage)
	find_garbage "$newest_ref" "$pending_list $rollback_list"
else
	usage
fi
exit 0
