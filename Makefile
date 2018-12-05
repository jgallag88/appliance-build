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

SHELL = /bin/bash

ALL_VARIANTS = $(shell find live-build/variants -maxdepth 1 -mindepth 1 -exec basename {} \;)
ALL_INTERNAL = $(shell find live-build/variants -maxdepth 1 -mindepth 1 -name 'internal-*' -exec basename {} \;)
ALL_EXTERNAL = $(shell find live-build/variants -maxdepth 1 -mindepth 1 -name 'external-*' -exec basename {} \;)

ALL_HYPERVISORS := generic aws azure gcp kvm

FINDEXEC.Darwin := -perm +111
FINDEXEC.Linux := -executable
FINDEXEC := $(FINDEXEC.$(shell uname -s))

SHELL_CHECKSTYLE_FILES = $(shell find scripts -type f $(FINDEXEC)) \
                $(shell find live-build/config/hooks -type f $(FINDEXEC)) \
                $(shell find live-build/misc/migration-scripts -type f) \
                $(shell find upgrade/upgrade-scripts -type f)

VM_ARTIFACTS.aws := vmdk
VM_ARTIFACTS.azure := vhdx
VM_ARTIFACTS.gcp := gcp.tar.gz
VM_ARTIFACTS.generic := ova qcow2 vmdk
VM_ARTIFACTS.kvm := qcow2

.PHONY: \
	all-external \
	all-internal \
	all-variants \
	fetch-livebuild-artifacts \
	ansiblecheck \
	check \
	shellcheck \
	shfmtcheck \
	shfmt \
	clean

all-variants: $(ALL_VARIANTS)
all-internal: $(ALL_INTERNAL)
all-external: $(ALL_EXTERNAL)

VM_ARTIFACTS := ova vmdk vhdx qcow2 gcp.tar.gz
NON_VM_ARTIFACTS := debs.tar.gz migration.tar.gz
ALL_ARTIFACTS := $(VM_ARTIFACTS) $(NON_VM_ARTIFACTS)

#
# Consider every file in live-build/ that isn't gitignored to be a dependency of
# live-build.
#
LIVE_BUILD_DEPENDS := $(shell git ls-files live-build; \
	git ls-files -o --exclude-standard live-build)

#
# Make the artifacts directories world writable because when the Jenkins job
# logic uploads the output of appliance-build, it will add some additional files
# (for instance, a SHA256SUM file). When it runs, it will be running outside the
# container and not as root.
#
%rtifacts:
	mkdir -p $@
	chmod 777 $@

#
# When invoking live-build, use a pattern rule to indicate that all of these
# output files are build by a single invocation of the recipe.
#
$(addprefix %.,$(ALL_ARTIFACTS)): ancillary-repository $(LIVE_BUILD_DEPENDS) \
		| live-build/artifacts
	./scripts/run-live-build.sh $$(basename $*)

define STAGE1_RULE
variant:=$(strip $(1))
hypervisor:=$(strip $(2))
.PHONY: $(variant)-$(hypervisor)
$(variant)-$(hypervisor): $(foreach vm_artifact, \
		$(NON_VM_ARTIFACTS) $(VM_ARTIFACTS.$(hypervisor)), \
		live-build/artifacts/$(variant)-$(hypervisor).$(vm_artifact))
	@echo "Built dependencies of $$@: $$^"
endef

#  Produces rules for targets internal-dev-generic, external-standard-aws, etc
$(foreach variant,$(ALL_VARIANTS), \
	$(foreach hypervisor,$(ALL_HYPERVISORS), \
	$(eval $(call STAGE1_RULE, $(variant), $(hypervisor)))))

#
# In order to build the second stage (which consists mainly of creating an
# upgrade image), we need either AWS_S3_URI_LIVEBUILD_ARTIFACTS or HYPERVISORS
# to be set in order to determine how we should obtain the necessary artifacts
# produced by live build. We don't want to enforce that one of these environment
# vars is set until the rule runs, because it should be possible to run other
# rules without them set. The check runs after the prerequisites have been built
# because it is part of the recipe. However, when the check is actually needed,
# nothing of interest will happen when executing prerequisites because
# HYPERVISORS is empty. Thus this check will be essentially the first thing
# done, which is what we want.
#
define STAGE2_RULE
variant:=$(strip $(1))
.PHONY: $(variant)
$(variant): $(if $(AWS_S3_URI_LIVEBUILD_ARTIFACTS), \
		fetch-livebuild-artifacts, \
		$(foreach hypervisor,$(HYPERVISORS),$(variant)-$(hypervisor))) \
		| artifacts
	@[[ -n $$$$AWS_S3_URI_LIVEBUILD_ARTIFACTS || -n $$$$HYPERVISORS ]] || \
		{ echo "Either 'AWS_S3_URI_LIVEBUILD_ARTIFACTS' or" \
		"'HYPERVISORS' must be defined as an environment variable." \
		"Re-run with HYPERVISORS set to a space-delimited list of" \
		"hypervisors for which to build (e.g 'HYPERVISORS=\"generic" \
		"aws kvm\" make ...') or with AWS_S3_URI_LIVEBUILD_ARTIFACTS" \
		"set to a space-delimited set of S3 URIs from which to fetch" \
		"previously built live-build artifacts."; exit 1; }
	./scripts/build-upgrade-image.sh $(variant)
	for ext in $(VM_ARTIFACTS) migration.tar.gz; do \
		if compgen -G "live-build/artifacts/$(variant)*$$$$ext"; then \
			cp live-build/artifacts/$(variant)*$$$$ext artifacts/ ; \
		fi ; \
	done
endef

#
# Produces rules for each variant. This will move the relevant artifacts
# produced by live-build into artifacts/ and create a single upgrade image per
# variant, consisting of all the packages needed to upgrade any of the
# hypervisor versions for that variant.
#
$(foreach variant, $(ALL_VARIANTS), \
    $(eval $(call STAGE2_RULE, $(variant))))

fetch-livebuild-artifacts:| live-build/artifacts
	./scripts/fetch-livebuild-artifacts.sh

ancillary-repository:
	./scripts/build-ancillary-repository.sh

shellcheck:
	shellcheck --exclude=SC1090,SC1091 $(SHELL_CHECKSTYLE_FILES)

#
# There doesn't appear to be a way to have "shfmt" return non-zero when
# it detects differences, so we have to be a little clever to accomplish
# this. Ultimately, we want "make" to fail when "shfmt" emits lines that
# need to be changed.
#
# When grep matches on lines emitted by "shfmt", it will return with a
# zero exit code. This tells us that "shfmt" did in fact detect changes
# that need to be made. When this occurs, we want "make" to fail, thus
# we have to invert grep's return code.
#
# This inversion also addresses the case where "shfmt" doesn't emit any
# lines. In this case, "grep" will return a non-zero exit code, so we
# invert this to cause "make" to succeed.
#
# Lastly, we want the lines emitted by "shfmt" to be user visible, so we
# leverage the fact that "grep" will emit any lines it matches on to
# stdout. This way, when lines are emitted from "shfmt", these
# problematic lines are conveyed to the user so they can be fixed.
#
shfmtcheck:
	! shfmt -d $(SHELL_CHECKSTYLE_FILES) | grep .

ansiblecheck:
	ansible-lint $$(find bootstrap live-build/variants -name playbook.yml)

check: shellcheck shfmtcheck ansiblecheck

shfmt:
	shfmt -w $(SHELL_CHECKSTYLE_FILES)

clean:
	if zpool list rpool &>/dev/null; then \
		zpool destroy -f rpool; \
	fi
	rm -rf ancillary-repository/ \
		artifacts/ \
		build/ \
		live-build/artifacts/ \
		live-build/build/ \
		upgrade/debs/ \
		upgrade/version.info
