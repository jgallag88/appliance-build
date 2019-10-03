#!/bin/bash
#
# Copyright 2018 Delphix
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

#
# This script is intended to be used to build the "ancillary" repository
# that is used when we run live-build to build our artifacts. Prior to
# running live-build to build any of the appliance variants, this
# ancillary repository must be created using this script.
#
# The ancillary repository is a directory containing an Aptly/APT
# repository that can be used as the root directory to "aptly serve".
# Further, this repository will contain all of the "first-party"
# packages produced by Delphix, such that they can be easily installed
# (and/or downloaded) via the live-build environment with normal APT
# commands (e.g. apt install, apt download, etc).
#

TOP=$(git rev-parse --show-toplevel 2>/dev/null)

if [[ -z "$TOP" ]]; then
	echo "Must be run inside the git repsitory." 2>&1
	exit 1
fi

set -o xtrace
set -o errexit
set -o pipefail

OUTPUT_DIR=$TOP/live-build/build/ancillary-repository

function resolve_s3_uri() {
	local pkg_uri="$1"
	local pkg_prefix="$2"
	local latest_subprefix="$3"

	local bucket="snapshot-de-images"
	local jenkinsid="jenkins-ops"
	local resolved_uri

	if [[ -n "$pkg_uri" ]]; then
		resolved_uri="$pkg_uri"
	elif [[ "$pkg_prefix" == s3* ]]; then
		resolved_uri="$pkg_prefix"
	elif [[ -n "$pkg_prefix" ]]; then
		resolved_uri="s3://$bucket/$pkg_prefix"
	elif [[ -n "$latest_subprefix" ]]; then
		aws s3 cp --quiet \
			"s3://$bucket/builds/$jenkinsid/$latest_subprefix" .
		resolved_uri="s3://$bucket/$(cat latest)"
		rm -f latest
	else
		echo "Invalid arguments provided to resolve_s3_uri()" 2>&1
		exit 1
	fi

	if aws s3 ls "$resolved_uri" &>/dev/null; then
		echo "$resolved_uri"
	else
		echo "'$resolved_uri' not found." 1>&2
		exit 1
	fi
}

function download_delphix_s3_debs() {
	local pkg_directory="$1"
	local S3_URI="$2"
	local tmp_directory

	tmp_directory=$(mktemp -d -p "$TOP/build" tmp.s3-debs.XXXXXXXXXX)
	pushd "$tmp_directory" &>/dev/null

	aws s3 sync --only-show-errors "$S3_URI" .
	sha256sum -c --strict SHA256SUMS

	mv ./*deb "$pkg_directory/"

	popd &>/dev/null
	rm -rf "$tmp_directory"
}

function build_ancillary_repository() {
	local pkg_directory="$1"

	rm -rf "$HOME/.aptly"
	aptly repo create \
		-distribution=bionic -component=main ancillary-repository
	aptly repo add ancillary-repository "$pkg_directory"
	aptly publish repo -skip-contents -skip-signing ancillary-repository

	mkdir -p "$OUTPUT_DIR/.."
	rm -rf "$OUTPUT_DIR"
	mv "$HOME/.aptly" "$OUTPUT_DIR"
	cat >"$OUTPUT_DIR/aptly.config" <<-EOF
		{
		    "rootDir": "$OUTPUT_DIR"
		}
	EOF
}

#
# The first-party packages produced by Delphix are stored in Amazon S3.
# Thus, in order to populate the ancillary repository with these
# packages, they must be downloaded from S3, so they can be then
# inserted into the Aptly repository.
#
# Here, we determine the URI of each of the first-party packages, and
# then use these URIs to download the packages later. Making this
# determination is a little complex, and is dependent on the policy set
# forth by the teams producing and storing the packages.
#
# With that said, there's three main methods of influencing the URI from
# which the packages are downloaded:
#
# 1. If the package specific AWS_S3_URI environment variable is provided
#    (e.g. AWS_S3_URI_VIRTUALIZATION), then this URI will be used to
#    download the package. This is the simplest case, and enables the
#    user of this script to directly influence this script.
#
# 2. If the package specific AWS_S3_PREFIX environment variable is
#    provided (e.g. AWS_S3_PREFIX_VIRTUALIZATION), then this value is
#    used to build the URI that will be used based on the default S3
#    bucket that is used.
#
# 3. If nether the package specific AWS_S3_URI nor AWS_S3_PREFIX
#    variables are provided, then logic kicks in to attempt to
#    dynamically determine the URI of the most recently built package,
#    and then uses that URI. This way, a naive user can not set any
#    environment variables, and the script will work as expected.
#

if [[ -z "$UPSTREAM_BRANCH" ]]; then
	echo "UPSTREAM_BRANCH is not set."
	exit 1
fi

AWS_S3_URI_VIRTUALIZATION=$(resolve_s3_uri \
	"$AWS_S3_URI_VIRTUALIZATION" \
	"$AWS_S3_PREFIX_VIRTUALIZATION" \
	"dlpx-app-gate/${UPSTREAM_BRANCH}/build-package/post-push/latest")

AWS_S3_URI_MASKING=$(resolve_s3_uri \
	"$AWS_S3_URI_MASKING" \
	"$AWS_S3_PREFIX_MASKING" \
	"dms-core-gate/${UPSTREAM_BRANCH}/build-package/post-push/latest")

AWS_S3_URI_USERLAND_PKGS=$(resolve_s3_uri \
	"$AWS_S3_URI_USERLAND_PKGS" \
	"$AWS_S3_PREFIX_USERLAND_PKGS" \
	"devops-gate/master/linux-pkg-build/${UPSTREAM_BRANCH}/userland/post-push/latest")

AWS_S3_URI_KERNEL_PKGS=$(resolve_s3_uri \
	"$AWS_S3_URI_KERNEL_PKGS" \
	"$AWS_S3_PREFIX_KERNEL_PKGS" \
	"devops-gate/master/linux-pkg-build/${UPSTREAM_BRANCH}/kernel/post-push/latest")

#
# All package files will be placed into this temporary directory, such
# that we can later point Aptly at this directory to build the Aptly/APT
# repository.
#
mkdir -p "$TOP/build"
PKG_DIRECTORY=$(mktemp -d -p "$TOP/build" tmp.pkgs.XXXXXXXXXX)

#
# Now that we've determined the URI of all first-party packages, we can
# proceed to download these packages.
#
download_delphix_s3_debs "$PKG_DIRECTORY" "$AWS_S3_URI_VIRTUALIZATION"
download_delphix_s3_debs "$PKG_DIRECTORY" "$AWS_S3_URI_MASKING"
download_delphix_s3_debs "$PKG_DIRECTORY" "$AWS_S3_URI_USERLAND_PKGS"
download_delphix_s3_debs "$PKG_DIRECTORY" "$AWS_S3_URI_KERNEL_PKGS"

#
# Now that our temporary package directory has been populated with all
# first-party packages needed by live-build, we use this directory to
# build up our Aptly/APT ancillary repository. After this function
# completes, there should be a directory named "ancillary-repository" at
# the top level of the git repository, that can later be "aptly
# serve"-ed and consumed by live-build.
#
build_ancillary_repository "$PKG_DIRECTORY"

rm -rf "$PKG_DIRECTORY"
