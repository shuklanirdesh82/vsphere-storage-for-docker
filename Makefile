#
# Makefile for Docker data volume VMDK plugin
#
# Builds client-side (docker engine) volume plug in code, and ESX-side VIB
#

# Place binaries here
BIN := ./bin

# source locations for Make
ESX_SRC     := vmdkops-esxsrv # esx service for docker volume ops

#  binaries location
PLUGNAME  := docker-vmdk-plugin
PLUGIN_BIN = $(BIN)/$(PLUGNAME)

VIBFILE := vmware-esx-vmdkops-1.0.0.vib
VIB_BIN := $(BIN)/$(VIBFILE)

# plugin name, for go build
PLUGIN := github.com/vmware/$(PLUGNAME)

GO := GO15VENDOREXPERIMENT=1 go

# make sure we rebuild of vmkdops or Dockerfile change (since we develop them together)
VMDKOPS_MODULE := vmdkops
VMDKOPS_MODULE_SRC = $(VMDKOPS_MODULE)/*.go $(VMDKOPS_MODULE)/vmci/*.[ch]

# All sources. We rebuild if anything changes here
SRC = plugin.go main.go log_formatter.go

#  TargetprintNQuit

# The default build is using a prebuilt docker image that has all dependencies.
.PHONY: dockerbuild
dockerbuild:
	@./scripts/check.sh dockerbuild
	./scripts/build.sh build

# The non docker build.
.PHONY: build
build: prereqs code_verify $(PLUGIN_BIN) $(BIN)/$(VMDKOPS_MODULE).test $(BIN)/$(PLUGNAME).test
	@cd  $(ESX_SRC)  ; $(MAKE)  $@

.PHONY: prereqs
prereqs:
	@./scripts/check.sh

$(PLUGIN_BIN): $(SRC) $(VMDKOPS_MODULE_SRC)
	@-mkdir -p $(BIN)
	$(GO) build --ldflags '-extldflags "-static"' -o $(PLUGIN_BIN) $(PLUGIN)

$(BIN)/$(VMDKOPS_MODULE).test: $(VMDKOPS_MODULE_SRC) $(VMDKOPS_MODULE)/*_test.go
	$(GO) test -c -o $@ $(PLUGIN)/$(VMDKOPS_MODULE)

$(BIN)/$(PLUGNAME).test: $(SRC) *_test.go
	$(GO) test -c -o $@ $(PLUGIN)

.PHONY: clean
clean:
	rm -f $(BIN)/* .build_*
	@cd  $(ESX_SRC)  ; $(MAKE)  $@


# GO Code quality checks.

.PHONY: code_verify
code_verify: lint vet fmt

.PHONY: lint
lint:
	@echo "Running $@"
	${GOPATH}/bin/golint
	${GOPATH}/bin/golint vmdkops

.PHONY: vet
vet:
	@echo "Running $@"
	@go vet *.go
	@go vet vmdkops/*.go

.PHONY: fmt
fmt:
	@echo "Running $@"
	gofmt -s -l *.go
	gofmt -s -l vmdkops/*.go

#
# 'make deploy'
# ----------
# temporary goal to simplify my deployments and sanity check test (create/delete)
#
# expectations:
#   Need target machines (ESX/Guest) to have proper ~/.ssh/authorized_keys
#
# Usage:
# either pass the ESX and VM
# make deploy-esx root@10.20.105.54
# make deploy-vm root@10.20.105.121
# or edit the entries below

ESX? = root@10.20.105.54
VM?  = root@10.20.105.121
VM2? = $(VM1) # run tests only on one VM
SCP := scp -o StrictHostKeyChecking=no
SSH := ssh -kTax -o StrictHostKeyChecking=no

# bin locations on target guest
GLOC := /usr/local/bin


# vib install: we install by file name but remove by internal name
VIBNAME := vmware-esx-vmdkops-service
VIBCMD  := localcli software vib
SCRIPTS := ./scripts
STARTESX := startesx.sh
STOPESX  := stopesx.sh
STARTVM := startvm.sh
STOPVM  := stopvm.sh
STARTVM_LOC := $(SCRIPTS)/$(STARTVM)
STOPVM_LOC  := $(SCRIPTS)/$(STOPVM)
STARTESX_LOC := $(SCRIPTS)/$(STARTESX)
STOPESX_LOC  := $(SCRIPTS)/$(STOPESX)

.PHONY: deploy-esx
# ignore failures in copy to guest (can be busy) and remove vib (can be not installed)
deploy-esx:
	$(SCP) $(VIB_BIN) $(ESX):/tmp
	$(SCP) $(STARTESX_LOC) $(STOPESX_LOC) $(ESX):/tmp
	-$(SSH) $(ESX) "sh /tmp/$(STOPESX)"
	-$(SSH) $(ESX) $(VIBCMD) remove --vibname $(VIBNAME)
	$(SSH) $(ESX) $(VIBCMD) install --no-sig-check  -v /tmp/$(VIBFILE)
	$(SSH) $(ESX) "sh /tmp/$(STARTESX)"

.PHONY: deploy-vm
deploy-vm:
	$(SCP) $(BIN)/*.test $(VM):/tmp
	$(SCP) $(STARTVM_LOC) $(STOPVM_LOC) $(VM):/tmp/
	-$(SSH) $(VM) "sh /tmp/$(STOPVM) &"
	$(SCP) $(PLUGIN_BIN) $(VM):$(GLOC)
	$(SSH) $(VM) "sh /tmp/$(STARTVM) &"

.PHONY:deploy
deploy: deploy-esx deploy-vm
	@echo Done


#
# 'make test' or 'make testremote'
# CAUTION: FOR NOW, RUN testremote DIRECTLY VIA 'make'. DO NOT run via './build.sh'
#  reason: ssh keys for accessing remote hosts are not in container used by ./build.sh
# ----------


# this is a set of unit tests run on build machine
.PHONY: test
test:
	./scripts/build.sh testasroot

.PHONY: testasroot
testasroot:
	$(GO) test $(PLUGIN)/vmdkops

# does sanity check of create/remove docker volume on the guest
TEST_VOL_NAME?=MyVolume

VM1? = $(VM)

.PHONY: testremote
testremote:
	$(SSH) $(VM1) /tmp/$(PLUGNAME).test
	$(SSH) $(VM1) /tmp/$(VMDKOPS_MODULE).test
	$(SSH) $(VM1) docker volume create \
			--driver=vmdk --name=$(TEST_VOL_NAME) \
			-o size=1gb -o policy=good
	$(SSH) $(VM1) docker run --rm \
		-v $(TEST_VOL_NAME):/$(TEST_VOL_NAME) \
		busybox touch /$(TEST_VOL_NAME)/file
	$(SSH) $(VM2) docker run --rm \
		-v $(TEST_VOL_NAME):/$(TEST_VOL_NAME) \
		--volume-driver=vmdk busybox \
		stat /$(TEST_VOL_NAME)/file
	$(SSH) $(VM1) "docker volume ls | grep $(TEST_VOL_NAME)"
	$(SSH) $(VM2) "docker volume ls | grep $(TEST_VOL_NAME)"
	$(SSH) $(VM1) "docker volume inspect $(TEST_VOL_NAME)| grep Driver | grep vmdk"
	$(SSH) $(VM2) "docker volume inspect $(TEST_VOL_NAME)| grep Driver | grep vmdk"
	$(SSH) $(VM1) docker volume rm $(TEST_VOL_NAME)
	-$(SSH) $(VM1) "docker volume ls "
	-$(SSH) $(VM2) "docker volume ls "

.PHONY: clean-vm
clean-vm:
	-$(SCP) $(STOPVM_LOC) $(VM):/tmp/
	-$(SSH) $(VM) "sh /tmp/$(STOPVM)"
	-$(SSH) $(VM) rm $(GLOC)/$(PLUGNAME)
	-$(SSH) $(VM) rm \
		      /tmp/$(STARTVM) \
		      /tmp/$(STOPVM) \
		      /tmp/$(VMDKOPS_MODULE).test \
		      /tmp/$(PLUGNAME).test
	-$(SSH) $(VM) rm -rvf /mnt/vmdk/$(TEST_VOL_NAME)
	-$(SSH) $(VM) docker volume rm $(TEST_VOL_NAME)  # delete any local datavolumes
	-$(SSH) $(VM) rm -rvf /tmp/docker-volumes/
	-$(SSH) $(VM) service docker restart

.PHONY: clean-esx
clean-esx:
	-$(SCP) $(STOPESX_LOC) $(ESX):/tmp
	-$(SSH) $(ESX) "sh /tmp/$(STOPESX)"
	-$(SSH) $(ESX) "rm -v /tmp/$(STARTESX) /tmp/$(STOPESX)"
	-$(SSH) $(ESX) $(VIBCMD) remove --vibname $(VIBNAME)
	-$(SSH) $(ESX) "rm -v /tmp/$(VIBFILE)"
