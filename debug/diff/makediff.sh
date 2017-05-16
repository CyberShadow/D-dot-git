#!/bin/bash
set -eu

for branch in master stable
do
	for ver in result result_old
	do
		(
			cd ../../$ver
			git log --pretty=format:%s $branch
		) > $branch-$ver.txt
	done
	diff -u $branch-result_old.txt $branch-result.txt > $branch.diff || true
done
